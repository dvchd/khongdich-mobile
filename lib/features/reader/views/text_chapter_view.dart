import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/markdown/markdown.dart';

/// Text chapter view with two modes:
///   - **vertical** (default): traditional scroll
///   - **horizontal**: page-flip mode — content is split into pages
///     that fit the screen. Swipe left/right to turn pages. When the
///     last page is reached, swipe left advances to the next chapter.
class TextChapterView extends ConsumerStatefulWidget {
  const TextChapterView({
    super.key,
    required this.markdown,
    required this.theme,
    this.scrollController,
    this.onChapterEnd,
    this.onChapterStart,
    this.isPageMode = false,
  });

  final String markdown;
  final ReaderTheme theme;
  final ScrollController? scrollController;
  final VoidCallback? onChapterEnd;
  final VoidCallback? onChapterStart;
  final bool isPageMode;

  @override
  ConsumerState<TextChapterView> createState() => _TextChapterViewState();
}

class _TextChapterViewState extends ConsumerState<TextChapterView> {
  late List<Block> _blocks;
  List<List<Block>>? _pages;
  final _pageController = PageController();

  @override
  void initState() {
    super.initState();
    _blocks = MarkdownParser().parse(widget.markdown);
    if (widget.isPageMode) {
      _pages = _splitIntoPages(_blocks);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Split blocks into pages. Each page is a list of blocks that fits
  /// within one screen. The split is heuristic: heading or paragraph
  /// boundaries are preferred. For MVP, we put 3-5 blocks per page
  /// (adjustable). A proper implementation would measure text height
  /// with TextPainter, but that requires a LayoutBuilder + post-frame
  /// callback — too complex for this iteration.
  List<List<Block>> _splitIntoPages(List<Block> blocks) {
    if (blocks.isEmpty) return [[]];
    final pages = <List<Block>>[];
    var current = <Block>[];
    var blockCount = 0;

    for (final block in blocks) {
      current.add(block);
      blockCount++;

      // Heuristic: start a new page after ~5 blocks or after a heading.
      final shouldBreak = blockCount >= 5 ||
          (block is Heading && current.length > 1);
      if (shouldBreak) {
        pages.add(current);
        current = [];
        blockCount = 0;
      }
    }
    if (current.isNotEmpty) pages.add(current);
    return pages.isEmpty ? [[]] : pages;
  }

  void _onPageChanged(int page) {
    if (widget.isPageMode && _pages != null) {
      if (page == _pages!.length - 1) {
        // Last page — next swipe will advance to next chapter.
        widget.onChapterEnd?.call();
      } else if (page == 0) {
        widget.onChapterStart?.call();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isPageMode && _pages != null) {
      return _buildPageMode();
    }
    return _buildScrollMode();
  }

  Widget _buildScrollMode() {
    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: MarkdownRenderer(blocks: _blocks, theme: widget.theme),
    );
  }

  Widget _buildPageMode() {
    return PageView.builder(
      controller: _pageController,
      itemCount: _pages!.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) {
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MarkdownRenderer(
                blocks: _pages![index],
                theme: widget.theme,
              ),
              // Page indicator at the bottom
              const SizedBox(height: 32),
              Center(
                child: Text(
                  '${index + 1}/${_pages!.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: widget.theme.bodyStyle.color
                        ?.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
