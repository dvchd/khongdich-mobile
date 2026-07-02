import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/scheduler.dart';

import 'app.dart';
import 'core/observability/app_logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.init();

  // Enable max refresh rate (120 Hz) on supported displays.
  // Flutter 3.x respects the AndroidManifest meta-data
  // `io.flutter.embedding.android.EnablePreferredRefreshRate` = true,
  // but we also set the timeDilation to 1.0 (normal speed) and
  // ensure the refresh rate is not throttled by the framework.
  timeDilation = 1.0;

  // Firebase đã bị bỏ — app dùng in-app notifications (GET /api/v1/mobile/
  // notifications) thay vì FCM push. Khi cần push lại: re-add firebase_core
  // + firebase_messaging, populate google-services.json, xây backend
  // push_devices table + FCM sender. Xem README mục "Tính năng thông báo".
  runApp(
    const ProviderScope(
      child: KhongdichApp(),
    ),
  );
}
