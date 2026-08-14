import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Runtime POST_NOTIFICATIONS request (Android 13+).
///
/// Without the grant, the audio_service foreground-service notification
/// (thanh quản lý audio / media controls) is silently hidden by the OS —
/// TTS still plays but the user gets no lock-screen or notification-shade
/// controls. We ask once when TTS playback starts.
class NotificationPermission {
  NotificationPermission._();

  static const MethodChannel _channel = MethodChannel(
    'khongdich/notifications',
  );

  /// True when the permission is already granted (or irrelevant, e.g.
  /// iOS / Android < 13). Calling this has no side effects.
  static Future<bool> hasPermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Request the permission. On Android 13+ the OS dialog appears; the
  /// result of the dialog is delivered asynchronously, so callers should
  /// treat this as fire-and-forget and re-check with [hasPermission] on
  /// subsequent plays.
  static Future<void> request() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } on MissingPluginException {
      // No native side (tests) — ignore.
    } on PlatformException {
      // Best-effort.
    }
  }
}
