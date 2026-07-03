import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/network/api_client.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/reader/services/reading_progress_service.dart';

class KhongdichApp extends ConsumerStatefulWidget {
  const KhongdichApp({super.key});

  @override
  ConsumerState<KhongdichApp> createState() => _KhongdichAppState();
}

class _KhongdichAppState extends ConsumerState<KhongdichApp>
    with WidgetsBindingObserver {
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
    super.dispose();
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
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);

    // Wait for ApiClient to be ready before rendering the router.
    final apiAsync = ref.watch(apiClientProvider);

    return MaterialApp.router(
      title: 'Không Dịch',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: apiAsync.when(
        loading: () => _splashRouter(),
        error: (e, _) => _splashRouter(),
        data: (api) {
          // Sync the runtime AppEnv provider + flush pending progress.
          Future.microtask(() {
            if (ref.read(appEnvProvider) != api.env) {
              ref.read(appEnvProvider.notifier).state = api.env;
            }
            // Flush pending reading progress khi app khởi động (có thể
            // có row synced=0 từ session trước).
            ref.read(readingProgressServiceProvider).flushPending();
          });
          return ref.read(appRouterProvider);
        },
      ),
    );
  }

  /// A minimal router that shows a splash screen while the ApiClient
  /// is initializing. This prevents the "ApiClient not ready" crash
  /// on cold start.
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
}
