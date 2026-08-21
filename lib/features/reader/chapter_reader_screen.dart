import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/network/api_client.dart';
import '../../core/observability/app_logger.dart';
import '../../models/chapter_content.dart';
import '../../models/comment.dart';
import '../../repositories/story_repository.dart';
import '../../services/chapter_cache_service.dart';
import '../story/story_detail_screen.dart' show vipStatusProvider;
import '../tts/tts_audio_handler.dart';
import '../tts/tts_control_panel.dart';
import '../comments/segment_composer_sheet.dart';
import 'chapter_provider.dart';
import 'chapter_tts_support.dart';
import 'reader_settings_provider.dart';
import 'services/reading_progress_service.dart';
import 'widgets/chapter_list_sheet.dart';
import 'widgets/reader_body.dart';
import 'widgets/reader_settings_sheet.dart';

export 'chapter_tts_support.dart' show chapterSupportsTts, chapterMarkdownOrNull;

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
  String? _prefetchedChapterId;
  StreamSubscription<TtsChapterCompleteEvent>? _chapterCompleteSub;
  TtsAudioHandler? _handler;

  @override
  void initState() {
    super.initState();
    // Mark the chapter as the user's current reading position on
    // mount — backend `PUT /api/v1/mobile/reading-progress/{story_id}`.
    Future.microtask(() async {
      try {
        await ref
            .read(readingProgressServiceProvider)
            .markChapterOpened(widget.storyId, widget.chapterNumber);
      } catch (e, s) {
        // ApiClient chưa sẵn sàng lúc boot → best-effort, không crash.
        AppLogger.warning('markChapterOpened failed on mount', e, s);
      }
      // Set locked chapter IDs từ VipStatus → ChapterCacheService skip
      // prefetch các chương VIP-locked (tránh spam API vô nghĩa).
      final vip = ref.read(vipStatusProvider(widget.storyId)).value;
      if (vip != null) {
        ref
            .read(chapterCacheServiceProvider)
            .setLockedChapterIds(vip.lockedChapterIds.toSet());
      }
      // Subscribe chapter-complete để auto-advance. Đăng ký ở initState
      // (không phải lúc tap headphone) — chuỗi auto-advance qua nhiều
      // màn hình vẫn hoạt động vì MỖI màn hình mới tự đăng ký listener
      // cho chương của chính nó.
      try {
        final handler = await ref.read(ttsHandlerProvider.future);
        if (!mounted) return;
        _handler = handler;
        _chapterCompleteSub =
            handler.onChapterCompleted.listen(_handleChapterCompleted);
      } catch (_) {
        // TTS init fail — reader vẫn hoạt động bình thường.
      }
    });
  }

  @override
  void dispose() {
    _chapterCompleteSub?.cancel();
    super.dispose();
  }

  /// TTS đọc xong một chương — nếu là chương CỦA MÀN HÌNH NÀY thì chỉ
  /// ĐIỀU HƯỚNG sang chương đích. Việc load + play chương đích do
  /// HANDLER tự làm (hoạt động cả khi app bị ẩn — xem TtsAudioHandler).
  /// Màn hình chính là guard: nó chỉ còn mounted khi reader của chương
  /// này vẫn nằm trên navigation stack.
  void _handleChapterCompleted(TtsChapterCompleteEvent event) {
    if (!mounted) return;
    final handler = _handler;
    if (handler == null) return;
    final matchesCurrent = event.storyId == widget.storyId &&
        event.chapterNumber == widget.chapterNumber;
    if (!shouldAutoAdvanceTts(
      matchesCurrentChapter: matchesCurrent,
      autoAdvanceEnabled: handler.autoAdvanceEnabled,
      manualSkip: event.manualSkip,
      nextChapterNumber: event.nextChapterNumber,
    )) {
      return;
    }
    GoRouter.of(
      context,
    ).replace('/chapter/${widget.storyId}:${event.nextChapterNumber}');
  }

  @override
  Widget build(BuildContext context) {
    final chapter = ref.watch(chapterProvider(_ref));
    final settings = ref.watch(readerSettingsProvider);
    // Prefetch chương kế tiếp ngầm (fire-and-forget) — qua ref.listen thay
    // vì chạy side-effect trong nhánh `data` của build (build phải pure).
    // Idempotent — chỉ chạy MỘT lần per chapter id.
    ref.listen(chapterProvider(_ref), (prev, next) {
      final c = next.value;
      if (c == null || _prefetchedChapterId == c.id) return;
      _prefetchedChapterId = c.id;
      unawaited(ref.read(chapterCacheServiceProvider).prefetchNext(c));
    });
    return Scaffold(
      body: chapter.when(
        loading: () => const _ReaderSkeleton(),
        error: (e, _) => _ReaderError(
          error: e,
          onRetry: () => ref.invalidate(chapterProvider(_ref)),
        ),
        data: (c) {
          final cache = ref.read(chapterCacheServiceProvider);
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
              onOpenComments: () => context.push(
                '/chapter-comments/${c.id}',
                extra: c.title,
              ),
              onParagraphLongPress: (plain) => _openSegmentComposer(c, plain),
              onToggleTts: chapterSupportsTts(c) ? () => _toggleTts(c) : null,
              onChapterNearEnd: () async {
                // Retry prefetch khi user scroll gần cuối — nếu prefetch
                // ban đầu fail (lỗi mạng), đây là cơ hội retry.
                unawaited(cache.prefetchNext(c));
                try {
                  await ref
                      .read(readingProgressServiceProvider)
                      .markChapterRead(widget.storyId, c.chapterNumber);
                } catch (e, s) {
                  AppLogger.warning('markChapterRead failed', e, s);
                }
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

  /// Long-press paragraph → bình luận đoạn / góp ý composer. Login-gated:
  /// anonymous users are prompted to sign in instead of seeing the sheet
  /// (bình luận đoạn + góp ý require an account, like the web).
  Future<void> _openSegmentComposer(
    ChapterContent chapter,
    String plainText,
  ) async {
    // Capture UI handles before any await (lint + safety).
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final api = ref.read(apiClientProvider).value;
    if (api == null || !await api.isAuthenticated()) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Đăng nhập để bình luận đoạn và góp ý.'),
        ),
      );
      router.push('/auth');
      return;
    }
    if (!mounted) return;
    final result = await showSegmentComposer(
      context,
      chapterId: chapter.id,
      quoteText: plainText,
    );
    if (result == null || !mounted) return;
    final message = switch (result) {
      CommentPostResult(:final wasHidden) => wasHidden
          ? 'Đã gửi — bình luận đang chờ kiểm duyệt.'
          : 'Đã gửi bình luận đoạn.',
      SuggestionPostResult() => 'Đã gửi góp ý cho tác giả.',
      _ => null,
    };
    if (message == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
    if (result is CommentPostResult) {
      router.push('/chapter-comments/${chapter.id}', extra: chapter.title);
    }
  }

  void _toggleTts(ChapterContent chapter) async {
    final markdown = chapterMarkdownOrNull(chapter);
    if (markdown == null) return;
    try {
      final handler = await ref.read(ttsHandlerProvider.future);
      _handler = handler;
      // Bật chuỗi auto-advance: hết chương này → tự chuyển chương kế +
      // tự play tiếp (listener đăng ký trong initState sẽ lo phần còn lại).
      handler.autoAdvanceEnabled = true;

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
          contentMarkdown: markdown,
          storySlug: chapter.storySlug,
          prevChapterNumber: chapter.prevChapter,
          nextChapterNumber: chapter.nextChapter,
          offline: false,
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
      data: (chapters) => ChapterListSheet(
        entries: [
          for (final c in chapters)
            ChapterListEntry(number: c.chapterNumber, title: c.title),
        ],
        currentChapter: currentChapter,
        storyId: storyId,
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
      error: (e, _) => _AccessCheckError(
        error: e,
        chapterId: chapter.id,
        storyId: storyId,
      ),
      data: (access) {
        if (access.canRead) return child;
        return VipLockedScreen(chapter: chapter, storyId: storyId);
      },
    );
  }
}

/// Shown when the access check fails (network error / 5xx). Offers a
/// retry button that re-runs the access check.
class _AccessCheckError extends ConsumerWidget {
  const _AccessCheckError({
    required this.error,
    required this.chapterId,
    required this.storyId,
  });
  final Object error;
  final String chapterId;
  final String storyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              onPressed: () =>
                  ref.invalidate(chapterAccessProvider(chapterId)),
              child: const Text('Thử lại'),
            ),
            TextButton(
              onPressed: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/story/$storyId');
                }
              },
              child: const Text('Về trang truyện'),
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
              onPressed: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/story/$storyId');
                }
              },
              icon: const Icon(Icons.arrow_back),
              label: const Text('Về trang truyện'),
            ),
          ],
        ),
      ),
    );
  }
}
