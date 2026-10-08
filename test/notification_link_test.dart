import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/features/notifications/notification_link.dart';

void main() {
  group('NotificationLink.parse', () {
    test('bình luận truyện (#comment)', () {
      final l = NotificationLink.parse('/truyen/truyen-a#comment-abc-123');
      expect(l, isNotNull);
      expect(l!.slug, 'truyen-a');
      expect(l.chapterNumber, isNull);
      expect(l.commentId, 'abc-123');
      expect(l.isReviews, isFalse);
    });

    test('bình luận chương (/chuong/{n}#comment)', () {
      final l =
          NotificationLink.parse('/truyen/truyen-a/chuong/12#comment-uuid-1');
      expect(l, isNotNull);
      expect(l!.slug, 'truyen-a');
      expect(l.chapterNumber, 12);
      expect(l.commentId, 'uuid-1');
    });

    test('chương mới — có chương, không có comment', () {
      final l = NotificationLink.parse('/truyen/truyen-a/chuong/7');
      expect(l, isNotNull);
      expect(l!.chapterNumber, 7);
      expect(l.commentId, isNull);
      expect(l.isReviews, isFalse);
    });

    test('đánh giá mới (#reviews)', () {
      final l = NotificationLink.parse('/truyen/truyen-a#reviews');
      expect(l, isNotNull);
      expect(l!.isReviews, isTrue);
      expect(l.commentId, isNull);
    });

    test('góp ý đoạn (#seg) — giữ chương, bỏ fragment', () {
      final l = NotificationLink.parse('/truyen/truyen-a/chuong/3#seg-abcdef');
      expect(l, isNotNull);
      expect(l!.chapterNumber, 3);
      expect(l.commentId, isNull);
      expect(l.isReviews, isFalse);
    });

    test('truyện thuần', () {
      final l = NotificationLink.parse('/truyen/truyen-a');
      expect(l, isNotNull);
      expect(l!.slug, 'truyen-a');
      expect(l.chapterNumber, isNull);
      expect(l.commentId, isNull);
    });

    test('URL tuyệt đối vẫn parse', () {
      final l = NotificationLink.parse(
        'https://khongdich.com/truyen/a/chuong/5#comment-x',
      );
      expect(l, isNotNull);
      expect(l!.slug, 'a');
      expect(l.chapterNumber, 5);
      expect(l.commentId, 'x');
    });

    test('link ngoài /truyen hoặc rỗng → null', () {
      expect(
        NotificationLink.parse('/cong-nghe-viet/bai-viet#comment-x'),
        isNull,
      );
      expect(NotificationLink.parse('https://example.com/'), isNull);
      expect(NotificationLink.parse(''), isNull);
    });
  });
}
