import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/observability/app_logger.dart';

/// Xuất toàn bộ chương truyện thành **một file WAV** bằng TTS on-device.
///
/// Dùng `flutter_tts.synthesizeToFile()` (Android native
/// `TextToSpeech.synthesizeToFile`) — xuất WAV/PCM, KHÔNG phải MP3
/// (plugin hardcode `audio/wav`, FlutterTtsPlugin.kt). Mỗi chunk
/// (~500 ký tự, giống TTS playback) được tổng hợp ra 1 file WAV tạm
/// rồi ghép thành 1 file duy nhất (cùng sample rate/bit depth/channels
/// → nối thẳng data, giữ header file đầu).
///
/// Instance FlutterTts RIÊNG — không dùng chung với handler đang play
/// để không phá trạng thái playback hiện tại.
class TtsAudioExporter {
  TtsAudioExporter({
    required this.chunks,
    required this.engine,
    required this.voiceName,
    required this.speed,
    this.onProgress,
  });

  /// Các chunk text của chương (thứ tự đọc).
  final List<String> chunks;

  /// Engine TTS đang chọn (từ handler) — để file xuất khớp giọng.
  final String? engine;

  /// Voice đang chọn (từ handler).
  final String? voiceName;

  /// Tốc độ đọc (từ handler).
  final double speed;

  /// Callback tiến độ (chunkIndex, total) để UI hiển thị.
  final void Function(int done, int total)? onProgress;

  static final FlutterTts _tts = FlutterTts();
  static bool _initialized = false;

  /// Ghép các WAV (cùng format) thành 1 file. Trả null nếu header không
  /// khớp nhau (khác sample rate/bit depth — hiếm khi xảy ra).
  static Future<File?> mergeWavs(List<File> parts, File out) async {
    if (parts.isEmpty) return null;
    final first = await parts.first.readAsBytes();
    if (first.length < 44 || first[0] != 0x52 || first[1] != 0x49) {
      return null; // không phải RIFF/WAV
    }
    final outSink = out.openWrite();
    try {
      // Header của file đầu (44 bytes chuẩn PCM) — giữ nguyên, chỉ sửa
      // 2 field size cuối khi ghi xong data.
      outSink.add(first.sublist(0, 44));
      var dataBytes = 0;
      for (final part in parts) {
        final bytes = await part.readAsBytes();
        if (bytes.length < 44 ||
            bytes[0] != 0x52 ||
            bytes[1] != 0x49) {
          return null;
        }
        final dataSize = _readU32(bytes, 40);
        final dataStart = 44;
        if (dataStart + dataSize > bytes.length) return null;
        outSink.add(bytes.sublist(dataStart, dataStart + dataSize));
        dataBytes += dataSize;
      }
      await outSink.flush();
      await outSink.close();

      // Cập nhật RIFF size (byte 4) + data size (byte 40).
      final riff = File(out.path);
      final bytes = await riff.readAsBytes();
      final riffSize = 36 + dataBytes;
      final buf = Uint8List.fromList(bytes);
      buf[4] = riffSize & 0xFF;
      buf[5] = (riffSize >> 8) & 0xFF;
      buf[6] = (riffSize >> 16) & 0xFF;
      buf[7] = (riffSize >> 24) & 0xFF;
      buf[40] = dataBytes & 0xFF;
      buf[41] = (dataBytes >> 8) & 0xFF;
      buf[42] = (dataBytes >> 16) & 0xFF;
      buf[43] = (dataBytes >> 24) & 0xFF;
      await riff.writeAsBytes(buf, flush: true);
      return out;
    } catch (e, s) {
      AppLogger.warning('TtsAudioExporter: merge WAV failed', e, s);
      return null;
    }
  }

  static int _readU32(List<int> b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  /// Cấu hình TTS giống handler playback (engine/voice/ngôn ngữ Việt).
  Future<void> _configure() async {
    if (_initialized) return;
    _initialized = true;
    if (engine != null) {
      try {
        await _tts.setEngine(engine!);
      } catch (e) {
        AppLogger.warning('TtsAudioExporter: setEngine failed', e);
      }
    }
    // Thử các format ngôn ngữ Việt — giống handler (vi-VN → vi_VN → vi).
    for (final lang in const ['vi-VN', 'vi_VN', 'vi']) {
      final raw = await _tts.setLanguage(lang);
      final r = (raw is int) ? raw : int.tryParse('$raw') ?? -2;
      if (r == 0 || r == 1) break;
    }
    if (voiceName != null) {
      try {
        final voices = await _tts.getVoices;
        if (voices != null) {
          final voice = (voices as List)
              .map((v) => Map<String, String>.from(v as Map))
              .where((v) => v['name'] == voiceName)
              .firstOrNull;
          if (voice != null) await _tts.setVoice(voice);
        }
      } catch (e) {
        AppLogger.warning('TtsAudioExporter: setVoice failed', e);
      }
    }
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    await _tts.setSpeechRate(speed.clamp(0.1, 2.0));
    await _tts.awaitSynthCompletion(true);
  }

  /// Sinh WAV cho toàn bộ chunks, ghép thành 1 file tại [outputPath].
  ///
  /// Trả về File đã ghép, hoặc throw `TtsExportException` khi thất bại.
  Future<File> export(String outputPath) async {
    await _configure();
    final tempDir = await getTemporaryDirectory();
    final parts = <File>[];
    try {
      for (var i = 0; i < chunks.length; i++) {
        final tmp = File(
            '${tempDir.path}/tts_chunk_${DateTime.now().microsecondsSinceEpoch}_$i.wav');
        // isFullPath: true → ghi thẳng vào path tuyệt đối (không cần
        // quyền MediaStore), sau đó ghép thủ công.
        await _tts.synthesizeToFile(chunks[i], tmp.path, true);
        if (!await tmp.exists() || await tmp.length() < 44) {
          throw TtsExportException(
              'Chunk ${i + 1}/${chunks.length} tổng hợp thất bại (engine TTS không xuất file).');
        }
        parts.add(tmp);
        onProgress?.call(i + 1, chunks.length);
      }
      final merged = await mergeWavs(parts, File(outputPath));
      if (merged == null) {
        throw const TtsExportException(
            'Các đoạn audio không cùng định dạng — không ghép được.');
      }
      return merged;
    } finally {
      // Dọn file tạm từng chunk — không đợi (best-effort).
      for (final p in parts) {
        try {
          if (await p.exists()) await p.delete();
        } catch (_) {}
      }
    }
  }
}

/// Lỗi xuất audio với thông báo user-friendly.
class TtsExportException implements Exception {
  const TtsExportException(this.message);
  final String message;
  @override
  String toString() => message;
}