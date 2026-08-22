import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/repositories/story_repository.dart';

/// Parse test cho hồ sơ tác giả (GET /api/v1/mobile/users/{username}).
void main() {
  test('AuthorProfile.fromJson parse đầy đủ', () {
    final profile = AuthorProfile.fromJson({
      'author': {
        'id': 'u-1',
        'username': 'du-linh-tu',
        'display_name': 'Du Linh Tử',
        'avatar_url': 'https://cdn.khongdich.com/a.png',
        'bio': 'Người kể chuyện.',
        'follower_count': 42,
        'trust_score': 85,
      },
      'stories': [
        {
          'id': 's-1',
          'title': 'Hậu Chiến Văn Minh',
          'slug': 'hau-chien-van-minh',
          'cover_url': 'https://cdn.khongdich.com/c.png',
          'synopsis': 'Tóm tắt.',
          'author_username': 'du-linh-tu',
          'author_display_name': 'Du Linh Tử',
          'chapter_count': 65,
          'view_count': 1000,
          'avg_rating': 4.5,
          'status': 'ongoing',
          'content_type': 'text',
          'updated_at': '2026-08-01T00:00:00Z',
          'is_vip': true,
        },
      ],
      'total_stories': 9,
      'page': 1,
      'per_page': 20,
      'total_pages': 1,
    });

    expect(profile.author.name, 'Du Linh Tử');
    expect(profile.author.username, 'du-linh-tu');
    expect(profile.author.bio, 'Người kể chuyện.');
    expect(profile.author.followerCount, 42);
    expect(profile.author.trustScore, 85);
    expect(profile.totalStories, 9);
    expect(profile.stories.single.title, 'Hậu Chiến Văn Minh');
    expect(profile.stories.single.isVip, true);
    expect(profile.stories.single.slug, 'hau-chien-van-minh');
  });

  test('AuthorInfo fallback username khi display_name trống + avatar rỗng', () {
    final info = AuthorInfo.fromJson({
      'id': 'u-2',
      'username': 'nobody',
      'display_name': '',
      'avatar_url': '',
      'follower_count': 0,
    });
    expect(info.name, 'nobody');
    expect(info.avatarUrl, isNull);
    // Endpoint cũ chưa trả trust_score → mặc định 0 (badge ẩn).
    expect(info.trustScore, 0);
  });
}
