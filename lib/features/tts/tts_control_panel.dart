import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/observability/app_logger.dart';
import '../../repositories/story_repository.dart';
import '../profile/profile_screen.dart' show currentUserProvider;
import 'tts_audio_exporter.dart';
import 'tts_audio_handler.dart';
import 'tts_bar_state.dart';

/// Mở [TtsControlPanel] dạng bottom sheet từ MỌI nơi (bar, reader, offline
/// reader). Việc ẩn now-playing bar khi panel mở do [TtsBarRouteObserver]
/// (gắn trên GoRouter) lo — bar nổi TRÊN Navigator nên modal sheet không
/// che được nó; trước đây reader mở panel trực tiếp bằng
/// showModalBottomSheet nên bar vẫn đè lên panel.
Future<void> showTtsControlPanel(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    showDragHandle: true,
    builder: (_) => const TtsControlPanel(),
  );
}

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
  StreamSubscription<TtsChunkProgress>? _progressSub;
  StreamSubscription<PlaybackState>? _playbackSub;

  @override
  void initState() {
    super.initState();
    _refreshFromHandler();
    // Store the subscription so we can cancel it in dispose(). Previously
    // the subscription was created inline and never cancelled → memory
    // leak accumulating with each panel open/close.
    _progressSub = widget.handler.chunkProgress.listen((p) {
      if (!mounted) return;
      // Lọc theo chapterId (AGENTS.md) — event của chương khác không
      // được đụng state. Đồng thời bỏ qua event chỉ advance blockIndex
      // trung gian TRONG cùng một chunk — trước đây mỗi event như vậy
      // (vài lần mỗi chunk) rebuild cả panel gồm dropdown 100+ voice.
      if (p.chapterId != widget.handler.currentChapterId) return;
      final prev = _progress;
      if (prev != null &&
          prev.chapterId == p.chapterId &&
          prev.chunkIndex == p.chunkIndex &&
          prev.totalChunks == p.totalChunks) {
        return;
      }
      setState(() => _progress = p);
    });
    // Đồng bộ với mini player: khi stop/idle/error/buffering, xoá
    // progress cũ — trước đây panel giữ nguyên "Đoạn x/y" cũ sau khi
    // stop (bar dưới đã reset về Đoạn 1/N nhưng panel thì không).
    _playbackSub = widget.handler.playbackState.listen((s) {
      if (!mounted) return;
      if (s.processingState == AudioProcessingState.idle ||
          s.processingState == AudioProcessingState.error ||
          s.processingState == AudioProcessingState.buffering) {
        // Chỉ setState khi thực sự cần reset — tránh rebuild kép cùng
        // event với StreamBuilder bên dưới.
        if (_progress != null) setState(() => _progress = null);
      }
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _playbackSub?.cancel();
    super.dispose();
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
                            Icon(
                              Icons.error_outline,
                              color: Colors.red.shade700,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                errorMsg ?? 'TTS gặp lỗi',
                                style: TextStyle(
                                  color: Colors.red.shade900,
                                  fontSize: 13,
                                ),
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
                // Progress bar — fallback về trạng thái hiện tại của handler
                // khi chưa có event stream nào (panel mở ngay sau khi play:
                // event chunk progress đầu tiên bị bỏ lỡ vì subscribe sau).
                if (_progress != null ||
                    widget.handler.chunkCount > 0) ...[
                  LinearProgressIndicator(
                    value: (_progress?.totalChunks ??
                                widget.handler.chunkCount) >
                            0
                        ? (_progress?.chunkIndex ??
                                widget.handler.currentChunkIndex) /
                            (_progress?.totalChunks ??
                                widget.handler.chunkCount)
                        : 0,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Đoạn ${(_progress?.chunkIndex ?? widget.handler.currentChunkIndex) + 1}/'
                    '${_progress?.totalChunks ?? widget.handler.chunkCount}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                ],
                // Play/pause/stop buttons + prev/next chapter
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous, size: 32),
                      tooltip: 'Chương trước',
                      onPressed: () => widget.handler.skipToPrevious(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.stop, size: 32),
                      tooltip: 'Dừng (tắt tự chuyển chương)',
                      // stopAutoAdvance: dừng + tắt chuỗi auto-advance —
                      // nếu chỉ stop() thì hết chương sau vẫn tự nhảy.
                      onPressed: () => widget.handler.stopAutoAdvance(),
                    ),
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
                    IconButton(
                      icon: const Icon(Icons.skip_next, size: 32),
                      tooltip: 'Chương sau',
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
                              value: _engines.contains(_selectedEngine)
                                  ? _selectedEngine
                                  : null,
                              hint: const Text('Mặc định hệ thống'),
                              isExpanded: true,
                              items: [
                                const DropdownMenuItem(
                                  value: null,
                                  child: Text('Mặc định hệ thống'),
                                ),
                                for (final e in _engines)
                                  DropdownMenuItem(value: e, child: Text(e)),
                              ],
                              onChanged: (name) async {
                                final newVoices = await widget.handler
                                    .setEngine(name);
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
                              // Sanitize: nếu voice đã lưu không còn
                              // trong danh sách hiện tại (đổi engine, gỡ
                              // giọng...) thì dùng null — trước đây
                              // DropdownButton assert crash vì value
                              // không match item nào.
                              value: _voices.any(
                                  (v) => v['name'] == _selectedVoice)
                                  ? _selectedVoice
                                  : null,
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
                          for (final s in [
                            0.5,
                            0.75,
                            1.0,
                            1.25,
                            1.5,
                            1.75,
                            2.0,
                            2.5,
                          ])
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
                // Tải audio chương (chỉ tác giả truyện): TTS on-device →
                // 1 file WAV → share sheet để lưu/chia sẻ.
                AuthorChapterDownloadButton(handler: widget.handler),
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

/// Nút "Tải audio chương" — chỉ hiện khi user đang đăng nhập LÀ TÁC GIẢ
/// của truyện đang nghe.
///
/// Luồng: lấy các chunk text hiện tại của handler → `TtsAudioExporter`
/// tổng hợp từng chunk bằng TTS on-device (synthesizeToFile) → ghép
/// thành 1 file WAV → mở share sheet để tác giả lưu vào máy/gửi đi.
class AuthorChapterDownloadButton extends ConsumerStatefulWidget {
  const AuthorChapterDownloadButton({super.key, required this.handler});

  final TtsAudioHandler handler;

  @override
  ConsumerState<AuthorChapterDownloadButton> createState() =>
      _AuthorChapterDownloadButtonState();
}

class _AuthorChapterDownloadButtonState
    extends ConsumerState<AuthorChapterDownloadButton> {
  bool _exporting = false;
  bool? _isAuthor; // null = chưa xác định / không phải tác giả
  String _error = '';

  @override
  void initState() {
    super.initState();
    _checkAuthor();
  }

  /// Xác định user hiện tại có phải tác giả của story đang nghe không
  /// (so author_id của story với id user — API trả author_id ở story
  /// detail, xem story_repository.dart:106).
  Future<void> _checkAuthor() async {
    final user = ref.read(currentUserProvider).value;
    final storyId = widget.handler.currentStoryId;
    if (user == null || storyId == null || storyId.isEmpty) return;
    try {
      final repo = ref.read(storyRepositoryProvider);
      final detail = await repo.fetchStoryDetail(storyId);
      if (!mounted) return;
      setState(() => _isAuthor = detail.authorId == user.id);
    } catch (e, s) {
      AppLogger.warning('Author download: không xác định được tác giả', e, s);
      if (mounted) setState(() => _isAuthor = false);
    }
  }

  Future<void> _exportAndShare() async {
    if (_exporting) return;
    final chunks = widget.handler.chunks;
    if (chunks.isEmpty) {
      setState(() => _error = 'Chưa có nội dung chương để tổng hợp.');
      return;
    }
    setState(() {
      _exporting = true;
      _error = '';
    });
    try {
      // QUAN TRỌNG: tạm dừng playback trước khi tổng hợp. Exporter dùng
      // instance FlutterTts RIÊNG nhưng cả hai đều gọi cùng engine TTS
      // của hệ điều hành — nếu speak() đang chạy, engine hủy ngầm
      // synthesizeToFile kế tiếp và callback completion không bao giờ
      // về → export treo vĩnh viễn ở "Đang tổng hợp..." (bug gặp thật
      // trên emulator khi vừa nghe vừa tải).
      if (widget.handler.playbackState.value.playing) {
        await widget.handler.pause();
        if (mounted) {
          setState(() => _error = 'Đã tạm dừng nghe để tổng hợp...');
        }
        // Cho engine nhả hoàn toàn utterance đang chạy.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      final docDir = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final baseName =
          'chuong-${widget.handler.currentChapterNumber ?? '?'}-$stamp';
      final fileName = '$baseName.wav';
      final outPath = '${docDir.path}/$fileName';

      final exporter = TtsAudioExporter(
        chunks: chunks,
        engine: widget.handler.selectedEngine,
        voiceName: widget.handler.selectedVoiceName,
        speed: widget.handler.speed,
        onProgress: (done, total) {
          if (mounted) setState(() => _error = 'Đang tổng hợp $done/$total...');
        },
      );
      final result = await exporter.export(outPath);
      if (!mounted) return;

      // Share sheet — tác giả chọn nơi lưu (Files/Drive/gửi...). SRT đi
      // kèm để ghép phụ đề khi dựng video (timing khớp WAV).
      final files = <XFile>[
        XFile(result.wav.path, mimeType: 'audio/wav'),
        if (result.srt != null)
          XFile(result.srt!.path, mimeType: 'application/x-subrip'),
      ];
      final shareResult = await SharePlus.instance.share(
        ShareParams(
          files: files,
          fileNameOverrides: [
            fileName,
            if (result.srt != null) '$baseName.srt',
          ],
          subject: 'Audio chương truyện — Không Dịch',
        ),
      );
      if (shareResult.status == ShareResultStatus.dismissed && mounted) {
        setState(() => _error = 'Đã huỷ chia sẻ — file vẫn lưu tại '
            '${result.wav.path}');
      }
    } catch (e, s) {
      AppLogger.warning('Tải audio chương thất bại', e, s);
      if (mounted) {
        setState(() => _error =
            'Tổng hợp audio thất bại: ${e is TtsExportException ? e.message : '$e'}');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Chỉ hiện khi chưa xác định được là tác giả — đang kiểm tra.
    if (_isAuthor != true) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 8),
        Row(
          children: [
            Icon(
              _exporting ? Icons.downloading : Icons.file_download_outlined,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _exporting
                    ? _error.isEmpty
                        ? 'Đang tổng hợp audio...'
                        : _error
                    : 'Tải audio chương (WAV + phụ đề SRT) — giọng đang chọn',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (_exporting)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              FilledButton.tonal(
                onPressed: _exportAndShare,
                child: const Text('Tải audio'),
              ),
          ],
        ),
        if (!_exporting && _error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _error,
              style: TextStyle(color: Colors.red.shade700, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
