import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/features/update/app_update_provider.dart';
import 'package:khongdich_mobile/features/update/app_update_service.dart';
import 'package:khongdich_mobile/features/update/update_banner.dart';

/// Fake [AppUpdateService] — điều khiển kết quả check/tải/cài từ test.
class _FakeService implements AppUpdateService {
  _FakeService({
    this.checkResult,
    this.checkError,
    this.downloadCompleter,
    this.downloadError,
    this.installError,
  });

  final AppUpdateCheck? checkResult;
  final Object? checkError;
  final Completer<void>? downloadCompleter;
  final Object? downloadError;
  final Object? installError;
  int installCount = 0;

  @override
  Future<AppUpdateCheck> check() async {
    final error = checkError;
    if (error != null) throw error;
    return checkResult!;
  }

  @override
  Future<void> startFlexibleDownload() async {
    final error = downloadError;
    if (error != null) throw error;
    await downloadCompleter?.future;
  }

  @override
  Future<void> completeInstall() async {
    installCount++;
    final error = installError;
    if (error != null) throw error;
  }
}

ProviderContainer _makeContainer(AppUpdateService service) {
  final container = ProviderContainer(
    overrides: [appUpdateServiceProvider.overrideWithValue(service)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('AppUpdateNotifier — unit', () {
    test('Có bản mới → phase available', () async {
      final container = _makeContainer(
        _FakeService(
          checkResult: const AppUpdateCheck(available: true, versionCode: 16),
        ),
      );
      await container.read(appUpdateProvider.notifier).checkOnce();
      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.available);
      expect(container.read(appUpdateProvider).showBanner, isTrue);
    });

    test('Không có bản mới → giữ idle', () async {
      final container = _makeContainer(
        _FakeService(checkResult: const AppUpdateCheck(available: false)),
      );
      await container.read(appUpdateProvider.notifier).checkOnce();
      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.idle);
    });

    test('Check throw (không phải bản cài Play) → im lặng về idle', () async {
      // Plugin throw PlatformException/MissingPluginException trên build
      // debug/sideload — phải nuốt, không được crash hay đổi phase.
      final container = _makeContainer(
        _FakeService(checkError: StateError('no play')),
      );
      await container.read(appUpdateProvider.notifier).checkOnce();
      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.idle);
    });

    test('"Để sau" ẩn banner nhưng giữ phase', () async {
      final container = _makeContainer(
        _FakeService(checkResult: const AppUpdateCheck(available: true)),
      );
      final notifier = container.read(appUpdateProvider.notifier);
      await notifier.checkOnce();
      notifier.dismiss();
      final state = container.read(appUpdateProvider);
      expect(state.dismissed, isTrue);
      expect(state.showBanner, isFalse);
      expect(state.phase, AppUpdatePhase.available);
    });

    test('startDownload chuyển downloading → readyToInstall', () async {
      final download = Completer<void>();
      final container = _makeContainer(
        _FakeService(
          checkResult: const AppUpdateCheck(available: true),
          downloadCompleter: download,
        ),
      );
      final notifier = container.read(appUpdateProvider.notifier);
      await notifier.checkOnce();

      final pending = notifier.startDownload();
      expect(
        container.read(appUpdateProvider).phase,
        AppUpdatePhase.downloading,
      );

      download.complete();
      await pending;
      expect(
        container.read(appUpdateProvider).phase,
        AppUpdatePhase.readyToInstall,
      );
    });

    test('Tải thất bại → quay lại available để thử lại', () async {
      final container = _makeContainer(
        _FakeService(
          checkResult: const AppUpdateCheck(available: true),
          downloadError: StateError('network'),
        ),
      );
      final notifier = container.read(appUpdateProvider.notifier);
      await notifier.checkOnce();
      await notifier.startDownload();
      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.available);
    });

    test('installDownloaded gọi Play complete đúng một lần', () async {
      final service = _FakeService(
        checkResult: const AppUpdateCheck(available: true),
      );
      final container = _makeContainer(service);
      final notifier = container.read(appUpdateProvider.notifier);
      await notifier.checkOnce();
      await notifier.startDownload(); // fake tải xong ngay
      await notifier.installDownloaded();
      expect(service.installCount, 1);

      // Phase vẫn readyToInstall (Play tự restart app khi cài thành công).
      await notifier.installDownloaded();
      expect(container.read(appUpdateProvider).phase,
          AppUpdatePhase.readyToInstall);
    });

    test('Cài thất bại → giữ readyToInstall để thử lại', () async {
      final service = _FakeService(
        checkResult: const AppUpdateCheck(available: true),
        installError: StateError('install failed'),
      );
      final container = _makeContainer(service);
      final notifier = container.read(appUpdateProvider.notifier);
      await notifier.checkOnce();
      await notifier.startDownload();
      await notifier.installDownloaded();
      expect(container.read(appUpdateProvider).phase,
          AppUpdatePhase.readyToInstall);
    });
  });

  group('AppUpdateBanner — widget', () {
    testWidgets('available: hiện banner mời cập nhật', (tester) async {
      final container = _makeContainer(
        _FakeService(checkResult: const AppUpdateCheck(available: true)),
      );
      await container.read(appUpdateProvider.notifier).checkOnce();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ListView(children: const [AppUpdateBanner()]),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Có phiên bản mới'), findsOneWidget);
      expect(find.text('Cập nhật'), findsOneWidget);
      expect(find.text('Để sau'), findsOneWidget);
    });

    testWidgets('idle: banner thu về 0px', (tester) async {
      final container = _makeContainer(
        _FakeService(checkError: StateError('no play')),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ListView(children: const [AppUpdateBanner()]),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Có phiên bản mới'), findsNothing);
    });

    testWidgets('Bấm "Để sau" → banner biến mất', (tester) async {
      final container = _makeContainer(
        _FakeService(checkResult: const AppUpdateCheck(available: true)),
      );
      await container.read(appUpdateProvider.notifier).checkOnce();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ListView(children: const [AppUpdateBanner()]),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Để sau'));
      await tester.pump();

      expect(find.text('Có phiên bản mới'), findsNothing);
      expect(container.read(appUpdateProvider).dismissed, isTrue);
    });

    testWidgets('readyToInstall: hiện nút "Cài ngay"', (tester) async {
      final container = _makeContainer(
        _FakeService(checkResult: const AppUpdateCheck(available: true)),
      );
      final notifier = container.read(appUpdateProvider.notifier);
      await notifier.checkOnce();
      await notifier.startDownload(); // fake resolve = tải xong

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ListView(children: const [AppUpdateBanner()]),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Bản cập nhật đã sẵn sàng'), findsOneWidget);
      expect(find.text('Cài ngay'), findsOneWidget);
    });
  });
}
