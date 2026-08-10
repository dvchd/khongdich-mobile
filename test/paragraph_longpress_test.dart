import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/core/markdown/markdown.dart';
import 'package:khongdich_mobile/features/reader/views/visual_chapter_view.dart';

void main() {
  group('MarkdownRenderer paragraph long-press (bình luận đoạn)', () {
    testWidgets('long-press fires with the normalized paragraph plain text',
        (tester) async {
      final captured = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MarkdownRenderer(
                blocks: MarkdownParser()
                    .parse('Đoạn đầu tiên.\n\nĐoạn thứ **hai** nè.\n\n# Tiêu đề'),
                theme: ReaderTheme.defaults(Brightness.light),
                onParagraphLongPress: (plain) => captured.add(plain),
              ),
            ),
          ),
        ),
      );

      // RichText with mixed inline spans — find.text matches RichText too.
      await tester.longPress(find.text('Đoạn đầu tiên.', findRichText: true));
      await tester.pumpAndSettle();
      expect(captured, contains('Đoạn đầu tiên.'));

      await tester.longPress(find.text('Đoạn thứ hai nè.', findRichText: true));
      await tester.pumpAndSettle();
      expect(captured, contains('Đoạn thứ hai nè.'));

      // Headings are NOT long-pressable (only paragraphs are).
      expect(captured.length, 2);
    });

    testWidgets('no callback wired → long-press does nothing',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MarkdownRenderer(
                blocks: MarkdownParser().parse('Đoạn không có callback.'),
                theme: ReaderTheme.defaults(Brightness.light),
              ),
            ),
          ),
        ),
      );
      await tester.longPress(find.text('Đoạn không có callback.', findRichText: true));
      await tester.pumpAndSettle();
      // No crash, still rendered.
      expect(find.text('Đoạn không có callback.', findRichText: true), findsOneWidget);
    });
  });

  group('VisualChapterView', () {
    testWidgets('renders thumbnail banner + text content', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 600,
              child: VisualChapterView(
                markdown: 'Nội dung bách khoa.',
                theme: ReaderTheme.defaults(Brightness.light),
                chapterId: 'c1',
                thumbnailUrl: 'https://cdn.example/banner.png',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // Thumbnail: Image.network fails in tests → errorBuilder renders
      // (and the 16:9 box still occupies space — no crash).
      expect(find.byType(VisualChapterView), findsOneWidget);
      expect(find.text('Nội dung bách khoa.', findRichText: true), findsOneWidget);
    });

    testWidgets('renders fine without a thumbnail', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 600,
              child: VisualChapterView(
                markdown: 'Nội dung.',
                theme: ReaderTheme.defaults(Brightness.light),
                chapterId: 'c2',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Nội dung.', findRichText: true), findsOneWidget);
    });
  });
}