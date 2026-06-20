import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/network/api_client.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class KhongdichApp extends ConsumerWidget {
  const KhongdichApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    // Wait for ApiClient to be ready before rendering the router.
    // The ApiClient is a FutureProvider (async init: loads JWT from
    // secure storage, resolves env). If we render the router before
    // it's ready, every screen that reads storyRepositoryProvider will
    // throw "ApiClient not ready" — this is the cold-start crash the
    // user saw.
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
          // Sync the runtime AppEnv provider.
          Future.microtask(() {
            if (ref.read(appEnvProvider) != api.env) {
              ref.read(appEnvProvider.notifier).state = api.env;
            }
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
          builder: (_, _) => Scaffold(
            backgroundColor: AppTheme.primary,
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/icons/ic_launcher_splash.png',
                    width: 96,
                    height: 96,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.menu_book, color: Colors.white, size: 72),
                  ),
                  const SizedBox(height: 16),
                  const CircularProgressIndicator(color: Colors.white),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
