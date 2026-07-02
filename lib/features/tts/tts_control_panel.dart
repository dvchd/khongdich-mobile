import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tts_audio_handler.dart';

/// Full-screen TTS control panel with:
///   - Play/pause/stop buttons
///   - Engine selector (dropdown of installed TTS engines)
///   - Voice selector (dropdown of available voices)
///   - Speed selector (0.5x, 0.75x, 1.0x, 1.25x, 1.5x, 1.75x, 2.0x, 2.5x)
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
  String? _selectedEngine;
  List<Map<String, String>> _voices = const [];
  List<String> _engines = const [];
  TtsChunkProgress? _progress;

  @override
  void initState() {
    super.initState();
    _refreshFromHandler();
    widget.handler.chunkProgress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
  }

  /// Sync local state from handler. Gọi sau reinit() để dropdown cập nhật
  /// danh sách engine/voice mới (trước đây capture 1 lần trong initState
  /// → sau "Thử lại" dropdown không refresh).
  void _refreshFromHandler() {
    _speed = widget.handler.speed;
    _selectedVoice = widget.handler.selectedVoiceName;
    _selectedEngine = widget.handler.selectedEngine;
    _voices = widget.handler.availableVoices;
    _engines = widget.handler.availableEngines;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: widget.handler.playbackState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final playing = state?.playing ?? false;
        final isError = state?.processingState == AudioProcessingState.error;
        final errorMsg = state?.errorMessage;
        final mediaItem = widget.handler.mediaItem.value;

        // Bọc trong SingleChildScrollView + ConstrainedBox để panel không
        // tràn màn khi nhiều thành phần (error + title + progress + buttons
        // + 2 dropdown + speed). Trước đây không có scroll → handle bị đẩy
        // ra khỏi viewport, swipe-down khó bắt đầu → user không tắt được.
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle (giữ lại — showDragHandle của framework cũng OK
                // nhưng handle tự vẽ nhìn gọn hơn trên một số device).
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Error banner — hiện khi TTS error. Có 2 nút: "Thử lại"
                // (reinit + play) và "Đóng" (đóng panel). Trước đây chỉ có
                // "Thử lại" → user không có lối thoát khi lỗi.
                if (isError) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      border: Border.all(color: Colors.red.shade200),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                errorMsg ?? 'TTS gặp lỗi',
                                style: TextStyle(color: Colors.red.shade900, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.of(context).maybePop(),
                              child: const Text('Đóng'),
                            ),
                            const SizedBox(width: 8),
                            TextButton.icon(
                              onPressed: () async {
                                await widget.handler.reinit();
                                // Refresh dropdowns với danh sách engine/voice mới.
                                setState(_refreshFromHandler);
                                if (widget.handler.currentChapterId != null) {
                                  await widget.handler.play();
                                }
                              },
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Thử lại'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
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
                      decoration: const BoxDecoration(
                        color: Color(0xFFE11D48),
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
                // Engine selector (Nguồn nghe) — LUÔN hiện.
                // Trước đây ẩn khi _engines rỗng → user không thấy dropdown
                // → không biết chọn engine. Giờ luôn hiện, nếu rỗng thì hiện
                // hint text hướng dẫn cài engine.
                Row(
                  children: [
                    const Text('Nguồn nghe'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _engines.isEmpty
                          ? const Text(
                              'Không có engine TTS. Mở Cài đặt → Text-to-speech.',
                              style: TextStyle(
                                fontStyle: FontStyle.italic,
                                fontSize: 12,
                              ),
                            )
                          : DropdownButton<String>(
                              value: _selectedEngine,
                              hint: const Text('Mặc định hệ thống'),
                              isExpanded: true,
                              items: [
                                const DropdownMenuItem(
                                  value: null,
                                  child: Text('Mặc định hệ thống'),
                                ),
                                for (final e in _engines)
                                  DropdownMenuItem(
                                    value: e,
                                    child: Text(e),
                                  ),
                              ],
                              onChanged: (name) async {
                                final newVoices =
                                    await widget.handler.setEngine(name);
                                setState(() {
                                  _selectedEngine = name;
                                  _voices = newVoices;
                                  _selectedVoice = null;
                                });
                              },
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Voice selector (Giọng đọc) — LUÔN hiện.
                // Trước đây ẩn khi _voices rỗng → user không thấy dropdown
                // giọng đọc. Giờ luôn hiện, nếu rỗng thì hiện hint.
                Row(
                  children: [
                    const Text('Giọng đọc'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _voices.isEmpty
                          ? const Text(
                              'Không có giọng đọc. Cài engine có hỗ trợ tiếng Việt.',
                              style: TextStyle(
                                fontStyle: FontStyle.italic,
                                fontSize: 12,
                              ),
                            )
                          : DropdownButton<String>(
                              value: _selectedVoice,
                              hint: const Text('Mặc định'),
                              isExpanded: true,
                              items: [
                                const DropdownMenuItem(
                                  value: null,
                                  child: Text('Mặc định'),
                                ),
                                for (final v in _voices)
                                  DropdownMenuItem(
                                    value: v['name'],
                                    child: Text(
                                      _voiceLabel(v),
                                      overflow: TextOverflow.ellipsis,
                                    ),
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
                const SizedBox(height: 12),
                // Speed selector
                Row(
                  children: [
                    const Text('Tốc độ'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        children: [
                          for (final s in [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5])
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
              ],
            ),
          ),
        );
      },
    );
  }

  /// Build a readable label for a voice map. Format:
  ///   `[name] ([locale])`
  /// e.g. `vi-vn-language (vi-VN)`
  /// Falls back to just the name if locale is missing.
  String _voiceLabel(Map<String, String> v) {
    final name = v['name'] ?? '';
    final locale = v['locale'] ?? v['language'] ?? '';
    if (locale.isEmpty) return name;
    return '$name ($locale)';
  }
}
