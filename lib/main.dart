import 'package:firebase_core/firebase_core.dart';
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

  // Initialise Firebase — required by firebase_messaging for push.
  try {
    await Firebase.initializeApp();
  } catch (e, s) {
    AppLogger.warning('Firebase init failed (push will be disabled)', e, s);
  }
  runApp(
    const ProviderScope(
      child: KhongdichApp(),
    ),
  );
}
