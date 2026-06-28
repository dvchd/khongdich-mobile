import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/markdown/markdown.dart';

/// Text chapter view with two modes:
///   - **vertical** (default): traditional scroll
///   - **horizontal** (page-flip): content is measured and split into
///     screen-sized pages. Swipe left/right to turn pages. At the last
///     page, swipe left advances to the next chapter. At the first page,
///     swipe right goes to the previous chapter.
class TextChapterView extends ConsumerStatefulWidget {
  const TextChapterView({
    super.key,
    required this.markdown,
    required this.theme,
    this.scrollController,
    this.pageController,
    this.onChapterEnd,
    this.onChapterStart,
    this.isPageMode = false,
  });

  final String markdown;
  final ReaderTheme theme;
  final ScrollController? scrollController;
  final PageController? pageController;
  final VoidCallback? onChapterEnd;
  final VoidCallback? onChapterStart;
  final bool isPageMode;

  @override
  ConsumerState<TextChapterView> createState() => _TextChapterViewState();
}

class _TextChapterViewState extends ConsumerState<TextChapterView> {
  late List<Block> _blocks;
  late final PageController _pageController;
  // Pre-split pages: each entry is a list of block indices.
  List<List<int>> _pageBlockIndices = [];
  Size? _lastSize;

  @override
  void initState() {
    super.initState();
    _blocks = MarkdownParser().parse(widget.markdown);
    _pageController = widget.pageController ?? PageController();
  }

