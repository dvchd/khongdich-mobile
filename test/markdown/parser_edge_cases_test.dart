import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/core/markdown/markdown.dart';

void main() {
  group('TtsMarkdownPreprocessor', () {
    test('strips heading markers and adds pause', () {
      final chunks = TtsMarkdownPreprocessor.process('# Chương 1');
      expect(chunks, isNotEmpty);
      expect(chunks.first, contains('Chương 1.'));
    });

    test('drops fenced code blocks', () {
      final chunks = TtsMarkdownPreprocessor.process(
        'Trước\n\n```rust\nfn main() {}\n```\n\nSau',
      );
      expect(chunks.join(' '), isNot(contains('fn main')));
      expect(chunks.join(' '), contains('Trước'));
      expect(chunks.join(' '), contains('Sau'));
    });

    test('keeps inline-code text', () {
      final chunks = TtsMarkdownPreprocessor.process('Gõ `cargo build` đi.');
      expect(chunks.first, contains('cargo build'));
      expect(chunks.first, isNot(contains('`')));
    });

    test('drops image syntax, keeps alt label in links', () {
      final chunks = TtsMarkdownPreprocessor.process(
        'Xem [báo](https://example.com) và ![](pic.png).',
      );
      expect(chunks.first, contains('báo'));
      expect(chunks.first, isNot(contains('https')));
      expect(chunks.first, isNot(contains('![]')));
    });

    test('splits long text into <=500-char chunks', () {
      final long = List.filled(50, 'Đoạn văn đủ dài. ').join();
      final chunks = TtsMarkdownPreprocessor.process(long);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(510));
      }
    });
  });

  group('MarkdownParser — additional edge cases', () {
    test('escapes backslash-prefixed punctuation', () {
      final blocks = MarkdownParser().parse(r'Foo \*not italic\* bar');
      final para = blocks.single as Paragraph;
      // The escaped asterisks should appear literally.
      expect((para.children.first as TextRun).text, contains('*'));
    });

    test('recognises horizontal rules variants', () {
      for (final src in ['---', '***', '___', '   - - -']) {
        final blocks = MarkdownParser().parse(src);
        expect(blocks.single, isA<HorizontalRule>(), reason: 'src=$src');
      }
    });

    test('ordered list can start at non-1 value', () {
      final blocks = MarkdownParser().parse('3. Ba\n4. Bốn');
      final list = blocks.single as OrderedList;
      expect(list.start, 3);
      expect(list.items.length, 2);
    });

    test('fenced code blocks can omit language', () {
      final blocks = MarkdownParser().parse('```\nplain code\n```');
      final code = blocks.single as CodeBlock;
      expect(code.language, isNull);
      expect(code.code, 'plain code');
    });

    test('link with unsafe scheme degrades to literal text', () {
      final blocks = MarkdownParser()
          .parse('Click [here](javascript:alert(1))');
      final para = blocks.single as Paragraph;
      // No LinkRun emitted; text is preserved.
      expect(para.children.whereType<LinkRun>(), isEmpty);
      expect(
        (para.children.first as TextRun).text,
        contains('here'),
      );
    });
  });
}
