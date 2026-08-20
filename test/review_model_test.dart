import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/models/comment.dart';
import 'package:khongdich_mobile/models/review.dart';
import 'package:khongdich_mobile/models/story.dart';

void main() {
  group('ReviewItem.fromJson', () {
    test('parses a full review row', () {
      final r = ReviewItem.fromJson({
        'id': '11111111-1111-1111-1111-111111111111',
        'username': 'doc_gia',
        'display_name': 'Độc giả',
        'avatar_url': null,
        'rating': 4,
        'content': 'Truyện hay!',
        'content_html': 'Truyện hay!',
        'created_at': '2026-08-10T01:00:00Z',
      });
      expect(r.displayAuthor, 'Độc giả');
      expect(r.rating, 4);
      expect(r.content, 'Truyện hay!');
      expect(r.createdAt.year, 2026);
    });

    test('falls back to username when display_name is empty', () {
      final r = ReviewItem.fromJson({
        'id': '11111111-1111-1111-1111-111111111111',
        'username': 'beta_reader',
        'display_name': '',
        'rating': 5,
        'content': 'OK',
        'created_at': '2026-08-10T01:00:00Z',
      });
      expect(r.displayAuthor, 'beta_reader');
    });

    test('missing optional fields default safely', () {
      final r = ReviewItem.fromJson({
        'id': '11111111-1111-1111-1111-111111111111',
        'content': 'OK',
        'created_at': '2026-08-10T01:00:00Z',
      });
      expect(r.rating, 0);
      expect(r.username, '');
      expect(r.avatarUrl, isNull);
    });
  });

  group('ReviewsFeed.fromJson', () {
    test('parses list + aggregates + my_rating', () {
      final feed = ReviewsFeed.fromJson({
        'reviews': [
          {
            'id': '11111111-1111-1111-1111-111111111111',
            'username': 'a',
            'display_name': '',
            'rating': 5,
            'content': 'Tuyệt',
            'created_at': '2026-08-10T01:00:00Z',
          },
        ],
        'total': 12,
        'page': 1,
        'per_page': 20,
        'total_pages': 1,
        'avg_rating': 4.67,
        'review_count': 12,
        'my_rating': 5,
      });
      expect(feed.reviews, hasLength(1));
      expect(feed.total, 12);
      expect(feed.avgRating, closeTo(4.67, 0.001));
      expect(feed.reviewCount, 12);
      expect(feed.myRating, 5);
    });

    test('my_rating defaults to null (anonymous / not reviewed)', () {
      final feed = ReviewsFeed.fromJson({
        'reviews': <Object>[],
        'total': 0,
        'page': 1,
        'per_page': 20,
        'total_pages': 0,
      });
      expect(feed.myRating, isNull);
      expect(feed.avgRating, 0);
      expect(feed.reviewCount, 0);
    });
  });

  group('CommentEditResult.fromJson', () {
    test('parses the edit response payload', () {
      final r = CommentEditResult.fromJson({
        'ok': true,
        'content': 'Nội dung mới',
        'content_html': 'Nội dung mới',
        'edited_at': '2026-08-11T02:00:00Z',
        'was_hidden': true,
      });
      expect(r.content, 'Nội dung mới');
      expect(r.contentHtml, 'Nội dung mới');
      expect(r.wasHidden, isTrue);
      expect(r.editedAt.year, 2026);
    });

    test('was_hidden defaults to false when absent', () {
      final r = CommentEditResult.fromJson({'content': 'x', 'content_html': 'x'});
      expect(r.wasHidden, isFalse);
    });
  });

  group('StorySummary reviewCount', () {
    test('parses review_count from story detail JSON', () {
      final s = StorySummary.fromStoryJson({
        'id': '11111111-1111-1111-1111-111111111111',
        'title': 'Truyện',
        'slug': 'truyen',
        'avg_rating': '4.87',
        'review_count': 123,
      });
      expect(s.reviewCount, 123);
      expect(s.rating, closeTo(4.87, 0.001));
    });

    test('defaults to 0 when absent', () {
      final s = StorySummary.fromStoryJson({
        'id': '11111111-1111-1111-1111-111111111111',
        'title': 'Truyện',
        'slug': 'truyen',
      });
      expect(s.reviewCount, 0);
      expect(s.rating, isNull);
    });
  });
}