/// Ánh xạ tốc độ user-facing (0.5–2.5x trong UI) → rate flutter_tts
/// (0.0–1.0).
///
/// **PHẢI dùng chung ở MỌI nơi gọi `setSpeechRate`** — playback
/// (`TtsAudioHandler._applySpeed`) và export (`TtsAudioExporter`). Nếu
/// hai nơi dùng công thức khác nhau, file tải xuống sẽ nhanh/chậm khác
/// tốc độ đang nghe (bug thực tế: nghe 2.5x → file xuất ra nhanh gấp
/// đôi, "2.5x áp 2 lần").
///
/// flutter_tts Android nhân rate này với 2 trước khi đưa engine
/// (FlutterTtsPlugin.kt: `rate * 2.0f`, "Android 1.0 is mapped to
/// flutter 0.5") — flutter 0.5 = Android 1.0 (tốc độ bình thường).
double ttsRateForUserSpeed(double speed) =>
    ((speed - 0.5) / 2.0).clamp(0.0, 1.0);
