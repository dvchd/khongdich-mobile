import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart' show Options, ResponseType;
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/database/app_database.dart';
import '../core/network/api_client.dart';
import '../core/observability/app_logger.dart';
import '../models/chapter_content.dart';
import '../models/story.dart';
import '../repositories/story_repository.dart';
import 'manga_image_downloader.dart';

/// Offline download manager. Plan §8.
///
/// Per chapter:
///   1. Fetch the chapter content via [StoryRepository.fetchChapter].
///   2. Serialize it into [DownloadedChapters.contentRaw] as JSON.
///   3. For manga content, also download each image to local cache and
///      store its path in [DownloadedChapterImages] (Phase 2 — for MVP
///      we let `cached_network_image` handle caching transparently).
///   4. Mark the queue row complete.
///
/// The queue is processed serially: only one chapter is in flight at a
/// time so we don't overwhelm the backend. Failures are recorded on the
/// queue row and the user can retry.
class DownloadManager {
  DownloadManager(
    this._db,
    this._repo,
    this._api,
    this._mangaImageDownloader, {
    StoryRepository? storyRepo,
  }) : _storyRepo = storyRepo; // ignore: prefer_initializing_formals

  final AppDatabase _db;
  final ChapterFetcher _repo;
  // ignore: unused_field
  final ApiClient? _api;
  final MangaImageDownloader _mangaImageDownloader;

  /// Repository đầy đủ (có fetchStoryDetail) để snapshot thông tin
  /// truyện khi download. Null trong test unit (FakeFetcher) → bỏ qua
  /// phần snapshot, vẫn tải chương bình thường.
  final StoryRepository? _storyRepo;

  /// Guard trùng fetch story info khi tải nhiều chương cùng story.
  final Set<String> _storyInfoInFlight = {};

  /// Serializes [\_processQueue] — without this, two concurrent
  /// `_processQueue()` runs (e.g. rapid enqueues from the story detail
  /// + a retry tap) would both snapshot the same 'pending' rows and
  /// fetch/save the same chapter twice (and download manga images to
  /// the same files concurrently).
  bool _processing = false;
  bool _rerunRequested = false;

  /// Backend giới hạn tối đa 50 chapter ids mỗi lần gọi batch
  /// (`src/api/mobile.rs::batch_get_chapters` — trả 400 nếu vượt quá).
  /// Trước đây `_processBatch` gửi TOÀN BỘ ids một lần → truyện >50
  /// chương luôn bị 400 → rơi vào fallback mà fallback lại no-op (xem
  /// `_processSingle`) → toàn bộ queue kẹt ở 'downloading' vĩnh viễn,
  /// nút tải ở story detail bị disable vĩnh viễn.
  static const int _batchChunkSize = 50;

  /// Recover queue rows stuck in 'downloading' after an app kill —
  /// reset them to 'retry' and resume processing. Called when the
  /// downloads screen opens (the queue is invisible until then).
  Future<void> recoverInterrupted() async {
    try {
      await _db.resetStuckDownloadingRows();
      unawaited(_processQueue());
    } catch (e, s) {
      // DB reset fail (vd. app vừa khởi động, DB chưa sẵn sàng) — log
      // và bỏ qua; lần mở downloads screen sau sẽ retry.
      AppLogger.warning('DownloadManager: recoverInterrupted failed', e, s);
    }
  }

  /// Re-queue a failed row without creating a duplicate queue row.
  /// `enqueueChapter` would insert a NEW row for the same chapter
  /// because it only skips rows already in 'pending'/'retry'/
  /// 'downloading' — the old 'failed' row would linger forever.
  Future<void> retry(int queueId) async {
    await _db.updateDownloadQueueRow(
      queueId,
      DownloadQueueCompanion(
        status: const Value('retry'),
        errorMessage: const Value(null),
      ),
    );
    unawaited(_processQueue());
  }

