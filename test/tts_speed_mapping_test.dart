import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/features/tts/tts_speed.dart';

/// Khóa mapping tốc độ user → rate flutter_tts dùng chung cho playback
/// và export audio tác giả.
///
/// Bug thực tế: exporter truyền thẳng user speed (2.5 → rate 2.0) trong
/// khi playback map qua công thức này (2.5 → rate 1.0) → file tải xuống
/// nhanh GẤP ĐÔI tốc độ đang nghe ("x2.5 áp 2 lần").
void main() {
  test('mapping khớp công thức playback: (speed - 0.5) / 2', () {
    expect(ttsRateForUserSpeed(0.5), closeTo(0.0, 0.0001));
    expect(ttsRateForUserSpeed(1.0), closeTo(0.25, 0.0001));
    expect(ttsRateForUserSpeed(1.5), closeTo(0.5, 0.0001));
    expect(ttsRateForUserSpeed(2.0), closeTo(0.75, 0.0001));
    expect(ttsRateForUserSpeed(2.5), closeTo(1.0, 0.0001));
  });

  test('clamp trong khoảng flutter_tts 0.0–1.0', () {
    expect(ttsRateForUserSpeed(0.1), 0.0);
    expect(ttsRateForUserSpeed(3.0), 1.0);
  });
}
