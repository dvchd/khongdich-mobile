import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/repositories/market_repository.dart';

/// Regression test cho bug reconnect-storm SSE Chợ Phiên: trước đây đường
/// "clean close" LUÔN reset delay về 1s — server/proxy flap (chấp nhận
/// kết nối rồi đóng ngay) khiến delay không bao giờ tăng, app reconnect
/// mỗi ~1s vô hạn (spam request + drain pin). Giờ chỉ kết nối sống đủ lâu
/// (≥60s) mới được reset; kết nối chết nhanh phải nhân đôi như failure.
void main() {
  group('nextReconnectDelay', () {
    test('Kết nối sống ≥ 60s (thực sự healthy) → reset về 1s', () {
      final d = nextReconnectDelay(
        healthyFor: const Duration(minutes: 10),
        currentDelay: const Duration(seconds: 30),
      );
      expect(d, const Duration(seconds: 1));
    });

    test('Đúng ngưỡng 60s → reset', () {
      final d = nextReconnectDelay(
        healthyFor: const Duration(seconds: 60),
        currentDelay: const Duration(seconds: 16),
      );
      expect(d, const Duration(seconds: 1));
    });

    test('Flap (chết nhanh) → nhân đôi tiếp như failure', () {
      final d = nextReconnectDelay(
        healthyFor: const Duration(seconds: 59),
        currentDelay: const Duration(seconds: 4),
      );
      expect(d, const Duration(seconds: 8));
    });

    test('Flap từ mức ban đầu: 1s → 2s', () {
      final d = nextReconnectDelay(
        healthyFor: const Duration(milliseconds: 200),
        currentDelay: const Duration(seconds: 1),
      );
      expect(d, const Duration(seconds: 2));
    });

    test('Flap chuỗi dài chặn ở max 30s', () {
      var delay = const Duration(seconds: 1);
      // Nhân đôi tới 30s rồi giữ nguyên dù tiếp tục flap.
      for (var i = 0; i < 10; i++) {
        delay = nextReconnectDelay(
          healthyFor: const Duration(seconds: 1),
          currentDelay: delay,
        );
      }
      expect(delay, const Duration(seconds: 30));
    });

    test('Sau flap, kết nối ổn định lại thì delay được reset', () {
      // Mô phỏng: server down → delay tăng lên 30s → server sống lại
      // một lúc lâu (>60s) rồi đóng stream bình thường.
      var delay = const Duration(seconds: 30);
      delay = nextReconnectDelay(
        healthyFor: const Duration(hours: 1),
        currentDelay: delay,
      );
      expect(delay, const Duration(seconds: 1));
    });
  });
}
