import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/markdown/markdown.dart';
import '../../core/theme/app_theme.dart';
import '../../models/chapter_content.dart';
import '../../repositories/story_repository.dart';
import '../tts/tts_audio_handler.dart';
import '../tts/tts_control_panel.dart';
import '../tts/tts_mini_player.dart';
import 'chapter_provider.dart';
import 'reader_settings_provider.dart';
import 'services/reading_progress_service.dart';
import 'views/chat_chapter_view.dart';
import 'views/manga_chapter_view.dart';
import 'views/text_chapter_view.dart';
import 'views/video_chapter_view.dart';
import 'widgets/reader_bar.dart';
import 'widgets/reader_settings_sheet.dart';

/// Polymorphic chapter reader. Dispatches to one of the four content_type
/// views (text / manga / chat / video) per `docs/plan-flutter-app.md`
/// §14.4. The reader chrome (app bar, progress bar, settings sheet) is
/// shared.
class ChapterReaderScreen extends ConsumerStatefulWidget {
  const ChapterReaderScreen({
    super.key,
    required this.storyId,
    required this.chapterNumber,
  });

  final String storyId;
  final int chapterNumber;

  @override
  ConsumerState<ChapterReaderScreen> createState() =>
      _ChapterReaderScreenState();
}

class _ChapterReaderScreenState extends ConsumerState<ChapterReaderScreen> {
  late final ChapterRef _ref = ChapterRef(
    storyId: widget.storyId,
    chapterNumber: widget.chapterNumber,
  );

  @override
  void initState() {
    super.initState();
    // Mark the chapter as the user's current reading position on
    // mount — backend `PUT /api/v1/mobile/reading-progress/{story_id}`.
    Future.microtask(() {
      ref
          .read(readingProgressServiceProvider)
          .markChapterOpened(widget.storyId, widget.chapterNumber);
    });
  }

  @override
  Widget build(BuildContext context) {
    final chapter = ref.watch(chapterProvider(_ref));
    final settings = ref.watch(readerSettingsProvider);
    return Scaffold(
      body: chapter.when(
        loading: () => const _ReaderSkeleton(),
        error: (e, _) => _ReaderError(
          error: e,
          onRetry: () => ref.invalidate(chapterProvider(_ref)),
        ),
        data: (c) => _ReaderBody(
          chapter: c,
          settings: settings,
          storyId: widget.storyId,
          onPrev: c.prevChapter == null
              ? null
              : () => context.go(
                  '/chapter/${widget.storyId}:${c.prevChapter}'),
          onNext: c.nextChapter == null
              ? null
              : () => context.go(
                  '/chapter/${widget.storyId}:${c.nextChapter}'),
          onOpenSettings: () => _openSettings(context),
          onOpenChapterList: () => _openChapterList(context, c),
          onToggleTts: c is TextChapterContent ? () => _toggleTts(c) : null,
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ReaderSettingsSheet(),
    );
  }

  void _openChapterList(BuildContext context, ChapterContent chapter) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ChapterListSheet(
        storyId: widget.storyId,
        currentChapter: chapter.chapterNumber,
      ),
    );
  }

  void _toggleTts(TextChapterContent chapter) async {
    try {
      final handler = await ref.read(ttsHandlerProvider.future);
      // If currently playing this chapter → open control panel.
      // Otherwise → load + play + open panel.
      final state = handler.playbackState.value;
      if (!state.playing || state.processingState == AudioProcessingState.idle) {
        await handler.loadChapter(
          chapterId: chapter.id,
          storyId: chapter.storyId,
          storyTitle: chapter.storyTitle,
          chapterTitle: chapter.title,
          chapterNumber: chapter.chapterNumber,
          contentMarkdown: chapter.contentMarkdown,
        );
        await handler.play();
      }
      // Open the full TTS control panel as a bottom sheet.
      if (mounted) {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => const TtsControlPanel(),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('TTS lỗi: $e')),
        );
      }
    }
  }
}

class _ReaderBody extends ConsumerStatefulWidget {
  const _ReaderBody({
    required this.chapter,
    required this.settings,
    required this.storyId,
    this.onPrev,
    this.onNext,
    this.onOpenSettings,
    this.onOpenChapterList,
    this.onToggleTts,
  });

  final ChapterContent chapter;
  final ReaderSettings settings;
  final String storyId;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenChapterList;
  final VoidCallback? onToggleTts;

  @override
  ConsumerState<_ReaderBody> createState() => _ReaderBodyState();
}

