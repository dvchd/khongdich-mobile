import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/features/downloads/offline_library_screen.dart'
    show downloadedStoryIdsProvider;
import 'package:khongdich_mobile/features/home/widgets/market_section.dart';
import 'package:khongdich_mobile/features/home/widgets/story_card.dart';
import 'package:khongdich_mobile/models/market.dart';
import 'package:khongdich_mobile/models/story.dart';

void main() {
  group('MarketHomeSection', () {
    MarketSection section({
      required bool open,
      List<StorySummary> stories = const [],
    }) {
      return MarketSection(
        open: open,
        masterUsername: 'master',
        masterDisplayName: 'Chủ Chợ',
        masterAvatar: null,
        stories: stories,
        messages: const [],
      );
    }

    StorySummary story(int i) => StorySummary(
      id: 's$i',
      title: 'Truyện $i',
      slug: 'truyen-$i',
      coverUrl: null,
      author: 'Tác giả',
      categories: const [],
      tags: const [],
      contentTypes: const [],
    );

    Widget wrap(Widget child) {
      return ProviderScope(
        overrides: [
          downloadedStoryIdsProvider.overrideWithValue(const <String>{}),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );
    }

    testWidgets('renders nothing when the chợ is closed', (tester) async {
      await tester.pumpWidget(
        wrap(MarketHomeSection(section: section(open: false))),
      );
      expect(find.text('🛒 Chợ Phiên'), findsNothing);
    });

    testWidgets('renders full-size StoryCard covers in the story rail', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          MarketHomeSection(section: section(open: true, stories: [
            story(1),
            story(2),
          ])),
        ),
      );
      expect(find.text('🛒 Chợ Phiên'), findsOneWidget);
      // Bìa truyện dùng StoryCard chuẩn (120px, AspectRatio 2:3) — không
      // còn tile thu nhỏ 70px.
      expect(find.byType(StoryCard), findsNWidgets(2));
      final card = tester.widget<StoryCard>(find.byType(StoryCard).first);
      expect(card.story.slug, 'truyen-1');
      // Mỗi card nằm trong khung rộng 120 (khớp các section truyện khác).
      final box = tester.getSize(find.byType(StoryCard).first);
      expect(box.width, 120);
    });
  });
}