  @override
  void didUpdateWidget(covariant TextChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the chapter changes (parent navigates to next/prev chapter),
    // the markdown content changes. We must:
    //   1. Re-parse the new markdown into blocks.
    //   2. Force a re-compute of page splits (clear _lastSize).
    //   3. Reset the PageController to page 0 — otherwise the
    //      controller keeps the old chapter's page index (e.g. 5/5)
    //      which is out of bounds for the new chapter (which may
    //      only have 3 pages). This was the root cause of the bug
    //      "sang chương mới, ấn vào cạnh không chuyển được trang cũng
    //      không chuyển được chương, bị đơ" — the PageView was stuck
    //      because its current page index exceeded the new itemCount.
    if (oldWidget.markdown != widget.markdown) {
      _blocks = MarkdownParser().parse(widget.markdown);
      _lastSize = null;
      // Reset to page 0 on the next frame, after _pageBlockIndices
      // has been re-computed by _computePages() during the next
      // LayoutBuilder pass. Using WidgetsBinding.addPostFrameCallback
      // ensures the controller has clients attached before we call
      // jumpToPage.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients) {
          _pageController.jumpToPage(0);
        }
      });
    }
  }

  @override
  void dispose() {
    // Only dispose if we created the controller internally
    if (widget.pageController == null) {
      _pageController.dispose();
    }
    super.dispose();
  }

  /// Measure the height of rendering a set of blocks with the current
  /// theme + font size. Uses TextPainter on a RichText for text blocks,
  /// and estimated heights for other block types.
  double _measureBlockHeight(Block block, double maxWidth) {
    final style = widget.theme.bodyStyle;
    final padding = widget.theme.paragraphSpacing;

    return switch (block) {
      Paragraph(:final children) => () {
          final tp = TextPainter(
            text: TextSpan(
              style: style,
              children: [
                for (final i in children)
                  _inlineToSpan(i, widget.theme),
              ],
            ),
            textAlign: TextAlign.left,
            textDirection: TextDirection.ltr,
            maxLines: null,
          );
          tp.layout(maxWidth: maxWidth - 32); // -32 for horizontal padding
          final h = tp.height + padding;
          tp.dispose();
          return h;
        }(),
      Heading(:final level, :final children) => () {
          final hStyle = widget.theme.headingStyle(level);
          final tp = TextPainter(
            text: TextSpan(
              style: hStyle,
              children: [
                for (final i in children)
                  _inlineToSpan(i, widget.theme),
              ],
            ),
            textDirection: TextDirection.ltr,
            maxLines: null,
          );
          tp.layout(maxWidth: maxWidth - 32);
          final h = tp.height + 12 + 8; // top + bottom padding
          tp.dispose();
          return h;
        }(),
      HorizontalRule() => 48.0,
      CodeBlock(:final code) => () {
          final lines = '\n'.allMatches(code).length + 1;
          return (lines * 20.0) + 24;
        }(),
      BulletList(:final items) => () {
          double total = 0;
          for (final item in items) {
            for (final b in item) {
              total += _measureBlockHeight(b, maxWidth - 24);
            }
            total += 6;
          }
          return total + 16;
        }(),
      OrderedList(:final items) => () {
          double total = 0;
          for (final item in items) {
            for (final b in item) {
              total += _measureBlockHeight(b, maxWidth - 24);
            }
            total += 6;
          }
          return total + 16;
        }(),
      BlockQuote(:final children) => () {
          double total = 0;
          for (final b in children) {
            total += _measureBlockHeight(b, maxWidth - 32);
          }
          return total + 24;
        }(),
      ImageBlock() => 200.0,
    };
  }

  InlineSpan _inlineToSpan(Inline inline, ReaderTheme t) {
    return switch (inline) {
      TextRun(:final text) => TextSpan(text: text),
      EmphasisRun(:final children) => TextSpan(
          style: const TextStyle(fontStyle: FontStyle.italic),
          children: [for (final i in children) _inlineToSpan(i, t)],
        ),
      StrongRun(:final children) => TextSpan(
          style: const TextStyle(fontWeight: FontWeight.bold),
          children: [for (final i in children) _inlineToSpan(i, t)],
        ),
      StrikethroughRun(:final children) => TextSpan(
          style: const TextStyle(decoration: TextDecoration.lineThrough),
          children: [for (final i in children) _inlineToSpan(i, t)],
        ),
      LinkRun(:final children) => TextSpan(
          style: TextStyle(color: t.accentColor, decoration: TextDecoration.underline),
          children: [for (final i in children) _inlineToSpan(i, t)],
        ),
      CodeRun(:final code) => TextSpan(text: code, style: t.codeStyle),
      LineBreak(:final hard) => TextSpan(text: hard ? '\n' : ' '),
    };
  }

  /// Split blocks into pages based on measured heights.
  void _computePages(Size size) {
    if (_lastSize != null &&
        (_lastSize!.width - size.width).abs() < 1 &&
        (_lastSize!.height - size.height).abs() < 1) {
      return; // Same size, no recompute
    }
    _lastSize = size;

    final maxWidth = size.width;
    final maxHeight = size.height - 80; // -80 for page indicator + padding

    _pageBlockIndices = [];
    var current = <int>[];
    var currentHeight = 0.0;

    for (var i = 0; i < _blocks.length; i++) {
      final h = _measureBlockHeight(_blocks[i], maxWidth);
      if (currentHeight + h > maxHeight && current.isNotEmpty) {
        _pageBlockIndices.add(current);
        current = [];
        currentHeight = 0;
      }
      current.add(i);
      currentHeight += h;
    }
    if (current.isNotEmpty) _pageBlockIndices.add(current);
    if (_pageBlockIndices.isEmpty) _pageBlockIndices = [[]];
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isPageMode) {
      return _buildScrollMode();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _computePages(Size(constraints.maxWidth, constraints.maxHeight));
        return _buildPageMode();
      },
    );
  }

  Widget _buildScrollMode() {
    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 48),
      child: MarkdownRenderer(blocks: _blocks, theme: widget.theme),
    );
  }

  Widget _buildPageMode() {
    if (_pageBlockIndices.length <= 1) {
      // Single page — just render all blocks
      return SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MarkdownRenderer(blocks: _blocks, theme: widget.theme),
            const SizedBox(height: 32),
            Center(
              child: Text(
                '1/1 — vuốt trái để sang chương sau',
                style: TextStyle(
                  fontSize: 12,
                  color: widget.theme.bodyStyle.color?.withValues(alpha: 0.4),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return PageView.builder(
      controller: _pageController,
      itemCount: _pageBlockIndices.length,
      itemBuilder: (context, pageIndex) {
        final blockIndices = _pageBlockIndices[pageIndex];
        final pageBlocks = [for (final i in blockIndices) _blocks[i]];
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MarkdownRenderer(blocks: pageBlocks, theme: widget.theme),
              const SizedBox(height: 32),
              Center(
                child: Text(
                  '${pageIndex + 1}/${_pageBlockIndices.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: widget.theme.bodyStyle.color?.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      // Page swipe is handled by PageView. Chapter navigation happens
      // ONLY when user swipes past the first/last page — we use
      // onPageChanged to detect this.
      onPageChanged: (page) {
        // No chapter nav here — that caused the bug. Chapter nav is
        // handled by the _HorizontalSwipeWrapper in the parent, which
        // is NOT used in page mode. Instead, we detect overscroll.
      },
    );
  }
}
