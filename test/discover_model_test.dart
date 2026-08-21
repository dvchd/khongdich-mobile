import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/models/story.dart';
import 'package:khongdich_mobile/repositories/story_repository.dart';

void main() {
  group('CategoryInfo.fromJson', () {
    test('parses name + slug + description', () {
      final c = CategoryInfo.fromJson({
        'id': 1,
        'name': 'Huyền Huyễn',
        'slug': 'huyen-huyen',
        'description': 'Mô tả',
      });
      expect(c.name, 'Huyền Huyễn');
      expect(c.slug, 'huyen-huyen');
      expect(c.description, 'Mô tả');
    });

    test('defaults safely', () {
      final c = CategoryInfo.fromJson({});
      expect(c.name, '');
      expect(c.slug, '');
      expect(c.id, 0);
    });
  });

  group('TagInfo.fromJson', () {
    test('parses name + slug + story_count', () {
      final t = TagInfo.fromJson({
        'name': 'Xuyên không',
        'slug': 'xuyen-khong',
        'story_count': 12,
      });
      expect(t.name, 'Xuyên không');
      expect(t.slug, 'xuyen-khong');
      expect(t.storyCount, 12);
    });
  });

  group('StorySummary category/tag slugs', () {
    test('fromStoryJson defaults to empty slug lists', () {
      final s = StorySummary.fromStoryJson({
        'id': '11111111-1111-1111-1111-111111111111',
        'title': 'T',
        'slug': 't',
      });
      expect(s.categorySlugs, isEmpty);
      expect(s.tagSlugs, isEmpty);
    });

    test('copyWith carries slugs through', () {
      final s = StorySummary.fromStoryJson({
        'id': '11111111-1111-1111-1111-111111111111',
        'title': 'T',
        'slug': 't',
      }).copyWith(
        categories: const ['Huyền Huyễn'],
        categorySlugs: const ['huyen-huyen'],
        tags: const ['Xuyên không'],
        tagSlugs: const ['xuyen-khong'],
      );
      expect(s.categories, ['Huyền Huyễn']);
      expect(s.categorySlugs, ['huyen-huyen']);
      expect(s.tagSlugs, ['xuyen-khong']);
    });
  });
}
