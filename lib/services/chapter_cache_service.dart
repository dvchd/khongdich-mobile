import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';
import '../core/observability/app_logger.dart';
import '../models/chapter_content.dart';
import '../models/story.dart' show ChapterSummary;
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
/// - Memory cache (Riverpod): `Map<chapterId, ChapterContent>` cho tốc độ
///   truy cập instant trong session. Không persist.
/// - Chapter list cache: `Map<storyId, _ChapterListCache>` TTL 5 phút.
///
/// **Prefetch**:
/// - Khi `chapterProvider` resolve → prefetch N+1 và N+2 fire-and-forget.
/// - Retry khi user scroll gần cuối (onChapterNearEnd).
/// - Idempotent: skip nếu đã cache/đang fetch.
/// - VIP gate: skip nếu chương thuộc lockedChapterIds (user không có
///   quyền đọc → fetch vô nghĩa).
///
/// **Cập nhật chương**: cache tự phát hiện stale bằng cách so sánh
/// `updated_at` từ chapter list (server) với `updated_at` của cache —
/// tác giả sửa chương → server `updated_at` mới hơn → refetch + ghi đè
/// cache cũ. Không cần user xóa truyện/tải lại.
class ChapterCacheService {
  ChapterCacheService(this._repo, this._db);

  final StoryRepository _repo;
  final AppDatabase _db;

  /// Memory cache cho chapter content. Key = chapterId.
  /// Phục vụ tốc độ truy cập instant trong session.
  final Map<String, ChapterContent> _chapterCache = {};

  /// Giới hạn memory cache — mỗi chương có thể ~100KB+; giữ vô hạn suốt
  /// session (đọc 100+ chương) ngốn chục MB RAM. Evict chương cũ nhất
  /// (Map mặc định giữ thứ tự chèn) khi vượt giới hạn.
  static const int _maxMemoryChapters = 50;

  /// Cache chapter list per story. Key = storyId. Value = (chapters, cachedAt).
  /// TTL 5 phút — tránh refetch list mỗi lần next/prev.
  final Map<String, _ChapterListCache> _chapterListCache = {};

  /// In-flight guard: chapterId đang được prefetch → skip duplicate.
  final Set<String> _inFlight = {};

  /// In-flight guard cho getChapter (fetch chính, không phải prefetch) —
  /// map chapterId → Future đang chạy.
  final Map<String, Future<ChapterContent>> _inFlightFetches = {};

  /// Locked chapter IDs (từ VipStatus) — skip prefetch để tránh spam API.
  Set<String> _lockedChapterIds = {};

  static const Duration _chapterListTtl = Duration(minutes: 5);
  static const int _maxAutoCachePerStory = 20;
  /// Prefetch bao nhiêu chương kế tiếp. 2 = N+1 + N+2.
  static const int _prefetchCount = 2;

  /// Insert into the memory cache with a simple oldest-first eviction cap.
  void _cacheChapter(String chapterId, ChapterContent chapter) {
    _chapterCache.remove(chapterId);
    if (_chapterCache.length >= _maxMemoryChapters) {
      final oldest = _chapterCache.keys.first;
      _chapterCache.remove(oldest);
    }
    _chapterCache[chapterId] = chapter;
  }

  /// Cache stale khi server `updated_at` mới hơn cache (tác giả sửa chương).
  /// Backend tăng `updated_at` khi sửa nội dung (`UPDATE chapters SET ...
  /// updated_at = NOW()`), content_version thì không → dùng updated_at.
  ///
  /// Public static để unit test.
  static bool isStale(DateTime cachedAt, DateTime? serverAt) {
    if (serverAt == null) return false; // server cũ không trả → tin cache
    // Dung sai 1s — updated_at có độ phân giải giây, tránh false positive
    // khi cùng giá trị nhưng parse lệch.
    return serverAt.difference(cachedAt).inSeconds > 1;
  }

  /// Cập nhật locked chapter IDs từ VipStatus. Gọi khi user mở story
  /// detail → prefetch skip các chương locked.
  void setLockedChapterIds(Set<String> ids) {
    _lockedChapterIds = ids;
  }

