import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/markdown/markdown.dart';
import '../../../core/network/api_client.dart';
import '../../../core/widgets/report_sheet.dart';
import '../../../models/chapter_content.dart';
import '../reader_settings_provider.dart';
import 'reader_bar.dart';
import 'reader_helpers.dart';
import 'tts_switch_banner.dart';

/// Shared chapter-reader body used by BOTH the online reader
/// (`ChapterReaderScreen`) and the offline reader
/// (`OfflineChapterReader`).
///
/// The only difference between online and offline is **where the
/// [ChapterContent] came from** — online fetches it from the API,
/// offline loads it from the local Drift DB. Everything else (reader
/// chrome, theme resolution, content rendering, page-flip / swipe
/// wrappers, tap zones, TTS highlight + auto-scroll, reading-progress
/// tracking) is identical and lives here.
///
/// Parents supply:
///   - [chapter]: the loaded `ChapterContent` (online or offline).
///   - [onPrev] / [onNext]: navigation callbacks (may be null when
///     there's no prev/next chapter).
///   - [onOpenSettings] / [onOpenChapterList]: open the matching
///     bottom sheets.
///   - [onToggleTts]: load + play TTS for this chapter (only for
///     text chapters).
///   - [onChapterNearEnd]: fired once when the user scrolls past 95%
///     of the chapter — parents use this to mark reading progress
///     (online → API call, offline → local Drift update).
///
/// NOTE: There used to be a `TtsMiniPlayer` bar pinned at the bottom
/// of the Stack while TTS was active. It was removed because the
/// `ReaderTapZones` overlay (also in the Stack) sits on top of it and
/// intercepts taps — pressing the bar would navigate chapters or
/// open the settings sheet instead of pausing TTS. The headphone
/// icon in the AppBar still opens the TTS control panel where the
/// user can pause/stop. While TTS is reading, the active block in
/// `TextChapterView` is highlighted yellow and the view auto-scrolls
/// (or page-flips) to follow along — see `TextChapterView` for the
/// implementation.
class ReaderBody extends ConsumerStatefulWidget {
  const ReaderBody({
    super.key,
    required this.chapter,
    required this.settings,
    required this.onOpenSettings,
    required this.onOpenChapterList,
    this.onPrev,
    this.onNext,
    this.onToggleTts,
    this.onOpenComments,
    this.onParagraphLongPress,
    this.onChapterNearEnd,
    this.mangaLocalImagePaths = const {},
  });

  /// Paragraph long-pressed inside a text/visual chapter — fires with the
  /// block's normalized plain text so parents can open the segment
  /// (bình luận đoạn) composer.
  final void Function(String plainText)? onParagraphLongPress;

  final ChapterContent chapter;
  final ReaderSettings settings;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenChapterList;
  final VoidCallback? onToggleTts;
  final VoidCallback? onOpenComments;
  final VoidCallback? onChapterNearEnd;

  /// For manga chapters, this maps `imageUrl → localFilePath` so the
  /// reader can render images from disk instead of the network. The
  /// offline reader populates this from the `downloaded_chapter_images`
  /// table; the online reader leaves it empty (falls back to
  /// `CachedNetworkImage`).
  final Map<String, String> mangaLocalImagePaths;

  @override
  ConsumerState<ReaderBody> createState() => _ReaderBodyState();
}

