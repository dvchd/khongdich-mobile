import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/models/market.dart';

void main() {
  group('MarketMessage.fromJson', () {
    test('parses a full chat message', () {
      final m = MarketMessage.fromJson({
        'id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'user_id': 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        'content': 'Chào mọi người :vui:',
        'content_html':
            'Chào mọi người <img class="custom-emoji" src="u" alt=":vui:">',
        'created_at': '2026-08-14T10:00:00Z',
        'story_id': 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        'story_title': 'Truyện mẫu',
        'story_slug': 'truyen-mau',
        'display_name': 'Tác Giả',
        'username': 'tacgia',
        'avatar_url': 'https://x/av.png',
      });
      expect(m.content, contains(':vui:'));
      expect(m.contentHtml, contains('custom-emoji'));
      expect(m.displayName, 'Tác Giả');
      expect(m.storySlug, 'truyen-mau');
      expect(m.storyTitle, 'Truyện mẫu');
    });

    test('parses a minimal SSE message', () {
      final m = MarketMessage.fromJson({
        'id': 'dddddddd-dddd-dddd-dddd-dddddddddddd',
        'user_id': 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
        'content': 'xin chào',
        'created_at': '2026-08-14T10:00:00Z',
        'display_name': '',
        'username': 'an',
      });
      expect(m.content, 'xin chào');
      expect(m.displayName, '');
      expect(m.username, 'an');
      expect(m.storySlug, isNull);
      expect(m.avatarUrl, isNull);
    });

    test('relTime follows the backend rules', () {
      final now = DateTime.utc(2026, 8, 14, 10, 0);
      MarketMessage at(DateTime t) => MarketMessage(
        id: 'x',
        userId: 'y',
        content: '',
        createdAt: t,
        displayName: 'a',
        username: 'b',
      );
      expect(at(now.subtract(const Duration(seconds: 30))).relTime(now), 'vừa xong');
      expect(at(now.subtract(const Duration(minutes: 5))).relTime(now), '5 phút trước');
      expect(at(now.subtract(const Duration(hours: 3))).relTime(now), '3 giờ trước');
      expect(at(now.subtract(const Duration(days: 2))).relTime(now), '2 ngày trước');
      expect(
        at(DateTime.utc(2026, 8, 1)).relTime(now),
        '01/08/2026',
      );
    });
  });

  group('MarketSection.fromJson', () {
    test('parses open section with master + rails', () {
      final s = MarketSection.fromJson({
        'open': true,
        'master_username': 'tacgia',
        'master_display_name': 'Tác Giả',
        'master_avatar': 'https://x/av.png',
        'stories': [
          {
            'id': 'ffffffff-ffff-ffff-ffff-ffffffffffff',
            'title': 'Truyện A',
            'slug': 'truyen-a',
            'cover_url': 'https://x/c.png',
            'synopsis': '',
            'author_username': 'tacgia',
            'author_display_name': 'Tác Giả',
            'chapter_count': 12,
            'view_count': 100,
            'avg_rating': 4.5,
            'status': 'ongoing',
            'content_type': 'text',
            'updated_at': '2026-08-14T00:00:00Z',
            'is_vip': false,
          },
        ],
        'messages': [
          {
            'id': '99999999-9999-9999-9999-999999999999',
            'user_id': 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            'content': 'hello',
            'created_at': '2026-08-14T09:00:00Z',
            'display_name': 'Tác Giả',
            'username': 'tacgia',
          },
        ],
      });
      expect(s.open, isTrue);
      expect(s.masterName, 'Tác Giả');
      expect(s.stories.single.slug, 'truyen-a');
      expect(s.messages.single.content, 'hello');
    });

    test('parses closed section with empty rails', () {
      final s = MarketSection.fromJson({
        'open': false,
        'master_username': null,
        'master_display_name': null,
        'master_avatar': null,
        'stories': [],
        'messages': [],
      });
      expect(s.open, isFalse);
      expect(s.masterName, isNull);
      expect(s.stories, isEmpty);
      expect(s.messages, isEmpty);
    });
  });
}
