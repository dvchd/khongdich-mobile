import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../tts/tts_audio_handler.dart';

/// One row in the shared [ChapterListSheet].
///
/// Both the online reader (which fetches chapters from the API) and
/// the offline reader (which loads chapters from local Drift) build
/// a list of [ChapterListEntry] and pass it to [ChapterListSheet].
/// The sheet itself doesn't care where the data came from — it just
/// renders the list and fires [onSelect] with the chosen chapter
/// number.
class ChapterListEntry {
  const ChapterListEntry({
    required this.number,
    required this.title,
  });
  final int number;
  final String title;
}

/// Bottom sheet listing chapters in the current story.
///
/// Shared by the online and offline readers. The parent screen
/// supplies the entries (from API or Drift) and an `onSelect`
/// callback that performs the navigation appropriate for its data
/// source (online → `/chapter/$storyId:$number`, offline →
/// `/chapter-offline/$chapterId`).
///
/// The current chapter is highlighted with [AppTheme.primary] and a
/// check-circle icon.
///
/// **Theo dõi TTS real-time**: khi [storyId] != null, nếu handler đang
/// phục vụ một chương của story đó (kể cả auto-advance đổi chương
/// ngay trong lúc sheet đang mở) thì chương ĐANG NGHE mới là chương
/// được tô check — audio là nguồn chân lý. Không nghe nữa (chưa có
/// chương nào load / đã bấm X / story khác) thì fallback về
/// [currentChapter] (chương màn hình đang hiển thị). Lúc mở sheet,
/// list tự scroll để chương hiện tại nằm trong khung nhìn.
class ChapterListSheet extends ConsumerStatefulWidget {
  const ChapterListSheet({
    super.key,
    required this.entries,
    required this.currentChapter,
    required this.onSelect,
    this.storyId,
  });

  final List<ChapterListEntry> entries;
  final int currentChapter;
  final ValueChanged<int> onSelect;

  /// Story id của màn hình mở sheet — dùng để khớp với chương đang
  /// nghe của TTS (xem class doc).
  final String? storyId;

  @override
  ConsumerState<ChapterListSheet> createState() => _ChapterListSheetState();
}

class _ChapterListSheetState extends ConsumerState<ChapterListSheet> {
  TtsAudioHandler? _handler;
  StreamSubscription<TtsChunkProgress>? _progressSub;
  StreamSubscription<PlaybackState>? _playbackSub;

  /// Chương TTS đang phục vụ (nếu thuộc story của sheet). null = không
  /// nghe gì → dùng [ChapterListSheet.currentChapter].
  int? _liveChapter;

  bool _initialScrollDone = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      try {
        final handler = await ref.read(ttsHandlerProvider.future);
        if (!mounted) return;
        _handler = handler;
        // chunkProgress fire mỗi chunk (và mỗi block advance) còn
        // playbackState fire khi load/stop chương → sheet đổi chỉ báo
        // NGAY khi handler chuyển chương, không cần user mở lại.
        _progressSub = handler.chunkProgress.listen((_) => _syncFromHandler());
        _playbackSub = handler.playbackState.listen((_) => _syncFromHandler());
        _syncFromHandler();
      } catch (_) {
        // TTS init fail — sheet vẫn hoạt động với chương màn hình.
      }
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _playbackSub?.cancel();
    super.dispose();
  }

  /// Chương được tô check: chương đang nghe (nếu có) → chương màn hình.
  int get _activeChapter => _liveChapter ?? widget.currentChapter;

  void _syncFromHandler() {
    final h = _handler;
    if (h == null || !mounted) return;
    final serving = widget.storyId != null &&
        h.currentStoryId == widget.storyId &&
        h.currentChapterId != null &&
        h.dismissedChapterId != h.currentChapterId;
    final live = serving ? h.currentChapterNumber : null;
    // Chương nghe phải có trong list (offline: chỉ chương đã tải;
    // online: danh sách API) — nếu không thì giữ chương màn hình.
    final inEntries =
        live != null && widget.entries.any((e) => e.number == live);
    final next = inEntries ? live : null;
    if (next == _liveChapter) return;
    setState(() => _liveChapter = next);
  }

  /// Scroll để chương đang chọn nằm trong khung nhìn — chỉ chạy MỘT
  /// lần khi mở sheet (không tự kéo list khi user đang tự cuộn).
  void _scrollToActiveOnce(ScrollController controller) {
    if (_initialScrollDone) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _initialScrollDone) return;
      if (!controller.hasClients) return;
      final i = widget.entries
          .indexWhere((e) => e.number == _activeChapter);
      if (i <= 0) return;
      // ListTile 1 dòng cao 56px (mặc định Material). -8 để chương
      // không dính sát mép dưới của header sheet.
      final target = (i * 56.0 - 8).clamp(
        0.0,
        controller.position.maxScrollExtent,
      );
      if (target <= 0) return;
      _initialScrollDone = true;
      controller.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        _scrollToActiveOnce(scrollController);
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text('Danh sách chương',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: widget.entries.isEmpty
                    ? const Center(child: Text('Chưa có chương nào.'))
                    : ListView.builder(
                        controller: scrollController,
                        // Mọi hàng ListTile đồng dạng (title 1 dòng, không
                        // subtitle) → itemExtent cố định, cuộn nhanh danh
                        // sách hàng trăm chương không phải đo từng item.
                        itemExtent: 56,
                        itemCount: widget.entries.length,
                        itemBuilder: (_, i) {
                          final e = widget.entries[i];
                          final isCurrent = e.number == _activeChapter;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: isCurrent
                                  ? AppTheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                              child: Text(
                                '${e.number}',
                                style: TextStyle(
                                  color: isCurrent
                                      ? Colors.white
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurface,
                                ),
                              ),
                            ),
                            title: Text(
                              e.title.isEmpty
                                  ? 'Chương ${e.number}'
                                  : e.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: isCurrent
                                  ? TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.primary,
                                    )
                                  : null,
                            ),
                            trailing: isCurrent
                                ? const Icon(Icons.check_circle,
                                    color: AppTheme.primary, size: 20)
                                : null,
                            onTap: () {
                              Navigator.of(context).pop();
                              widget.onSelect(e.number);
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
