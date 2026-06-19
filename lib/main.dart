// ignore_for_file: prefer_single_quotes, require_trailing_commas
//
// Single-purpose entry point. The prefer_single_quotes / require_trailing_commas
// rules are disabled for this file because we want to keep the bootstrap concise.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/observability/app_logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.init();
  runApp(
    const ProviderScope(
      child: KhongdichApp(),
    ),
  );
}