class _ReaderBodyState extends ConsumerState<_ReaderBody> {
  late final ScrollController _scrollController;
  final PageController _pageController = PageController();
  bool _progressSaved = false;
  bool _chromeVisible = true;

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
    final ratio = pos.pixels / (pos.maxScrollExtent == 0 ? 1 : pos.maxScrollExtent);
    if (ratio > 0.95 && !_progressSaved) {
      _progressSaved = true;
      ref.read(readingProgressServiceProvider).markChapterRead(
            widget.storyId,
            widget.chapter.chapterNumber,
            scrollRatio: ratio.clamp(0.0, 1.0),
          );
    }
  }

  void _onTapZone(ReaderTapZone zone) {
    final isPageMode = widget.settings.scrollMode == ReaderScrollMode.horizontal;
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
        setState(() => _chromeVisible = !_chromeVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = switch (widget.settings.theme) {
      ReaderThemeMode.light => Brightness.light,
      ReaderThemeMode.sepia => Brightness.light,
      ReaderThemeMode.dark => Brightness.dark,
      ReaderThemeMode.system => MediaQuery.of(context).platformBrightness,
    };
    final readerTheme = _resolveReaderTheme(widget.settings, brightness);
    final isPageMode = widget.settings.scrollMode == ReaderScrollMode.horizontal;

    final content = _scrollWrapper(
      switch (widget.chapter) {
        TextChapterContent(:final contentMarkdown) => TextChapterView(
            markdown: contentMarkdown,
            theme: readerTheme,
            scrollController: _scrollController,
            pageController: isPageMode ? _pageController : null,
            isPageMode: isPageMode,
          ),
        MangaChapterContent(:final images) => MangaChapterView(
            images: [for (final p in images) p.url],
            scrollController: _scrollController,
          ),
        ChatChapterContent(:final participants, :final messages) =>
          ChatChapterView(
            participants: participants,
            messages: messages,
            scrollController: _scrollController,
            onNext: widget.onNext,
            onPrev: widget.onPrev,
          ),
        VideoChapterContent(:final video, :final captionMarkdown) =>
          VideoChapterView(
            videoId: video.videoId,
            captionMarkdown: captionMarkdown,
            readerTheme: readerTheme,
            scrollController: _scrollController,
          ),
      },
    );

    final body = isPageMode
        ? _PageModeWrapper(
            onNext: widget.onNext,
            onPrev: widget.onPrev,
            child: content,
          )
        : _HorizontalSwipeWrapper(
            onSwipeLeft: widget.onNext,
            onSwipeRight: widget.onPrev,
            child: content,
          );

    final isSepia = widget.settings.theme == ReaderThemeMode.sepia;
    final isReaderLight = brightness == Brightness.light && !isSepia;
    final readerBgColor = isSepia
        ? const Color(0xFFF5E6C8)
        : (isReaderLight ? const Color(0xFFFAFAFA) : const Color(0xFF0F172A));

    return ReaderBar(
      chapter: widget.chapter,
      onPrev: widget.onPrev,
      onNext: widget.onNext,
      onOpenSettings: widget.onOpenSettings,
      onOpenChapterList: widget.onOpenChapterList,
      onToggleTts: widget.onToggleTts,
      // Hide AppBar chrome when user taps center zone
      chromeVisible: _chromeVisible,
      child: ColoredBox(
        color: readerBgColor,
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

  ReaderTheme _resolveReaderTheme(ReaderSettings s, Brightness brightness) {
    final isSepia = s.theme == ReaderThemeMode.sepia;
    final isLight = brightness == Brightness.light && !isSepia;

    // Resolve base colors from the theme mode.
    final textColor = isSepia
        ? const Color(0xFF3A2E1F)
        : (isLight ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9));
    final blockBg = isSepia
        ? const Color(0xFFEDE0C8)
        : (isLight ? const Color(0xFFF1F5F9) : const Color(0xFF1E293B));

    // Resolve font: use GoogleFonts for actual font loading.
    final baseFont = switch (s.fontFamily) {
      'NotoSans' => GoogleFonts.notoSans(),
      'monospace' => GoogleFonts.robotoMono(),
      _ => GoogleFonts.notoSerif(),
    };

    return ReaderTheme(
      bodyStyle: baseFont.copyWith(
        fontSize: s.fontSize,
        height: s.lineHeight,
        color: textColor,
      ),
      headingStyles: {
        for (final entry in [1, 2, 3, 4, 5, 6])
          entry: GoogleFonts.notoSans(
            fontWeight: FontWeight.w700,
            fontSize: switch (entry) {
              1 => 28.0,
              2 => 24.0,
              3 => 20.0,
              4 => 18.0,
              5 => 16.0,
              _ => 14.0,
            } * (s.fontSize / 18),
            height: 1.3,
            color: textColor,
          ),
      },
      accentColor: const Color(0xFF3B82F6),
      paragraphSpacing: 6,
      codeStyle: GoogleFonts.robotoMono(
        fontSize: 15,
        color: textColor,
        backgroundColor: blockBg,
      ),
      quoteColor: const Color(0xFFE11D48),
      blockBackground: blockBg,
    );
  }
}

class _ReaderSkeleton extends StatelessWidget {
  const _ReaderSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

class _ReaderError extends StatelessWidget {
  const _ReaderError({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: AppTheme.primary),
            const SizedBox(height: 12),
            Text(
              'Không tải được chương',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Thử lại')),
          ],
        ),
      ),
    );
  }
}

