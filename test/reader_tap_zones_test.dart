import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:khongdich_mobile/features/reader/reader_settings_provider.dart';
import 'package:khongdich_mobile/features/reader/widgets/reader_body.dart';
import 'package:khongdich_mobile/models/chapter_content.dart';

/// Tap-zone behavior sau đổi UX:
///   - Cuộn dọc: KHÔNG còn chạm viền để chuyển chương (tránh chạm nhầm
///     khi cuộn/đọc) — chuyển chương bằng nút cuối chương hoặc ghost.
///     Chạm giữa vẫn mở settings.
///   - Lật trang: chạm viền đổi trang; trang đầu/cuối mới chuyển chương,
///     kiểm tra ĐỒNG BỘ theo vị trí scroll (không delay 250ms). Trang
///     cuối hiện hint "chạm phải để sang chương sau".
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  TextChapterContent chapter({String? markdown}) => TextChapterContent(
        id: 'ch7',
        storyId: 's1',
        storyTitle: 'Truyện Test',
        storySlug: 'truyen-test',
        chapterNumber: 7,
        title: 'Vân Tĩnh Nhai',
        contentVersion: 1,
        wordCount: 1097,
        isPublished: true,
        updatedAt: DateTime(2026, 8, 22),
        prevChapter: 6,
        // nextChapter null để khỏi fetch ghost provider trong test;
        // callback onNext vẫn non-null (hasNextChapter = true).
        nextChapter: null,
        contentMarkdown:
            markdown ?? 'Đoạn đầu tiên.\n\nĐoạn thứ hai.\n\nĐoạn thứ ba.',
        contentFormat: 'markdown',
      );

  Widget wrap(
    ChapterContent chapter, {
    VoidCallback? onPrev,
    VoidCallback? onNext,
    VoidCallback? onOpenSettings,
    ReaderScrollMode mode = ReaderScrollMode.vertical,
  }) =>
      ProviderScope(
        child: MaterialApp(
          home: ReaderBody(
            chapter: chapter,
            settings: ReaderSettings(scrollMode: mode),
            onPrev: onPrev,
            onNext: onNext,
            onOpenSettings: onOpenSettings ?? () {},
            onOpenChapterList: () {},
          ),
        ),
      );

  group('cuộn dọc: viền không còn chuyển chương', () {
    testWidgets(
        'chạm viền trái/phải không gọi onPrev/onNext; chạm giữa mở settings',
        (tester) async {
      var prev = 0;
      var next = 0;
      var settings = 0;
      // Chương DÀI để không rơi vào trạng thái _atBottom (chương ngắn →
      // footer nằm giữa màn hình → tap-zones chừa đáy lớn, chạm bị rơi
      // xuống nội dung thay vì vào vùng chạm).
      final longText = List.generate(
        40,
        (i) => 'Đoạn $i — nội dung dài để chương có thể cuộn thật.',
      ).join('\n\n');
      await tester.pumpWidget(
        wrap(
          chapter(markdown: longText),
          onPrev: () => prev++,
          onNext: () => next++,
          onOpenSettings: () => settings++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(100, 300));
      await tester.tapAt(const Offset(700, 300));
      await tester.pump();
      expect(prev, 0, reason: 'chạm viền trái không được đổi chương');
      expect(next, 0, reason: 'chạm viền phải không được đổi chương');

      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      expect(settings, 1, reason: 'chạm giữa vẫn mở settings');
      expect(prev, 0);
      expect(next, 0);
    });
  });

  group('lật trang: viền đổi trang, trang đầu/cuối đổi chương', () {
    testWidgets('chương 1 trang: hint + chạm trái/phải chuyển chương',
        (tester) async {
      var prev = 0;
      var next = 0;
      await tester.pumpWidget(
        wrap(
          chapter(),
          mode: ReaderScrollMode.horizontal,
          onPrev: () => prev++,
          onNext: () => next++,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1/1 — chạm phải để sang chương sau'), findsOneWidget);

      await tester.tapAt(const Offset(100, 300));
      await tester.pump();
      expect(prev, 1);
      // Lock chuyển chương 500ms — chờ qua lock rồi mới thử chiều ngược.
      await tester.pump(const Duration(milliseconds: 600));

      await tester.tapAt(const Offset(700, 300));
      await tester.pump();
      expect(next, 1);
      // Chờ hết lock chuyển chương (Future.delayed 500ms) để không còn
      // timer pending khi test kết thúc.
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('trang cuối: chạm phải chuyển chương ngay + hint, không delay',
        (tester) async {
      var next = 0;
      final longText = List.generate(
        60,
        (i) => 'Đoạn $i — nội dung dài để chương chia thành nhiều trang đọc.',
      ).join('\n\n');
      await tester.pumpWidget(
        wrap(
          chapter(markdown: longText),
          mode: ReaderScrollMode.horizontal,
          onNext: () => next++,
        ),
      );
      await tester.pumpAndSettle();

      int totalPages() {
        final regex = RegExp(r'^(\d+)/(\d+)$');
        for (final t in tester.widgetList<Text>(find.byType(Text))) {
          final m = regex.firstMatch(t.data ?? '');
          if (m != null) return int.parse(m.group(2)!);
        }
        throw StateError('Không tìm thấy số trang');
      }

      final total = totalPages();
      expect(total, greaterThan(1));
      // Các trang giữa chỉ đếm trang, chưa có hint.
      expect(find.textContaining('chạm phải'), findsNothing);

      // Lật tới trang cuối bằng chạm viền phải.
      for (var i = 1; i < total; i++) {
        await tester.tapAt(const Offset(700, 300));
        await tester.pumpAndSettle();
      }
      expect(next, 0, reason: 'lật trang không được chuyển chương');
      expect(
        find.text('$total/$total — chạm phải để sang chương sau'),
        findsOneWidget,
      );

      // Trang cuối: chạm phải chuyển chương NGAY (không delay 250ms).
      await tester.tapAt(const Offset(700, 300));
      await tester.pump();
      expect(next, 1);
      // Chờ hết lock chuyển chương (Future.delayed 500ms).
      await tester.pump(const Duration(milliseconds: 600));
    });
  });
}
