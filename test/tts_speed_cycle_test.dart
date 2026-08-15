import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/features/tts/tts_mini_player.dart';

/// Regression test cho vòng xoay tốc độ trên mini player.
///
/// Bug cũ: `firstWhere((s) => (s - current).abs() > 0.01)` chọn phần tử
/// ĐẦU TIÊN khác current → khi đang 1.5x chọn 1.0x → vòng xoay chỉ dao
/// động giữa 1.0x và 1.5x (user chỉ chọn được 2 tốc độ).
void main() {
  test('xoay vòng đủ 4 mốc 1.0 → 1.5 → 2.0 → 0.75 → 1.0', () {
    expect(nextSpeedInCycle(1.0), 1.5);
    expect(nextSpeedInCycle(1.5), 2.0);
    expect(nextSpeedInCycle(2.0), 0.75);
    expect(nextSpeedInCycle(0.75), 1.0);
  });

  test('current ngoài vòng → mốc lớn hơn kế tiếp', () {
    expect(nextSpeedInCycle(1.25), 1.5);
    expect(nextSpeedInCycle(0.9), 1.0);
  });

  test('current trên mốc cuối → quay về mốc đầu', () {
    expect(nextSpeedInCycle(2.5), 1.0);
  });
}
