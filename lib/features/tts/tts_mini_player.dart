/// Helpers tốc độ dùng chung cho TTS now-playing bar.
///
/// Widget mini player ghim trong reader đã được thay bằng [TtsNowPlayingBar]
/// (tts_now_playing_bar.dart) — một thanh "now playing" toàn cục hiển thị
/// trên MỌI màn hình khi TTS đang phục vụ một chương, không chỉ riêng
/// màn hình reader của chương đang đọc. File này giữ lại các hàm thuần
/// (pure) cho vòng xoay tốc độ vì chúng được unit-test riêng.
library;

/// Mốc tốc độ xoay vòng của nút tốc độ trên now-playing bar:
/// 1.0x → 1.5x → 2.0x → 0.75x → 1.0x.
const List<double> kMiniPlayerSpeedCycle = [1.0, 1.5, 2.0, 0.75];

/// Tính mốc tốc độ KẾ TIẾP trong vòng xoay [kMiniPlayerSpeedCycle].
///
/// Bug cũ: `firstWhere((s) => (s - current).abs() > 0.01)` chọn phần tử
/// ĐẦU TIÊN khác current — khi đang ở 1.5x, phần tử đầu khác 1.5 là 1.0
/// → vòng xoay chỉ dao động giữa 1.0x và 1.5x, không bao giờ tới 2.0x
/// hay 0.75x. Nay tìm index của current rồi chọn phần tử kế tiếp (wrap
/// về đầu khi tới cuối vòng).
double nextSpeedInCycle(double current, [List<double>? cycle]) {
  final c = cycle ?? kMiniPlayerSpeedCycle;
  final idx = c.indexWhere((s) => (s - current).abs() <= 0.01);
  if (idx >= 0) return c[(idx + 1) % c.length];
  // current ngoài vòng (vd. 1.25x đặt từ control panel) → chọn mốc lớn
  // hơn kế tiếp, hoặc quay về mốc đầu.
  return c.firstWhere(
    (s) => s > current + 0.01,
    orElse: () => c.first,
  );
}