  /// Khi user tải chương, tải LUÔN thông tin chi tiết truyện + bìa về
  /// máy (bảng offline_stories + file bìa local) để offline story detail
  /// / tủ truyện hiển thị y hệt online khi không có mạng. Best-effort:
  /// fail không ảnh hưởng việc tải chương.
  Future<void> ensureStoryInfoSaved({
    required String storyId,
    required String storySlug,
  }) async {
    final storyRepo = _storyRepo;
    if (storyRepo == null) return;
    if (_storyInfoInFlight.contains(storyId)) return;
    final existing = await _db.getOfflineStory(storyId);
    // Đã có snapshot + bìa local rồi → không cần tải lại.
    if (existing != null && existing.coverLocalPath != null) return;
    _storyInfoInFlight.add(storyId);
    try {
      final detail = await storyRepo.fetchStoryDetail(storySlug);
      final story = detail.story;
      String? coverLocalPath = existing?.coverLocalPath;
      final coverUrl = story.coverUrl;
      if (coverLocalPath == null && coverUrl != null && coverUrl.isNotEmpty) {
        coverLocalPath = await _downloadCoverToLocal(coverUrl, story.id);
      }
      await _db.upsertOfflineStory(OfflineStoriesCompanion.insert(
        storyId: story.id,
        title: story.title,
        slug: story.slug,
        coverUrl: Value(coverUrl),
        coverLocalPath: Value(coverLocalPath),
        author: Value(story.author),
        authorUsername: Value(detail.authorUsername),
        synopsis: Value(story.synopsis ?? ''),
        contentType: Value(story.contentTypes.isNotEmpty
            ? story.contentTypes.first
            : 'text'),
        status: Value(story.status ?? ''),
        categoriesJson: Value(jsonEncode(story.categories)),
        tagsJson: Value(jsonEncode(story.tags)),
        rating: Value(story.rating ?? 0),
        viewCount: Value(story.viewCount ?? 0),
        chapterCount: Value(story.chapterCount ?? 0),
        wordCount: Value(story.wordCount ?? 0),
        updatedAt: Value(DateTime.now().toIso8601String()),
      ));
      AppLogger.info(
          'DownloadManager: saved story info for $storyId (cover=${coverLocalPath != null})');
    } catch (e, s) {
      AppLogger.warning(
          'DownloadManager: ensureStoryInfoSaved failed for $storyId', e, s);
    } finally {
      _storyInfoInFlight.remove(storyId);
    }
  }

