import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/core/markdown/markdown.dart';
import 'package:khongdich_mobile/features/tts/tts_audio_exporter.dart';

void main() {
  group('MarkdownParser — ảnh đứng riêng dòng → ImageBlock', () {
    test('1 ảnh standalone → ImageBlock đúng url/alt', () {
      final blocks = MarkdownParser()
          .parse('![ảnh bìa](https://cdn.example/a.png)');
      expect(blocks, hasLength(1));
      final img = blocks.single as ImageBlock;
      expect(img.url, 'https://cdn.example/a.png');
      expect(img.alt, 'ảnh bìa');
    });

    test('ảnh có title "..." → caption', () {
      final blocks = MarkdownParser().parse(
          '![alt](https://cdn.example/b.png "Chú thích")');
      final img = blocks.single as ImageBlock;
      expect(img.caption, 'Chú thích');
    });

    test('nhiều ảnh mỗi dòng một ảnh (soft break) → nhiều ImageBlock', () {
      final md = '![a](https://x/1.png)\n![b](https://x/2.png)';
      final blocks = MarkdownParser().parse(md);
      expect(blocks, hasLength(2));
      expect((blocks[0] as ImageBlock).url, 'https://x/1.png');
      expect((blocks[1] as ImageBlock).url, 'https://x/2.png');
    });

    test('ảnh trộn text cùng dòng → giữ behavior cũ (text [alt])', () {
      final blocks = MarkdownParser()
          .parse('Xem ![ảnh](https://x/i.png) này.');
      final para = blocks.single as Paragraph;
      final texts = para.children.whereType<TextRun>().map((t) => t.text);
      expect(texts.join(), contains('[ảnh]'));
    });

    test('scheme không an toàn → KHÔNG tạo ImageBlock (fallback text)', () {
      final blocks = MarkdownParser().parse('![x](javascript:alert(1))');
      expect(blocks.single, isA<Paragraph>());
      expect(
        (blocks.single as Paragraph)
            .children
            .whereType<TextRun>()
            .map((t) => t.text)
            .join(),
        contains('[x]'),
      );
    });

    test('dòng ảnh + dòng text thường → paragraph text, không ảnh', () {
      final md = '![a](https://x/1.png)\nDòng chữ thường.';
      final blocks = MarkdownParser().parse(md);
      expect(blocks.single, isA<Paragraph>());
    });
  });

  group('MarkdownRenderer — caption ảnh', () {
    testWidgets('alt là tên file → KHÔNG hiện dưới ảnh (khớp web)',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownRenderer(
              blocks: MarkdownParser().parse('![3310.webp](https://x/a.webp)'),
              theme: ReaderTheme.defaults(Brightness.light),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // alt chỉ được dùng trong errorWidget khi ảnh tải lỗi (test env luôn
      // lỗi mạng) — KHÔNG có dòng caption riêng bên dưới.
      expect(find.text('3310.webp').evaluate().length, lessThanOrEqualTo(1));
    });

    testWidgets('caption tường minh "..." → hiện dưới ảnh', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownRenderer(
              blocks: MarkdownParser()
                  .parse('![alt](https://x/a.png "Tranh minh hoạ chương")'),
              theme: ReaderTheme.defaults(Brightness.light),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Tranh minh hoạ chương'), findsOneWidget);
    });
  });

  group('TtsMarkdownPreprocessor — bỏ qua ImageBlock', () {
    test('ảnh standalone không được đọc thành lời', () {
      final chunks = TtsMarkdownPreprocessor.process(
          'Trước.\n\n![ảnh bìa](https://x/y.png)\n\nSau.');
      final joined = chunks.join(' ');
      expect(joined, contains('Trước.'));
      expect(joined, contains('Sau.'));
      expect(joined, isNot(contains('ảnh bìa')));
    });
  });

  group('MarkdownRenderer — long-press paragraph nhiều dòng (WYSIWYG)', () {
    testWidgets('long-press gửi quote NGUYÊN paragraph (khớp anchor web)',
        (tester) async {
      final captured = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownRenderer(
              blocks: MarkdownParser()
                  .parse('Lời thoại A.  \nLời thoại B dài hơn.  \nLời thoại C.'),
              theme: ReaderTheme.defaults(Brightness.light),
              onParagraphLongPress: (plain) => captured.add(plain),
            ),
          ),
        ),
      ));

      // Cả 3 dòng là MỘT RichText trong cùng Paragraph — bấm vào bất kỳ
      // đâu cũng nhận plain text của cả đoạn.
      await tester.longPress(find.textContaining(
          'Lời thoại B', findRichText: true));
      await tester.pumpAndSettle();
      expect(captured.single,
          'Lời thoại A. Lời thoại B dài hơn. Lời thoại C.');
    });
  });

  group('TtsAudioExporter — SRT', () {
    Uint8List makeWav(int dataBytes, {int byteRate = 44100}) {
      final b = Uint8List(44 + dataBytes);
      b.setRange(0, 4, 'RIFF'.codeUnits);
      b.setRange(8, 12, 'WAVE'.codeUnits);
      b.setRange(12, 16, 'fmt '.codeUnits);
      b[16] = 16;
      b[20] = 1;
      b[22] = 1; // mono
      b[24] = byteRate & 0xFF; // sample rate (thay mặt cho đơn giản —
      b[25] = (byteRate >> 8) & 0xFF; // chỉ cần byteRate = sr*align đọc ra khớp)
      b[28] = byteRate & 0xFF;
      b[29] = (byteRate >> 8) & 0xFF;
      b[32] = 1; // block align 1 → byteRate header = sampleRate*align
      b[34] = 8; // bits
      b.setRange(36, 40, 'data'.codeUnits);
      b[40] = dataBytes & 0xFF;
      b[41] = (dataBytes >> 8) & 0xFF;
      b[42] = (dataBytes >> 16) & 0xFF;
      b[43] = (dataBytes >> 24) & 0xFF;
      return b;
    }

    test('formatSrtTime chuẩn hh:mm:ss,mmm', () {
      expect(TtsAudioExporter.formatSrtTime(0), '00:00:00,000');
      expect(TtsAudioExporter.formatSrtTime(3661.5), '01:01:01,500');
      expect(TtsAudioExporter.formatSrtTime(-3), '00:00:00,000');
      expect(TtsAudioExporter.formatSrtTime(754.4567), '00:12:34,457');
    });

    test('wavDurationSeconds đọc từ header WAV', () async {
      final dir = await Directory.systemTemp.createTemp('srt_test');
      final f = File('${dir.path}/a.wav')
        ..writeAsBytesSync(makeWav(88200, byteRate: 44100)); // 2 giây
      expect(await TtsAudioExporter.wavDurationSeconds(f), closeTo(2.0, 1e-9));
      await dir.delete(recursive: true);
    });

    test('buildCues: ranh giới chunk chính xác, câu chia tỷ lệ ký tự', () {
      final cues = TtsAudioExporter.buildCues(
        ['Câu đầu tiên. Câu thứ hai dài hơn nè.', 'Chunk cuối.'],
        [4.0, 2.0],
      );
      // Chunk 1: 2 câu — tổng con phải khớp đúng [0, 4].
      expect(cues[0].start, 0.0);
      expect(cues[1].end, closeTo(4.0, 1e-9));
      // Tỷ lệ ký tự: 'Câu đầu tiên.' (13) vs câu còn lại (23) trong 4s.
      expect(cues[0].duration, closeTo(4.0 * 13 / 36, 1e-9));
      expect(cues[1].duration, closeTo(4.0 * 23 / 36, 1e-9));
      // Chunk 2 kết thúc đúng 6.0.
      expect(cues.last.end, closeTo(6.0, 1e-9));
      expect(cues.last.text, 'Chunk cuối.');
      // Cue liên tục, không hở không chồng.
      for (var i = 1; i < cues.length; i++) {
        expect(cues[i].start, closeTo(cues[i - 1].end, 1e-9));
      }
    });

    test('buildSrt định dạng chuẩn SRT', () {
      final srt = TtsAudioExporter.buildSrt(const [
        SrtCue(start: 0, end: 1.5, text: 'Xin chào.'),
        SrtCue(start: 1.5, end: 3.25, text: 'Hết.'),
      ]);
      expect(
        srt,
        '1\n'
        '00:00:00,000 --> 00:00:01,500\n'
        'Xin chào.\n'
        '\n'
        '2\n'
        '00:00:01,500 --> 00:00:03,250\n'
        'Hết.\n'
        '\n',
      );
    });
  });
}

extension on SrtCue {
  double get duration => end - start;
}
