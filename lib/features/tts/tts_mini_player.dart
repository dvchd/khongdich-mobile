import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chapter_content.dart';
import 'tts_audio_handler.dart';

/// Mini player bar pinned above the chapter chrome while TTS is active.
///
/// Plan §14.3 — mini + full player. For MVP we ship the mini bar only;
/// the full player sheet lands in Phase 2.
class TtsMiniPlayer extends ConsumerStatefulWidget {
  const TtsMiniPlayer({super.key, required this.chapter});

  final ChapterContent chapter;

  @override
  ConsumerState<TtsMiniPlayer> createState() => _TtsMiniPlayerState();
}

class _TtsMiniPlayerState extends ConsumerState<TtsMiniPlayer> {
  bool _loading = false;

  Future<void> _play() async {
    if (widget.chapter is! TextChapterContent) {
      _toast('TTS chỉ hỗ trợ chương text.');
      return;
    }
    setState(() => _loading = true);
    try {
      final handler = await ref.read(ttsHandlerProvider.future);
      final c = widget.chapter as TextChapterContent;
      await handler.loadChapter(
        chapterId: c.id,
        storyId: c.storyId,
        storyTitle: c.storyTitle,
        chapterTitle: c.title,
        chapterNumber: c.chapterNumber,
        contentMarkdown: c.contentMarkdown,
      );
      await handler.play();
    } catch (e) {
      _toast('Không bật được TTS: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pause() async {
    final handler = await ref.read(ttsHandlerProvider.future);
    await handler.pause();
  }

  Future<void> _stop() async {
    final handler = await ref.read(ttsHandlerProvider.future);
    await handler.stop();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final handlerAsync = ref.watch(ttsHandlerProvider);
    return handlerAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (handler) {
        return StreamBuilder<PlaybackState>(
          stream: handler.playbackState,
          builder: (context, snapshot) {
            final state = snapshot.data;
            final playing = state?.playing ?? false;
            if (state == null ||
                state.processingState == AudioProcessingState.idle ||
                state.processingState == AudioProcessingState.error) {
              return const SizedBox.shrink();
            }
            return Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(_stateIcon(state.processingState),
                      color: const Color(0xFFE11D48)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _stateLabel(state.processingState, playing),
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (playing)
                    IconButton(
                      icon: const Icon(Icons.pause),
                      onPressed: _pause,
                      visualDensity: VisualDensity.compact,
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.play_arrow),
                      onPressed: _play,
                      visualDensity: VisualDensity.compact,
                    ),
                  IconButton(
                    icon: const Icon(Icons.stop),
                    onPressed: _stop,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  IconData _stateIcon(AudioProcessingState s) {
    return switch (s) {
      AudioProcessingState.loading || AudioProcessingState.buffering =>
        Icons.hourglass_top,
      AudioProcessingState.ready => Icons.graphic_eq,
      AudioProcessingState.error => Icons.error_outline,
      AudioProcessingState.completed => Icons.check_circle,
      AudioProcessingState.idle => Icons.play_circle_outline,
    };
  }

  String _stateLabel(AudioProcessingState s, bool playing) {
    return switch (s) {
      AudioProcessingState.loading => 'Đang chuẩn bị…',
      AudioProcessingState.buffering => 'Đang đệm…',
      AudioProcessingState.ready => playing ? 'Đang đọc' : 'Tạm dừng',
      AudioProcessingState.error => 'Lỗi TTS',
      AudioProcessingState.completed => 'Đã đọc xong',
      AudioProcessingState.idle => 'Sẵn sàng',
    };
  }
}
