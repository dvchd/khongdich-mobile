import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/markdown/markdown.dart';
import '../../../core/observability/app_logger.dart';
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
  // Pages đã phân: mỗi trang là danh sách các unit (block + index GỐC
  // trong [_blocks] cho TTS highlight). Paragraph bị chẻ ở ranh giới
  // trang tạo nhiều unit có CÙNG originalIndex — highlight vẫn đúng.
  List<List<_PageUnit>> _pageUnits = [];
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
      // Reset to page 0 on the next frame, after _pageUnits
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
  ///
  /// [maxWidth] = chiều rộng THẬT của cột chữ (đã trừ padding ngoài):
  /// cuộn dọc = viewport - 32, lật trang = viewport - 48. Trước đây hàm
  /// tự trừ 32 bên trong → đo theo width SAI với page mode (padding 48)
  /// → chiều cao lệch, trang bị tràn/thiếu chữ.
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
        tp.layout(maxWidth: maxWidth);
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
        tp.layout(maxWidth: maxWidth);
        final h = tp.height + 12 + 8; // top + bottom padding
        tp.dispose();
        return h;
      }(),
      HorizontalRule() => () {
        // Render: Padding(vertical 24) + Text('* * *', letterSpacing 8).
        // Trước đây ước lượng 48 cứng → thiếu chiều cao dòng chữ (~29px)
        // → trang bị TRÀN. Đo đúng bằng TextPainter.
        final tp = TextPainter(
          text: TextSpan(
            text: '* * *',
            style: style.copyWith(letterSpacing: 8),
          ),
          textDirection: TextDirection.ltr,
        );
        tp.layout(maxWidth: maxWidth);
        final h = tp.height + 48;
        tp.dispose();
        return h;
      }(),
      CodeBlock(:final code, :final language) => () {
        // Render: margin vertical 12×2 + padding 12×2 + (nhãn ngôn ngữ
        // nếu có: padding bottom 6 + dòng fontSize 12) + SelectableText
        // theo codeStyle. Trước đây ước lượng lines*20+24 → sai với code
        // block ngắn (thiếu chrome 24px) → trang bị TRÀN.
        final tp = TextPainter(
          text: TextSpan(text: code, style: widget.theme.codeStyle),
          textDirection: TextDirection.ltr,
          maxLines: null,
        );
        tp.layout(maxWidth: maxWidth - 24);
        final h = tp.height + 24 + 24 + (language != null ? 20 : 0);
        tp.dispose();
        return h;
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
        // Render: Container margin vertical 12×2 + padding (left 16, top
        // 4, bottom 4) + border left 4 → cột chữ con rộng maxWidth-20
        // (trước đây đo -32 → quote bị đo CAO hơn thật → trang trống).
        double total = 0;
        for (final b in children) {
          total += _measureBlockHeight(b, maxWidth - 20);
        }
        return total + 24 + 8;
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
  /// Dùng danh sách "unit" (block + index GỐC của nó trong [_blocks] cho
  /// TTS highlight). Khi một paragraph không vừa phần còn lại của trang,
  /// CHẺ ĐÚNG RANH GIỚI (theo chiều cao đo được, cắt ở ranh giới từ):
  /// phần vừa khít điền đầy trang hiện tại, phần còn lại sang trang sau —
  /// không còn cảnh trang cuối mỗi đoạn "hiển thị một nửa" (block bị đẩy
  /// nguyên sang trang mới → trang cũ chừa nửa trống).
  void _computePages(Size size) {
    if (_lastSize != null &&
        (_lastSize!.width - size.width).abs() < 1 &&
        (_lastSize!.height - size.height).abs() < 1) {
      return; // Same size, no recompute
    }
    _lastSize = size;

    // Chiều rộng cột chữ THẬT: page mode padding ngang 24 mỗi bên.
    final textWidth = size.width - 48;
    // Chrome mỗi trang: padding dọc 8×2 + SizedBox 32 + dòng chỉ trang
    // (fontSize 12 ≈ 14px) ≈ 62px — trừ 68 chừa ~6px sai số. Trước đây
    // trừ 80 → mỗi trang trống thêm ~18px ("trống hơi nhiều").
    final maxHeight = size.height - 68;

    // Trang 1 chứa header chương → capacity trang đầu bị trừ đúng phần
    // header đã đo; các trang sau dùng trọn viewport.
    final headerReserve =
        widget.header != null && _pageHeaderMeasured ? _pageHeaderHeight : 0.0;
    double capacity(int pageIndex) {
      if (pageIndex != 0) return maxHeight;
      final cap = maxHeight - headerReserve;
      return cap <= 0 ? 0.0 : cap;
    }

    // Unit khởi đầu = mỗi block gốc một unit (giữ index gốc).
    final units = <_PageUnit>[
      for (var i = 0; i < _blocks.length; i++) _PageUnit(_blocks[i], i),
    ];

    final pages = <List<_PageUnit>>[];
    final oversizedFlags = <bool>[];
    var current = <_PageUnit>[];
    var currentHeight = 0.0;
    var currentHasOversized = false;
    var pageIndex = 0;
    var i = 0;

    while (i < units.length) {
      final cap = capacity(pageIndex);
      final unit = units[i];
      var h = _measureBlockHeight(unit.block, textWidth);

      if (current.isNotEmpty && currentHeight + h > cap) {
        // Trang đầy → thử chẻ paragraph tại ranh giới để ĐIỀN ĐẦY trang.
        final remaining = cap - currentHeight;
        final split = _splitParagraphToHeight(unit.block, textWidth, remaining);
        if (split != null) {
          current.add(_PageUnit(split.$1, unit.originalIndex));
          pages.add(current);
          oversizedFlags.add(currentHasOversized);
          current = [];
          currentHeight = 0;
          currentHasOversized = false;
          pageIndex++;
          // Phần còn lại trở thành unit mới, xử lý tiếp ở trang mới.
          units[i] = _PageUnit(split.$2, unit.originalIndex);
          continue;
        }
        // Không chẻ được (heading/quote/ảnh/inline phức tạp) → đẩy
        // nguyên block sang trang mới.
        pages.add(current);
        oversizedFlags.add(currentHasOversized);
        current = [];
        currentHeight = 0;
        currentHasOversized = false;
        pageIndex++;
      }

      // Block một mình còn cao hơn cả trang → chẻ theo chiều cao trang
      // nếu là paragraph thuần text; không chẻ được → trang scroll dọc.
      if (current.isEmpty && h > capacity(pageIndex)) {
        final split =
            _splitParagraphToHeight(unit.block, textWidth, capacity(pageIndex));
        if (split != null) {
          current.add(_PageUnit(split.$1, unit.originalIndex));
          currentHeight += _measureBlockHeight(split.$1, textWidth);
          units[i] = _PageUnit(split.$2, unit.originalIndex);
          i++; // đã xử lý phần đầu; phần còn lại là unit tiếp theo
          // KHÔNG đánh dấu oversized — mỗi phần đều vừa trang.
          continue;
        }
        currentHasOversized = true;
      }

      // Ảnh có chiều cao thật không đo được (fitWidth theo tỷ lệ ảnh
      // gốc) → đánh dấu trang scroll dọc để ảnh to không bao giờ bị
      // cắt/tràn khi trang không scroll.
      if (unit.block is ImageBlock) currentHasOversized = true;

      current.add(unit);
      currentHeight += h;
      i++;
    }
    if (current.isNotEmpty) {
      pages.add(current);
      oversizedFlags.add(currentHasOversized);
    }
    if (pages.isEmpty) {
      pages.add(const []);
      oversizedFlags.add(false);
    }
    _pageUnits = pages;
    _pageHasOversized = oversizedFlags;
  }

  /// Chẻ [Paragraph] tại độ cao [height] bằng line metrics CHÍNH XÁC: lấy
  /// đúng các dòng nguyên vẹn vừa khít budget (không cắt giữa từ — dòng
  /// đã wrap tại ranh giới từ sẵn). Inline được chẻ đệ quy nên GIỮ
  /// NGUYÊN định dạng (in nghiêng/đậm/link/code) ở cả 2 phần — trước đây
  /// paragraph có inline phức tạp bị coi là "không chẻ được" → đẩy
  /// nguyên đoạn sang trang sau, trang cũ chừa cả khoảng trống lớn.
  /// Trả về (phần đầu vừa khít, phần còn lại); null khi không chẻ được
  /// hoặc không đáng chẻ.
  (Paragraph, Paragraph)? _splitParagraphToHeight(
    Block block,
    double textWidth,
    double height,
  ) {
    if (block is! Paragraph) return null;
    final style = widget.theme.bodyStyle;
    final full = block.children.map((c) => c.plainText).join();
    if (full.isEmpty) return null;

    final tp = TextPainter(
      text: TextSpan(
        style: style,
        children: [
          for (final i in block.children) _inlineToSpan(i, widget.theme),
        ],
      ),
      textAlign: TextAlign.left,
      textDirection: TextDirection.ltr,
      maxLines: null,
    );
    tp.layout(maxWidth: textWidth);

    // Budget = phần còn lại của trang trừ spacing đoạn (packing sẽ cộng
    // spacing vào chiều cao phần đầu) và slack 4px (sai số đo).
    final budget = height - widget.theme.paragraphSpacing - 4;
    final metrics = tp.computeLineMetrics();
    if (budget <= 0 || metrics.isEmpty) {
      tp.dispose();
      return null;
    }
    double cum = 0;
    var take = 0;
    for (final m in metrics) {
      if (cum + m.height > budget) break;
      cum += m.height;
      take++;
    }
    if (take == 0 || take >= metrics.length) {
      // Không lấy được dòng nào (budget < 1 dòng) hoặc cả đoạn vừa khít.
      tp.dispose();
      return null;
    }

    // Vị trí kết thúc của dòng thứ `take` (take-1 index) — lùi 1px vào
    // trong dòng để chắc chắn getPositionForOffset rơi đúng dòng đó.
    final pos = tp.getPositionForOffset(Offset(textWidth, cum - 1));
    final range = tp.getLineBoundary(pos);
    tp.dispose();

    var cut = range.end;
    if (cut <= 0 || cut >= full.length) return null;

    final split = _splitInlineList(block.children, cut);
    if (split == null) return null;
    final (firstInlines, restInlines) = split;
    if (firstInlines == null || restInlines == null) return null;
    return (Paragraph(firstInlines), Paragraph(restInlines));
  }

  /// Chẻ danh sách inline tại [offset] (theo plainText) — trả (first,
  /// rest) gồm các inline NGUYÊN VẸN; inline bị cắt được chẻ đệ quy nên
  /// cả 2 phía giữ nguyên kiểu (emphasis/strong/strike/link/code).
  /// Null khi offset nằm ở biên (không có gì để cắt).
  (List<Inline>?, List<Inline>?)? _splitInlineList(
    List<Inline> children,
    int offset,
  ) {
    var used = 0;
    for (var i = 0; i < children.length; i++) {
      final len = children[i].plainText.length;
      if (used + len < offset) {
        used += len;
        continue;
      }
      if (used + len == offset) {
        // Cắt đúng biên giữa 2 inline.
        return (
          offset == 0 ? null : children.sublist(0, i + 1),
          i + 1 >= children.length ? null : children.sublist(i + 1),
        );
      }
      // Cắt giữa inline i → chẻ sâu.
      final s = _splitInlineAt(children[i], offset - used);
      if (s == null) return null;
      return (
        [
          ...children.sublist(0, i),
          if (s.$1 != null) s.$1!,
        ],
        [
          if (s.$2 != null) s.$2!,
          ...children.sublist(i + 1),
        ],
      );
    }
    return null; // offset > tổng độ dài — không xảy ra.
  }

  /// Chẻ 1 inline tại [offset] (0 < offset < plainText.length) — trả
  /// (phần đầu, phần còn lại); null khi offset nằm ở biên.
  (Inline?, Inline?)? _splitInlineAt(Inline inline, int offset) {
    return switch (inline) {
      TextRun(:final text) => offset <= 0 || offset >= text.length
          ? null
          : (
              TextRun(text.substring(0, offset)),
              TextRun(text.substring(offset)),
            ),
      EmphasisRun(:final children) => _splitWrapped(
          children,
          offset,
          (first, rest) => (EmphasisRun(first), EmphasisRun(rest))),
      StrongRun(:final children) => _splitWrapped(
          children,
          offset,
          (first, rest) => (StrongRun(first), StrongRun(rest))),
      StrikethroughRun(:final children) => _splitWrapped(
          children,
          offset,
          (first, rest) => (StrikethroughRun(first), StrikethroughRun(rest))),
      LinkRun(:final url, :final children) => _splitWrapped(
          children,
          offset,
          (first, rest) => (LinkRun(url, first), LinkRun(url, rest))),
      CodeRun(:final code) => offset <= 0 || offset >= code.length
          ? null
          : (
              CodeRun(code.substring(0, offset)),
              CodeRun(code.substring(offset)),
            ),
      LineBreak() => null, // length 1 — mọi offset hợp lệ đều ở biên.
    };
  }

  /// Chẻ danh sách con của inline wrapper (emphasis/strong/…) rồi bọc lại
  /// đúng kiểu ở cả 2 phía.
  (Inline, Inline)? _splitWrapped(
    List<Inline> children,
    int offset,
    (Inline, Inline) Function(List<Inline>, List<Inline>) wrap,
  ) {
    final s = _splitInlineList(children, offset);
    if (s == null || s.$1 == null || s.$2 == null) return null;
    return wrap(s.$1!, s.$2!);
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
    if (_pageUnits.length <= 1) {
      // Single page — content đã vừa khít (paragraph quá cao đã chẻ),
      // không scroll trừ khi còn block oversize (code/ảnh) hoặc header
      // chưa kịp đo chiều cao.
      final units = _pageUnits.isEmpty ? <_PageUnit>[] : _pageUnits.first;
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
              blocks: [for (final u in units) u.block],
              theme: widget.theme,
              activeBlock: _activeBlock,
              globalIndices: [for (final u in units) u.originalIndex],
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
      itemCount: _pageUnits.length,
      itemBuilder: (context, pageIndex) {
        final units = _pageUnits[pageIndex];
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
                blocks: [for (final u in units) u.block],
                theme: widget.theme,
                activeBlock: _activeBlock,
                baseBlockIndex: 0,
                // Global index gốc của từng block — TTS highlight theo
                // block gốc (chương chưa chẻ) nên không thể dùng index
                // liên tục khi paragraph bị chẻ ranh giới trang.
                globalIndices: [for (final u in units) u.originalIndex],
                onParagraphLongPress: widget.onParagraphLongPress,
              ),
              const SizedBox(height: 32),
              Center(
                child: Text(
                  '${pageIndex + 1}/${_pageUnits.length}',
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
      // vì paragraph có thể bị chẻ ranh giới trang (một block gốc nằm
      // rải nhiều trang — tìm trang ĐẦU TIÊN chứa nó).
      if (!_pageController.hasClients) return;
      for (var p = 0; p < _pageUnits.length; p++) {
        final contains =
            _pageUnits[p].any((u) => u.originalIndex == active);
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
      // Chiều rộng cột chữ thật = viewport - 32 (padding 16 mỗi bên).
      final textWidth = contentWidth - 32;
      double offset = 0;
      for (var i = 0; i < active && i < _blocks.length; i++) {
        offset += _measureBlockHeightCached(i, _blocks[i], textWidth);
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

/// Unit phân trang: một block trên một trang + index GỐC của block trong
/// danh sách block chương (dùng cho TTS highlight). Paragraph thuần text
/// bị chẻ ở ranh giới trang tạo nhiều unit CÙNG originalIndex.
class _PageUnit {
  const _PageUnit(this.block, this.originalIndex);

  final Block block;
  final int originalIndex;
}
