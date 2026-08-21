import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/network/api_client.dart';
import 'core/observability/app_logger.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/reader/services/reading_progress_service.dart';
import 'features/tts/tts_audio_handler.dart';
import 'features/tts/tts_now_playing_bar.dart';
import 'services/chapter_cache_service.dart';
import 'services/download_manager.dart';

class KhongdichApp extends ConsumerStatefulWidget {
  const KhongdichApp({super.key});

  @override
  ConsumerState<KhongdichApp> createState() => _KhongdichAppState();
}

class _KhongdichAppState extends ConsumerState<KhongdichApp>
    with WidgetsBindingObserver {
  StreamSubscription<bool>? _notificationClickSub;

  @override
  void initState() {
    super.initState();
    // Observe app lifecycle state changes để flush pending reading
    // progress khi app resume (từ background → foreground).
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notificationClickSub?.cancel();
    super.dispose();
  }

  /// Tap vào media notification (thanh điều khiển khi app ẩn) → điều
  /// hướng về chương đang nghe. audio_service (MainActivity extends
  /// AudioServiceActivity) tự set activityClassName từ activity nên tap
  /// notification emit `AudioService.notificationClicked = true` — đây là
  /// lúc app chưa có route tương ứng, nên navigate qua router instance.
  void _setupNotificationDeepLink() {
    if (_notificationClickSub != null) return;
    _notificationClickSub = AudioService.notificationClicked
        .where((clicked) => clicked)
        .listen((_) {
      unawaited(_goToPlayingChapter());
    });
  }

  Future<void> _goToPlayingChapter() async {
    try {
      final handler = await ref.read(ttsHandlerProvider.future);
      final router = ref.read(appRouterProvider);
      final chapterId = handler.currentChapterId;
      if (chapterId == null) return;
      final storyId = handler.currentStoryId;
      final number = handler.currentChapterNumber;
      if (handler.offlineMode) {
        router.go('/chapter-offline/$chapterId');
      } else if (storyId != null && number != null) {
        router.go('/chapter/$storyId:$number');
      }
    } catch (e, s) {
      AppLogger.warning('TTS: notification deep link failed', e, s);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // App resume → flush pending reading progress (synced=0) lên
      // server. Đọc offline để lại row synced=0, retry khi online lại.
      Future.microtask(() {
        ref.read(readingProgressServiceProvider).flushPending();
      });
    }
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    // Android báo thiếu RAM → giải phóng cache ảnh + chapter memory
    // cache (trước đây không bao giờ được gọi — chương đọc online giữ
    // trong RAM suốt session, ảnh decode giữ trong ImageCache).
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    ref.read(chapterCacheServiceProvider).clearMemoryCache();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);

    // Wait for ApiClient to be ready before rendering the router.
    final apiAsync = ref.watch(apiClientProvider);

    // Màn hình hiện tại có bottom nav không → đặt now-playing bar lên trên
    // thay vì đè lên nav (cập nhật real-time khi đổi route).
    final hasBottomNav = locationHasBottomNav(ref.watch(topLocationProvider));

    return MaterialApp.router(
      title: 'Không Dịch',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      // Global TTS now-playing bar — overlay ở gốc app, trên MỌI màn hình
      // (reader, story detail, home...) bất kể TTS đang phục vụ chương nào.
      builder: (context, child) {
        final bottomSafe = MediaQuery.paddingOf(context).bottom;
        final barBottom =
            (hasBottomNav ? kBottomNavHeight + bottomSafe : bottomSafe) + 8;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (child != null) child,
            Positioned(
              left: 8,
              right: 8,
              bottom: barBottom,
              child: const TtsNowPlayingBar(),
            ),
          ],
        );
      },
      routerConfig: apiAsync.when(
        loading: () => _splashRouter(),
        error: (e, _) => _bootErrorRouter(e),
        data: (api) {
          // Sync the runtime AppEnv provider + flush pending progress.
          Future.microtask(() {
            if (ref.read(appEnvProvider) != api.env) {
              ref.read(appEnvProvider.notifier).state = api.env;
            }
            // Flush pending reading progress khi app khởi động (có thể
            // có row synced=0 từ session trước).
            ref.read(readingProgressServiceProvider).flushPending();
            // Recover queue kẹt 'downloading' khi app khởi động. Trước
            // đây chỉ chạy khi MỞ màn Tải xuống → rows kẹt (vd. app bị
            // kill giữa batch download) làm nút tải ở story detail bị
            // disable vĩnh viễn cho tới khi user mở đúng màn đó.
            ref.read(downloadManagerProvider).recoverInterrupted();
            // Lắng nghe tap vào media notification → điều hướng về chương
            // đang nghe (chỉ khi router đã sẵn sàng).
            _setupNotificationDeepLink();
          });
          return ref.read(appRouterProvider);
        },
      ),
    );
  }

  /// Minimal router shown while the ApiClient is initializing. This
  /// prevents the "ApiClient not ready" crash on cold start.
  GoRouter _splashRouter() {
    return GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final bgColor = isDark ? const Color(0xFF0F172A) : const Color(0xFFFAFAFA);
            final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
            return Scaffold(
              backgroundColor: bgColor,
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Image.asset(
                        'assets/icons/ic_launcher.png',
                        width: 96,
                        height: 96,
                        errorBuilder: (_, _, _) => Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            color: AppTheme.primary,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: const Icon(
                            Icons.menu_book,
                            color: Colors.white,
                            size: 48,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Không Dịch',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    CircularProgressIndicator(color: AppTheme.primary),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  /// Minimal router shown when the ApiClient fails to initialize
  /// (e.g. secure-storage platform error). Instead of an eternal
  /// spinner, show the error with a retry button that re-runs the
  /// initialization.
  GoRouter _bootErrorRouter(Object error) {
    return GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final bgColor = isDark
                ? const Color(0xFF0F172A)
                : const Color(0xFFFAFAFA);
            final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
            return Scaffold(
              backgroundColor: bgColor,
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 64,
                        color: isDark ? const Color(0xFFF87171) : AppTheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Không khởi động được ứng dụng',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '$error',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: textColor.withValues(alpha: 0.6),
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: () => ref.invalidate(apiClientProvider),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Thử lại'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
