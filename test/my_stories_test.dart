
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:khongdich_mobile/features/author/my_stories_screen.dart';
import 'package:khongdich_mobile/models/my_story.dart';

void main() {
  group('MyStory.fromJson', () {
    test('parse đầy đủ + nhãn trạng thái mirror web', () {
      final s = MyStory.fromJson(const {
        'id': 'id-1',
        'slug': 'truyen-a',
        'title': 'Truyện A',
        'visibility': 'draft',
        'status': 'ongoing',
        'content_type': 'text',
        'chapter_count': 10,
        'published_chapters': 3,
        'word_count': 12345,
        'updated_at': '2026-08-24T00:00:00Z',
      });
      expect(s.slug, 'truyen-a');
      expect(s.publishedChapters, 3);
      expect(s.visibilityLabel, 'Nháp');
    });

    test('nhãn khớp badge web dashboard', () {
      String label(String v) => MyStory.fromJson({
            'id': '',
            'slug': '',
            'title': '',
            'visibility': v,
          }).visibilityLabel;
      expect(label('public'), 'Công khai');
      expect(label('private'), 'Riêng tư');
      expect(label('pending'), 'Chờ duyệt');
    });

    test('cover_url rỗng/null → null (không fetch URL rỗng)', () {
      expect(
        MyStory.fromJson(const {
          'id': '',
          'slug': '',
          'title': '',
          'cover_url': '',
        }).coverUrl,
        isNull,
      );
    });
  });

  group('MyStoriesScreen', () {
    final sample = [
      MyStory(
        id: 'id-1',
        slug: 'truyen-a',
        title: 'Truyện A',
        visibility: 'draft',
        status: 'ongoing',
        contentType: 'text',
        chapterCount: 10,
        publishedChapters: 3,
        wordCount: 1000,
        updatedAt: DateTime(2026),
      ),
    ];

    Future<void> pump(
      WidgetTester tester, {
      List<MyStory>? stories,
      Object? error,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            myStoriesProvider.overrideWith((ref) => Future.sync(() {
                  if (error != null) throw error;
                  return stories ?? const <MyStory>[];
                })),
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              initialLocation: '/my-stories',
              routes: [
                GoRoute(
                  path: '/my-stories',
                  builder: (_, _) => const MyStoriesScreen(),
                ),
                GoRoute(
                  path: '/story/:slug',
                  builder: (_, state) =>
                      Text('DETAIL:${state.pathParameters['slug']}'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('hiện danh sách: tiêu đề + chip Nháp + tiến độ chương',
        (tester) async {
      await pump(tester, stories: sample);
      expect(find.text('Truyện A'), findsOneWidget);
      expect(find.text('Nháp'), findsOneWidget);
      expect(find.text('3/10 chương'), findsOneWidget);
    });

    testWidgets('tap truyện → mở story detail theo slug', (tester) async {
      await pump(tester, stories: sample);
      await tester.tap(find.text('Truyện A'));
      await tester.pumpAndSettle();
      expect(find.text('DETAIL:truyen-a'), findsOneWidget);
    });

    testWidgets('rỗng → empty state có nút đăng truyện web', (tester) async {
      await pump(tester, stories: const []);
      expect(find.text('Bạn chưa có truyện nào'), findsOneWidget);
      expect(find.text('Đăng truyện trên web'), findsOneWidget);
    });

    testWidgets('lỗi → nút Thử lại', (tester) async {
      await pump(tester, error: Exception('network'));
      expect(find.text('Không tải được danh sách truyện.'), findsOneWidget);
      expect(find.text('Thử lại'), findsOneWidget);
    });
  });
}
