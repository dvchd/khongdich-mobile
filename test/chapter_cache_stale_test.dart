import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/services/chapter_cache_service.dart';

/// Chapter cache stale detection: tác giả sửa chương → server updated_at
/// mới hơn cache → refetch. Dung sai 1s (updated_at độ phân giải giây).
void main() {
  group('ChapterCacheService.isStale', () {
    final base = DateTime.utc(2026, 8, 22, 10, 0, 0);

    test('server mới hơn cache → stale', () {
      expect(ChapterCacheService.isStale(base, base.add(const Duration(seconds: 5))), isTrue);
      expect(ChapterCacheService.isStale(base, base.add(const Duration(minutes: 1))), isTrue);
    });

    test('bằng nhau / lệch ≤1s → không stale', () {
      expect(ChapterCacheService.isStale(base, base), isFalse);
      expect(ChapterCacheService.isStale(base, base.add(const Duration(seconds: 1))), isFalse);
    });

    test('server null (backend cũ không trả) → tin cache', () {
      expect(ChapterCacheService.isStale(base, null), isFalse);
    });

    test('cache mới hơn server (đồng hồ lệch) → không stale', () {
      expect(
        ChapterCacheService.isStale(base, base.subtract(const Duration(minutes: 3))),
        isFalse,
      );
    });
  });
}