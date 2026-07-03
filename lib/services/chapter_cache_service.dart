import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';
import '../core/observability/app_logger.dart';
import '../models/chapter_content.dart';
import '../repositories/story_repository.dart';

/// Storage + memory cache + prefetch service cho chapter content.
///
/// **Mục đích**: khi user đang đọc chương N, prefetch chương N+1 và N+2
/// ngầm vào Drift DB (storage). Khi user bấm "Next", chapterProvider
/// check DB cache trước → nếu có → render ngay không loading spinner.
/// Cache persist qua app restart → user đọc lại không cần refetch.
///
/// **Cache strategy**:
/// - Storage (Drift DB, bảng `downloaded_chapters`): persist qua app
///   restart. Có 2 source:
///   - `manual_download`: user chủ động bấm download → hiện trong Offline
///     Library, không bị LRU evict.
///   - `auto_cache`: prefetch ngầm khi đọc online → ẩn khỏi Offline
///     Library, LRU evict (giữ 20 chương gần nhất per story).
/// - Memory cache (Riverpod): Map<chapterId, ChapterContent> cho tốc độ
///   truy cập instant trong session. Không persist.
/// - Chapter list cache: Map<storyId, _ChapterListCache> TTL 5 phút.
///
/// **Prefetch**:
/// - Khi `chapterProvider` resolve → prefetch N+1 và N+2 fire-and-forget.
/// - Retry khi user scroll gần cuối (onChapterNearEnd).
/// - Idempotent: skip nếu đã cache/đang fetch.
/// - VIP gate: skip nếu chương thuộc lockedChapterIds (user không có
///   quyền đọc → fetch vô nghĩa).
///
/// **Cập nhật chương**: cache có thể cũ khi tác giả sửa chương. MVP:
/// user xóa truyện cũ + tải lại nếu muốn cập nhật. Phase 2: check
/// `updated_at` từ server → refetch nếu cache cũ.
class ChapterCacheService {
  ChapterCacheService(this._repo, this._db);

  final StoryRepository _repo;
  final AppDatabase _db;

  /// Memory cache cho chapter content. Key = chapterId.
  /// Phục vụ tốc độ truy cập instant trong session.
  final Map<String, ChapterContent> _chapterCache = {};

  /// Cache chapter list per story. Key = storyId. Value = (chapters, cachedAt).
  /// TTL 5 phút — tránh refetch list mỗi lần next/prev.
  final Map<String, _ChapterListCache> _chapterListCache = {};

  /// In-flight guard: chapterId đang được fetch → skip duplicate.
  final Set<String> _inFlight = {};

  /// Locked chapter IDs (từ VipStatus) — skip prefetch để tránh spam API.
  Set<String> _lockedChapterIds = {};

  static const Duration _chapterListTtl = Duration(minutes: 5);
  static const int _maxAutoCachePerStory = 20;
  /// Prefetch bao nhiêu chương kế tiếp. 2 = N+1 + N+2.
  static const int _prefetchCount = 2;

  /// Cập nhật locked chapter IDs từ VipStatus. Gọi khi user mở story
  /// detail → prefetch skip các chương locked.
  void setLockedChapterIds(Set<String> ids) {
    _lockedChapterIds = ids;
  }

  /// Lấy chapter content. Check memory → DB → API.
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
    final chapterId = match.id;

    // 2. Check memory cache → instant return.
    final memCached = _chapterCache[chapterId];
    if (memCached != null) {
      AppLogger.info('ChapterCache: memory HIT for N$chapterNumber');
      return memCached;
    }

    // 3. Check DB cache (downloaded_chapters) → parse JSON → return.
    final dbCached = await _db.getDownloadedChapter(chapterId);
    if (dbCached != null) {
      try {
        final chapter = ChapterContent.fromJson(
          jsonDecode(dbCached.contentRaw) as Map<String, dynamic>,
        );
        _chapterCache[chapterId] = chapter;
        AppLogger.info('ChapterCache: DB HIT for N$chapterNumber '
            '(source: ${dbCached.source})');
        // Update lastReadAt để LRU evict biết chương này được đọc gần đây.
        await _db.markChapterRead(chapterId);
        return chapter;
      } catch (e) {
        AppLogger.warning('ChapterCache: DB parse failed for N$chapterNumber, refetching', e);
      }
    }