  /// Chương [chapterNumber] của [storyId] có bị VIP-locked không —
  /// dùng để chặn ghost "cuộn tiếp sang chương sau" tải chương VIP
  /// vào cache khi user không có quyền (trước đây setLockedChapterIds
  /// chỉ chặn prefetch, ghost là đường tải ngầm thứ hai).
  Future<bool> isChapterLocked({
    required String storyId,
    required int chapterNumber,
  }) async {
    if (_lockedChapterIds.isEmpty) return false;
    final chapters = await _getChapterList(storyId);
    final meta =
        chapters.where((c) => c.chapterNumber == chapterNumber).firstOrNull;
    if (meta == null) return false;
    return _lockedChapterIds.contains(meta.id);
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
    final chapterMeta = match;
    final chapterId = chapterMeta.id;

    // 2. Check memory cache → instant return (trừ khi stale).
    final memCached = _chapterCache[chapterId];
    if (memCached != null) {
      if (isStale(memCached.updatedAt, chapterMeta.updatedAt)) {
        _chapterCache.remove(chapterId);
        AppLogger.info('ChapterCache: memory STALE for N$chapterNumber '
            '(cache ${memCached.updatedAt.toIso8601String()} vs server '
            '${chapterMeta.updatedAt?.toIso8601String()}) — refetch');
      } else {
        AppLogger.info('ChapterCache: memory HIT for N$chapterNumber');
        return memCached;
      }
    }

    // 3. Check DB cache (downloaded_chapters) → parse JSON → return.
    final dbCached = await _db.getDownloadedChapter(chapterId);
    if (dbCached != null) {
      try {
        final chapter = ChapterContent.fromJson(
          jsonDecode(dbCached.contentRaw) as Map<String, dynamic>,
        );
        if (isStale(chapter.updatedAt, chapterMeta.updatedAt)) {
          AppLogger.info('ChapterCache: DB STALE for N$chapterNumber '
              '(cache ${chapter.updatedAt.toIso8601String()} vs server '
              '${chapterMeta.updatedAt?.toIso8601String()}) — refetch');
        } else {
          _cacheChapter(chapterId, chapter);
          AppLogger.info('ChapterCache: DB HIT for N$chapterNumber '
              '(source: ${dbCached.source})');
          // Update lastReadAt để LRU evict biết chương này được đọc gần đây.
          await _db.markChapterRead(chapterId);
          return chapter;
        }
      } catch (e) {
        AppLogger.warning('ChapterCache: DB parse failed for N$chapterNumber, refetching', e);
      }
    }

    // In-flight guard: 2 màn hình cùng request 1 chapter (vd. prefetch
    // đang chạy trong lúc user bấm vào chương đó) → dùng chung 1 fetch
    // thay vì 2 request API + 2 lần ghi DB.
    final inFlight = _inFlightFetches[chapterId];
    if (inFlight != null) {
      AppLogger.info('ChapterCache: joining in-flight fetch for N$chapterNumber');
      return inFlight;
    }

    // 4. Cache miss → fetch API + write DB + memory cache.
    final future = _fetchAndSave(chapterId, chapterNumber);
    _inFlightFetches[chapterId] = future;
    try {
      final chapter = await future;
      _cacheChapter(chapterId, chapter);
      return chapter;
    } finally {
      _inFlightFetches.remove(chapterId);
    }
  }

  Future<ChapterContent> _fetchAndSave(String chapterId, int chapterNumber) async {
    final chapter = await _repo.fetchChapter(chapterId);
    await _saveToDb(chapter, source: 'auto_cache');
    AppLogger.info('ChapterCache: MISS → fetched N$chapterNumber '
        '(${_chapterCache.length} memory, DB saved)');
    return chapter;
  }

  /// Prefetch N+1 và N+2 ngầm (fire-and-forget). Idempotent.
  /// VIP gate: skip nếu chương thuộc lockedChapterIds.
  /// Toàn bộ body bọc try/catch — hàm này được gọi qua `unawaited(...)`
  /// từ reader; lỗi mạng/DB ở `_getChapterList` nếu không bắt sẽ thành
  /// unhandled async error → crash.
  Future<void> prefetchNext(ChapterContent currentChapter) async {
    try {
      await _prefetchNextInner(currentChapter);
    } catch (e, s) {
      AppLogger.warning('ChapterCache: prefetchNext failed (ignored)', e, s);
    }
  }

  Future<void> _prefetchNextInner(ChapterContent currentChapter) async {
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
      final ch = match;

      // VIP gate: skip nếu chương locked.
      if (_lockedChapterIds.contains(ch.id)) {
        AppLogger.info('ChapterCache: skip prefetch N$nextNumIter (VIP locked)');
        break; // Nếu N+1 locked, N+2 cũng có thể locked → stop.
      }

      futures.add(_prefetchOne(ch.id, nextNumIter, currentChapter.storyId));
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
      _cacheChapter(chapterId, chapter);
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
      // Race narrow nhưng hậu quả nặng: prefetch (auto_cache) đã fetch
      // xong chương TRONG LÚC user bấm download manual → upsert với
      // source=auto_cache sau đó sẽ ghi ĐÈ row manual_download → chương
      // bị ẩn khỏi Offline Library + dính LRU evict. Giữ source manual
      // nếu row hiện tại đã là manual_download.
      final existing = await _db.getDownloadedChapter(chapter.id);
      final effectiveSource = existing?.source == 'manual_download'
          ? 'manual_download'
          : source;
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
        source: Value(effectiveSource),
      ));
    } catch (e, s) {
      AppLogger.warning('ChapterCache: _saveToDb failed for ${chapter.id}', e, s);
    }
  }

  /// Lấy chapter list (cache TTL 5 phút). Tránh refetch mỗi lần next/prev.
  /// `fetchAllChapters` loops backend pages — stories >200 chapters are
  /// resolved completely (a single perPage=200 fetch truncates them).
  Future<List<ChapterSummary>> _getChapterList(String storyId) async {
    final cached = _chapterListCache[storyId];
    if (cached != null && DateTime.now().difference(cached.cachedAt) < _chapterListTtl) {
      return cached.chapters;
    }
    final chapters = await _repo.fetchAllChapters(storyId);
    _chapterListCache[storyId] = _ChapterListCache(
      chapters: chapters,
      cachedAt: DateTime.now(),
    );
    return chapters;
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
