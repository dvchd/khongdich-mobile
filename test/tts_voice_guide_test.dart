import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/features/tts/tts_voice_guide_sheet.dart';

/// Tên engine hiển thị trong sheet hướng dẫn cập nhật giọng đọc — map
/// package name kỹ thuật sang tên đọc được, khớp engine chính trên thị
/// trường (Google/Samsung/Huawei).
void main() {
  test('package name Google → tên hiển thị Google', () {
    expect(
      ttsEngineDisplayName('com.google.android.tts'),
      'Google (Speech Recognition & Synthesis)',
    );
  });

  test('package name Samsung → Samsung TTS', () {
    expect(ttsEngineDisplayName('com.samsung.SMT'), 'Samsung TTS');
  });

  test('package name Huawei → Huawei TTS', () {
    expect(ttsEngineDisplayName('com.huawei.vassistant'), 'Huawei TTS');
  });

  test('engine lạ giữ nguyên package name', () {
    expect(ttsEngineDisplayName('com.example.tts'), 'com.example.tts');
  });

  test('engine null/rỗng → engine mặc định của máy', () {
    expect(ttsEngineDisplayName(null), 'Engine mặc định của máy');
    expect(ttsEngineDisplayName(''), 'Engine mặc định của máy');
  });
}
