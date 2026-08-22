import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router/app_router.dart' show appRouterProvider;
import 'tts_audio_handler.dart';
import 'tts_bar_state.dart';
import 'tts_control_panel.dart' show showTtsControlPanel;
import 'tts_mini_player.dart' show nextSpeedInCycle;

/// Thanh "now playing" TOÀN CỤC cho TTS.
///
/// Thay thế mini player cũ ghim trong `ReaderBody` (chỉ hiện khi đang đọc
/// đúng chương mà TTS phục vụ — đổi chương là bar biến mất, điều hướng ra
/// ngoài reader cũng không biết đang nghe chương nào). Bar được đặt vào
/// LUỒNG LAYOUT ở đáy (không phải overlay nổi) nên mọi màn hình có nó
/// trong cây khi TTS đang phục vụ một chương:
///
///   - Route KHÔNG có bottom nav (reader, settings…) → root app xếp
///     Column [nội dung, bar] — Scaffold tự thu hẹp, không đè nội dung.
///   - Route CÓ bottom nav (4 tab shell, story detail) → bar nằm trong
///     slot bottomNavigationBar, TRÊN menu (Column [bar, AppBottomNav]).
///
///   - Luôn cho biết đang nghe truyện/chương nào (story + "Chương N").
///   - Điều khiển nhanh: play/pause, tốc độ (xoay vòng), stop, dismiss (X).
///   - Tap vào vùng text/progress → mở full control panel.
///   - Nút sách → nhảy thẳng tới reader của chương đang nghe.
///
/// Ẩn khi: chưa có handler / chưa load chương nào / user đã bấm X
/// "dừng hẳn và đóng" (dismissedChapterId) / có modal sheet đang mở.
class TtsNowPlayingBar extends ConsumerStatefulWidget {
  const TtsNowPlayingBar({super.key, this.bottomSafe = false});

  /// Che đáy màn hình (safe-area gesture bar) bằng padding dưới — chỉ
  /// dùng khi bar đứng cuối layout (root Column). Trong slot
  /// bottomNavigationBar thì menu bên dưới lo phần safe này.
  final bool bottomSafe;

  @override
  ConsumerState<TtsNowPlayingBar> createState() => _TtsNowPlayingBarState();
}

class _TtsNowPlayingBarState extends ConsumerState<TtsNowPlayingBar> {
  StreamSubscription<TtsChunkProgress>? _progressSub;
  StreamSubscription<PlaybackState>? _playbackSub;
  TtsAudioHandler? _handler;
  TtsChunkProgress? _progress;
  PlaybackState? _playbackState;
  String? _lastDismissedSeen;

  @override
  void dispose() {
    _progressSub?.cancel();
    _playbackSub?.cancel();
    super.dispose();
  }

