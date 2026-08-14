import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/core/markdown/markdown.dart';

/// Regression tests cho depth guard của parser.
///
/// Trước đây `_parseBlockquote`/`_parseList` tạo `MarkdownParser()` MỚI
/// mỗi level đệ quy → counter `_depth` luôn reset về 0 → guard không bao
/// giờ kích hoạt → nội dung lồng sâu (vd. `> > > ...` × 1000, từ server)
/// gây StackOverflowError crash toàn app. Inline recursion
/// (`**a **b ...** b** a**`) cũng không có guard.
void main() {
  group('MarkdownParser — nesting depth guard', () {
    test('deep blockquote nesting does not crash (500 levels)', () {
      final input = List.filled(500, '> ').join() + 'text';
      final blocks = MarkdownParser().parse(input);
      expect(blocks, isNotEmpty);
      // Guard fallback: tối đa 50 level BlockQuote lồng nhau, level sâu
      // nhất là Paragraph chứa raw text — không crash, không mất nội dung.
      var current = blocks.single;
      var levels = 0;
      while (current is BlockQuote) {
        current = current.children.single;
        levels++;
      }
      expect(levels, lessThanOrEqualTo(51));
      expect(current, isA<Paragraph>());
      expect(current.toJson()['children'].toString(), contains('text'));
    });

    test('deep bullet list nesting does not crash (200 levels)', () {
      final lines = <String>[];
      for (var i = 0; i < 200; i++) {
        lines.add('${'  ' * i}- item $i');
      }
      final blocks = MarkdownParser().parse(lines.join('\n'));
      expect(blocks, isNotEmpty);
    });

    test('deep inline strong nesting does not crash', () {
      // `**a **a **a ...** a** a**` — mỗi level 2 cặp marker.
      const depth = 500;
      final text = List.filled(depth, '**a ').join() +
          'core' +
          List.filled(depth, ' a**').join();
      final blocks = MarkdownParser().parse(text);
      expect(blocks, isNotEmpty);
      expect(blocks.single, isA<Paragraph>());
      final para = blocks.single as Paragraph;
      expect(para.toJson()['children'].toString(), contains('core'));
    });

    test('normal (shallow) blockquote nesting still parses correctly', () {
      const input = '> > > deep';
      final blocks = MarkdownParser().parse(input);
      expect(blocks.single, isA<BlockQuote>());
      final outer = blocks.single as BlockQuote;
      expect(outer.children.single, isA<BlockQuote>());
      final middle = outer.children.single as BlockQuote;
      expect(middle.children.single, isA<BlockQuote>());
      final inner = middle.children.single as BlockQuote;
      final para = inner.children.single as Paragraph;
      expect(para.toJson()['children'].toString(), contains('deep'));
    });

    test('sequential independent blockquotes parse independently', () {
      const input = '> a\n\n> b\n\n> c';
      final blocks = MarkdownParser().parse(input);
      expect(blocks.whereType<BlockQuote>().length, 3);
    });
  });
}