/// Wraps content with horizontal swipe detection for the horizontal
/// reader mode. Swipe right → next chapter, swipe left → prev chapter.
/// Vertical scrolling passes through to the child widget.
class _HorizontalSwipeWrapper extends StatelessWidget {
  const _HorizontalSwipeWrapper({
    required this.child,
    this.onSwipeLeft,
    this.onSwipeRight,
  });

  final Widget child;
  final VoidCallback? onSwipeLeft;
  final VoidCallback? onSwipeRight;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -300 && onSwipeLeft != null) {
          onSwipeLeft!();
        } else if (velocity > 300 && onSwipeRight != null) {
          onSwipeRight!();
        }
      },
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}

/// Bottom sheet listing all chapters in the current story. Tapping a
/// chapter navigates to it. The current chapter is highlighted.
class _ChapterListSheet extends ConsumerWidget {
  const _ChapterListSheet({
    required this.storyId,
    required this.currentChapter,
  });

  final String storyId;
  final int currentChapter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chaptersAsync = ref.watch(chapterListProvider(storyId));
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text('Danh sách chương',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: chaptersAsync.when(
                  loading: () => const Center(
                      child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('Lỗi: $e')),
                  data: (page) => ListView.builder(
                    controller: scrollController,
                    itemCount: page.chapters.length,
                    itemBuilder: (_, i) {
                      final c = page.chapters[i];
                      final isCurrent = c.chapterNumber == currentChapter;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isCurrent
                              ? AppTheme.primary
                              : Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                          child: Text(
                            '${c.chapterNumber}',
                            style: TextStyle(
                              color: isCurrent
                                  ? Colors.white
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurface,
                            ),
                          ),
                        ),
                        title: Text(
                          c.title.isEmpty
                              ? 'Chương ${c.chapterNumber}'
                              : c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: isCurrent
                              ? TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.primary,
                                )
                              : null,
                        ),
                        trailing: isCurrent
                            ? const Icon(Icons.check_circle,
                                color: AppTheme.primary, size: 20)
                            : null,
                        onTap: () {
                          context.go(
                              '/chapter/$storyId:${c.chapterNumber}');
                          Navigator.of(context).pop();
                        },
                      );
                    },
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

/// Wrapper for page-flip mode. Intercepts horizontal drag gestures that
/// go BEYOND the PageView's scroll boundaries — i.e. swiping left on
/// the last page or right on the first page. Only those overscrolls
/// trigger chapter navigation. Normal page-turn swipes are handled by
/// the PageView inside.
///
/// Implementation: we use `NotificationListener<ScrollNotification>` to
/// detect when the PageView reaches its boundary AND the user keeps
/// swiping. The OverscrollNotification fires at that point.
class _PageModeWrapper extends StatefulWidget {
  const _PageModeWrapper({this.onNext, this.onPrev, required this.child});
  final VoidCallback? onNext;
  final VoidCallback? onPrev;
  final Widget child;

  @override
  State<_PageModeWrapper> createState() => _PageModeWrapperState();
}

class _PageModeWrapperState extends State<_PageModeWrapper> {
  double _accumulatedOverscroll = 0;
  static const _threshold = 60.0; // px of overscroll to trigger chapter nav

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is OverscrollNotification &&
            notification.metrics.axis == Axis.horizontal) {
          _accumulatedOverscroll += notification.overscroll;
          if (_accumulatedOverscroll.abs() > _threshold) {
            if (_accumulatedOverscroll > 0 && widget.onNext != null) {
              widget.onNext!();
            } else if (_accumulatedOverscroll < 0 && widget.onPrev != null) {
              widget.onPrev!();
            }
            _accumulatedOverscroll = 0;
          }
        } else if (notification is ScrollEndNotification) {
          _accumulatedOverscroll = 0;
        }
        return false;
      },
      child: widget.child,
    );
  }
}

/// Which third of the screen was tapped.
enum ReaderTapZone { left, center, right }

/// Detects taps on left (30%), center (40%), and right (30%) zones.
class ReaderTapZones extends StatelessWidget {
  const ReaderTapZones({super.key, required this.onTap});
  final void Function(ReaderTapZone) onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 3,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => onTap(ReaderTapZone.left),
          ),
        ),
        Expanded(
          flex: 4,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => onTap(ReaderTapZone.center),
          ),
        ),
        Expanded(
          flex: 3,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => onTap(ReaderTapZone.right),
          ),
        ),
      ],
    );
  }
}