class _ReaderBodyState extends ConsumerState<ReaderBody> {
  late final ScrollController _scrollController;
  final PageController _pageController = PageController();
  bool _progressSaved = false;
  /// Đang ở cuối chương (cuộn dọc + có footer "Chương kế tiếp") → thu hẹp
  /// overlay tap-zones ở đáy để chạm được nút trong footer (overlay nằm
  /// TRÊN nội dung scroll trong Stack nên nếu không chừa, mọi chạm vào
  /// nút đều bị vùng tap giữa bắt → mở settings thay vì chuyển chương).
  bool _atBottom = false;
  /// Đang ở đầu chương → chừa vùng trên cho header (Chia sẻ / Báo cáo).
  /// Mặc định TRUE: scroll khởi đầu ở pixels 0 nhưng listener chưa chắc
  /// đã fire event nào (mở chương xong chạm ngay "Chia sẻ" vẫn phải chừa
  /// vùng — trước đây để false nên chạm đầu chương bị vùng tap nuốt).
  bool _atTop = true;
  /// Chiều cao vùng footer cuối chương chừa cho tap-zones (~Hết chương +
  /// nút + padding). Lớn hơn một chút để chừa thừa cũng vô hại.
  static const _footerBottomInset = 190.0;
  /// Chiều cao header đầu chương (tiêu đề 1-2 dòng + meta + chia sẻ/báo
  /// cáo). Phải đủ lớn để cả header nằm trong vùng chừa — trước đây 110
  /// còn nhỏ hơn header thật nên chạm "Chia sẻ" vẫn bị vùng tap giữa nuốt.
  static const _headerTopInset = 160.0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ReaderBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset the one-shot progress flag when the chapter changes so the
    // new chapter can fire onChapterNearEnd again. Without this, if the
    // ReaderBody is ever reused with a different chapter (e.g. via
    // didUpdateWidget in a parent), _progressSaved stays true and the
    // new chapter's reading progress is never marked.
    if (oldWidget.chapter.id != widget.chapter.id) {
      _progressSaved = false;
      _atBottom = false;
      // Chương mới mở ở đầu trang → chừa vùng header ngay.
      _atTop = true;
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // maxScrollExtent == 0 → nội dung ngắn hơn viewport (không scroll
    // được). Trước đây ratio = 0/1 = 0 → chương ngắn KHÔNG BAO GIỜ được
    // đánh dấu đã đọc (onChapterNearEnd không fire, "continue reading"
    // không cập nhật, LRU evict sai). Coi như đã đọc xong.
    final ratio = pos.maxScrollExtent == 0
        ? 1.0
        : pos.pixels / pos.maxScrollExtent;
    if (ratio > 0.95 && !_progressSaved) {
      _progressSaved = true;
      widget.onChapterNearEnd?.call();
    }
    // Footer chỉ được render ở chế độ cuộn dọc cho text/visual → chỉ
    // chừa vùng tap khi footer tồn tại và user đang ở sát cuối.
    final hasFooter = widget.settings.scrollMode == ReaderScrollMode.vertical &&
        (widget.chapter is TextChapterContent ||
            widget.chapter is VisualChapterContent);
    final atBottom = hasFooter &&
        pos.maxScrollExtent > 0 &&
        pos.pixels >= pos.maxScrollExtent - 8;
    if (atBottom != _atBottom) {
      setState(() => _atBottom = atBottom);
    }
    // Header chương (Chia sẻ / Báo cáo) chỉ ở đầu nội dung → chừa vùng
    // trên cho tap-zones khi user đang ở sát đỉnh.
    final atTop = hasFooter && pos.pixels <= 8;
    if (atTop != _atTop) {
      setState(() => _atTop = atTop);
    }
  }

  /// Chat chapters reveal messages one tap at a time — when everything
  /// is revealed the chat view reports it via this callback so reading
  /// progress is still recorded (the shared scroll controller is not
  /// attached to the chat's internal list).
  void _onAllRevealed() {
    if (_progressSaved) return;
    _progressSaved = true;
    widget.onChapterNearEnd?.call();
  }

