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

  static Logger? _instance;

  /// Lazy singleton — tự tạo logger nếu [init] chưa chạy (vd. widget
  /// test không gọi main()). `init()` chỉ để khởi tạo sớm / rõ ràng.
  static Logger get _log => _instance ??= _build();

  static Logger _build() => Logger(
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

  static void init() {
    _instance ??= _build();
  }

  static void debug(String message, [Object? error, StackTrace? stack]) =>
      _log.d(message, error: error, stackTrace: stack);

  static void info(String message, [Object? error, StackTrace? stack]) =>
      _log.i(message, error: error, stackTrace: stack);

  static void warning(String message, [Object? error, StackTrace? stack]) =>
      _log.w(message, error: error, stackTrace: stack);

  static void error(String message, [Object? error, StackTrace? stack]) =>
      _log.e(message, error: error, stackTrace: stack);
}
