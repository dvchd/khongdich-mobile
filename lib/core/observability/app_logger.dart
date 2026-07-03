import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:logger/logger.dart';

/// Lightweight singleton logger used across the app.
///
/// Plan §3 (Tech Stack → logger) and §16 (Observability). In Phase 2,
/// errors tagged with [Level.error] are forwarded to Firebase Crashlytics
/// in addition to the local console sink.
///
/// Log level is `debug` in debug builds (verbose — useful during dev)
/// and `warning` in release builds (only warnings + errors ship to
/// production logcat, avoiding information disclosure of chapter IDs,
/// story IDs, TTS engine names, etc.).
class AppLogger {
  AppLogger._();

  static late final Logger _instance;

  static void init() {
    _instance = Logger(
      printer: PrettyPrinter(
        methodCount: 0,
        errorMethodCount: 8,
        lineLength: 100,
        colors: true,
        printEmojis: false,
        dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
      ),
      level: kDebugMode ? Level.debug : Level.warning,
    );
  }

  static void debug(String message, [Object? error, StackTrace? stack]) =>
      _instance.d(message, error: error, stackTrace: stack);

  static void info(String message, [Object? error, StackTrace? stack]) =>
      _instance.i(message, error: error, stackTrace: stack);

  static void warning(String message, [Object? error, StackTrace? stack]) =>
      _instance.w(message, error: error, stackTrace: stack);

  static void error(String message, [Object? error, StackTrace? stack]) =>
      _instance.e(message, error: error, stackTrace: stack);
}
