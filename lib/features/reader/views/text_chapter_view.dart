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
  });

  final String markdown;
  final ReaderTheme theme;
  final String chapterId;
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

  // TTS highlight state.
  StreamSubscription<TtsChunkProgress>? _ttsSub;
  StreamSubscription<PlaybackState>? _playbackSub;
  int? _activeBlockIndex;
  // Cache of normalized plain text per block — computing it on every chunk
  // event would be wasteful since blocks don't change between chunks.
  late List<String> _blockPlainTextCache;
  // Monotonic cursor: _findBlockForChunk only searches from this index
  // forward, so the highlight never jumps backwards. Reset in
  // didUpdateWidget when the chapter changes.
  int _searchFromBlock = 0;
  // Content width captured from LayoutBuilder in scroll mode — needed
  // by _measureBlockHeight for accurate scroll offset calculation.
  // In page mode, _lastSize.width is used instead.
  double? _scrollModeWidth;

  @override
  void initState() {
    super.initState();
    _blocks = MarkdownParser().parse(widget.markdown);
    _blockPlainTextCache = [for (final b in _blocks) _normalize(b.plainText)];
    _pageController = widget.pageController ?? PageController();
    // Subscribe to TTS chunk progress. We'll filter by chapterId in the
    // listener so a different chapter's TTS doesn't trigger a highlight
    // here. The subscription is set up after the first frame so that
    // `ref.read(ttsHandlerProvider.future)` doesn't block initState.
    Future.microtask(() async {
      try {
        final handler = await ref.read(ttsHandlerProvider.future);
        if (!mounted) return;
        _ttsSub = handler.chunkProgress.listen(_onChunkProgress);
        // Also listen to playbackState so we can clear the highlight
        // when TTS stops, completes, or errors. Without this, the yellow
        // tint stays on the last block forever after TTS finishes.
        _playbackSub = handler.playbackState.listen(_onPlaybackState);
        // If TTS is already mid-chapter for THIS chapter when we mount,
        // highlight the current block immediately.
        if (handler.currentChapterId == widget.chapterId &&
            handler.currentChunkIndex >= 0 &&
            handler.chunks.isNotEmpty) {
          _applyChunk(handler.currentChunkIndex, handler.chunks);
        }
      } catch (_) {
        // TTS init may fail — silently ignore; the reader still works.
      }
    });
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
      _blockPlainTextCache = [for (final b in _blocks) _normalize(b.plainText)];
      _lastSize = null;
      // Clear highlight + reset monotonic cursor when chapter changes —
      // the new chunk event for the new chapter will set a fresh
      // highlight starting from block 0.
      _activeBlockIndex = null;
      _searchFromBlock = 0;
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
          ),
        );
      },
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
            MarkdownRenderer(
              blocks: _blocks,
              theme: widget.theme,
              activeBlockIndex: _activeBlockIndex,
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
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MarkdownRenderer(
                blocks: pageBlocks,
                theme: widget.theme,
                activeBlockIndex: localActive,
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
    final handler = ref.read(ttsHandlerProvider).valueOrNull;
    if (handler == null) return;
    _applyChunk(p.chunkIndex, handler.chunks);
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
          _searchFromBlock = 0;
        });
      }
    }
  }

  void _applyChunk(int chunkIndex, List<String> chunks) {
    if (chunkIndex < 0 || chunkIndex >= chunks.length) return;
    final chunkText = chunks[chunkIndex];
    final newActive = _findBlockForChunk(chunkText);
    if (newActive == _activeBlockIndex) return;
    // Advance the monotonic cursor so future chunk searches only look
    // forward — prevents the highlight from jumping backwards if a
    // later chunk's text happens to match an earlier block.
    if (newActive != null) {
      _searchFromBlock = newActive;
    }
    setState(() => _activeBlockIndex = newActive);
    // After the next frame (so the renderer has laid out the new
    // highlighted block), scroll or page-flip to keep it in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollOrFlipToActive();
    });
  }

  /// Find which block the TTS chunk starts in.
  ///
  /// Strategy: take the first 40 chars of the chunk's normalized plain
  /// text as a "fingerprint", then walk through blocks comparing their
  /// normalized plain text's first chars. The chunk's first chars should
  /// match the block it starts in (the TTS preprocessor splits on
  /// paragraph boundaries, so each chunk typically begins at a block
  /// boundary). Returns null if no match — happens for chunks that
  /// span only horizontal rules or stripped code blocks.
  int? _findBlockForChunk(String chunkText) {
    final needle = _normalize(chunkText);
    if (needle.length < 5) return null;
    final fingerprint = needle.substring(0, needle.length.clamp(0, 40));

    // Pass 1: prefix match — chunk's first chars match block's first chars.
    // This handles the common case where the chunk starts at a block
    // boundary (paragraph, heading, list item, etc.).
    //
    // Monotonic: search from _searchFromBlock forward so the highlight
    // never jumps backwards. This prevents a false match when a later
    // chunk's text coincidentally matches an earlier block.
    for (var i = _searchFromBlock; i < _blockPlainTextCache.length; i++) {
      final blockText = _blockPlainTextCache[i];
      if (blockText.isEmpty) continue;
      final cmpLen = fingerprint.length < blockText.length
          ? fingerprint.length
          : blockText.length;
      if (cmpLen < 5) continue;
      if (fingerprint.substring(0, cmpLen) == blockText.substring(0, cmpLen)) {
        return i;
      }
    }

    // Pass 2: substring match — chunk's first 20 chars appear inside the
    // block. This handles the case where the chunk starts mid-block
    // (rare — happens when a long paragraph is split into multiple chunks
    // by the preprocessor's 500-char limit).
    // Also monotonic — search from _searchFromBlock forward.
    final short = fingerprint.substring(0, fingerprint.length.clamp(0, 20));
    if (short.length < 5) return null;
    for (var i = _searchFromBlock; i < _blockPlainTextCache.length; i++) {
      final blockText = _blockPlainTextCache[i];
      if (blockText.contains(short)) return i;
    }

    // Pass 3 (fallback): search backward up to 3 blocks. Handles the
    // edge case where a null match advanced the chunk but not the
    // cursor, and the next chunk legitimately belongs to an earlier
    // block (e.g. code blocks stripped from TTS, horizontal rules with
    // empty plain text). Without this fallback the highlight would be
    // lost for those blocks.
    final backStart = (_searchFromBlock - 3).clamp(
      0,
      _blockPlainTextCache.length,
    );
    for (var i = _searchFromBlock - 1; i >= backStart; i--) {
      final blockText = _blockPlainTextCache[i];
      if (blockText.isNotEmpty && blockText.contains(short)) return i;
    }
    return null;
  }

  /// Normalize whitespace for fuzzy text matching: collapse runs of
  /// whitespace into a single space and trim. Case is preserved because
  /// Vietnamese diacritics make case-insensitive matching tricky on
  /// some engines.
  String _normalize(String s) {
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
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
