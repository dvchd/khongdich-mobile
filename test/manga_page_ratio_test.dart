import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/features/reader/views/manga_chapter_view.dart';
import 'package:khongdich_mobile/models/chapter_content.dart';

void main() {
  group('MangaPage width/height', () {
    test('fromJson parses server-provided dimensions', () {
      final page = MangaPage.fromJson(const {
        'image_url': 'https://cdn.khongdich/1.webp',
        'width': 800,
        'height': 1200,
      });
      expect(page.url, 'https://cdn.khongdich/1.webp');
      expect(page.width, 800);
      expect(page.height, 1200);
    });

    test('fromJson tolerates legacy rows without dimensions', () {
      final page = MangaPage.fromJson(const {
        'image_url': 'https://cdn.khongdich/old.png',
      });
      expect(page.width, isNull);
      expect(page.height, isNull);
    });

    test('toJson roundtrips dimensions (offline download persistence)', () {
      const page = MangaPage(
        url: 'https://cdn.khongdich/1.webp',
        width: 800,
        height: 1200,
      );
      final back = MangaPage.fromJson(page.toJson());
      expect(back.width, 800);
      expect(back.height, 1200);
      expect(back.url, page.url);
    });
  });

  group('MangaChapterView layout stability', () {
    testWidgets(
        'page with server dimensions reserves AspectRatio (no jump, no distortion)',
        (tester) async {
      // Tall surface so the lazy ListView builds BOTH pages.
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MangaChapterView(
              pages: const [
                MangaPage(url: 'https://cdn.khongdich/1.webp', width: 800, height: 1200),
                MangaPage(url: 'https://cdn.khongdich/2.webp', width: 400, height: 900),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final view = find.byType(MangaChapterView);
      final aspects = tester
          .widgetList<AspectRatio>(
            find.descendant(of: view, matching: find.byType(AspectRatio)),
          )
          .toList();

      // Each page reserves its REAL ratio from the server payload —
      // pages with different ratios keep them, nothing is forced to 3:4.
      expect(aspects, hasLength(2));
      expect(aspects[0].aspectRatio, closeTo(800 / 1200, 0.0001));
      expect(aspects[1].aspectRatio, closeTo(400 / 900, 0.0001));

      // No fixed-height loading box is shown for known-ratio pages.
      final loadingBoxes = tester.widgetList<SizedBox>(
        find.descendant(of: view, matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.height == 240,
        )),
      );
      expect(loadingBoxes, isEmpty);
    });

    testWidgets(
        'page without dimensions falls back to the fixed placeholder until decoded',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MangaChapterView(
              pages: const [MangaPage(url: 'https://cdn.khongdich/legacy.png')],
            ),
          ),
        ),
      );
      await tester.pump();

      final view = find.byType(MangaChapterView);
      // Ratio unknown (no server dims, decode still in flight) → the
      // item keeps the fixed-height box and has NO AspectRatio yet.
      expect(
        find.descendant(of: view, matching: find.byType(AspectRatio)),
        findsNothing,
      );
      final box = tester.widget<SizedBox>(
        find.descendant(of: view, matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.height == 240,
        )),
      );
      expect(box.height, 240);
    });
  });
}
