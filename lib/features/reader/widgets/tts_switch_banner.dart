import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/chapter_content.dart';
import '../../tts/tts_audio_handler.dart';

/// Banner nhỏ trong reader khi TTS đang đọc MỘT CHƯƠNG KHÁC của cùng
/// truyện so với chương user đang đọc.
///
/// Giải quyết bối rối "đổi chương mà audio vẫn đọc chương cũ": thay vì
/// để user không biết gì, banner cho biết đang nghe chương nào và cho
/// nút "Nghe chương này" để chuyển TTS sang chương đang mở (tái dùng
/// luồng headphone `_toggleTts` của màn hình — load + play chương này).
///
/// Tự ẩn khi: TTS chuyển sang đúng chương này (condition fail), user bấm
/// X, hoặc handler không còn phục vụ truyện này.
class TtsSwitchChapterBanner extends ConsumerStatefulWidget {
  const TtsSwitchChapterBanner({
    super.key,
    required this.chapter,
    this.onSwitchToThis,
  });

  final ChapterContent chapter;

  /// Load + play TTS cho chương đang đọc (nối thẳng vào `onToggleTts`).
  final VoidCallback? onSwitchToThis;

  @override
  ConsumerState<TtsSwitchChapterBanner> createState() =>
      _TtsSwitchChapterBannerState();
}

class _TtsSwitchChapterBannerState
    extends ConsumerState<TtsSwitchChapterBanner> {
  StreamSubscription<PlaybackState>? _playbackSub;
  StreamSubscription<TtsChunkProgress>? _progressSub;
  TtsAudioHandler? _handler;
  int? _playingChapter;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      try {
        final handler = await ref.read(ttsHandlerProvider.future);
        if (!mounted) return;
        _handler = handler;
        // loadChapter/play/stop đều emit playbackState; chunkProgress fire
        // mỗi chunk → banner cập nhật NGAY khi handler đổi chương (kể cả
        // auto-advance khi app bị ẩn rồi mở lại).
        void sync() {
          if (!mounted) return;
          final ch = handler.currentChapterNumber;
          if (ch != _playingChapter) setState(() => _playingChapter = ch);
        }

        _progressSub = handler.chunkProgress.listen((_) => sync());
        _playbackSub = handler.playbackState.listen((_) => sync());
        sync();
      } catch (_) {
        // TTS init fail — không hiện banner, reader vẫn hoạt động.
      }
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _playbackSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final handler = _handler;
    if (handler == null || _dismissed) return const SizedBox.shrink();
    final current = handler.currentChapterId;
    // Chỉ hiện khi handler đang phục vụ MỘT chương KHÁC của CÙNG truyện
    // với chương đang đọc (và chưa bị dismiss).
    if (current == null ||
        current == widget.chapter.id ||
        handler.dismissedChapterId == current ||
        handler.currentStoryId != widget.chapter.storyId) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(
          children: [
            Icon(
              Icons.headphones,
              size: 16,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Đang nghe Chương ${handler.currentChapterNumber ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
              ),
            ),
            TextButton(
              onPressed: widget.onSwitchToThis,
              child: const Text('Nghe chương này'),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Ẩn',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _dismissed = true),
            ),
          ],
        ),
      ),
    );
  }
}
