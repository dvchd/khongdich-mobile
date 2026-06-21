import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/markdown/markdown.dart';
import '../../../models/chapter_content.dart';
import '../../tts/tts_mini_player.dart';
import '../reader_settings_provider.dart';
import 'reader_bar.dart';
import 'reader_helpers.dart';

/// Shared chapter-reader body used by BOTH the online reader
/// (`ChapterReaderScreen`) and the offline reader
/// (`OfflineChapterReader`).
///
/// The only difference between online and offline is **where the
/// [ChapterContent] came from** — online fetches it from the API,
/// offline loads it from the local Drift DB. Everything else (reader
/// chrome, theme resolution, content rendering, page-flip / swipe
/// wrappers, tap zones, TTS mini player, reading-progress tracking)
/// is identical and lives here.
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
    this.onChapterNearEnd,
  });

  final ChapterContent chapter;
  final ReaderSettings settings;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenChapterList;
  final VoidCallback? onToggleTts;
  final VoidCallback? onChapterNearEnd;

  @override
  ConsumerState<ReaderBody> createState() => _ReaderBodyState();
}

class _ReaderBodyState extends ConsumerState<ReaderBody> {
  late final ScrollController _scrollController;
  final PageController _pageController = PageController();
  bool _progressSaved = false;
  // Chrome is always visible — tap-center opens the settings sheet
  // instead of toggling the AppBar.
  final bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
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
    final ratio =
        pos.pixels / (pos.maxScrollExtent == 0 ? 1 : pos.maxScrollExtent);
    if (ratio > 0.95 && !_progressSaved) {
      _progressSaved = true;
      widget.onChapterNearEnd?.call();
    }
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

    return ReaderBar(
      chapter: widget.chapter,
      onPrev: widget.onPrev,
      onNext: widget.onNext,
      onOpenSettings: widget.onOpenSettings,
      onOpenChapterList: widget.onOpenChapterList,
      onToggleTts: widget.onToggleTts,
      chromeVisible: _chromeVisible,
      child: ColoredBox(
        color: bgColor,
        child: Stack(
          children: [
            body,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: TtsMiniPlayer(chapter: widget.chapter),
            ),
            // Tap zones for edge navigation
            // Skip for chat — it handles its own tap to reveal next message.
            if (widget.chapter is! ChatChapterContent)
              Positioned.fill(
                child: ReaderTapZones(onTap: _onTapZone),
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
