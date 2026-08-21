import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tts_audio_handler.dart';
import 'tts_control_panel.dart';

/// Mini player ghim dưới đáy reader khi TTS đang phục vụ chương này.
///
/// Sau khi bỏ TtsMiniPlayer cũ (bị tap-zone overlay nuốt tap), người dùng
/// chỉ có cách mở full control panel để pause/play — bất tiện. Bản này
/// đặt NGOÀI Stack chứa tap zones (đáy của Column trong ReaderBody) nên
/// tap không bị chặn, và gói gọn các thao tác nhanh:
///   - play/pause + stop (stop cũng tắt chuỗi tự chuyển chương)
///   - progress "Đoạn x/y" + thanh tiến trình
///   - tốc độ nhanh: chạm để xoay vòng 1.0x → 1.5x → 2.0x → 0.75x
///     (áp dụng NGAY cả khi đang đọc — handler restart chunk hiện tại)
///   - chạm vào vùng progress mở full control panel
class TtsMiniPlayer extends ConsumerStatefulWidget {
  const TtsMiniPlayer({
    super.key,
    required this.chapterId,
  });

  final String chapterId;

  @override
  ConsumerState<TtsMiniPlayer> createState() => _TtsMiniPlayerState();
}

/// Mốc tốc độ xoay vòng của nút tốc độ trên mini player:
/// 1.0x → 1.5x → 2.0x → 0.75x → 1.0x.
const List<double> kMiniPlayerSpeedCycle = [1.0, 1.5, 2.0, 0.75];

/// Tính mốc tốc độ KẾ TIẾP trong vòng xoay [kMiniPlayerSpeedCycle].
///
/// Bug cũ: `firstWhere((s) => (s - current).abs() > 0.01)` chọn phần tử
/// ĐẦU TIÊN khác current — khi đang ở 1.5x, phần tử đầu khác 1.5 là 1.0
/// → vòng xoay chỉ dao động giữa 1.0x và 1.5x, không bao giờ tới 2.0x
/// hay 0.75x. Nay tìm index của current rồi chọn phần tử kế tiếp (wrap
/// về đầu khi tới cuối vòng).
double nextSpeedInCycle(double current, [List<double>? cycle]) {
  final c = cycle ?? kMiniPlayerSpeedCycle;
  final idx = c.indexWhere((s) => (s - current).abs() <= 0.01);
  if (idx >= 0) return c[(idx + 1) % c.length];
  // current ngoài vòng (vd. 1.25x đặt từ control panel) → chọn mốc lớn
  // hơn kế tiếp, hoặc quay về mốc đầu.
  return c.firstWhere(
    (s) => s > current + 0.01,
    orElse: () => c.first,
  );
}

class _TtsMiniPlayerState extends ConsumerState<TtsMiniPlayer> {
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
          // Chỉ nhận event của CHÍNH chương này — event của chương cũ/
          // chương khác (auto-advance) không được hiện sai "Đoạn x/y".
          if (p.chapterId != widget.chapterId) {
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
        // TTS init fail — mini player không hiện, reader vẫn hoạt động.
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
    // setState để cập nhật ngay (bug "ấn tốc độ dưới thanh bar không
    // thay đổi đúng").
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final handlerAsync = ref.watch(ttsHandlerProvider);
    final handler = handlerAsync.value;
    // Ẩn bar khi: chưa có handler / TTS đang phục vụ chương khác /
    // user đã bấm X "dừng hẳn và đóng".
    if (handler == null ||
        handler.currentChapterId != widget.chapterId ||
        handler.dismissedChapterId == widget.chapterId) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final playing = _playbackState?.playing ?? false;
    final total = _progress?.totalChunks ?? handler.chunkCount;
    final index = _progress?.chunkIndex ?? handler.currentChunkIndex;
    final ratio = total > 0
        ? ((index + 1) / total).clamp(0.0, 1.0)
        : 0.0;

    return Material(
      color: scheme.surfaceContainerLow,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
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
                  onTap: () => _openPanel(handler),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: ratio,
                            minHeight: 4,
                            backgroundColor:
                                scheme.primary.withValues(alpha: 0.12),
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
                            Text(
                              total > 0
                                  ? 'Đoạn ${index + 1}/$total'
                                  : 'Đang đọc',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Tốc độ nhanh — xoay vòng, áp dụng ngay khi đang đọc.
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
                icon: const Icon(Icons.stop_circle_outlined, size: 26),
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
      ),
    );
  }
}
