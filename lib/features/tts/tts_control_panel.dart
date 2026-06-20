import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tts_audio_handler.dart';

/// Full-screen TTS control panel with:
///   - Play/pause/stop buttons
///   - Speed selector (0.5x – 2.5x)
///   - Voice selector (dropdown of available vi-VN voices)
///   - Progress bar showing chunk N/total
///   - Chapter title display
///
/// Plan §9.5 + §14.3 — full player sheet.
class TtsControlPanel extends ConsumerStatefulWidget {
  const TtsControlPanel({super.key});

  @override
  ConsumerState<TtsControlPanel> createState() => _TtsControlPanelState();
}

class _TtsControlPanelState extends ConsumerState<TtsControlPanel> {
  @override
  Widget build(BuildContext context) {
    final handlerAsync = ref.watch(ttsHandlerProvider);
    return handlerAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('TTS lỗi: $e')),
      data: (handler) => _PanelContent(handler: handler),
    );
  }
}

class _PanelContent extends StatefulWidget {
  const _PanelContent({required this.handler});
  final TtsAudioHandler handler;

  @override
  State<_PanelContent> createState() => _PanelContentState();
}

class _PanelContentState extends State<_PanelContent> {
  late double _speed;
  String? _selectedVoice;
  TtsChunkProgress? _progress;

  @override
  void initState() {
    super.initState();
    _speed = widget.handler.speed;
    _selectedVoice = widget.handler.selectedVoiceName;
    widget.handler.chunkProgress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: widget.handler.playbackState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final playing = state?.playing ?? false;
        final mediaItem = widget.handler.mediaItem.value;

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Chapter title
              if (mediaItem != null) ...[
                Text(
                  mediaItem.title,
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  mediaItem.album ?? '',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
              ],
              // Progress bar
              if (_progress != null) ...[
                LinearProgressIndicator(
                  value: _progress!.totalChunks > 0
                      ? _progress!.chunkIndex / _progress!.totalChunks
                      : 0,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 4),
                Text(
                  'Đoạn ${_progress!.chunkIndex + 1}/${_progress!.totalChunks}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
              ],
              // Play/pause/stop buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.stop, size: 32),
                    onPressed: () => widget.handler.stop(),
                  ),
                  const SizedBox(width: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFE11D48),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: Icon(
                        playing ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 36,
                      ),
                      iconSize: 36,
                      onPressed: () {
                        if (playing) {
                          widget.handler.pause();
                        } else {
                          widget.handler.play();
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(Icons.skip_next, size: 32),
                    onPressed: () => widget.handler.skipToNext(),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Speed selector
              Row(
                children: [
                  const Text('Tốc độ'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      children: [
                        for (final s in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5])
                          ChoiceChip(
                            label: Text('${s}x'),
                            selected: (_speed - s).abs() < 0.01,
                            onSelected: (_) async {
                              await widget.handler.setSpeed(s);
                              setState(() => _speed = s);
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Voice selector
              if (widget.handler.availableVoices.isNotEmpty) ...[
                Row(
                  children: [
                    const Text('Giọng đọc'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButton<String>(
                        value: _selectedVoice,
                        hint: const Text('Mặc định'),
                        isExpanded: true,
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('Mặc định'),
                          ),
                          for (final v in widget.handler.availableVoices)
                            DropdownMenuItem(
                              value: v['name'],
                              child: Text(v['name'] ?? ''),
                            ),
                        ],
                        onChanged: (name) async {
                          await widget.handler.setVoice(name);
                          setState(() => _selectedVoice = name);
                        },
                      ),
                    ),
                  ],
                ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Không tìm thấy giọng đọc tiếng Việt.\n'
                    'Cài đặt Google TTS → Thêm giọng → Vietnamese.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