    // 4. Cache miss → fetch API + write DB + memory cache.
    final chapter = await _repo.fetchChapter(chapterId);
    _chapterCache[chapterId] = chapter;
    await _saveToDb(chapter, source: 'auto_cache');
    AppLogger.info('ChapterCache: MISS → fetched N$chapterNumber '
        '(${_chapterCache.length} memory, DB saved)');
    return chapter;
  }

  /// Prefetch N+1 và N+2 ngầm (fire-and-forget). Idempotent.
  /// VIP gate: skip nếu chương thuộc lockedChapterIds.
  Future<void> prefetchNext(ChapterContent currentChapter) async {
    final nextNum = currentChapter.nextChapter;
    if (nextNum == null) return;

    // Resolve chapter list để lấy ID của N+1, N+2.
    final chapters = await _getChapterList(currentChapter.storyId);

    // Prefetch N+1, N+2 (nếu có).
    final futures = <Future<void>>[];
    int nextNumIter = nextNum;
    for (int i = 0; i < _prefetchCount; i++) {
      final match = chapters.where((c) => c.chapterNumber == nextNumIter).firstOrNull;
      if (match == null) break;

      // VIP gate: skip nếu chương locked.
      if (_lockedChapterIds.contains(match.id)) {
        AppLogger.info('ChapterCache: skip prefetch N$nextNumIter (VIP locked)');
        break; // Nếu N+1 locked, N+2 cũng có thể locked → stop.
      }

      futures.add(_prefetchOne(match.id, nextNumIter, currentChapter.storyId));
      // Tìm chương kế tiếp cho vòng lặp.
      final next = chapters.where((c) => c.chapterNumber == nextNumIter + 1).firstOrNull;
      if (next == null) break;
      nextNumIter = next.chapterNumber;
    }

    // Fire-and-forget tất cả prefetch.
    await Future.wait(futures);
  }

  Future<void> _prefetchOne(String chapterId, int chapterNum, String storyId) async {
    if (_chapterCache.containsKey(chapterId)) return;
    if (_inFlight.contains(chapterId)) return;
    final dbCached = await _db.getDownloadedChapter(chapterId);
    if (dbCached != null) return; // đã có trong DB
    _inFlight.add(chapterId);

    try {
      AppLogger.info('ChapterCache: prefetching N$chapterNum');
      final chapter = await _repo.fetchChapter(chapterId);
      _chapterCache[chapterId] = chapter;
      await _saveToDb(chapter, source: 'auto_cache');
      // LRU evict: giữ tối đa _maxAutoCachePerStory auto-cache per story.
      await _db.evictOldAutoCache(storyId, keep: _maxAutoCachePerStory);
      AppLogger.info('ChapterCache: prefetch done N$chapterNum');
    } catch (e, s) {
      AppLogger.warning('ChapterCache: prefetch failed N$chapterNum (ignored)', e, s);
    } finally {
      _inFlight.remove(chapterId);
    }
  }

  /// Lưu chapter vào DB (downloaded_chapters) với source = auto_cache
  /// hoặc manual_download.
  Future<void> _saveToDb(ChapterContent chapter, {required String source}) async {
    try {
      final json = chapter.toJson();
      await _db.upsertDownloadedChapter(DownloadedChaptersCompanion.insert(
        chapterId: chapter.id,
        storyId: chapter.storyId,
        storyTitle: chapter.storyTitle,
        storySlug: chapter.storySlug,
        chapterNumber: chapter.chapterNumber,
        chapterTitle: chapter.title,
        contentType: chapter.contentType,
        contentRaw: jsonEncode(json),
        contentVersion: Value(chapter.contentVersion),
        wordCount: Value(chapter.wordCount),
        downloadedAt: DateTime.now().toIso8601String(),
        source: Value(source),
      ));
    } catch (e, s) {
      AppLogger.warning('ChapterCache: _saveToDb failed for ${chapter.id}', e, s);
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

  /// Clear memory cache (DB cache vẫn giữ). Gọi khi memory pressure.
  void clearMemoryCache() {
    _chapterCache.clear();
    _chapterListCache.clear();
    _inFlight.clear();
  }

  /// Clear toàn bộ auto_cache trong DB (manual_download vẫn giữ).
  /// Gọi khi user muốn dọn dẹp storage.
  Future<void> clearAutoCache() async {
    await _db.customStatement(
      "DELETE FROM downloaded_chapters WHERE source = 'auto_cache'",
    );
    _chapterCache.clear();
    AppLogger.info('ChapterCache: cleared all auto_cache from DB');
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
  final db = ref.watch(appDatabaseProvider);
  return ChapterCacheService(repo, db);
});
