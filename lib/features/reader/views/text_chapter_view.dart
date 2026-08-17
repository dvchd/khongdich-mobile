import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/markdown/markdown.dart';
import '../../tts/tts_audio_handler.dart';

/// Text chapter view with two modes:
///   - **vertical** (default): traditional scroll
///   - **horizontal** (page-flip): content is measured and split into
///     screen-sized pages. Swipe left/right to turn pages. At the last
///     page, swipe left advances to the next chapter. At the first page,
///     swipe right goes to the previous chapter.
///
/// When TTS is active for THIS chapter, the block being read is highlighted
/// with a yellow tint and the view auto-scrolls (or page-flips) to keep
/// that block visible. The bottom TtsMiniPlayer bar was removed because
/// taps on it were intercepted by the reader's tap-zones overlay (which
/// navigated chapters or opened settings) — see ReaderBody.
class TextChapterView extends ConsumerStatefulWidget {
  const TextChapterView({
    super.key,
    required this.markdown,
    required this.theme,
    required this.chapterId,
    this.scrollController,
    this.pageController,
    this.onChapterEnd,
    this.onChapterStart,
    this.isPageMode = false,
    this.onParagraphLongPress,
  });

  final String markdown;
  final ReaderTheme theme;
  final String chapterId;
  final ScrollController? scrollController;
  final PageController? pageController;
  final VoidCallback? onChapterEnd;
  final VoidCallback? onChapterStart;
  final bool isPageMode;

  /// Long-press on a paragraph block — normalized plain text payload
  /// (used by bình luận đoạn).
  final void Function(String plainText)? onParagraphLongPress;

  @override
  ConsumerState<TextChapterView> createState() => _TextChapterViewState();
}

class _TextChapterViewState extends ConsumerState<TextChapterView> {
  late List<Block> _blocks;
  late final PageController _pageController;
  // Pre-split pages: each entry is a list of block indices.
  List<List<int>> _pageBlockIndices = [];
  Size? _lastSize;

  // TTS highlight state.
  TtsAudioHandler? _handler;
  StreamSubscription<TtsChunkProgress>? _ttsSub;
  StreamSubscription<PlaybackState>? _playbackSub;
  int? _activeBlockIndex;
  // Content width captured from LayoutBuilder in scroll mode — needed
  // by _measureBlockHeight for accurate scroll offset calculation.
  // In page mode, _lastSize.width is used instead.
  double? _scrollModeWidth;

  @override
  void initState() {
    super.initState();
    _blocks = MarkdownParser().parse(widget.markdown);
    _pageController = widget.pageController ?? PageController();
    // Subscribe to TTS chunk progress. We'll filter by chapterId in the
    // listener so a different chapter's TTS doesn't trigger a highlight
    // here. The subscription is set up after the first frame so that
    // `ref.read(ttsHandlerProvider.future)` doesn't block initState.
    Future.microtask(() async {
      try {
        final handler = await ref.read(ttsHandlerProvider.future);
        if (!mounted) return;
        _handler = handler;
        _ttsSub = handler.chunkProgress.listen(_onChunkProgress);
        // Also listen to playbackState so we can clear the highlight
        // when TTS stops, completes, or errors. Without this, the yellow
        // tint stays on the last block forever after TTS finishes.
        _playbackSub = handler.playbackState.listen(_onPlaybackState);
        // If TTS is already serving THIS chapter when we mount (đang nghe
        // hoặc đang load — kể cả trở lại chương đang nghe sau khi đọc
        // chương khác), highlight + scroll về đúng đoạn đang nghe ngay,
        // không đợi chunk progress tiếp theo (có thể mất hàng chục giây).
        _applyFromHandlerState();
      } catch (_) {
        // TTS init may fail — silently ignore; the reader still works.
      }
    });
  }

