import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../models/chapter_content.dart';
import '../../repositories/story_repository.dart';
import '../tts/tts_audio_handler.dart';
import '../tts/tts_control_panel.dart';
import 'chapter_provider.dart';
import 'reader_settings_provider.dart';
import 'services/reading_progress_service.dart';
import 'widgets/chapter_list_sheet.dart';
import 'widgets/reader_body.dart';
import 'widgets/reader_settings_sheet.dart';

/// Online chapter reader. Plan §5.4.
///
/// This screen is a **thin entry point**: it fetches the chapter via
/// [chapterProvider] (API call) and delegates all rendering to the
/// shared [ReaderBody] widget, which is also used by the offline
/// reader. The only online-specific behaviour is:
///   - Marking the chapter as opened (API call via
///     `readingProgressServiceProvider`).
///   - Marking the chapter as read when the user scrolls near the end
///     (API call).
///   - Building the chapter list sheet from the API's chapter list.
///   - Loading + playing TTS for the chapter.
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
        data: (c) => ReaderBody(
          chapter: c,
          settings: settings,
          onPrev: c.prevChapter == null
              ? null
              : () => context.replace(
                  '/chapter/${widget.storyId}:${c.prevChapter}'),
          onNext: c.nextChapter == null
              ? null
              : () => context.replace(
                  '/chapter/${widget.storyId}:${c.nextChapter}'),
          onOpenSettings: () => _openSettings(context),
          onOpenChapterList: () => _openChapterList(context, c),
          onToggleTts: c is TextChapterContent ? () => _toggleTts(c) : null,
          onChapterNearEnd: () {
            ref.read(readingProgressServiceProvider).markChapterRead(
                  widget.storyId,
                  c.chapterNumber,
                );
          },
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
      builder: (_) => _OnlineChapterListSheet(
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

/// Online chapter-list sheet — fetches the chapter list from the API
/// and forwards selection to the shared [ChapterListSheet].
class _OnlineChapterListSheet extends ConsumerWidget {
  const _OnlineChapterListSheet({
    required this.storyId,
    required this.currentChapter,
  });

  final String storyId;
  final int currentChapter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chaptersAsync = ref.watch(chapterListProvider(storyId));
    return chaptersAsync.when(
      loading: () => const SizedBox(
        height: 400,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => SizedBox(
        height: 400,
        child: Center(child: Text('Lỗi: $e')),
      ),
      data: (page) => ChapterListSheet(
        entries: [
          for (final c in page.chapters)
            ChapterListEntry(number: c.chapterNumber, title: c.title),
        ],
        currentChapter: currentChapter,
        onSelect: (number) =>
            context.replace('/chapter/$storyId:$number'),
      ),
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
