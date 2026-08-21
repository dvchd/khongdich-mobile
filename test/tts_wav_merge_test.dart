import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/features/tts/tts_audio_exporter.dart';

/// Verify WAV merging: nối data của các WAV cùng format, giữ header file
/// đầu, cập nhật RIFF size + data size.
void main() {
  Uint8List makeWav(int dataBytes) {
    final total = 44 + dataBytes;
    final b = Uint8List(total);
    // RIFF header
    b.setRange(0, 4, 'RIFF'.codeUnits);
    b[4] = (36 + dataBytes) & 0xFF;
    b[5] = ((36 + dataBytes) >> 8) & 0xFF;
    b[6] = ((36 + dataBytes) >> 16) & 0xFF;
    b[7] = ((36 + dataBytes) >> 24) & 0xFF;
    b.setRange(8, 12, 'WAVE'.codeUnits);
    b.setRange(12, 16, 'fmt '.codeUnits);
    b[16] = 16; // fmt chunk size
    b[20] = 1; // PCM
    b[22] = 1; // mono
    // sample rate 22050 (bytes 24-27)
    b[24] = 0x22;
    b[25] = 0x56;
    // byte rate (bytes 28-31) — bỏ qua
    // block align (32-33), bits (34-35)
    b.setRange(36, 40, 'data'.codeUnits);
    b[40] = dataBytes & 0xFF;
    b[41] = (dataBytes >> 8) & 0xFF;
    b[42] = (dataBytes >> 16) & 0xFF;
    b[43] = (dataBytes >> 24) & 0xFF;
    for (var i = 44; i < total; i++) {
      b[i] = (i - 44) & 0xFF;
    }
    return b;
  }

  int readU32(List<int> b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  test('ghép 2 WAV cùng format → 1 file đúng size', () async {
    final dir = await Directory.systemTemp.createTemp('wav_test');
    final a = File('${dir.path}/a.wav')..writeAsBytesSync(makeWav(100));
    final b = File('${dir.path}/b.wav')..writeAsBytesSync(makeWav(50));
    final out = File('${dir.path}/out.wav');

    final result = await TtsAudioExporter.mergeWavs([a, b], out);

    expect(result, isNotNull);
    final bytes = await result!.readAsBytes();
    expect(bytes.length, 44 + 150); // header + 100 + 50 data
    expect(readU32(bytes, 4), 36 + 150); // RIFF size
    expect(readU32(bytes, 40), 150); // data size
    // Data file đầu nối tiếp data file sau.
    expect(bytes[44], 0);
    expect(bytes[143], 99);
    expect(bytes[144], 0);
    expect(bytes[193], 49);
    // Header giữ nguyên từ file đầu.
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    await dir.delete(recursive: true);
  });

  test('file không phải WAV → trả null', () async {
    final dir = await Directory.systemTemp.createTemp('wav_test2');
    final bad = File('${dir.path}/bad.wav')
      ..writeAsBytesSync(Uint8List.fromList(List.filled(100, 1)));
    final out = File('${dir.path}/out.wav');

    final result = await TtsAudioExporter.mergeWavs([bad], out);
    expect(result, isNull);
    await dir.delete(recursive: true);
  });
}