  @override
  void didUpdateWidget(covariant TextChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Khi theme settings (font/size/line height) đổi, chiều cao block
    // đổi theo → phải tính lại page split. _computePages chỉ cache theo
    // kích thước màn hình nên trước đây đổi font không làm mới phân
    // trang → page dùng split cũ trong khi text thật cao hơn/thấp hơn.
    final themeChanged = _themeFingerprint(oldWidget.theme) !=
        _themeFingerprint(widget.theme);
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
      // Clear highlight when chapter changes — the new chunk event for
      // the new chapter will set a fresh highlight starting from block 0.
      _activeBlockIndex = null;
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
    } else if (themeChanged) {
      _lastSize = null;
    }
  }

  /// Fingerprint các yếu tố ảnh hưởng chiều cao đo được — đổi bất kỳ
  /// giá trị nào cũng phải làm mới page split.
  String _themeFingerprint(ReaderTheme t) {
    final style = t.bodyStyle;
    return '${style.fontSize}|${style.height}|${style.fontFamily}';
  }

  @override
  void dispose() {
    _ttsSub?.cancel();
    _playbackSub?.cancel();
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
              for (final i in children) _inlineToSpan(i, widget.theme),
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
              for (final i in children) _inlineToSpan(i, widget.theme),
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
        style: TextStyle(
          color: t.accentColor,
          decoration: TextDecoration.underline,
        ),
        children: [for (final i in children) _inlineToSpan(i, t)],
      ),
      CodeRun(:final code) => TextSpan(text: code, style: t.codeStyle),
      LineBreak(:final hard) => TextSpan(text: hard ? '\n' : ' '),
    };
  }

  /// Split blocks into pages based on measured heights.
  ///
  /// Blocks taller than a full page are placed on their own page —
  /// the SingleChildScrollView inside each PageView page will scroll
  /// vertically to reveal the rest. This is better than the old behavior
  /// which would push a tall block to the next page, leaving the current
  /// page mostly empty.
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
        // Current page is full — flush it and start a new page.
        _pageBlockIndices.add(current);
        current = [];
        currentHeight = 0;
      }
      // Add block to current page. If the block itself is taller than
      // maxHeight, it gets its own page and the SingleChildScrollView
      // inside the page will allow vertical scrolling to see the rest.
      // This avoids leaving large blank space on the previous page.
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
    // Wrap in LayoutBuilder to capture the content width so
    // _scrollOrFlipToActive can measure block heights accurately.
    // Without this, we'd have no way to compute the correct scroll
    // offset (ScrollController.position.viewportDimension returns
    // the HEIGHT for a vertical scroll, not the width).
    return LayoutBuilder(
      builder: (context, constraints) {
        _scrollModeWidth = constraints.maxWidth;
        return SingleChildScrollView(
          controller: widget.scrollController,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 48),
          child: MarkdownRenderer(
            blocks: _blocks,
            theme: widget.theme,
            activeBlockIndex: _activeBlockIndex,
            onParagraphLongPress: widget.onParagraphLongPress,
          ),
        );
      },
    );
  }

  Widget _buildPageMode() {
    if (_pageBlockIndices.length <= 1) {
      // Single page — just render all blocks, allow scroll if content
      // is taller than viewport.
      return SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MarkdownRenderer(
              blocks: _blocks,
              theme: widget.theme,
              activeBlockIndex: _activeBlockIndex,
              onParagraphLongPress: widget.onParagraphLongPress,
            ),
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
        // Convert the global active block index to a local index within
        // this page's block list. The renderer highlights by local index.
        final localActive =
            (_activeBlockIndex != null &&
                blockIndices.contains(_activeBlockIndex))
            ? blockIndices.indexOf(_activeBlockIndex!)
            : null;
        return SingleChildScrollView(
          // Allow vertical scrolling for pages with tall blocks that
          // exceed the viewport height. Previously NeverScrollable caused
          // tall blocks to be clipped with no way to see the rest.
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MarkdownRenderer(
              blocks: pageBlocks,
              theme: widget.theme,
              activeBlockIndex: localActive,
              onParagraphLongPress: widget.onParagraphLongPress,
            ),
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

  // ─── TTS highlight + auto-scroll/page-flip ─────────────────────────
  //
  // When the TTS handler emits a chunk progress event for THIS chapter,
  // we look up the chunk's text and find which rendered Block it starts
  // in. That block becomes "active" — the renderer wraps it in a yellow
  // tint — and we auto-scroll (vertical mode) or page-flip (horizontal
  // mode) to keep it visible.

  void _onChunkProgress(TtsChunkProgress p) {
    if (!mounted) return;
    // Ignore chunks for other chapters — they shouldn't highlight here.
    if (p.chapterId != widget.chapterId) {
      if (_activeBlockIndex != null) {
        setState(() => _activeBlockIndex = null);
      }
      return;
    }
    _applyBlock(p.blockIndex);
  }

  /// Listen to playbackState changes so we can clear the highlight when
  /// TTS stops, completes, or errors. Without this, the yellow tint
  /// stays on the last block forever after TTS finishes — the user
  /// would think TTS is still reading.
  void _onPlaybackState(PlaybackState state) {
    if (!mounted) return;
    final s = state.processingState;
    if (s == AudioProcessingState.idle ||
        s == AudioProcessingState.error ||
        s == AudioProcessingState.completed) {
      if (_activeBlockIndex != null) {
        setState(() {
          _activeBlockIndex = null;
        });
      }
      return;
    }
    // TTS quay lại phục vụ chương này (play lại sau stop, hoặc mount lúc
    // buffering bỏ lỡ fallback) → khôi phục highlight nếu đang trống.
    if (s == AudioProcessingState.ready && _activeBlockIndex == null) {
      _applyFromHandlerState();
    }
  }

  /// Highlight + scroll về đúng đoạn TTS đang phục vụ cho CHƯƠNG NÀY
  /// (đọc trực tiếp từ state handler — không chờ chunk progress event).
  /// Chỉ áp dụng khi handler thực sự đang serving (ready hoặc buffering)
  /// — sau stop/dismiss (idle) thì KHÔNG tô vàng lại.
  void _applyFromHandlerState() {
    final handler = _handler;
    if (handler == null) return;
    if (handler.currentChapterId != widget.chapterId) return;
    final s = handler.playbackState.value.processingState;
    if (s != AudioProcessingState.ready &&
        s != AudioProcessingState.buffering) {
      return;
    }
    if (handler.currentChunkIndex < 0 || handler.chunkModels.isEmpty) return;
    // Bound check: chunkIndex có thể trỏ ra ngoài danh sách chunk sau khi
    // nội dung chương được cập nhật (ít chunk hơn) — trước đây RangeError
    // bị catch (_) nuốt lặng lẽ.
    final index = handler.currentChunkIndex;
    if (index >= handler.chunkModels.length) return;
    final chunk = handler.chunkModels[index];
    _applyBlock(
      chunk.blocks.isEmpty ? -1 : chunk.blocks.first.blockIndex,
    );
  }

  /// Highlight the exact block being spoken. [blockIndex] comes straight
  /// from the block-aligned TTS chunker — no text matching, so the
  /// highlight can never drift to the wrong paragraph. `-1` (chunk maps
  /// to no block) CLEARS the highlight — trước đây -1 return sớm làm
  /// highlight vàng dính ở block trước đó.
  void _applyBlock(int blockIndex) {
    if (blockIndex < 0) {
      if (_activeBlockIndex != null) {
        setState(() => _activeBlockIndex = null);
      }
      return;
    }
    if (blockIndex >= _blocks.length) return;
    if (blockIndex == _activeBlockIndex) return;
    setState(() => _activeBlockIndex = blockIndex);
    // After the next frame (so the renderer has laid out the new
    // highlighted block), scroll or page-flip to keep it in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollOrFlipToActive();
    });
  }

  /// Auto-scroll (vertical mode) or page-flip (horizontal mode) so the
  /// active block stays visible. Called after `_activeBlockIndex`
  /// changes and the renderer has laid out the new highlighted block.
  void _scrollOrFlipToActive() {
    final active = _activeBlockIndex;
    if (active == null) return;

    if (widget.isPageMode) {
      // Page mode: find the page containing the active block, then
      // animate to it. We avoid animateToPage when already on the
      // target page (no-op) to prevent jitter.
      if (!_pageController.hasClients) return;
      for (var p = 0; p < _pageBlockIndices.length; p++) {
        if (_pageBlockIndices[p].contains(active)) {
          final current = _pageController.page?.round() ?? 0;
          if (current != p) {
            _pageController.animateToPage(
              p,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
            );
          }
          return;
        }
      }
    } else {
      // Scroll mode: compute the cumulative height of all blocks
      // BEFORE the active one, then scroll so that block is in the
      // upper third of the viewport. We use the same measurement
      // function that powers page splitting so the offsets match.
      final controller = widget.scrollController;
      if (controller == null || !controller.hasClients) return;
      // Use the content width captured by LayoutBuilder in
      // _buildScrollMode. Falls back to MediaQuery screen width if
      // not yet captured (e.g. auto-scroll fires before the first
      // LayoutBuilder pass). Previously this used
      // `controller.position.viewportDimension` which returns the
      // HEIGHT for a vertical scroll — causing text to wrap at the
      // wrong width and block heights to be completely wrong.
      final contentWidth =
          _scrollModeWidth ?? MediaQuery.of(context).size.width;
      double offset = 0;
      for (var i = 0; i < active && i < _blocks.length; i++) {
        offset += _measureBlockHeight(_blocks[i], contentWidth);
      }
      // Subtract a small top padding so the highlighted block isn't
      // flush against the AppBar — bring it to roughly the upper third.
      final target = (offset - 80).clamp(
        0.0,
        controller.position.maxScrollExtent,
      );
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
  }
}
