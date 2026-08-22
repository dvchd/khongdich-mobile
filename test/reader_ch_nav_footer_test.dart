import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:khongdich_mobile/features/reader/reader_settings_provider.dart';
import 'package:khongdich_mobile/features/reader/widgets/reader_body.dart';
import 'package:khongdich_mobile/models/chapter_content.dart';

/// Ch-nav cuối chương (mirror web `.ch-nav`): 2 nút "← Ch.trước" /
/// "Ch.kế →" hiện đúng nhãn chương mấy; cache cũ fallback "Ch. N";
/// chương đầu/cuối ẩn nút tương ứng.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  TextChapterContent chapter({
    int chapterNumber = 7,
    int? prev,
    int? next,
    String? title = 'Vân Tĩnh Nhai',
    String? label,
    String? prevLabel,
    String? nextLabel,
    ReaderScrollMode mode = ReaderScrollMode.vertical,
  }) =>
      TextChapterContent(
        id: 'ch$chapterNumber',
        storyId: 's1',
        storyTitle: 'Truyện Test',
        storySlug: 'truyen-test',
        chapterNumber: chapterNumber,
        title: title ?? '',
        contentVersion: 1,
        wordCount: 1097,
        isPublished: true,
        updatedAt: DateTime(2026, 8, 22),
        prevChapter: prev,
        nextChapter: next,
        label: label,
        prevLabel: prevLabel,
        nextLabel: nextLabel,
        contentMarkdown: 'Đoạn đầu tiên.\n\nĐoạn thứ hai.\n\nĐoạn thứ ba.',
        contentFormat: 'markdown',
      );

  Widget wrap(ChapterContent chapter, {
    VoidCallback? onPrev,
    VoidCallback? onNext,
    ReaderSettings settings = const ReaderSettings(),
  }) =>
      ProviderScope(
        child: MaterialApp(
          home: ReaderBody(
            chapter: chapter,
            settings: settings,
            onPrev: onPrev,
            onNext: onNext,
            onOpenSettings: () {},
            onOpenChapterList: () {},
          ),
        ),
      );

  group('Ch-nav cuối chương (cuộn dọc)', () {
    testWidgets(
        'hiện 2 nút với nhãn chương trước/kế — bấm gọi đúng callback',
        (tester) async {
      var prevTapped = false;
      var nextTapped = false;
      await tester.pumpWidget(
        wrap(
          chapter(prev: 6, next: 8, prevLabel: 'Q1·Ch.6', nextLabel: 'Q1·Ch.8'),
          onPrev: () => prevTapped = true,
          onNext: () => nextTapped = true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Hết chương'), findsOneWidget);
      expect(find.text('Q1·Ch.6'), findsOneWidget);
      expect(find.text('Q1·Ch.8'), findsOneWidget);

      // Scroll tới ĐÁY chương — _atBottom đúng thì tap-zones mới chừa vùng
      // nút (không chừa thì chạm bị vùng tap giữa nuốt → mở settings).
      await tester.dragFrom(const Offset(720, 350), const Offset(0, -2500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Q1·Ch.8'));
      await tester.pump();
      expect(nextTapped, isTrue);

      await tester.tap(find.text('Q1·Ch.6'));
      await tester.pump();
      expect(prevTapped, isTrue);
    });

    testWidgets('cache cũ không có label → fallback "Ch. N" cho 2 bên',
        (tester) async {
      await tester.pumpWidget(
        wrap(chapter(prev: 6, next: 8), onPrev: () {}, onNext: () {}),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ch. 6'), findsOneWidget);
      expect(find.text('Ch. 8'), findsOneWidget);
    });

    testWidgets('chương đầu chỉ có nút kế; chương cuối chỉ "Hết truyện"',
        (tester) async {
      await tester.pumpWidget(
        wrap(chapter(prev: null, next: 8), onNext: () {}),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hết chương'), findsOneWidget);
      expect(find.text('Ch. 8'), findsOneWidget);
      expect(find.text('Chương trước'), findsNothing);

      await tester.pumpWidget(wrap(chapter(prev: null, next: null)));
      await tester.pumpAndSettle();
      expect(find.text('Hết truyện'), findsOneWidget);
      expect(find.text('Chương kế tiếp'), findsNothing);
    });
  });

  group('Header chương ở chế độ lật trang', () {
    testWidgets('hiện ở đầu trang 1 (nhãn Q·Ch + tiêu đề)', (tester) async {
      await tester.pumpWidget(wrap(
        chapter(prev: 6, next: 8, label: 'Q1·Ch.7'),
        settings: const ReaderSettings(
          scrollMode: ReaderScrollMode.horizontal,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Q1·Ch.7: Vân Tĩnh Nhai'), findsOneWidget);
      expect(find.text('📋 Chia sẻ'), findsOneWidget);
      expect(find.text('⚠️ Báo cáo'), findsOneWidget);
    });
  });
}
