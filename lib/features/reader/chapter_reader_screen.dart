import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/markdown/markdown.dart';
import '../../core/theme/app_theme.dart';
import '../../models/chapter_content.dart';
import '../tts/tts_mini_player.dart';
import 'chapter_provider.dart';
import 'reader_settings_provider.dart';
import 'services/reading_progress_service.dart';
import 'views/chat_chapter_view.dart';
import 'views/manga_chapter_view.dart';
import 'views/text_chapter_view.dart';
import 'views/video_chapter_view.dart';
import 'widgets/reader_chrome.dart';
import 'widgets/reader_settings_sheet.dart';

/// Polymorphic chapter reader. Dispatches to one of the four content_type
/// views (text / manga / chat / video) per `docs/plan-flutter-app.md`
/// §14.4. The reader chrome (app bar, progress bar, settings sheet) is
/// shared.
class ChapterReaderScreen extends ConsumerStatefulWidget {
  const ChapterReaderScreen({
    super.key,
    required this.storySlug,
    required this.chapterNumber,
    this.chapterId,
  });

  final String storySlug;
  final int chapterNumber;
  final String? chapterId;

  @override
  ConsumerState<ChapterReaderScreen> createState() =>
      _ChapterReaderScreenState();
}

class _ChapterReaderScreenState extends ConsumerState<ChapterReaderScreen> {
  late final ChapterRef _ref = ChapterRef(
    storySlug: widget.storySlug,
    chapterNumber: widget.chapterNumber,
    chapterId: widget.chapterId,
  );

  @override
  void initState() {
    super.initState();
    // Mark the chapter as the user's current reading position on
    // mount — the backend's `PUT /api/v1/reading-progress/{story_id}`
    // endpoint accepts { chapter, scroll_ratio, anchor }.
    Future.microtask(() {
      ref
          .read(readingProgressServiceProvider)
          .markChapterOpened(widget.storySlug, widget.chapterNumber);
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
          storySlug: widget.storySlug,
          onPrev: c.prevChapter == null
              ? null
              : () => context.go('/chapter/${widget.storySlug}/${c.prevChapter}'),
          onNext: c.nextChapter == null
              ? null
              : () => context.go('/chapter/${widget.storySlug}/${c.nextChapter}'),
          onOpenSettings: () => _openSettings(context),
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
}

class _ReaderBody extends ConsumerStatefulWidget {
  const _ReaderBody({
    required this.chapter,
    required this.settings,
    required this.storySlug,
    this.onPrev,
    this.onNext,
    this.onOpenSettings,
  });

  final ChapterContent chapter;
  final ReaderSettings settings;
  final String storySlug;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onOpenSettings;

  @override
  ConsumerState<_ReaderBody> createState() => _ReaderBodyState();
}

class _ReaderBodyState extends ConsumerState<_ReaderBody> {
  late final ScrollController _scrollController;
  bool _progressSaved = false;

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
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final ratio = pos.pixels / (pos.maxScrollExtent == 0 ? 1 : pos.maxScrollExtent);
    if (ratio > 0.95 && !_progressSaved) {
      _progressSaved = true;
      ref.read(readingProgressServiceProvider).markChapterRead(
            widget.storySlug,
            widget.chapter.chapterNumber,
            scrollRatio: ratio.clamp(0.0, 1.0),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final readerTheme = _resolveReaderTheme(widget.settings, Brightness.dark);
    return ReaderChrome(
      chapter: widget.chapter,
      onPrev: widget.onPrev,
      onNext: widget.onNext,
      onOpenSettings: widget.onOpenSettings,
      child: Stack(
        children: [
          _scrollWrapper(
            switch (widget.chapter) {
              TextChapterContent(:final contentMarkdown) => TextChapterView(
                  markdown: contentMarkdown,
                  theme: readerTheme,
                  scrollController: _scrollController,
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
                ),
              VideoChapterContent(:final video, :final captionMarkdown) =>
                VideoChapterView(
                  videoId: video.videoId,
                  captionMarkdown: captionMarkdown,
                  readerTheme: readerTheme,
                  scrollController: _scrollController,
                ),
            },
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: TtsMiniPlayer(chapter: widget.chapter),
          ),
        ],
      ),
    );
  }

  Widget _scrollWrapper(Widget child) {
    // Manga and chat have their own internal ListView. Wrap text+video
    // in our ScrollController so we can track reading progress.
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
    final base = ReaderTheme.defaults(brightness);
    return ReaderTheme(
      bodyStyle: base.bodyStyle.copyWith(
        fontSize: s.fontSize,
        height: s.lineHeight,
        fontFamily: s.fontFamily,
        color: s.theme == ReaderThemeMode.sepia
            ? const Color(0xFF3A2E1F)
            : base.bodyStyle.color,
      ),
      headingStyles: {
        for (final entry in base.headingStyles.entries)
          entry.key: entry.value.copyWith(
            fontFamily: s.fontFamily,
            fontSize: (entry.value.fontSize ?? 18) * (s.fontSize / 18),
            color: s.theme == ReaderThemeMode.sepia
                ? const Color(0xFF3A2E1F)
                : entry.value.color,
          ),
      },
      accentColor: base.accentColor,
      paragraphSpacing: base.paragraphSpacing,
      codeStyle: base.codeStyle.copyWith(fontFamily: s.fontFamily),
      quoteColor: base.quoteColor,
      blockBackground: s.theme == ReaderThemeMode.sepia
          ? const Color(0xFFF1E6CE)
          : base.blockBackground,
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
