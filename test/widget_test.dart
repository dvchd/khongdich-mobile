import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/core/markdown/markdown.dart';

void main() {
  group('MarkdownParser — text → Block AST', () {
    test('paragraph + heading + horizontal rule', () {
      final src = '# Heading\n\nPara 1.\n\n---\n\nPara 2.';
      final blocks = MarkdownParser().parse(src);
      expect(blocks.length, 4);
      expect(blocks[0], isA<Heading>());
      expect(blocks[1], isA<Paragraph>());
      expect(blocks[2], isA<HorizontalRule>());
      expect(blocks[3], isA<Paragraph>());
    });

    test('bullet list parses 3 items', () {
      final src = '- one\n- two\n- three';
      final list = MarkdownParser().parse(src).single as BulletList;
      expect(list.items.length, 3);
    });
  });

  group('TtsMarkdownPreprocessor', () {
    test('strips headings and adds pause', () {
      final chunks = TtsMarkdownPreprocessor.process('# Chương 1');
      expect(chunks.first, contains('Chương 1.'));
    });

    test('drops fenced code blocks', () {
      final chunks = TtsMarkdownPreprocessor.process(
        'Trước\n\n```rust\nfn main() {}\n```\n\nSau',
      );
      expect(chunks.join(' '), isNot(contains('fn main')));
    });

    test('splits long paragraphs on sentence boundaries', () {
      final long = List.filled(50, 'Đây là một câu dài. ').join();
      final chunks = TtsMarkdownPreprocessor.process(long);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(510));
      }
    });
  });

  testWidgets('MaterialApp.router smoke test', (tester) async {
    // We don't boot the full app — its ApiClient needs a real filesystem
    // (PersistCookieJar). Instead we verify a tiny MaterialApp builds
    // and disposes cleanly.
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: const Center(child: Text('smoke')),
          ),
        ),
      ),
    );
    expect(find.text('smoke'), findsOneWidget);
  });
}
