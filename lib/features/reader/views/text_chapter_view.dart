import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/markdown/markdown.dart';
import '../../../models/chapter_content.dart';
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
    this.footer,
    this.header,
    this.nextChapter,
    this.onContinue,
    this.continueHint,
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

  /// Widget đặt cuối nội dung CHẾ ĐỘ CUỘN DỌC (block "Hết chương —
  /// Chương kế tiếp") — nằm trong luồng scroll nên không che chữ cuối.
  final Widget? footer;

  /// Widget đặt đầu nội dung CHẾ ĐỘ CUỘN DỌC (header "Ch. N: Title" +
  /// meta chia sẻ/báo cáo) — cuộn xuống là trôi đi như web mobile.
  final Widget? header;

  /// Chương kế tiếp (ghost): sau block "Hết chương", nội dung chương sau
  /// được render NGAY TIẾP trong luồng scroll — cuộn tới là thấy dần
  /// (giống web đọc truyện cuộn liên tục). Khi ghost trượt lên qua ~45%
  /// viewport → [onContinue] để parent route-replace sang chương sau
  /// (đã prefetch nên không flash). Chỉ áp dụng CHẾ ĐỘ CUỘN DỌC.
  final ChapterContent? nextChapter;

  /// Fired MỘT LẦN khi ghost chương kế trượt qua ngưỡng chuyển chương.
  final VoidCallback? onContinue;

  /// Gợi ý nhỏ hiển thị dưới footer khi ghost chưa sẵn sàng ("Đang tải
  /// chương kế tiếp…" / "Chương kế tiếp không tải được") — không ngưỡng,
  /// không key, nút chương kế vẫn dùng được.
  final String? continueHint;

  @override
  ConsumerState<TextChapterView> createState() => _TextChapterViewState();
}

class _TextChapterViewState extends ConsumerState<TextChapterView> {
  late List<Block> _blocks;
  late final PageController _pageController;
  // Pre-split pages: each entry is a list of indices vào [_pageBlocks]
  // (khác [_blocks]: _pageBlocks đã chẻ paragraph quá cao thành nhiều
  // paragraph con — xem _computePages).
  List<List<int>> _pageBlockIndices = [];
  /// Block đã chẻ dùng để dựng trang (page mode).
  List<Block> _pageBlocks = [];
  /// Với mỗi index trong [_pageBlocks], index GỐC của block trong
  /// [_blocks] — TTS highlight + tìm trang theo block gốc vẫn đúng.
  List<int> _pageBlockOriginalIndex = [];
  /// Trang nào còn chứa block cao hơn 1 trang (code block, ảnh, quote
  /// dài, inline phức tạp…) thì trang đó mới được phép scroll dọc.
  List<bool> _pageHasOversized = [];
  Size? _lastSize;

  // Header chương ("Ch. N: Title" + meta) ở ĐẦU TRANG 1 của page mode —
  // đo chiều cao thật sau frame đầu rồi trừ đúng phần đó khỏi capacity
  // trang 1 khi phân trang (các trang sau giữ nguyên độ cao đọc).
  double _pageHeaderHeight = 0;
  final GlobalKey _pageHeaderKey = GlobalKey();
  bool _pageHeaderMeasured = false;

  // TTS highlight state.
  TtsAudioHandler? _handler;
  StreamSubscription<TtsChunkProgress>? _ttsSub;
  StreamSubscription<PlaybackState>? _playbackSub;
  /// Listenable highlight — renderer lắng nghe để chỉ rebuild block
  /// active cũ + mới thay vì setState rebuild cả chương mỗi chunk TTS.
  final ValueNotifier<int?> _activeBlock = ValueNotifier<int?>(null);
  int? get _activeBlockIndex => _activeBlock.value;
  // Content width captured from LayoutBuilder in scroll mode — needed
  // by _measureBlockHeight for accurate scroll offset calculation.
  // In page mode, _lastSize.width is used instead.
  double? _scrollModeWidth;

  /// Cache chiều cao block đã đo — key `(blockIndex, maxWidth)`. Trước
  /// đây mỗi lần TTS chunk advance, `_scrollOrFlipToActive` đo lại TẤT
  /// CẢ block từ đầu chương tới block active bằng TextPainter mới → O(n)
  /// layout mỗi chunk (chương dài + TTS đang đọc = jank kép với rebuild).
  final Map<String, double> _heightCache = {};