  /// Tải bìa truyện về file local ổn định
  /// (documents/covers/[storyId].jpg) — không phụ thuộc cache ảnh có
  /// thể bị evict.
  Future<String?> _downloadCoverToLocal(String url, String storyId) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final coversDir = Directory(p.join(dir.path, 'covers'));
      if (!await coversDir.exists()) {
        await coversDir.create(recursive: true);
      }
      final file = File(p.join(coversDir.path, '$storyId.jpg'));
      if (await file.exists()) return file.path;
      final client = _api;
      if (client != null) {
        final bytes = await client.dio
            .get<List<int>>(
              url,
              options: Options(responseType: ResponseType.bytes),
            )
            .then((r) => r.data ?? const <int>[]);
        if (bytes.isNotEmpty) {
          await file.writeAsBytes(bytes, flush: true);
          return file.path;
        }
      }
      return null;
    } catch (e) {
      AppLogger.warning('DownloadManager: cover download failed ($url)', e);
      return null;
    }
  }

  /// Enqueue a single chapter for download.
  Future<int> enqueueChapter({
    required String storyId,
    required String storySlug,
    required String chapterId,
    required int chapterNumber,
    String downloadType = 'chapter',
    String? storyTitle,
    String? coverUrl,
    String? storyAuthor,
    String? storySynopsis,
  }) async {
    // Nếu chương đã có trong DB: nếu chỉ là auto_cache (prefetch ngầm)
    // thì promote thành manual_download — user bấm tải là ý muốn chủ
    // động, chương phải hiện trong Offline Library. Trước đây skip
    // thẳng → chương đã đọc online không bao giờ tải offline được.
    final existing = await _db.getDownloadedChapter(chapterId);
    if (existing != null) {
      if (existing.source == 'auto_cache') {
        await _db.promoteChapterToManual(chapterId);
        AppLogger.info(
            'DownloadManager: promoted auto_cache → manual_download for $chapterId');
      }
      // User chủ động tải → kèm luôn snapshot thông tin + bìa truyện.
      unawaited(ensureStoryInfoSaved(storyId: storyId, storySlug: storySlug));
      return -1;
    }

    // Skip if already in the queue (pending or retry).
    final queue = await _db.getDownloadQueue();
    for (final q in queue) {
      if (q.chapterId != chapterId) continue;
      if (q.status == 'pending' || q.status == 'retry' || q.status == 'downloading') {
        return -1;
      }
      // A 'failed'/'cancelled' row exists — re-activate it instead of
      // inserting a duplicate queue row for the same chapter.
      await _db.updateDownloadQueueRow(
        q.id,
        DownloadQueueCompanion(
          status: const Value('retry'),
          errorMessage: const Value(null),
        ),
      );
      unawaited(_processQueue());
      return q.id;
    }

    final id = await _db.enqueueDownload(DownloadQueueCompanion.insert(
      storyId: storyId,
      storySlug: storySlug,
      storyTitle: Value(storyTitle ?? ''),
      chapterId: chapterId,
      chapterNumber: chapterNumber,
      downloadType: downloadType,
      coverUrl: Value(coverUrl),
      storyAuthor: Value(storyAuthor),
      storySynopsis: Value(storySynopsis),
      queuedAt: DateTime.now().toIso8601String(),
    ));
    // Tải luôn snapshot thông tin truyện + bìa (best-effort, không chặn).
    unawaited(ensureStoryInfoSaved(storyId: storyId, storySlug: storySlug));
    unawaited(_processQueue());
    return id;
  }

  /// Enqueue every chapter of a story. Returns the number of chapters
  /// actually enqueued (skips already-downloaded and already-queued).
  Future<int> enqueueAllChapters({
    required String storyId,
    required String storySlug,
    required List<ChapterSummary> chapters,
    String? storyTitle,
    String? coverUrl,
    String? storyAuthor,
    String? storySynopsis,
  }) async {
    final queue = await _db.getDownloadQueue();
    final queuedIds = queue
        .where((q) =>
            q.status == 'pending' || q.status == 'retry' || q.status == 'downloading')
        .map((q) => q.chapterId)
        .toSet();
    // Chương đã có trong DB do prefetch ngầm (auto_cache) → promote hết
    // thành manual_download thay vì skip (user chủ động tải cả truyện =
    // muốn toàn bộ offline). Trước đây chúng bị skip → Offline Library
    // thiếu các chương user từng đọc online.
    await _db.promoteStoryAutoCacheToManual(storyId);
    // One batched query for already-downloaded chapters — previously this
    // was N sequential `getDownloadedChapter` reads (one per chapter).
    final downloadedIds = (await _db.getDownloadedChaptersForStory(storyId))
        .map((c) => c.chapterId)
        .toSet();

    int enqueued = 0;
    for (final cs in chapters) {
      // Skip if already downloaded.
      if (downloadedIds.contains(cs.id)) continue;
      // Skip if already in the queue.
      if (queuedIds.contains(cs.id)) continue;

      await _db.enqueueDownload(DownloadQueueCompanion.insert(
        storyId: storyId,
        storySlug: storySlug,
        storyTitle: Value(storyTitle ?? ''),
        chapterId: cs.id,
        chapterNumber: cs.chapterNumber,
        downloadType: 'chapter',
        coverUrl: Value(coverUrl),
        storyAuthor: Value(storyAuthor),
        storySynopsis: Value(storySynopsis),
        queuedAt: DateTime.now().toIso8601String(),
      ));
      queuedIds.add(cs.id);
      enqueued++;
    }
    // Tải luôn snapshot thông tin truyện + bìa (best-effort, không chặn).
    unawaited(ensureStoryInfoSaved(storyId: storyId, storySlug: storySlug));
    unawaited(_processQueue());
    return enqueued;
  }

  /// Cancel a queued or in-progress download.
  Future<void> cancel(int queueId) async {
    await _db.updateDownloadQueueRow(queueId,
        DownloadQueueCompanion(status: const Value('cancelled')));
  }

  Future<void> _processQueue() async {
    if (_processing) {
      // A run is in flight — request one more pass when it finishes so
      // rows enqueued meanwhile are not left behind.
      _rerunRequested = true;
      return;
    }
    _processing = true;
    try {
      do {
        _rerunRequested = false;
        await _processQueueOnce();
      } while (_rerunRequested);
    } catch (e, s) {
      // Lỗi DB/mạng bất ngờ trong lúc xử lý queue — log + để queue ở
      // trạng thái hiện tại (rows vẫn 'pending'/'retry' → retry lần sau
      // qua recoverInterrupted / retry()). Trước đây ngoại lệ thoát ra
      // khỏi future fire-and-forget → unhandled async error.
      AppLogger.warning('DownloadManager: _processQueue crashed (queue giữ '
          'nguyên, sẽ retry ở lần chạy sau)', e, s);
    } finally {
      _processing = false;
    }
  }

  Future<void> _processQueueOnce() async {
    final queue = await _db.getDownloadQueue();
    final pending = queue
        .where((q) => q.status == 'pending' || q.status == 'retry')
        .toList();
    if (pending.isEmpty) return;

    // Group pending rows by story_id.
    final byStory = <String, List<DownloadQueueData>>{};
    for (final row in pending) {
      byStory.putIfAbsent(row.storyId, () => []).add(row);
    }

    for (final storyRows in byStory.values) {
      // Fetch vip-status MỘT LẦN per story thay vì check access từng
      // chương: chapter KHÔNG nằm trong lockedChapterIds chắc chắn đọc
      // được (list_chapters đã lọc draft/visibility với non-author) →
      // skip access check. Trước đây truyện 216 chương = 216 request
      // access tuần tự → mất vài phút + 1 lỗi mạng giữa chừng hủy cả
      // batch. Nếu fetch fail (mạng) → lockedIds = null → quay lại
      // check access từng chương (fail-closed, không lộ VIP).
      final lockedIds = await _fetchLockedChapterIds(storyRows.first.storyId);
      // If 3+ pending for the same story, use batch fetch.
      if (storyRows.length >= 3) {
        await _processBatch(storyRows, lockedIds: lockedIds);
      } else {
        for (final row in storyRows) {
          await _processSingle(row, lockedIds: lockedIds);
        }
      }
    }
  }

  /// Lấy tập chapter VIP-locked của story, hoặc null nếu không xác
  /// định được (fetch fail → caller PHẢI check access per chapter).
  Future<Set<String>?> _fetchLockedChapterIds(String storyId) async {
    try {
      final vip = await _repo.fetchVipStatusStrict(storyId);
      return vip.lockedChapterIds.toSet();
    } catch (e, s) {
      AppLogger.warning(
          'DownloadManager: vip-status fetch failed for $storyId — '
          'fallback to per-chapter access check', e, s);
      return null;
    }
  }

  /// Check quyền đọc một chapter. Nếu [lockedIds] != null thì các
  /// chapter ngoài danh sách lock CHẮC CHẮN đọc được → không cần gọi
  /// API. [lockedIds] == null → gọi access API per chapter (fail-closed).
  Future<ChapterAccess> _checkAccess(
      String chapterId, Set<String>? lockedIds) async {
    if (lockedIds != null && !lockedIds.contains(chapterId)) {
      return const ChapterAccess(canRead: true, isLocked: false);
    }
    return _repo.fetchChapterAccess(chapterId);
  }

  Future<bool> _isCancelled(int queueId) async {
    final current = await _db.getDownloadQueueRow(queueId);
    return current == null || current.status == 'cancelled';
  }

  Future<void> _saveChapter(DownloadQueueData row, ChapterContent chapter) async {
    // User cancelled while the fetch was in flight — don't write the
    // chapter back. Without this re-check, cancel() was ineffective:
    // the in-flight _processSingle always finished and overwrote the
    // 'cancelled' status with 'completed'.
    if (await _isCancelled(row.id)) return;
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
      coverUrl: Value(row.coverUrl),
      storyAuthor: Value(row.storyAuthor),
      storySynopsis: Value(row.storySynopsis),
      // source = 'manual_download' — user chủ động bấm download → hiện
      // trong Offline Library, không bị LRU evict.
      source: const Value('manual_download'),
    ));
    // For manga chapters, also download every image to local storage
    // so the reader can render them 100% offline. Without this, the
    // reader's `CachedNetworkImage` would try to fetch from the
    // remote URL and fail when the device is offline.
    if (chapter is MangaChapterContent) {
      try {
        await _mangaImageDownloader.downloadImages(
          chapterId: chapter.id,
          imageUrls: [for (final p in chapter.images) p.url],
        );
      } catch (e, s) {
        // Don't fail the whole download if image fetch fails — the
        // chapter content is still saved and text chapters work
        // regardless. The reader will fall back to remote URLs for
        // any images not present locally.
        AppLogger.warning(
            'DownloadManager: manga image fetch failed for chapter ${chapter.id}', e, s);
      }
    }
    // Re-check once more — the user may have cancelled while the manga
    // images were downloading.
    if (await _isCancelled(row.id)) return;
    await _db.updateDownloadQueueRow(
        row.id,
        DownloadQueueCompanion(
          status: const Value('completed'),
          progress: const Value(1.0),
          completedAt: Value(DateTime.now().toIso8601String()),
        ));
  }

  Future<void> _processSingle(
    DownloadQueueData row, {
    Set<String>? lockedIds,
  }) async {
    try {
      // Re-read the row: it may have been cancelled while queued, or
      // re-queued by a batch fallback after another run resolved it.
      //
      // Ngoài 'pending'/'retry', CHẤP NHẬN 'downloading' — queue được
      // xử lý tuần tự (`_processing` serialize) nên row 'downloading' ở
      // thời điểm này LUÔN là stale: hoặc từ lần chạy trước bị crash
      // giữa chừng, hoặc từ _processBatch vừa đánh dấu rồi fail và
      // fallback về đây. Nếu skip, row sẽ kẹt vĩnh viễn (bug "tải
      // offline không hoạt động").
      final current = await _db.getDownloadQueueRow(row.id);
      if (current == null ||
          (current.status != 'pending' &&
              current.status != 'retry' &&
              current.status != 'downloading')) {
        return;
      }

      final existing = await _db.getDownloadedChapter(row.chapterId);
      if (existing != null) {
        // Nếu row tồn tại chỉ do auto_cache (prefetch ngầm khi đọc
        // online) — promote thành manual_download để chương hiện trong
        // Offline Library thay vì kẹt vô hình.
        if (existing.source == 'auto_cache') {
          await _db.promoteChapterToManual(row.chapterId);
        }
        await _db.updateDownloadQueueRow(
            row.id,
            DownloadQueueCompanion(
              status: const Value('completed'),
              progress: const Value(1.0),
              completedAt: Value(DateTime.now().toIso8601String()),
            ));
        return;
      }

      // VIP gate: check chapter access BEFORE marking as downloading.
      // If the chapter is VIP-locked and the user lacks a grant, mark
      // the queue row as 'failed' with a clear Vietnamese message
      // rather than wasting a fetch round-trip that would 403 anyway.
      final access = await _checkAccess(row.chapterId, lockedIds);
      if (!access.canRead) {
        await _markFailed(
            row.id,
            access.reason == 'access_check_failed'
                ? _accessCheckFailedMsg
                : _vipLockedMsg);
        return;
      }

      await _db.updateDownloadQueueRow(
          row.id,
          DownloadQueueCompanion(
            status: const Value('downloading'),
            startedAt: Value(DateTime.now().toIso8601String()),
            progress: const Value(0.1),
          ));

      final chapter = await _repo.fetchChapter(row.chapterId);
      await _saveChapter(row, chapter);
    } catch (e, s) {
      AppLogger.warning('DownloadManager._processSingle failed for row ${row.id}', e, s);
      // Best-effort error marking — if this DB write itself fails,
      // don't let the exception escape into the unawaited
      // _processQueue() future (unhandled async error).
      try {
        await _db.updateDownloadQueueRow(
            row.id,
            DownloadQueueCompanion(
              status: const Value('failed'),
              errorMessage: Value(e.toString()),
            ));
      } catch (dbErr, dbStack) {
        AppLogger.warning(
            'DownloadManager: failed to mark row ${row.id} failed', dbErr, dbStack);
      }
    }
  }

  static const String _accessCheckFailedMsg =
      'Không kiểm tra được quyền truy cập — kiểm tra mạng rồi thử lại';
  static const String _vipLockedMsg =
      'Chương VIP — cần được tác giả cấp quyền để tải offline';

  Future<void> _processBatch(
    List<DownloadQueueData> rows, {
    Set<String>? lockedIds,
  }) async {
    try {
      // VIP gate: check access for all chapters in the batch before
      // fetching. VIP-locked chapters the user can't read are marked
      // failed immediately — they won't be in the batch fetch.
      //
      // Mỗi lỗi access check chỉ làm FAIL ĐÚNG row đó — trước đây 1
      // exception trong vòng lặp làm cả _processBatch throw → fallback
      // hàng loạt về single (216 row re-check lại từ đầu).
      final accessibleRows = <DownloadQueueData>[];
      for (final row in rows) {
        final ChapterAccess access;
        try {
          access = await _checkAccess(row.chapterId, lockedIds);
        } catch (e, s) {
          AppLogger.warning(
              'DownloadManager: access check failed for row ${row.id}', e, s);
          await _markFailed(row.id, _accessCheckFailedMsg);
          continue;
        }
        if (access.canRead) {
          accessibleRows.add(row);
        } else {
          await _markFailed(
              row.id,
              access.reason == 'access_check_failed'
                  ? _accessCheckFailedMsg
                  : _vipLockedMsg);
        }
      }
      if (accessibleRows.isEmpty) return;
      final accessibleIds = accessibleRows.map((r) => r.chapterId).toList();

      // Mark all as downloading.
      for (final row in accessibleRows) {
        await _db.updateDownloadQueueRow(
            row.id,
            DownloadQueueCompanion(
              status: const Value('downloading'),
              startedAt: Value(DateTime.now().toIso8601String()),
              progress: const Value(0.3),
            ));
      }

      // Fetch theo từng chunk ≤ _batchChunkSize — backend trả 400 nếu
      // gửi >50 ids một lần. Chunk nào fail thì fallback SINGLE đúng
      // các row của chunk đó (không hủy cả batch).
      final byId = <String, ChapterContent>{};
      final fallbackRows = <DownloadQueueData>[];
      final fallbackChapterIds = <String>{};
      for (var i = 0; i < accessibleIds.length; i += _batchChunkSize) {
        final end = math.min(i + _batchChunkSize, accessibleIds.length);
        final chunkRows = accessibleRows.sublist(i, end);
        final chunkIds = accessibleIds.sublist(i, end);
        try {
          final chapters = await _repo.fetchChaptersBatch(chunkIds);
          for (final c in chapters) {
            byId[c.id] = c;
          }
        } catch (e, s) {
          AppLogger.warning(
              'DownloadManager: batch chunk ${i ~/ _batchChunkSize + 1} '
              'failed, falling back to single for ${chunkIds.length} rows',
              e, s);
          fallbackRows.addAll(chunkRows);
          fallbackChapterIds.addAll(chunkIds);
        }
      }

      for (final row in accessibleRows) {
        final ch = byId[row.chapterId];
        if (ch != null) {
          await _saveChapter(row, ch);
        } else if (!fallbackChapterIds.contains(row.chapterId)) {
          // Chapter not returned — skip / mark failed.
          await _markFailed(row.id, 'Không tìm thấy chương trên máy chủ');
        }
      }

      // Fallback cho các chunk bị lỗi — reset 'downloading' về 'retry'
      // để _processSingle nhận row (guard cũ chỉ nhận pending/retry đã
      // gây bug kẹt vĩnh viễn; nay guard chấp nhận 'downloading' luôn).
      for (final row in fallbackRows) {
        final current = await _db.getDownloadQueueRow(row.id);
        if (current != null && current.status == 'downloading') {
          await _db.updateDownloadQueueRow(
              row.id,
              DownloadQueueCompanion(status: const Value('retry')));
        }
        await _processSingle(row, lockedIds: lockedIds);
      }
    } catch (e, s) {
      // Batch failed — fall back to individual fetches. Trước đây
      // fallback gọi _processSingle trực tiếp nhưng rows đã bị đánh
      // dấu 'downloading' → guard của _processSingle skip hết → queue
      // kẹt vĩnh viễn. Reset các row còn 'downloading' về 'retry'
      // trước khi fallback (rows đã completed/failed/cancelled được
      // _processSingle tự skip).
      AppLogger.warning('DownloadManager._processBatch failed, falling back to single', e, s);
      for (final row in rows) {
        final current = await _db.getDownloadQueueRow(row.id);
        if (current != null && current.status == 'downloading') {
          await _db.updateDownloadQueueRow(
              row.id,
              DownloadQueueCompanion(status: const Value('retry')));
        }
      }
      for (final row in rows) {
        await _processSingle(row, lockedIds: lockedIds);
      }
    }
  }

  Future<void> _markFailed(int queueId, String message) {
    return _db.updateDownloadQueueRow(
        queueId,
        DownloadQueueCompanion(
          status: const Value('failed'),
          errorMessage: Value(message),
        ));
  }
}

final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final api = ref.watch(apiClientProvider).maybeWhen(
        data: (c) => c,
        orElse: () => throw StateError('ApiClient not ready'),
      );
  final repo = ref.watch(storyRepositoryProvider);
  final mangaImageDownloader = ref.watch(mangaImageDownloaderProvider);
  return DownloadManager(
    db,
    repo,
    api,
    mangaImageDownloader,
    storyRepo: repo,
  );
});