  /// Chương ngắn (vừa một màn hình) không bao giờ phát sinh scroll
  /// event → kiểm tra một lần sau layout để không bỏ sót tiến trình.
  /// Chỉ áp dụng cho text/visual — manga ảnh load async nên extent
  /// lúc đầu chưa đáng tin (có thể đánh dấu đã đọc nhầm khi ảnh chưa
  /// kịp tải), chat có cơ chế reveal riêng, video không cần.
  void _checkShortChapterAfterLayout() {
    if (widget.chapter is! TextChapterContent &&
        widget.chapter is! VisualChapterContent) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _progressSaved) return;
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (pos.maxScrollExtent == 0) {
        _progressSaved = true;
        widget.onChapterNearEnd?.call();
      }
    });
  }

  void _onTapZone(ReaderTapZone zone) {
    final isPageMode =
        widget.settings.scrollMode == ReaderScrollMode.horizontal;
    switch (zone) {
      case ReaderTapZone.left:
        if (isPageMode && _pageController.hasClients) {
          final page = _pageController.page?.round() ?? 0;
          if (page > 0) {
            _pageController.previousPage(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
            );
            return;
          }
        }
        widget.onPrev?.call();
      case ReaderTapZone.right:
        if (isPageMode && _pageController.hasClients) {
          final before = _pageController.page?.round() ?? 0;
          _pageController.nextPage(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
          );
          Future.delayed(const Duration(milliseconds: 250), () {
            if (!mounted) return;
            final after = _pageController.page?.round() ?? 0;
            if (after <= before) {
              widget.onNext?.call();
            }
          });
          return;
        }
        widget.onNext?.call();
      case ReaderTapZone.center:
        // Tap center → open the reader settings sheet (matches the
        // behaviour of popular reader apps like NovelFever).
        widget.onOpenSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final brightness = readerBrightness(s, context);
    final readerTheme = resolveReaderTheme(s, brightness);
    final isPageMode = s.scrollMode == ReaderScrollMode.horizontal;
    final bgColor = readerBgColor(s.theme, brightness);

    final content = _scrollWrapper(
      buildChapterContent(
        widget.chapter,
        readerTheme,
        isPageMode,
        scrollController: _scrollController,
        pageController: _pageController,
        onNext: widget.onNext,
        onPrev: widget.onPrev,
        onParagraphLongPress: widget.onParagraphLongPress,
        mangaLocalImagePaths: widget.mangaLocalImagePaths,
        onAllRevealed: widget.chapter is ChatChapterContent
            ? _onAllRevealed
            : null,
        // Block "Hết chương — Chương kế tiếp" nằm TRONG nội dung scroll
        // (thay pill float đếm ngược từng che chữ cuối). Chỉ áp dụng cho
        // text/visual (chế độ cuộn dọc) — bấm mới chuyển chương, không
        // auto-lật.
        footer: widget.settings.scrollMode == ReaderScrollMode.vertical
            ? _ChapterEndFooter(
                hasNext: widget.onNext != null,
                onNext: widget.onNext,
                textColor:
                    readerTheme.bodyStyle.color ?? const Color(0xFF0F172A),
              )
            : null,
        // Header chương đầu nội dung — mirror web mobile (ch-head +
        // ch-meta): "Ch. N: Title" + thời gian đọc · số từ · Chia sẻ ·
        // Báo cáo. Nằm trong luồng scroll nên cuộn xuống là trôi đi.
        header: widget.settings.scrollMode == ReaderScrollMode.vertical
            ? _ChapterHeader(
                chapter: widget.chapter,
                textColor:
                    readerTheme.bodyStyle.color ?? const Color(0xFF0F172A),
              )
            : null,
      ),
    );

    final body = isPageMode
        ? PageModeWrapper(
            onNext: widget.onNext,
            onPrev: widget.onPrev,
            child: content,
          )
        : HorizontalSwipeWrapper(
            onSwipeLeft: widget.onNext,
            onSwipeRight: widget.onPrev,
            child: content,
          );

    // Short-chapter check after layout (no-op for scrolling chapters).
    _checkShortChapterAfterLayout();

    return ReaderBar(
      chapter: widget.chapter,
      onPrev: widget.onPrev,
      onNext: widget.onNext,
      onOpenSettings: widget.onOpenSettings,
      onOpenChapterList: widget.onOpenChapterList,
      onToggleTts: widget.onToggleTts,
      onOpenComments: widget.onOpenComments,
      child: ColoredBox(
        color: bgColor,
        child: Column(
          children: [
            // Banner "Đang nghe Chương X — Nghe chương này" khi TTS đang
            // đọc một chương khác của cùng truyện (mini player cũ chỉ hiện
            // cho chương đang đọc → đổi chương không biết đang nghe gì).
            // Thanh điều khiển chính giờ là TtsNowPlayingBar toàn cục
            // (đặt ở gốc app), hiển thị trên mọi màn hình.
            if (widget.onToggleTts != null)
              TtsSwitchChapterBanner(
                chapter: widget.chapter,
                onSwitchToThis: widget.onToggleTts,
              ),
            Expanded(
              child: Stack(
                children: [
                  body,
                  // Tap zones for edge navigation
                  // Skip for chat — it handles its own tap to reveal next message.
                  // Skip for video too — the overlay would swallow the YouTube
                  // player's own controls (play/seek/fullscreen). Reader chrome
                  // (settings / chapter list) stays reachable via ReaderBar.
                  // Skip for manga as well — the overlay would swallow taps on
                  // images, making the pinch-to-zoom gallery unreachable
                  // (the overlay wins the gesture arena because it's the last
                  // child in the Stack).
                  if (widget.chapter is! ChatChapterContent &&
                      widget.chapter is! VideoChapterContent &&
                      widget.chapter is! MangaChapterContent)
                    Positioned.fill(
                        child: ReaderTapZones(
                      // Chế độ cuộn dọc: vùng viền thu hẹp 20% mỗi bên
                      // (giữa 60%) — bấm gần giữa không nhảy chương nhầm.
                      // Lật trang ngang giữ 30% như cũ.
                      edgeFlex: isPageMode ? 3 : 2,
                      centerFlex: isPageMode ? 4 : 6,
                      // Ở cuối chương: chừa vùng đáy cho nút "Chương kế
                      // tiếp" trong footer (overlay nằm trên nội dung nên
                      // không chừa thì bấm nút bị vùng tap giữa nuốt).
                      bottomInset: _atBottom && !isPageMode
                          ? _footerBottomInset
                          : 0,
                      // Ở đầu chương: chừa vùng trên cho header (Chia sẻ /
                      // Báo cáo) — không chừa thì chạm vào header bị vùng
                      // tap trái/giữa bắt → nhảy chương/settings.
                      topInset: _atTop && !isPageMode
                          ? _headerTopInset
                          : 0,
                      onTap: _onTapZone,
                    )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Wrap content with the PrimaryScrollController so descendants
  /// (e.g. text view) inherit our scroll controller. Video view also
  /// needs it for the caption's scroll. Manga/chat views manage their
  /// own scroll internally so they don't need the wrapper.
  Widget _scrollWrapper(Widget child) {
    if (widget.chapter is TextChapterContent ||
        widget.chapter is VisualChapterContent ||
        widget.chapter is VideoChapterContent) {
      return PrimaryScrollController(
        controller: _scrollController,
        child: child,
      );
    }
    return child;
  }
}

// Re-export ReaderTheme for callers that need it.
typedef ReaderThemeAlias = ReaderTheme;

/// Header đầu chương — mirror web mobile (`templates/story/chapter.html`
/// `.ch-head` + `.ch-meta`): dòng tiêu đề "Ch. N: Title" rồi meta
/// "~X phút đọc · Y từ · 📋 Chia sẻ · ⚠️ Báo cáo". Nằm TRONG nội dung
/// scroll (cuộn xuống là trôi đi như web). Chia sẻ = copy link chương
/// (đúng URL web), Báo cáo = report sheet target chapter.
class _ChapterHeader extends StatelessWidget {
  const _ChapterHeader({required this.chapter, required this.textColor});
  final ChapterContent chapter;
  final Color textColor;

  /// Ước lượng thời gian đọc ~200 từ/phút (web dùng reading_time_str).
  static String _readingTime(int wordCount) {
    if (wordCount <= 0) return 'Chưa rõ';
    final minutes = (wordCount / 200).ceil().clamp(1, 9999);
    return '~$minutes phút đọc';
  }

  static String _fmtCount(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  Future<void> _copyChapterLink(BuildContext context) async {
    final baseUrl = ProviderScope.containerOf(
      context,
    ).read(apiClientProvider).value?.baseUrl ?? 'https://khongdich.com';
    final url =
        '$baseUrl/truyen/${chapter.storySlug}/chuong/${chapter.chapterNumber}';
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Đã sao chép link chương'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = textColor.withValues(alpha: 0.55);
    final title = chapter.title.isEmpty
        ? 'Ch. ${chapter.chapterNumber}'
        : 'Ch. ${chapter.chapterNumber}: ${chapter.title}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: textColor,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (chapter.wordCount > 0)
                Text(
                  '${_readingTime(chapter.wordCount)} · ${_fmtCount(chapter.wordCount)} từ',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: muted),
                ),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => _copyChapterLink(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '📋 Chia sẻ',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => showReportSheet(
                  context,
                  targetType: 'chapter',
                  targetId: chapter.id,
                  targetLabel: 'chương ${chapter.chapterNumber}',
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '⚠️ Báo cáo',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(color: textColor.withValues(alpha: 0.15), height: 1),
        ],
      ),
    );
  }
}

/// Block "Hết chương — Chương kế tiếp" nằm TRONG nội dung scroll (thay
/// pill float đếm ngược từng che mất chữ cuối). Cuộn tới cuối là thấy
/// tự nhiên, BẤM mới chuyển chương — không auto-lật nữa (trước đây đếm
/// ngược 5s có thể nhảy sang chương kế khi user chưa đọc xong đoạn
/// cuối). Chương cuối cùng (không có chương kế) chỉ hiện "Hết truyện".
class _ChapterEndFooter extends StatelessWidget {
  const _ChapterEndFooter({
    required this.hasNext,
    required this.onNext,
    required this.textColor,
  });
  final bool hasNext;
  final VoidCallback? onNext;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(color: textColor.withValues(alpha: 0.2)),
          const SizedBox(height: 20),
          Center(
            child: Text(
              hasNext ? 'Hết chương' : 'Hết truyện',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: textColor.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          const SizedBox(height: 12),
          if (hasNext && onNext != null)
            Center(
              child: FilledButton.icon(
                onPressed: onNext,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Chương kế tiếp'),
              ),
            ),
        ],
      ),
    );
  }
}
