import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/core/markdown/markdown.dart';

void main() {
  group('TtsMarkdownPreprocessor.processWithBlocks', () {
    test('maps each chunk to the exact rendered block index', () {
      final md = [
        'Đoạn một — mở đầu.',
        '',
        'Đoạn hai tiếp nối.',
        '',
        'Đoạn ba kết thúc.',
      ].join('\n');
      final blocks = MarkdownParser().parse(md);
      final chunks = TtsMarkdownPreprocessor.processWithBlocks(md);

      // 3 short paragraphs → 1 chunk (well under 500 chars).
      expect(chunks.length, 1);
      expect(chunks.single.blocks.map((b) => b.blockIndex).toList(), [0, 1, 2]);
      expect(chunks.single.text, contains('Đoạn một'));
      expect(chunks.single.text, contains('Đoạn ba'));
      expect(blocks.length, 3);
    });

    test('skips blocks with no speakable text (HR, images, code)', () {
      final md = [
        'Trước.',
        '',
        '```rust',
        'fn main() {}',
        '```',
        '',
        'Sau.',
      ].join('\n');
      final chunks = TtsMarkdownPreprocessor.processWithBlocks(md);
      expect(chunks.single.text, isNot(contains('fn main')));
      // Block 0 = "Trước.", block 1 = CodeBlock (skipped), block 2 = "Sau.".
      expect(chunks.single.blocks.map((b) => b.blockIndex).toList(), [0, 2]);
    });

    test('splits an over-long paragraph into chunks sharing one block', () {
      final long = List.filled(60, 'Câu đủ dài để cắt. ').join();
      final chunks = TtsMarkdownPreprocessor.processWithBlocks(long);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.text.length, lessThanOrEqualTo(510));
        // Every piece maps back to the single paragraph (block 0).
        expect(c.blocks.map((b) => b.blockIndex).toSet(), {0});
      }
    });

    test('chunk boundary respects paragraph boundaries', () {
      // Many ~300-char paragraphs: chunk N+1 must never start mid-block.
      final para = 'Chữ ' * 150; // 300 chars
      final md = List.generate(5, (_) => para).join('\n\n');
      final chunks = TtsMarkdownPreprocessor.processWithBlocks(md);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        // Every chunk's first block must contain the chunk's first chars
        // exactly (prefix match) — no mid-paragraph splits.
        final firstBlock = c.blocks.first;
        expect(
          c.text.startsWith(firstBlock.text.substring(0, 20)),
          isTrue,
        );
      }
    });

    test('empty and decorative markdown produce no chunks', () {
      expect(
        TtsMarkdownPreprocessor.processWithBlocks('').length,
        0,
      );
      expect(
        TtsMarkdownPreprocessor.processWithBlocks('---\n\n***').length,
        0,
      );
    });
  });
}
