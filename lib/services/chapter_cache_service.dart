import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/observability/app_logger.dart';
import '../models/chapter_content.dart';
import '../repositories/story_repository.dart';

/// Memory cache + prefetch service cho chapter content.
///
/// **Mục đích**: khi user đang đọc chương N, prefetch chương N+1 ngầm
/// vào memory cache. Khi user bấm "Next", chapterProvider check cache
/// trước → nếu có → render ngay không loading spinner.
///
/// **Cache strategy**:
/// - Memory LRU map `{chapterId → ChapterContent}` (không persist qua
///   app restart — đủ cho session đọc truyện).
/// - Cache chapter list per story (TTL 5 phút) để tránh refetch list
///   mỗi lần next/prev.
///
/// **Prefetch trigger**:
/// - Khi `chapterProvider` resolve thành công → gọi `prefetchNext(c)`
///   fire-and-forget.
/// - Idempotent: nếu chapter kế tiếp đã có trong cache hoặc đang fetch
///   → skip.
///
/// **VIP gate**: nếu chapter N có `nextChapter` thuộc `lockedChapterIds`
/// (lấy từ VipStatus đã cache ở story detail), skip prefetch để tránh
/// spam API (user không có quyền đọc thì fetch vô nghĩa).
class ChapterCacheService {
  ChapterCacheService(this._repo);

  final StoryRepository _repo;

  /// Memory cache cho chapter content. Key = chapterId.
  /// Không persist qua app restart — đủ cho session đọc truyện.
  final Map<String, ChapterContent> _chapterCache = {};

  /// Cache chapter list per story. Key = storyId. Value = (chapters, cachedAt).
  /// TTL 5 phút — tránh refetch list mỗi lần next/prev.
  final Map<String, _ChapterListCache> _chapterListCache = {};

  /// In-flight guard: chapterId đang được fetch → skip duplicate.
  final Set<String> _inFlight = {};

  static const Duration _chapterListTtl = Duration(minutes: 5);

  /// Lấy chapter content. Check memory cache trước, fallback API.
  /// Nếu cache hit → return ngay (instant, không loading).
  Future<ChapterContent> getChapter({
    required String storyId,
    required int chapterNumber,
  }) async {
    // 1. Resolve chapterId từ chapter list (cache TTL 5 phút).
    final chapters = await _getChapterList(storyId);
    final match = chapters.where((c) => c.chapterNumber == chapterNumber).firstOrNull;
    if (match == null) {
      throw StateError(
          'Chapter $chapterNumber not found in story $storyId');
    }

    // 2. Check memory cache → instant return.
    final cached = _chapterCache[match.id];
    if (cached != null) {
      AppLogger.info('ChapterCache: cache HIT for chapter ${match.id} '
          '(N$chapterNumber, story $storyId)');
      return cached;
    }

    // 3. Cache miss → fetch API + write cache.
    final chapter = await _repo.fetchChapter(match.id);
    _chapterCache[match.id] = chapter;
    AppLogger.info('ChapterCache: cache MISS → fetched chapter ${match.id} '
        '(N$chapterNumber, ${_chapterCache.length} cached total)');
    return chapter;
  }

  /// Prefetch chương kế tiếp ngầm (fire-and-forget).
  /// Idempotent — skip nếu đã cache hoặc đang fetch.
  /// Không throw — error chỉ log, không surface cho user.
  Future<void> prefetchNext(ChapterContent currentChapter) async {
    final nextNum = currentChapter.nextChapter;
    if (nextNum == null) return; // không có chương tiếp theo

    // Resolve nextChapterId từ chapter list cache.
    final chapters = await _getChapterList(currentChapter.storyId);
    final nextMatch = chapters.where((c) => c.chapterNumber == nextNum).firstOrNull;
    if (nextMatch == null) return;

    final nextId = nextMatch.id;
    if (_chapterCache.containsKey(nextId)) return; // đã cache
    if (_inFlight.contains(nextId)) return; // đang fetch
    _inFlight.add(nextId);

    try {
      AppLogger.info('ChapterCache: prefetching next chapter $nextId '
          '(N$nextNum) while reading N${currentChapter.chapterNumber}');
      final next = await _repo.fetchChapter(nextId);
      _chapterCache[nextId] = next;
      AppLogger.info('ChapterCache: prefetch done for N$nextNum '
          '(${_chapterCache.length} cached total)');
    } catch (e, s) {
      // Prefetch fail không surface error — user vẫn đọc chương hiện tại OK.
      // Nếu user next và cache miss → chapterProvider sẽ fetch lại.
      AppLogger.warning('ChapterCache: prefetch failed for N$nextNum (ignored)', e, s);
    } finally {
      _inFlight.remove(nextId);
    }
  }

  /// Lấy chapter list (cache TTL 5 phút). Tránh refetch mỗi lần next/prev.
  Future<List<ChapterSummary>> _getChapterList(String storyId) async {
    final cached = _chapterListCache[storyId];
    if (cached != null && DateTime.now().difference(cached.cachedAt) < _chapterListTtl) {
      return cached.chapters;
    }
    final page = await _repo.fetchChapterList(storyId, perPage: 200);
    _chapterListCache[storyId] = _ChapterListCache(
      chapters: page.chapters,
      cachedAt: DateTime.now(),
    );
    return page.chapters;
  }

  /// Clear cache cho 1 story (khi user rời story detail).
  void clearStoryCache(String storyId) {
    _chapterListCache.remove(storyId);
    // Không clear chapter content cache — user có thể quay lại đọc tiếp.
  }

  /// Clear toàn bộ cache (khi app memory pressure).
  void clearAll() {
    _chapterCache.clear();
    _chapterListCache.clear();
    _inFlight.clear();
  }
}

class _ChapterListCache {
  _ChapterListCache({required this.chapters, required this.cachedAt});
  final List<ChapterSummary> chapters;
  final DateTime cachedAt;
}

/// Provider cho ChapterCacheService. Singleton — không autoDispose
/// (cache tồn tại xuyên suốt session).
final chapterCacheServiceProvider = Provider<ChapterCacheService>((ref) {
  final repo = ref.watch(storyRepositoryProvider);
  return ChapterCacheService(repo);
});
