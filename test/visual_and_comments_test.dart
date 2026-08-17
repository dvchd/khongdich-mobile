import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/core/markdown/ast.dart';
import 'package:khongdich_mobile/models/chapter_content.dart';
import 'package:khongdich_mobile/models/comment.dart';

Map<String, dynamic> _common({
  String contentType = 'text',
  Map<String, dynamic> extra = const {},
}) =>
    {
      'id': '11111111-1111-1111-1111-111111111111',
      'story_id': '22222222-2222-2222-2222-222222222222',
      'story_title': 'Truyện mẫu',
      'story_slug': 'truyen-mau',
      'chapter_number': 3,
      'title': 'Chương 3',
      'content_type': contentType,
      'content_version': 2,
      'word_count': 120,
      'is_published': true,
      'prev_chapter': 2,
      'next_chapter': 4,
      'updated_at': '2026-08-10T00:00:00Z',
      ...extra,
    };

void main() {
  group('ChapterContent.fromJson', () {
    test('visual (Bách khoa trực quan) parses as VisualChapterContent', () {
      final c = ChapterContent.fromJson(
        _common(
          contentType: 'visual',
          extra: {
            'content_markdown': '## Hình minh hoạ\n\nNội dung.',
            'content_format': 'markdown',
            'thumbnail_url': 'https://cdn.example/visual-banner.jpg',
            'author_note': 'Ghi chú tác giả',
          },
        ),
      );
      expect(c, isA<VisualChapterContent>());
      final v = c as VisualChapterContent;
      expect(v.contentMarkdown, contains('Hình minh hoạ'));
      expect(v.thumbnailUrl, 'https://cdn.example/visual-banner.jpg');
      expect(v.authorNote, 'Ghi chú tác giả');
      expect(v.contentType, 'visual');
      expect(v.chapterNumber, 3);

      // Round-trips so offline storage keeps the banner.
      final back = ChapterContent.fromJson(v.toJson());
      expect(back, isA<VisualChapterContent>());
      expect((back as VisualChapterContent).thumbnailUrl, v.thumbnailUrl);
    });

    test('visual chapter without thumbnail keeps null + empty markdown ok',
        () {
      final c = ChapterContent.fromJson(
        _common(contentType: 'visual', extra: {'content_markdown': ''}),
      );
      expect(c, isA<VisualChapterContent>());
      expect((c as VisualChapterContent).thumbnailUrl, isNull);
    });

    test('text chapters still parse untouched', () {
      final c = ChapterContent.fromJson(
        _common(
          extra: {'content_markdown': 'Nội dung', 'content_format': 'markdown'},
        ),
      );
      expect(c, isA<TextChapterContent>());
    });

    test('completely unknown content types still throw (fail loudly)', () {
      expect(
        () => ChapterContent.fromJson(_common(contentType: 'mystery')),
        throwsArgumentError,
      );
    });
  });

  group('normalizeParagraphPlain (segment quote)', () {
    test('collapses whitespace + trims like the backend', () {
      expect(
        normalizeParagraphPlain(const [TextRun('  Đoạn   một  ')]),
        'Đoạn một',
      );
    });

    test('hard line breaks become spaces', () {
      expect(
        normalizeParagraphPlain([
          const TextRun('Dòng 1'),
          const LineBreak(true),
          const TextRun('Dòng 2'),
        ]),
        'Dòng 1 Dòng 2',
      );
    });

    test('inline formatting contributes only its text', () {
      expect(
        normalizeParagraphPlain([
          const TextRun('Có '),
          const StrongRun([TextRun('đậm')]),
          const TextRun(' và '),
          const EmphasisRun([TextRun('nghiêng')]),
          const LinkRun('https://x.example', [TextRun('liên kết')]),
        ]),
        'Có đậm và nghiêngliên kết',
      );
    });
  });

  group('CommentItem.fromJson', () {
    test('parses a root comment with mobile-only fields', () {
      final c = CommentItem.fromJson({
        'id': '33333333-3333-3333-3333-333333333333',
        'user_id': '44444444-4444-4444-4444-444444444444',
        'username': 'doc_gia',
        'display_name': 'Độc giả',
        'avatar_url': null,
        'content': 'Hay quá!',
        'content_html': 'Hay quá!',
        'like_count': 2,
        'created_at': '2026-08-10T01:00:00Z',
        'edited': false,
        'hidden': false,
        'is_mine': true,
        'liked_by_me': true,
        'pinned': true,
        'parent_id': null,
        'reply_to_id': '',
        'is_segment': false,
      });
      expect(c.displayAuthor, 'Độc giả');
      expect(c.isMine, isTrue);
      expect(c.likedByMe, isTrue);
      expect(c.likeCount, 2);
      expect(c.pinned, isTrue);
      expect(c.replies, isEmpty);
    });

    test('parses pinned=false by default (older servers)', () {
      final c = CommentItem.fromJson({
        'id': '33333333-3333-3333-3333-333333333333',
        'user_id': '44444444-4444-4444-4444-444444444444',
        'content': 'Hay quá!',
        'created_at': '2026-08-10T01:00:00Z',
      });
      expect(c.pinned, isFalse);
      expect(c.content, 'Hay quá!');
    });

    test('parses a segment comment with quote + replies', () {
      final c = CommentItem.fromJson({
        'id': '55555555-5555-5555-5555-555555555555',
        'user_id': '66666666-6666-6666-6666-666666666666',
        'username': 'beta',
        'display_name': '',
        'content': 'Chỗ này đọc lạ quá.',
        'content_html': 'Chỗ này đọc lạ quá.',
        'like_count': 0,
        'created_at': '2026-08-10T02:00:00Z',
        'edited': false,
        'hidden': false,
        'is_mine': false,
        'liked_by_me': false,
        'parent_id': null,
        'reply_to_id': '',
        'is_segment': true,
        'quote_text': 'Đoạn trích.',
        'para_key': 'abc123abc123abc1',
        'seg_chapter_id': '11111111-1111-1111-1111-111111111111',
        'replies': [
          {
            'id': '77777777-7777-7777-7777-777777777777',
            'user_id': '88888888-8888-8888-8888-888888888888',
            'username': 'doc_gia',
            'display_name': 'Độc giả',
            'content': 'Đồng ý.',
            'content_html': 'Đồng ý.',
            'like_count': 1,
            'created_at': '2026-08-10T03:00:00Z',
            'edited': false,
            'hidden': false,
            'is_mine': false,
            'liked_by_me': false,
            'parent_id': '55555555-5555-5555-5555-555555555555',
            'reply_to_id': '55555555-5555-5555-5555-555555555555',
            'is_segment': true,
          },
        ],
      });
      expect(c.isSegment, isTrue);
      expect(c.quoteText, 'Đoạn trích.');
      expect(c.displayAuthor, 'beta');
      expect(c.replies, hasLength(1));
      expect(c.replies.first.parentId, c.id);
    });
  });

  group('PaginatedComments.fromJson', () {
    test('parses can_moderate for author/moderator pinning', () {
      final feed = PaginatedComments.fromJson({
        'comments': [
          {
            'id': '99999999-9999-9999-9999-999999999999',
            'user_id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            'content': 'Ghim tôi!',
            'created_at': '2026-08-10T04:00:00Z',
            'pinned': true,
          },
        ],
        'total': 1,
        'page': 1,
        'per_page': 20,
        'total_pages': 1,
        'can_moderate': true,
      });
      expect(feed.canModerate, isTrue);
      expect(feed.comments, hasLength(1));
      expect(feed.comments.first.pinned, isTrue);
    });

    test('can_moderate defaults to false when absent', () {
      final feed = PaginatedComments.fromJson({
        'comments': <Object>[],
        'total': 0,
        'page': 1,
        'per_page': 20,
        'total_pages': 0,
      });
      expect(feed.canModerate, isFalse);
    });
  });
}