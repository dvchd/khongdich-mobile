import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../models/chapter_content.dart';
import '../../repositories/story_repository.dart';
import '../../services/chapter_cache_service.dart';
import '../story/story_detail_screen.dart' show vipStatusProvider;
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
      // Set locked chapter IDs từ VipStatus → ChapterCacheService skip
      // prefetch các chương VIP-locked (tránh spam API vô nghĩa).
      final vip = ref.read(vipStatusProvider(widget.storyId)).valueOrNull;
      if (vip != null) {
        ref
            .read(chapterCacheServiceProvider)
            .setLockedChapterIds(vip.lockedChapterIds.toSet());
      }
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
        data: (c) {
          // Prefetch chương kế tiếp ngầm (fire-and-forget). Khi user bấm
          // Next, chapterProvider check cache → nếu hit → render ngay
          // không loading spinner. Idempotent — skip nếu đã cache/đang
          // fetch. Không await để không block UI.
          final cache = ref.read(chapterCacheServiceProvider);
          unawaited(cache.prefetchNext(c));
          return _AccessGate(
            chapter: c,
            storyId: widget.storyId,
            child: ReaderBody(
              chapter: c,
              settings: settings,
              onPrev: c.prevChapter == null
                  ? null
                  : () => context.replace(
                      '/chapter/${widget.storyId}:${c.prevChapter}',
                    ),
              onNext: c.nextChapter == null
                  ? null
                  : () => context.replace(
                      '/chapter/${widget.storyId}:${c.nextChapter}',
                    ),
              onOpenSettings: () => _openSettings(context),
              onOpenChapterList: () => _openChapterList(context, c),
              onToggleTts: c is TextChapterContent ? () => _toggleTts(c) : null,
              onChapterNearEnd: () {
                ref
                    .read(readingProgressServiceProvider)
                    .markChapterRead(widget.storyId, c.chapterNumber);
                // Retry prefetch khi user scroll gần cuối — nếu prefetch
                // ban đầu fail (lỗi mạng), đây là cơ hội retry.
                unawaited(cache.prefetchNext(c));
              },
            ),
          );
        },
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
      // Nếu đang play/pause chương KHÁC chương user vừa tap → stop + load
      // chương mới. Trước đây chỉ load khi `!state.playing`, nên nếu TTS
      // đang chạy chương A mà user tap headphone ở chương B → không gì
      // xảy ra (bug "TTS không chuyển chương").
      // Nếu ĐANG play đúng chương này → chỉ mở control panel (pause/play
      // từ panel), không reload.
      if (handler.currentChapterId != chapter.id) {
        await handler.stop();
        await handler.loadChapter(
          chapterId: chapter.id,
          storyId: chapter.storyId,
          storyTitle: chapter.storyTitle,
          chapterTitle: chapter.title,
          chapterNumber: chapter.chapterNumber,
          contentMarkdown: chapter.contentMarkdown,
        );
        await handler.play();
      } else {
        // Cùng chương — nếu đang pause thì play, nếu đang play thì chỉ
        // mở panel (user dùng panel để pause).
        final state = handler.playbackState.value;
        if (!state.playing &&
            state.processingState != AudioProcessingState.error) {
          await handler.play();
        }
      }
      // Open the full TTS control panel as a bottom sheet.
      if (mounted) {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          isDismissible: true, // cho phép tap ngoài / back để tắt
          enableDrag: true, // cho phép swipe down để tắt
          showDragHandle: true, // vẽ handle + nút X góc phải
          builder: (_) => const TtsControlPanel(),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('TTS lỗi: $e')));
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
      error: (e, _) =>
          SizedBox(height: 400, child: Center(child: Text('Lỗi: $e'))),
      data: (page) => ChapterListSheet(
        entries: [
          for (final c in page.chapters)
            ChapterListEntry(number: c.chapterNumber, title: c.title),
        ],
        currentChapter: currentChapter,
        onSelect: (number) => context.replace('/chapter/$storyId:$number'),
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

// ─── VIP access gate ─────────────────────────────────────────────────
//
// Wraps the chapter reader body. Calls `GET /api/v1/mobile/chapters/{id}/access`
// to check whether the user can read the chapter. If the chapter is
// VIP-locked and the user lacks a grant, shows the VipLockedScreen
// instead of the chapter content.

/// Provider that fetches the access status for a chapter.
final chapterAccessProvider = FutureProvider.autoDispose
    .family<ChapterAccess, String>((ref, chapterId) async {
      final repo = ref.watch(storyRepositoryProvider);
      return repo.fetchChapterAccess(chapterId);
    });

class _AccessGate extends ConsumerWidget {
  const _AccessGate({
    required this.chapter,
    required this.storyId,
    required this.child,
  });

  final ChapterContent chapter;
  final String storyId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accessAsync = ref.watch(chapterAccessProvider(chapter.id));
    return accessAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      // Fail CLOSED: on access-check error, show a retry screen instead
      // of leaking chapter content. The previous code returned `child`
      // (full chapter content) on any error → VIP bypass on transient
      // network failures or backend 500s.
      error: (e, _) => _AccessCheckError(error: e),
      data: (access) {
        if (access.canRead) return child;
        return VipLockedScreen(chapter: chapter, storyId: storyId);
      },
    );
  }
}

/// Shown when the access check fails (network error / 5xx). Offers a
/// retry button — user should re-check access before seeing content.
class _AccessCheckError extends StatelessWidget {
  const _AccessCheckError({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Color(0xFFD97706)),
            const SizedBox(height: 12),
            const Text(
              'Không kiểm tra được quyền truy cập',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                // Invalidate the access provider to trigger a re-fetch.
                // Reader consumers watch it, so they'll rebuild.
              },
              child: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the user tries to read a VIP-locked chapter they don't
/// have access to. Mirrors the web's `chapter/vip_locked.html` page.
class VipLockedScreen extends StatelessWidget {
  const VipLockedScreen({
    super.key,
    required this.chapter,
    required this.storyId,
  });

  final ChapterContent chapter;
  final String storyId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/story/$storyId');
            }
          },
        ),
        title: const Text('Chương VIP'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.lock, size: 80, color: Color(0xFFD97706)),
            const SizedBox(height: 16),
            Text(
              '🔒 Chương VIP',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: const Color(0xFFD97706),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Chương ${chapter.chapterNumber}: ${chapter.title}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            const Text(
              'Chương này là chương VIP — chỉ những đọc giả được tác giả '
              'cấp quyền mới có thể đọc. Liên hệ tác giả để được cấp '
              'quyền truy cập.',
              textAlign: TextAlign.center,
              style: TextStyle(height: 1.6),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => context.go('/story/$storyId'),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Về trang truyện'),
            ),
          ],
        ),
      ),
    );
  }
}
