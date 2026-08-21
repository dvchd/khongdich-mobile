import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router/app_router.dart' show appRouterProvider;
import 'tts_audio_handler.dart';
import 'tts_control_panel.dart';
import 'tts_mini_player.dart' show nextSpeedInCycle;

/// Thanh "now playing" TOÀN CỤC cho TTS.
///
/// Thay thế mini player cũ ghim trong `ReaderBody` (chỉ hiện khi đang đọc
/// đúng chương mà TTS phục vụ — đổi chương là bar biến mất, điều hướng ra
/// ngoài reader cũng không biết đang nghe chương nào). Bar này được đặt ở
/// gốc app (MaterialApp.builder overlay) nên hiển thị trên MỌI màn hình
/// khi TTS đang phục vụ một chương:
///
///   - Luôn cho biết đang nghe truyện/chương nào (story + "Chương N").
///   - Điều khiển nhanh: play/pause, tốc độ (xoay vòng), stop, dismiss (X).
///   - Tap vào vùng text/progress → mở full control panel.
///   - Nút sách → nhảy thẳng tới reader của chương đang nghe.
///
/// Ẩn khi: chưa có handler / chưa load chương nào / user đã bấm X
/// "dừng hẳn và đóng" (dismissedChapterId).
class TtsNowPlayingBar extends ConsumerStatefulWidget {
  const TtsNowPlayingBar({super.key});

  @override
  ConsumerState<TtsNowPlayingBar> createState() => _TtsNowPlayingBarState();
}

