import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/core/markdown/markdown.dart';
import 'package:khongdich_mobile/features/reader/views/text_chapter_view.dart';
import 'package:khongdich_mobile/models/chapter_content.dart';

/// Ghost "cuộn hết chương → hiện dần chương kế → cuộn qua ngưỡng thì
/// route-replace sang chương sau" (chế độ cuộn dọc).
void main() {
  ChapterContent nextChapter() => TextChapterContent(
        id: 'ch8',
        storyId: 's1',
        storyTitle: 'Truyện Test',
        storySlug: 'truyen-test',
        chapterNumber: 8,
        title: 'Tiếp theo',
        contentVersion: 1,
        wordCount: 200,
        isPublished: true,
        prevChapter: 7,
        nextChapter: 9,
        updatedAt: DateTime(2026, 8, 22),
        label: 'Q1·Ch.8',
        // Ghost phải ĐỦ CAO để top của nó vượt được lên trên ngưỡng
        // 45% viewport (ghost ngắn thì min(top) = viewport - ghostHeight
        // không bao giờ chạm ngưỡng — giống chương thật dài).
        contentMarkdown: List.generate(
          40,
          (i) => 'Đoạn chương sau $i — nội dung.',
        ).join('\n\n'),
        contentFormat: 'markdown',
      );

  testWidgets(
      'ghost hiện dần sau "Hết chương" + onContinue khi cuộn qua ngưỡng',
      (tester) async {
    var continued = 0;
    final controller = ScrollController();
    final longText = List.generate(
      40,
      (i) => 'Đoạn $i — nội dung dài để tạo scroll thật.',
    ).join('\n\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextChapterView(
            markdown: longText,
            theme: ReaderTheme.defaults(Brightness.light),
            chapterId: 'c7',
            scrollController: controller,
            nextChapter: nextChapter(),
            onContinue: () => continued++,
          ),
        ),
      ),
    );
    await tester.pump();

    // Ghost render nội dung chương kế + nhãn.
    expect(find.text('— Chương sau: Q1·Ch.8: Tiếp theo —'), findsOneWidget);
    expect(find.text('Đoạn chương sau 0 — nội dung.', findRichText: true),
        findsOneWidget);

    // Cuộn xuống hết nội dung + ghost trượt lên qua ~45% viewport.
    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(SingleChildScrollView),
          const Offset(0, -3000));
      await tester.pumpAndSettle();
    }
    await tester.drag(find.byType(SingleChildScrollView),
        const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(continued, 1);

    // Cuộn tiếp không fire lần nữa (guard một lần mỗi chương).
    await tester.drag(find.byType(SingleChildScrollView),
        const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(continued, 1);
    controller.dispose();
  });

  testWidgets('không có chương kế → không render ghost', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextChapterView(
            markdown: 'Nội dung ngắn.',
            theme: ReaderTheme.defaults(Brightness.light),
            chapterId: 'c9',
            nextChapter: null,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('— Chương sau'), findsNothing);
  });
}
