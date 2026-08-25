import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Mở màn "Text-to-speech output" của hệ thống để user cập nhật engine
/// và tải dữ liệu giọng đọc (voice data).
///
/// Native side (MainActivity.kt, channel `khongdich/tts_settings`) dùng
/// intent `com.android.settings.TTS_SETTINGS`, fallback Cài đặt chung.
/// Không có native side (test) hoặc máy không hỗ trợ → trả false.
class TtsSettingsLauncher {
  TtsSettingsLauncher._();

  static const MethodChannel _channel = MethodChannel(
    'khongdich/tts_settings',
  );

  /// True khi đã mở được cài đặt TTS. False khi thất bại — caller nên
  /// hiện hướng dẫn vào tay (Cài đặt → Ngôn ngữ & nhập liệu →
  /// Text-to-speech).
  static Future<bool> openSystemTtsSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('openTtsSettings') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