class _TtsNowPlayingBarState extends ConsumerState<TtsNowPlayingBar> {
  StreamSubscription<TtsChunkProgress>? _progressSub;
  StreamSubscription<PlaybackState>? _playbackSub;
  TtsChunkProgress? _progress;
  PlaybackState? _playbackState;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      try {
        final handler = await ref.read(ttsHandlerProvider.future);
        if (!mounted) return;
        _progressSub = handler.chunkProgress.listen((p) {
          if (!mounted) return;
          // Chỉ nhận event của chương handler đang phục vụ — event của
          // chương cũ/chương khác (auto-advance) không hiện sai "Đoạn x/y".
          if (p.chapterId != handler.currentChapterId) {
            if (_progress != null) setState(() => _progress = null);
            return;
          }
          // Bỏ qua event chỉ advance blockIndex trung gian trong cùng
          // chunk — không đổi gì trên bar, đỡ rebuild không cần thiết.
          final prev = _progress;
          if (prev != null &&
              prev.chunkIndex == p.chunkIndex &&
              prev.totalChunks == p.totalChunks) {
            return;
          }
          setState(() => _progress = p);
        });
        _playbackSub = handler.playbackState.listen((s) {
          if (!mounted) return;
          final prev = _playbackState;
          // Stop/idle/error/buffering → không còn "đang đọc" đoạn nào
          // hợp lệ, xoá progress cũ để hiển thị fallback từ handler
          // (sau stop chunk index đã reset về 0).
          final shouldResetProgress =
              s.processingState == AudioProcessingState.idle ||
              s.processingState == AudioProcessingState.error ||
              s.processingState == AudioProcessingState.buffering;
          // buffering→ready lặp lại MỖI chunk — nếu không có gì thay đổi
          // (playing/processingState giữ nguyên, progress đã reset) thì
          // bỏ qua, tránh rebuild bar vài lần mỗi chunk.
          if (prev != null &&
              prev.playing == s.playing &&
              prev.processingState == s.processingState &&
              !(shouldResetProgress && _progress != null)) {
            return;
          }
          setState(() {
            _playbackState = s;
            if (shouldResetProgress) _progress = null;
          });
        });
      } catch (_) {
        // TTS init fail — bar không hiện, app vẫn hoạt động bình thường.
      }
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _playbackSub?.cancel();
    super.dispose();
  }

  void _openPanel(TtsAudioHandler handler) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      showDragHandle: true,
      builder: (_) => const TtsControlPanel(),
    );
  }

  Future<void> _cycleSpeed(TtsAudioHandler handler) async {
    final next = nextSpeedInCycle(handler.speed);
    await handler.setSpeed(next);
    // setSpeed đổi handler.speed nhưng không có stream event nào đảm
    // bảo rebuild (nhất là khi đang pause) → label "1.5x" phải tự
    // setState để cập nhật ngay.
    if (mounted) setState(() {});
  }

  /// Nhảy tới reader của chương đang nghe (online hoặc offline).
  void _goToChapter(TtsAudioHandler handler) {
    final chapterId = handler.currentChapterId;
    if (chapterId == null) return;
    final storyId = handler.currentStoryId;
    final number = handler.currentChapterNumber;
    final router = ref.read(appRouterProvider);
    if (handler.offlineMode) {
      router.go('/chapter-offline/$chapterId');
    } else if (storyId != null && number != null) {
      router.go('/chapter/$storyId:$number');
    }
  }

  @override
  Widget build(BuildContext context) {
    final handlerAsync = ref.watch(ttsHandlerProvider);
    final handler = handlerAsync.value;
    // Ẩn bar khi: chưa có handler / chưa load chương nào / user đã bấm
    // X "dừng hẳn và đóng" (dismiss).
    final visible = handler != null &&
        handler.currentChapterId != null &&
        handler.dismissedChapterId != handler.currentChapterId;

    final Widget child;
    if (!visible) {
      child = const SizedBox.shrink(key: ValueKey('tts-now-playing-hidden'));
    } else {
      final scheme = Theme.of(context).colorScheme;
      final playing = _playbackState?.playing ?? false;
      final total = _progress?.totalChunks ?? handler.chunkCount;
      final index = _progress?.chunkIndex ?? handler.currentChunkIndex;
      final ratio = total > 0
          ? ((index + 1) / total).clamp(0.0, 1.0)
          : 0.0;
      final media = handler.mediaItem.value;
      final rawTitle = media?.title ?? '';
      final number = handler.currentChapterNumber;
      final chapterLabel = number != null && rawTitle.isNotEmpty
          ? 'Chương $number · $rawTitle'
          : (rawTitle.isNotEmpty ? rawTitle : 'Chương ${number ?? ''}');
      final storyTitle = media?.album ?? '';

      child = Material(
        key: const ValueKey('tts-now-playing-bar'),
        color: scheme.surfaceContainerHigh,
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  size: 32,
                  color: scheme.primary,
                ),
                tooltip: playing ? 'Tạm dừng' : 'Nghe tiếp',
                onPressed: () {
                  if (playing) {
                    handler.pause();
                  } else {
                    handler.play();
                  }
                },
              ),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _openPanel(handler),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 4,
                      horizontal: 4,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (storyTitle.isNotEmpty)
                          Text(
                            storyTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                          ),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: ratio,
                            minHeight: 4,
                            backgroundColor: scheme.primary.withValues(
                              alpha: 0.12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.headphones,
                              size: 13,
                              color: scheme.onSurface.withValues(alpha: 0.6),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                chapterLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ),
                            Text(
                              total > 0
                                  ? 'Đoạn ${index + 1}/$total'
                                  : 'Đang đọc',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              InkWell(
                onTap: () => _cycleSpeed(handler),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Text(
                    '${handler.speed}x',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.menu_book_outlined, size: 22),
                tooltip: 'Mở chương đang nghe',
                onPressed: () => _goToChapter(handler),
              ),
              IconButton(
                icon: const Icon(Icons.stop_circle_outlined, size: 24),
                tooltip: 'Dừng (tắt tự chuyển chương)',
                onPressed: () => handler.stopAutoAdvance(),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 22),
                tooltip: 'Dừng hẳn và đóng',
                onPressed: () => handler.dismiss(),
              ),
            ],
          ),
        ),
      );
    }

    // AnimatedSwitcher nằm ngoài cả hai nhánh (hidden/shown) để bar trượt
    // + fade vào/ra mượt thay vì xuất hiện đột ngột.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.5),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
