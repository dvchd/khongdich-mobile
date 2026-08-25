import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/observability/app_logger.dart';
import 'tts_speed.dart';

/// Xuất toàn bộ chương truyện thành **một file WAV** bằng TTS on-device,
/// kèm **file phụ đề SRT** (timing thật đo từ header WAV từng chunk).
///
/// Dùng `flutter_tts.synthesizeToFile()` (Android native
/// `TextToSpeech.synthesizeToFile`) — xuất WAV/PCM, KHÔNG phải MP3
/// (plugin hardcode `audio/wav`, FlutterTtsPlugin.kt). Mỗi chunk
/// (~500 ký tự, giống TTS playback) được tổng hợp ra 1 file WAV tạm
/// rồi ghép thành 1 file duy nhất (cùng sample rate/bit depth/channels
/// → nối thẳng data, giữ header file đầu).
///
/// Timing SRT: mỗi chunk có duration CHÍNH XÁC đọc từ header WAV tạm
/// (`dataSize / byteRate`) trước khi xoá — ranh giới chunk chuẩn tuyệt
/// đối. Bên trong chunk, text được chẻ theo câu và chia thời lượng tỷ
 /// lệ số ký tự (sai số nhỏ, gTTS-sidecar bên web dùng cùng cách).
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
    if (!_initialized) {
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
    }
    // Pitch/volume/rate áp MỖI LẦN export (không nằm trong guard init):
    // lần export thứ hai với tốc độ khác phải ghi đè rate cũ.
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    // Cùng công thức mapping với playback (tts_speed.dart) — truyền
    // thẳng user speed vào đây từng làm file xuất ra nhanh GẤP ĐÔI
    // tốc độ đang nghe (nghe 2.5x → file ×4 thực tế).
    await _tts.setSpeechRate(ttsRateForUserSpeed(speed));
    await _tts.awaitSynthCompletion(true);
  }

  /// Sinh WAV cho toàn bộ chunks, ghép thành 1 file tại [outputPath].
  /// Đồng thời sinh phụ đề SRT cạnh đó (`{outputPath không .wav}.srt`)
  /// từ timing thật của từng chunk — trả về trong [TtsExportResult.srt]
  /// (null khi không đo được duration, vd header WAV dị dạng).
  ///
  /// Throw `TtsExportException` khi tổng hợp thất bại.
  Future<TtsExportResult> export(String outputPath) async {
    await _configure();
    final tempDir = await getTemporaryDirectory();
    final parts = <File>[];
    final durations = <double>[];
    var durationKnown = true;
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
        final dur = await wavDurationSeconds(tmp);
        if (dur == null) {
          durationKnown = false;
        } else {
          durations.add(dur);
        }
        onProgress?.call(i + 1, chunks.length);
      }
      final merged = await mergeWavs(parts, File(outputPath));
      if (merged == null) {
        throw const TtsExportException(
            'Các đoạn audio không cùng định dạng — không ghép được.');
      }

      // SRT — chỉ sinh khi đủ duration cho mọi chunk.
      File? srt;
      if (durationKnown && durations.length == chunks.length) {
        try {
          final cues = buildCues(chunks, durations);
          if (cues.isNotEmpty) {
            final base =
                outputPath.toLowerCase().endsWith('.wav')
                    ? outputPath.substring(0, outputPath.length - 4)
                    : outputPath;
            srt = File('$base.srt');
            await srt.writeAsString(buildSrt(cues), flush: true);
          }
        } catch (e, s) {
          // SRT là tính năng kèm theo — lỗi format không được phá export.
          AppLogger.warning('TtsAudioExporter: build SRT failed', e, s);
          srt = null;
        }
      }
      return TtsExportResult(wav: merged, srt: srt);
    } finally {
      // Dọn file tạm từng chunk — không đợi (best-effort).
      for (final p in parts) {
        try {
          if (await p.exists()) await p.delete();
        } catch (_) {}
      }
    }
  }

  /// Duration (giây) đọc từ header WAV: `dataSize / byteRate`. Trả null
  /// khi header thiếu fmt chuẩn (byteRate=0 và không suy ra được từ
  /// sampleRate × blockAlign).
  static Future<double?> wavDurationSeconds(File wav) async {
    final bytes = await wav.readAsBytes();
    if (bytes.length < 44 || bytes[0] != 0x52 || bytes[1] != 0x49) {
      return null;
    }
    final dataSize = _readU32(bytes, 40);
    var byteRate = _readU32(bytes, 28);
    if (byteRate <= 0) {
      final sampleRate = _readU32(bytes, 24);
      final blockAlign = bytes[32] | (bytes[33] << 8);
      if (sampleRate > 0 && blockAlign > 0) byteRate = sampleRate * blockAlign;
    }
    if (byteRate <= 0 || dataSize <= 0) return null;
    return dataSize / byteRate;
  }

  /// Cue phụ đề từ duration chunk đã đo. Bên trong mỗi chunk chẻ TỪNG
  /// CÂU thành một cue (cue quá dài cắt cứng tại [maxCueLen] ký tự) rồi
  /// chia thời lượng tỷ lệ số ký tự — ranh giới chunk vẫn chính xác
  /// tuyệt đối vì mảnh cuối lấy phần dư, tổng con = đúng duration chunk.
  static List<SrtCue> buildCues(
    List<String> chunks,
    List<double> durations, {
    int maxCueLen = 160,
  }) {
    final out = <SrtCue>[];
    var t = 0.0;
    for (var i = 0; i < chunks.length; i++) {
      final text = chunks[i].trim();
      final dur = durations[i].clamp(0.0, double.maxFinite);
      if (text.isNotEmpty && dur > 0) {
        final sentences = _sentencesOf(text, maxLen: maxCueLen);
        if (sentences.isEmpty) {
          out.add(SrtCue(start: t, end: t + dur, text: text));
        } else {
          // Chia tỷ lệ số ký tự; mảnh CUỐI lấy phần dư để tổng con khớp
          // chính xác duration chunk (không tích lũy sai số làm tròn).
          final totalChars =
              sentences.fold<int>(0, (sum, s) => sum + s.length);
          var cursor = t;
          for (var j = 0; j < sentences.length; j++) {
            final isLast = j == sentences.length - 1;
            final end = isLast || totalChars == 0
                ? t + dur
                : cursor + dur * sentences[j].length / totalChars;
            out.add(SrtCue(
              start: cursor,
              end: end,
              text: sentences[j].trim(),
            ));
            cursor = end;
          }
        }
      }
      t += dur;
    }
    return out;
  }

  /// Chẻ text thành câu (`. `, `! `, `? `) — mỗi câu một phần tử, KHÔNG
  /// gộp câu ngắn (khác preprocessor TTS): phụ đề cần granularity câu.
  /// Câu vượt [maxLen] bị cắt cứng.
  static final RegExp _sentenceEndRegExp = RegExp(r'(?<=[.!?])\s+');

  static List<String> _sentencesOf(String text, {required int maxLen}) {
    final out = <String>[];
    for (final raw in text.split(_sentenceEndRegExp)) {
      final s = raw.trim();
      if (s.isEmpty) continue;
      if (s.length <= maxLen) {
        out.add(s);
        continue;
      }
      var start = 0;
      while (start < s.length) {
        final end = (start + maxLen).clamp(0, s.length);
        final piece = s.substring(start, end).trim();
        if (piece.isNotEmpty) out.add(piece);
        start = end;
      }
    }
    return out;
  }

  /// Serialize cues → chuỗi file `.srt` chuẩn
  /// `hh:mm:ss,mmm --> hh:mm:ss,mmm`.
  static String buildSrt(List<SrtCue> cues) {
    final sb = StringBuffer();
    for (var i = 0; i < cues.length; i++) {
      sb
        ..writeln(i + 1)
        ..writeln(
            '${formatSrtTime(cues[i].start)} --> ${formatSrtTime(cues[i].end)}')
        ..writeln(cues[i].text)
        ..writeln();
    }
    return sb.toString();
  }

  /// `02:03:04,005` — SRT dùng dấu phẩy trước mili-giây (khác WebVTT).
  static String formatSrtTime(double seconds) {
    final totalMs = (seconds < 0 ? 0 : seconds * 1000).round();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    final h = totalMs ~/ 3600000;
    final m = (totalMs % 3600000) ~/ 60000;
    final s = (totalMs % 60000) ~/ 1000;
    final ms = totalMs % 1000;
    return '${two(h)}:${two(m)}:${two(s)},${three(ms)}';
  }
}

/// Lỗi xuất audio với thông báo user-friendly.
class TtsExportException implements Exception {
  const TtsExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Kết quả export: WAV chính + SRT kèm theo (null khi không đo được
/// timing — WAV vẫn dùng được).
class TtsExportResult {
  const TtsExportResult({required this.wav, this.srt});

  final File wav;
  final File? srt;
}

/// Một cue phụ đề: `[start, end)` giây + text hiển thị.
class SrtCue {
  const SrtCue({
    required this.start,
    required this.end,
    required this.text,
  });

  final double start;
  final double end;
  final String text;
}