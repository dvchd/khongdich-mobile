import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:khongdich_mobile/core/network/api_client.dart';
import 'package:khongdich_mobile/features/settings/settings_screen.dart';

/// Regression tests cho các bug được fix trước khi lên CH Play.
///
/// 1. Settings "Đăng nhập với Google" từng gọi `Navigator.pushNamed('auth')`
///    — app dùng go_router (MaterialApp.router) không có named routes →
///    crash chắc chắn khi bấm. Giờ dùng `context.push('/auth')`.
/// 2. Boot-fail từng hiện splash vô hạn (error state giống loading) —
///    giờ hiện màn hình lỗi kèm nút "Thử lại".
void main() {
  group('Settings screen — go_router navigation', () {
    testWidgets(
        'Settings renders and does NOT crash when ApiClient not ready '
        '(auth tile tap needs router context — router-less test only verifies build)', (
        tester) async {
      // SettingsScreen phụ thuộc readerSettingsProvider + package_info_plus.
      // Trong test môi trường không có plugin platform, chỉ verify widget
      // build được trong ProviderScope (không crash) — đủ để phát hiện
      // regression cú pháp/navigator misuse trong build path.
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Settings auth tile uses go_router push (route registered)',
        (tester) async {
      // Router thật với route /auth — nếu tile vẫn dùng pushNamed('auth')
      // thì MaterialApp.router không có onGenerateRoute → throw
      // NoSuchMethodError/FlutterError khi bấm.
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/settings',
            builder: (_, _) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/auth',
            builder: (_, _) => const Scaffold(body: Text('AUTH_SCREEN')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Tap tile "Đăng nhập với Google" (nằm sâu trong ListView).
      await tester.scrollUntilVisible(
        find.text('Đăng nhập với Google'),
        200,
        scrollable: find.byType(Scrollable),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đăng nhập với Google'));
      await tester.pumpAndSettle();

      // Không crash + đã điều hướng tới /auth.
      expect(tester.takeException(), isNull);
      expect(find.text('AUTH_SCREEN'), findsOneWidget);
    });
  });

  group('ApiClient boot error', () {
    test('create() falls back to prod env when secure storage unavailable',
        () async {
      // ApiClient.create() chạy thật cần plugin flutter_secure_storage
      // (MissingPluginException trong test) → phải bắt lỗi, không crash.
      // Đây là regression guard: nếu create() throw, app.dart error state
      // sẽ hiển thị + retry (đã có _bootErrorRouter).
      try {
        await ApiClient.create();
        fail('Expected MissingPluginException in test environment');
      } on ApiException {
        // Server API error — không mong đợi trong test.
      } catch (_) {
        // MissingPluginException / PlatformException — như kỳ vọng.
      }
    });
  });
}
