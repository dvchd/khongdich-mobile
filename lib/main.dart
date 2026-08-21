import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/observability/app_logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.init();

  // Enable max refresh rate (120 Hz) on supported displays.
  // Flutter 3.x respects the AndroidManifest meta-data
  // `io.flutter.embedding.android.EnablePreferredRefreshRate` = true.
  // (timeDilation = 1.0 trước đây ở đây là no-op — giá trị mặc định.)

  // Firebase đã bị bỏ — app dùng in-app notifications (GET /api/v1/mobile/
  // notifications) thay vì FCM push. Khi cần push lại: re-add firebase_core
  // + firebase_messaging, populate google-services.json, xây backend
  // push_devices table + FCM sender. Xem README mục "Tính năng thông báo".
  runApp(
    ProviderScope(
      // Riverpod 3.0 mặc định tự retry provider fail vô hạn — app v2 giữ
      // error cho tới khi invalidate thủ công (nút "Thử lại" trong UI).
      // Tắt retry tự động để giữ hành vi cũ, tránh spam API khi server lỗi.
      retry: (retryCount, error) => null,
      child: KhongdichApp(),
    ),
  );
}