  // Ghost "cuộn hết chương → hiện chương sau": key đo vị trí ghost trong
  // scroll + cờ chống fire nhiều lần cho cùng một chương.
  final GlobalKey _ghostKey = GlobalKey();
  bool _continueFired = false;

  /// Ngưỡng chuyển: khi top của ghost trượt lên qua ~45% viewport nghĩa
  /// là user đã chủ động tiếp tục đọc sang chương sau → route-replace.
  static const double _continueThreshold = 0.45;

  @override
  void initState() {
    super.initState();
    _blocks = MarkdownParser().parse(widget.markdown);
    _pageController = widget.pageController ?? PageController();
    widget.scrollController?.addListener(_maybeContinueToNext);
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
      _heightCache.clear();
      // Đổi chương → header đổi tiêu đề → đo lại chiều cao trang 1.
      _pageHeaderMeasured = false;
      _pageHeaderHeight = 0;
      // Chương mới → ghost mới → cho phép gọi onContinue lại.
      _continueFired = false;
      // Clear highlight when chapter changes — the new chunk event for
      // the new chapter will set a fresh highlight starting from block 0.
      _activeBlock.value = null;
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
      // Chiều cao block phụ thuộc font/size/line-height → đo lại.
      _heightCache.clear();
      // Header chương (chữ lớn hơn/nhỏ hơn) cũng cao/thấp theo font →
      // đo lại reserve trang 1 (page mode).
      _pageHeaderMeasured = false;
      _pageHeaderHeight = 0;
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
    widget.scrollController?.removeListener(_maybeContinueToNext);
    _ttsSub?.cancel();
    _playbackSub?.cancel();
    _activeBlock.dispose();
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

  /// [_measureBlockHeight] có cache theo (blockIndex, maxWidth) — dùng
  /// cho các vòng lặp đo lặp lại (page split, auto-scroll TTS).
  double _measureBlockHeightCached(int index, Block block, double maxWidth) {
    final key = '$index|${maxWidth.toStringAsFixed(1)}';
    final cached = _heightCache[key];
    if (cached != null) return cached;
    final h = _measureBlockHeight(block, maxWidth);
    _heightCache[key] = h;
    return h;
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
  /// Bước 1: chẻ paragraph thuần text quá cao (cao hơn 1 trang) thành
  /// nhiều paragraph nhỏ — đây là lý do trước đây "mỗi trang vẫn có
  /// scroll": block cao hơn viewport bị đẩy vào trang riêng với
  /// SingleChildScrollView. Giờ chỉ còn những block KHÔNG chẻ được
  /// (code block, ảnh, quote/inline phức tạp) giữ scroll fallback, còn
  /// trang bình thường thì không scroll.
  void _computePages(Size size) {
    if (_lastSize != null &&
        (_lastSize!.width - size.width).abs() < 1 &&
        (_lastSize!.height - size.height).abs() < 1) {
      return; // Same size, no recompute
    }
    _lastSize = size;

    final maxWidth = size.width;
    final maxHeight = size.height - 80; // -80 for page indicator + padding

    // Trang 1 chứa header chương → capacity trang đầu bị trừ đúng phần
    // header đã đo; các trang sau dùng trọn viewport.
    final headerReserve =
        widget.header != null && _pageHeaderMeasured ? _pageHeaderHeight : 0.0;
    double capacity(int pageIndex) {
      if (pageIndex != 0) return maxHeight;
      final cap = maxHeight - headerReserve;
      return cap <= 0 ? 0.0 : cap;
    }

    _pageBlocks = _buildPageBlocks(_blocks, maxWidth, maxHeight);

    _pageBlockIndices = [];
    _pageHasOversized = [];
    var current = <int>[];
    var currentHeight = 0.0;
    var currentHasOversized = false;
    var pageIndex = 0;

    // KHÔNG dùng _measureBlockHeightCached ở đây: cache được [_buildPageBlocks]
    // ghi theo index GỐC trong [_blocks], còn [_pageBlocks] sau khi chẻ
    // paragraph quá cao thì index bị DỊCH — tra cache bằng index mới lấy
    // nhầm chiều cao của block khác (fragment đầu của paragraph bị chẻ
    // còn bị gán nguyên chiều cao paragraph mẹ) → phân trang sai và trang
    // thuần prose bị gắn cờ scroll fallback oan. _computePages chỉ chạy
    // lại khi kích thước/font đổi nên đo trực tiếp không tốn thêm gì.
    for (var i = 0; i < _pageBlocks.length; i++) {
      final cap = capacity(pageIndex);
      final h = _measureBlockHeight(_pageBlocks[i], maxWidth);
      final oversized = h > cap;
      if (currentHeight + h > cap && current.isNotEmpty) {
        // Current page is full — flush it and start a new page.
        _pageBlockIndices.add(current);
        _pageHasOversized.add(currentHasOversized);
        current = [];
        currentHeight = 0;
        currentHasOversized = false;
        pageIndex++;
      }
      current.add(i);
      currentHeight += h;
      currentHasOversized = currentHasOversized || oversized;
    }
    if (current.isNotEmpty) {
      _pageBlockIndices.add(current);
      _pageHasOversized.add(currentHasOversized);
    }
    if (_pageBlockIndices.isEmpty) {
      _pageBlockIndices = [[]];
      _pageHasOversized = [false];
    }
  }

  /// Chẻ các paragraph quá cao thành paragraph nhỏ hơn (giữ nguyên
  /// index gốc trong [_pageBlockOriginalIndex]). Chỉ chẻ paragraph mà
  /// mọi inline đều là [TextRun]/[LineBreak] (plain prose — đại đa số
  /// truyện chữ); inline phức tạp (đậm/liên kết/…) giữ nguyên → trang
  /// đó rơi vào _pageHasOversized và có scroll fallback.
  List<Block> _buildPageBlocks(
    List<Block> blocks,
    double maxWidth,
    double maxHeight,
  ) {
    final result = <Block>[];
    final origin = <int>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (b is Paragraph &&
          b.children.every((c) => c is TextRun || c is LineBreak)) {
        final h = _measureBlockHeightCached(i, b, maxWidth);
        if (h > maxHeight) {
          for (final p in _splitTallParagraph(b, maxWidth, maxHeight)) {
            result.add(p);
            origin.add(i);
          }
          continue;
        }
      }
      result.add(b);
      origin.add(i);
    }
    _pageBlockOriginalIndex = origin;
    return result;
  }

  /// Chia [Paragraph] thành N paragraph nhỏ sao cho mỗi phần vừa khít
  /// trang. Cắt tại khoảng trắng gần ranh giới (không chẻ giữa từ);
  /// nếu không tìm được khoảng trắng thì cắt đúng ranh giới (hiếm).
  List<Paragraph> _splitTallParagraph(
    Paragraph p,
    double maxWidth,
    double maxHeight,
  ) {
    final style = widget.theme.bodyStyle;
    final tp = TextPainter(
      text: TextSpan(
        style: style,
        children: [
          for (final i in p.children) _inlineToSpan(i, widget.theme),
        ],
      ),
      textAlign: TextAlign.left,
      textDirection: TextDirection.ltr,
      maxLines: null,
    );
    tp.layout(maxWidth: maxWidth - 32); // -32 for horizontal padding
    final h = tp.height + widget.theme.paragraphSpacing;
    tp.dispose();
    if (h <= maxHeight) return [p];

    // Hệ số 0.92: chẻ nhiều hơn vừa đủ để phần cuối không tràn đúng
    // ranh giới trang (sai số đo lường nhỏ cũng không làm trang scroll).
    final parts = (h / (maxHeight * 0.92)).ceil().clamp(2, 64);
    final full = p.children.map((i) => i.plainText).join();
    if (full.isEmpty) return [p];

    // Guard: text quá ngắn so với số phần cần chẻ → target = 0 làm vòng
    // lặp cắt không bao giờ tiến (chunks rỗng, start đứng yên → loop
    // vô hạn). Trường hợp này không thể chẻ thêm → giữ nguyên paragraph.
    final target = full.length ~/ parts;
    if (target < 1) return [p];

    final chunks = <String>[];
    var start = 0;
    while (chunks.length < parts - 1) {
      var end = (start + target).clamp(0, full.length);
      // Lùi về khoảng trắng gần ranh giới nhất (cửa sổ 40 ký tự) để
      // không cắt giữa từ.
      final windowStart = (end - 40).clamp(0, full.length);
      final space = full.lastIndexOf(RegExp(r'\s'), end);
      if (space > windowStart) end = space + 1;
      if (end <= start) end = (start + target).clamp(0, full.length);
      chunks.add(full.substring(start, end));
      start = end;
    }
    chunks.add(full.substring(start));
    return [for (final c in chunks) Paragraph([TextRun(c)])];
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isPageMode) {
      return _buildScrollMode();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _computePages(Size(constraints.maxWidth, constraints.maxHeight));
        _schedulePageHeaderMeasure();
        return _buildPageMode();
      },
    );
  }

  /// Đo chiều cao header chương trên trang 1 (page mode). Trước khi đo
  /// xong, trang 1 được phép scroll dọc (chống tràn chữ trong lúc chờ);
  /// đo xong nếu khác giá trị cũ thì setState ép phân trang lại với
  /// reserve đúng.
  void _schedulePageHeaderMeasure() {
    if (!widget.isPageMode || widget.header == null) return;
    if (_pageHeaderMeasured) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pageHeaderMeasured) return;
      final ctx = _pageHeaderKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final h = ctx.size?.height ?? 0.0;
      _pageHeaderMeasured = true;
      if ((h - _pageHeaderHeight).abs() > 1) {
        setState(() {
          _pageHeaderHeight = h;
          // Ép LayoutBuilder → _computePages chạy lại với reserve mới.
          _lastSize = null;
        });
      }
    });
  }

  /// Scroll qua ghost → ghost trượt lên trên ~45% viewport nghĩa là user
  /// chủ động đọc tiếp chương sau → route-replace (một lần mỗi chương;
  /// guard [_continueFired] chống fire lại trong lúc animation route).
  void _maybeContinueToNext() {
    final onContinue = widget.onContinue;
    if (widget.nextChapter == null ||
        onContinue == null ||
        _continueFired) {
      return;
    }
    final controller = widget.scrollController;
    if (controller == null || !controller.hasClients) return;
    final ctx = _ghostKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final ghostTop = box.localToGlobal(Offset.zero).dy;
    if (ghostTop <=
        controller.position.viewportDimension * _continueThreshold) {
      _continueFired = true;
      onContinue();
    }
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
          // Footer tự có padding dưới (40) — nếu không có footer thì giữ
          // padding đáy 48 như cũ cho chữ cuối không dính mép.
          padding: EdgeInsets.fromLTRB(
              16, 0, 16, widget.footer == null ? 48 : 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.header != null) widget.header!,
              MarkdownRenderer(
                blocks: _blocks,
                theme: widget.theme,
                activeBlock: _activeBlock,
                onParagraphLongPress: widget.onParagraphLongPress,
              ),
              if (widget.footer != null) widget.footer!,
              // Ghost chương kế: hiện dần khi cuộn hết chương (xem
              // doc nextChapter) + gợi ý trạng thái khi chưa sẵn sàng.
              if (widget.continueHint != null)
                _ContinueHintRow(text: widget.continueHint!),
              if (widget.nextChapter != null)
                KeyedSubtree(
                  key: _ghostKey,
                  child: _NextChapterGhost(
                    chapter: widget.nextChapter!,
                    theme: widget.theme,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPageMode() {
    if (_pageBlockIndices.length <= 1) {
      // Single page — content đã vừa khít (paragraph quá cao đã chẻ),
      // không scroll trừ khi còn block oversize (code/ảnh) hoặc header
      // chưa kịp đo chiều cao.
      final indices = [
        for (var i = 0; i < _pageBlocks.length; i++) _pageBlockOriginalIndex[i],
      ];
      final scrollable = (_pageHasOversized.isNotEmpty &&
              _pageHasOversized.first) ||
          !_pageHeaderMeasured;
      return SingleChildScrollView(
        physics: scrollable
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.header != null)
              KeyedSubtree(key: _pageHeaderKey, child: widget.header!),
            MarkdownRenderer(
              blocks: _pageBlocks,
              theme: widget.theme,
              activeBlock: _activeBlock,
              globalIndices: indices,
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
        final pageBlocks = [
          for (final i in blockIndices) _pageBlocks[i],
        ];
        // Global index gốc của từng block trên trang — TTS highlight theo
        // block gốc (chương chưa chẻ) nên không thể dùng baseBlockIndex+i
        // khi page blocks đã bị chẻ paragraph.
        final globalIndices = [
          for (final i in blockIndices) _pageBlockOriginalIndex[i],
        ];
        // Trang chỉ scroll dọc khi chứa block oversize (code block, ảnh,
        // quote/inline phức tạp) — hoặc trang 1 chưa đo xong header.
        // Trang thuần prose không scroll nữa.
        final scrollable =
            _pageHasOversized[pageIndex] ||
                (pageIndex == 0 && !_pageHeaderMeasured);
        return SingleChildScrollView(
          physics: scrollable
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (pageIndex == 0 && widget.header != null)
                KeyedSubtree(key: _pageHeaderKey, child: widget.header!),
              MarkdownRenderer(
                blocks: pageBlocks,
                theme: widget.theme,
                activeBlock: _activeBlock,
                baseBlockIndex: 0,
                globalIndices: globalIndices,
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
      if (_activeBlock.value != null) {
        _activeBlock.value = null;
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
      if (_activeBlock.value != null) {
        _activeBlock.value = null;
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
    if (handler.currentChunkIndex < 0 || handler.chunkCount == 0) return;
    // Bound check: chunkIndex có thể trỏ ra ngoài danh sách chunk sau khi
    // nội dung chương được cập nhật (ít chunk hơn) — trước đây RangeError
    // bị catch (_) nuốt lặng lẽ.
    final index = handler.currentChunkIndex;
    if (index >= handler.chunkCount) return;
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
      if (_activeBlock.value != null) {
        _activeBlock.value = null;
      }
      return;
    }
    if (blockIndex >= _blocks.length) return;
    if (blockIndex == _activeBlock.value) return;
    // Chỉ đổi notifier — renderer rebuild đúng 2 block (cũ + mới),
    // không setState cả chương.
    _activeBlock.value = blockIndex;
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
      // target page (no-op) to prevent jitter. So sánh theo index GỐC
      // vì page blocks đã chẻ paragraph (một block gốc có thể nằm rải
      // nhiều trang — tìm trang ĐẦU TIÊN chứa nó).
      if (!_pageController.hasClients) return;
      for (var p = 0; p < _pageBlockIndices.length; p++) {
        final contains = _pageBlockIndices[p]
            .any((i) => _pageBlockOriginalIndex[i] == active);
        if (contains) {
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
        offset += _measureBlockHeightCached(i, _blocks[i], contentWidth);
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

/// Gợi ý trạng thái dưới footer "Hết chương" khi ghost chưa sẵn sàng
/// (đang tải / không tải được) — không có key nên KHÔNG kích hoạt
/// onContinue; user vẫn chuyển chương bằng 2 nút phía trên.
class _ContinueHintRow extends StatelessWidget {
  const _ContinueHintRow({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.5),
              ),
        ),
      ),
    );
  }
}

/// Ghost chương kế tiếp: render nội dung chương sau NGAY dưới
/// "Hết chương" trong luồng scroll — cuộn tiếp là đọc luôn chương sau
/// (giống web truyện chữ cuộn liên tục). Long-press bình luận đoạn
/// bị TẮT ở đây: đoạn vẫn thuộc chương sau, bình luận khi đang ở
/// phần nhìn trước sẽ gửi quote lệch chapterId.
class _NextChapterGhost extends StatelessWidget {
  const _NextChapterGhost({required this.chapter, required this.theme});
  final ChapterContent chapter;
  final ReaderTheme theme;

  @override
  Widget build(BuildContext context) {
    final markdown = switch (chapter) {
      TextChapterContent(:final contentMarkdown) => contentMarkdown,
      VisualChapterContent(:final contentMarkdown) => contentMarkdown,
      _ => '',
    };
    final label = chapter.label ?? 'Ch. ${chapter.chapterNumber}';
    final title =
        chapter.title.isEmpty ? label : '$label: ${chapter.title}';
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(color: theme.bodyStyle.color?.withValues(alpha: 0.2)),
          const SizedBox(height: 16),
          Center(
            child: Text(
              '— Chương sau: $title —',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: theme.bodyStyle.color?.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          const SizedBox(height: 16),
          MarkdownRenderer(
            blocks: MarkdownParser().parse(markdown),
            theme: theme,
            onParagraphLongPress: null,
          ),
        ],
      ),
    );
  }
}