  /// (Re)subscribe stream của handler khi nó khả dụng — gọi IDEMPOTENT từ
  /// build. Trước đây subscribe 1 lần trong initState microtask:
  /// `ttsHandlerProvider` bị watch lần đầu ngay lúc boot (bar ở gốc app) —
  /// nếu dependency của provider (vd. appDatabaseProvider) chưa sẵn sàng
  /// và lỗi transient, subscription thất bại vĩnh viễn → bar không bao
  /// giờ hiện dù TTS đang chạy (TTS vẫn phát vì handler retry thành công
  /// về sau, nhưng bar không nhận event nào để rebuild).
  void _ensureSubscriptions(TtsAudioHandler handler) {
    if (identical(_handler, handler)) return;
    _progressSub?.cancel();
    _playbackSub?.cancel();
    _handler = handler;
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
      // dismissedChapterId đổi mà KHÔNG kèm thay đổi playing/state (vd.
      // bấm X ngay sau Stop: dismiss() → stop() phát lại idle/not-playing
      // y hệt event trước) → vẫn phải rebuild để bar ẩn, nếu không X sẽ
      // vô hiệu và bar kẹt trên màn hình cho tới khi có event khác.
      final dismissed = handler.dismissedChapterId;
      final dismissedChanged = dismissed != _lastDismissedSeen;
      _lastDismissedSeen = dismissed;
      // buffering→ready lặp lại MỖI chunk — nếu không có gì thay đổi
      // (playing/processingState giữ nguyên, progress đã reset) thì
      // bỏ qua, tránh rebuild bar vài lần mỗi chunk.
      if (prev != null &&
          !dismissedChanged &&
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
  }

  void _openPanel(TtsAudioHandler handler) {
    // Bar nằm TRÊN Navigator (MaterialApp.builder overlay) → context của nó
    // KHÔNG có Overlay/Navigator — showModalBottomSheet với context này sẽ
    // throw "No Overlay widget found". Dùng context của ROOT navigator.
    final navigatorContext =
        ref.read(appRouterProvider).routerDelegate.navigatorKey.currentContext;
    if (navigatorContext == null) return;
    // showTtsControlPanel ẩn bar trong lúc panel mở (bar nổi trên Navigator
    // nên modal sheet không che được nó), đóng panel thì bar hiện lại.
    unawaited(showTtsControlPanel(navigatorContext, ref));
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
    if (handler.offlineMode && storyId != null && number != null) {
      // Truyện đã tải → reader hybrid (đọc DB offline, fetch online).
      router.go('/chapter-offline/$storyId/$number');
    } else if (storyId != null && number != null) {
      router.go('/chapter/$storyId:$number');
    }
  }

  @override
  Widget build(BuildContext context) {
    final handlerAsync = ref.watch(ttsHandlerProvider);
    final handler = handlerAsync.value;
    // Subscribe idempotent khi handler khả dụng (xem _ensureSubscriptions) —
    // chịu được provider lỗi transient lúc boot (retry sau này vẫn bắt
    // được stream khi handler mới xuất hiện).
    if (handler != null) _ensureSubscriptions(handler);
    // Ẩn bar khi: chưa có handler / chưa load chương nào / user đã bấm
    // X "dừng hẳn và đóng" (dismiss) / có modal sheet đang mở (bar nằm
    // TRÊN Navigator nên không nên đè lên sheet — do TtsBarRouteObserver
    // cập nhật sheetOpen).
    //
    // sheetOpen phải được đọc qua ListenableBuilder ở cuối build:
    // ttsBarStateProvider là Provider chứa ChangeNotifier — đọc
    // `.sheetOpen` ngay trong build KHÔNG subscribe notifyListeners.
    // Trước đây bar chỉ ẩn đúng lúc nếu trùng lúc có rebuild khác
    // (chunkProgress TTS đang chạy); TTS đang PAUSE thì bar đè lên
    // sheet vĩnh viễn.
    final barState = ref.watch(ttsBarStateProvider);
    final hasChapter = handler != null &&
        handler.currentChapterId != null &&
        handler.dismissedChapterId != handler.currentChapterId;

    final Widget child;
    if (!hasChapter) {
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

      // Margin ngoài: 8 hai bên + 4 trên (dáng pill nổi); dưới = khoảng
      // nghỉ phía trên gesture bar của hệ điều hành (chỉ khi bar đứng cuối
      // layout — slot bottomNavigationBar thì menu bên dưới đã tự xử lý
      // safe-area, chỉ cần khe 4px đằm giữa bar và menu).
      child = Padding(
        padding: EdgeInsets.only(
          left: 8,
          right: 8,
          top: 4,
          bottom: widget.bottomSafe
              ? MediaQuery.paddingOf(context).bottom
              : 4,
        ),
        child: Material(
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
                                color: scheme.onSurface.withValues(
                                  alpha: 0.6,
                                ),
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
                  onPressed: () => _goToChapter(handler),
                ),
                IconButton(
                  icon: const Icon(Icons.stop_circle_outlined, size: 24),
                  onPressed: () => handler.stopAutoAdvance(),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 22),
                  onPressed: () => handler.dismiss(),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // AnimatedSwitcher nằm ngoài cả hai nhánh (hidden/shown) để bar trượt
    // + fade vào/ra mượt thay vì xuất hiện đột ngột. Padding đáy
    // (safe-area) chỉ tồn tại khi bar HIỂN THỊ — ẩn thì bar là SizedBox
    // 0px nên layout thu về, modal sheet / snackbar chạm đáy thật.
    //
    // ListenableBuilder để bar ẩn NGAY khi sheet/dialog mở và hiện lại
    // NGAY khi đóng (xem giải thích ở trên — ChangeNotifier không được
    // subscribe qua ref.watch provider thường).
    return ListenableBuilder(
      listenable: barState,
      builder: (context, _) {
        final hidden = !hasChapter || barState.sheetOpen;
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 108),
          child: AnimatedSwitcher(
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
            child: hidden
                ? const SizedBox.shrink(
                    key: ValueKey('tts-now-playing-hidden'),
                  )
                : child,
          ),
        );
      },
    );
  }
}
