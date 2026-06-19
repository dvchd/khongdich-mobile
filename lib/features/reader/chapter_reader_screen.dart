import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/markdown/markdown.dart';
import '../../core/theme/app_theme.dart';
import '../../models/chapter_content.dart';
import 'chapter_provider.dart';
import 'reader_settings_provider.dart';
import 'views/chat_chapter_view.dart';
import 'views/manga_chapter_view.dart';
import 'views/text_chapter_view.dart';
import 'views/video_chapter_view.dart';
import 'widgets/reader_chrome.dart';

/// Polymorphic chapter reader. Dispatches to one of the four content_type
/// views (text / manga / chat / video) per `docs/plan-flutter-app.md`
/// §14.4. The reader chrome (app bar, progress bar, settings sheet) is
/// shared.
class ChapterReaderScreen extends ConsumerWidget {
  const ChapterReaderScreen({super.key, required this.chapterId});

  final String chapterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapter = ref.watch(chapterProvider(chapterId));
    final settings = ref.watch(readerSettingsProvider);
    return Scaffold(
      body: chapter.when(
        loading: () => const _ReaderSkeleton(),
        error: (e, _) => _ReaderError(
          error: e,
          onRetry: () => ref.invalidate(chapterProvider(chapterId)),
        ),
        data: (c) => _ReaderBody(chapter: c, settings: settings),
      ),
    );
  }
}

class _ReaderBody extends ConsumerWidget {
  const _ReaderBody({required this.chapter, required this.settings});

  final ChapterContent chapter;
  final ReaderSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readerTheme = _resolveReaderTheme(settings, Brightness.dark);
    return ReaderChrome(
      chapter: chapter,
      onPrev: chapter.prevChapter == null
          ? null
          : () => context.go('/chapter/${chapter.storyId}:${chapter.prevChapter}'),
      onNext: chapter.nextChapter == null
          ? null
          : () => context.go('/chapter/${chapter.storyId}:${chapter.nextChapter}'),
      child: switch (chapter) {
        TextChapterContent(:final contentMarkdown) => TextChapterView(
            markdown: contentMarkdown,
            theme: readerTheme,
          ),
        MangaChapterContent(:final images) =>
          MangaChapterView(images: [for (final p in images) p.url]),
        ChatChapterContent(:final participants, :final messages) =>
          ChatChapterView(participants: participants, messages: messages),
        VideoChapterContent(:final video, :final captionMarkdown) =>
          VideoChapterView(
            videoId: video.videoId,
            captionMarkdown: captionMarkdown,
            readerTheme: readerTheme,
          ),
      },
    );
  }

  ReaderTheme _resolveReaderTheme(ReaderSettings s, Brightness brightness) {
    final base = ReaderTheme.defaults(brightness);
    return ReaderTheme(
      bodyStyle: base.bodyStyle.copyWith(
        fontSize: s.fontSize,
        height: s.lineHeight,
        fontFamily: s.fontFamily,
      ),
      headingStyles: {
        for (final entry in base.headingStyles.entries)
          entry.key: entry.value.copyWith(
            fontFamily: s.fontFamily,
            fontSize: (entry.value.fontSize ?? 18) * (s.fontSize / 18),
          ),
      },
      accentColor: base.accentColor,
      paragraphSpacing: base.paragraphSpacing,
      codeStyle: base.codeStyle.copyWith(fontFamily: s.fontFamily),
      quoteColor: base.quoteColor,
      blockBackground: base.blockBackground,
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
