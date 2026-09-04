import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/features/search/search_screen.dart';

void main() {
  group('SearchFilters multi category/tag (AND)', () {
    test('rỗng khi chưa chọn gì', () {
      const f = SearchFilters();
      expect(f.isEmpty, isTrue);
      expect(f.categoryLabel, '🏷 Thể loại');
      expect(f.tagLabel, '# Tag');
    });

    test('1 lựa chọn hiện tên', () {
      const f = SearchFilters(
        categorySlugs: ['tien-hiep'],
        categoryNames: ['Tiên Hiệp'],
        tagSlugs: ['hot'],
        tagNames: ['Hot'],
      );
      expect(f.isEmpty, isFalse);
      expect(f.categoryLabel, '🏷 Tiên Hiệp');
      expect(f.tagLabel, '# Hot');
    });

    test('nhiều lựa chọn hiện số lượng', () {
      const f = SearchFilters(
        categorySlugs: ['tien-hiep', 'kiem-hiep'],
        categoryNames: ['Tiên Hiệp', 'Kiếm Hiệp'],
        tagSlugs: ['a', 'b', 'c'],
        tagNames: ['A', 'B', 'C'],
      );
      expect(f.categoryLabel, '🏷 2 thể loại');
      expect(f.tagLabel, '# 3 tag');
    });

    test('copyWith giữ danh sách còn lại', () {
      const f = SearchFilters(
        categorySlugs: ['tien-hiep'],
        categoryNames: ['Tiên Hiệp'],
      );
      final next = f.copyWith(tagSlugs: ['hot'], tagNames: ['Hot']);
      expect(next.categorySlugs, ['tien-hiep']);
      expect(next.tagSlugs, ['hot']);
      expect(next.isEmpty, isFalse);
    });
  });
}
