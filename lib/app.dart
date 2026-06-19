import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/network/api_client.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class KhongdichApp extends ConsumerWidget {
  const KhongdichApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);

    // Pre-warm the ApiClient (loads JWT + base URL). It's okay if this
    // FutureProvider is still loading on first paint — every consumer
    // that needs an ApiClient uses ref.watch + .maybeWhen to gracefully
    // handle the loading state.
    final apiAsync = ref.watch(apiClientProvider);
    // Sync the runtime AppEnv provider so the Settings screen can
    // display the active environment as soon as the ApiClient is ready.
    if (apiAsync.hasValue) {
      final api = apiAsync.value!;
      // Only update if the value actually changed to avoid loops.
      Future.microtask(() {
        if (ref.read(appEnvProvider) != api.env) {
          ref.read(appEnvProvider.notifier).state = api.env;
        }
      });
    }

    return MaterialApp.router(
      title: 'Không Dịch',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
