import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  DownloadManager(this._db, this._repo, this._api, this._mangaImageDownloader);

  final AppDatabase _db;
  final StoryRepository _repo;
  // ignore: unused_field
  final ApiClient _api;
  final MangaImageDownloader _mangaImageDownloader;

  /// Serializes [\_processQueue] — without this, two concurrent
  /// `_processQueue()` runs (e.g. rapid enqueues from the story detail
  /// + a retry tap) would both snapshot the same 'pending' rows and
  /// fetch/save the same chapter twice (and download manga images to
  /// the same files concurrently).
  bool _processing = false;
  bool _rerunRequested = false;

  /// Recover queue rows stuck in 'downloading' after an app kill —
  /// reset them to 'retry' and resume processing. Called when the
  /// downloads screen opens (the queue is invisible until then).
  Future<void> recoverInterrupted() async {
    await _db.resetStuckDownloadingRows();
    unawaited(_processQueue());
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

  /// Enqueue a single chapter for download.
  Future<int> enqueueChapter({
    required String storyId,
    required String storySlug,
    required String chapterId,
    required int chapterNumber,
    String downloadType = 'chapter',
    String? coverUrl,
    String? storyAuthor,
    String? storySynopsis,
  }) async {
    // Skip if already downloaded.
    final existing = await _db.getDownloadedChapter(chapterId);
    if (existing != null) return -1;

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
      chapterId: chapterId,
      chapterNumber: chapterNumber,
      downloadType: downloadType,
      coverUrl: Value(coverUrl),
      storyAuthor: Value(storyAuthor),
      storySynopsis: Value(storySynopsis),
      queuedAt: DateTime.now().toIso8601String(),
    ));
    unawaited(_processQueue());
    return id;
  }

  /// Enqueue every chapter of a story. Returns the number of chapters
  /// actually enqueued (skips already-downloaded and already-queued).
  Future<int> enqueueAllChapters({
    required String storyId,
    required String storySlug,
    required List<ChapterSummary> chapters,
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
      // If 3+ pending for the same story, use batch fetch.
      if (storyRows.length >= 3) {
        await _processBatch(storyRows);
      } else {
        for (final row in storyRows) {
          await _processSingle(row);
        }
      }
    }
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

  Future<void> _processSingle(DownloadQueueData row) async {
    try {
      // Re-read the row: it may have been cancelled while queued, or
      // re-queued by a batch fallback after another run resolved it.
      final current = await _db.getDownloadQueueRow(row.id);
      if (current == null ||
          (current.status != 'pending' && current.status != 'retry')) {
        return;
      }

      final existing = await _db.getDownloadedChapter(row.chapterId);
      if (existing != null) {
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
      final access = await _repo.fetchChapterAccess(row.chapterId);
      if (!access.canRead) {
        await _db.updateDownloadQueueRow(
            row.id,
            DownloadQueueCompanion(
              status: const Value('failed'),
              errorMessage: const Value(
                  'Chương VIP — cần được tác giả cấp quyền để tải offline'),
            ));
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

  Future<void> _processBatch(List<DownloadQueueData> rows) async {
    try {
      // VIP gate: check access for all chapters in the batch before
      // fetching. VIP-locked chapters the user can't read are marked
      // failed immediately — they won't be in the batch fetch.
      final accessibleRows = <DownloadQueueData>[];
      for (final row in rows) {
        final access = await _repo.fetchChapterAccess(row.chapterId);
        if (access.canRead) {
          accessibleRows.add(row);
        } else {
          await _db.updateDownloadQueueRow(
              row.id,
              DownloadQueueCompanion(
                status: const Value('failed'),
                errorMessage: const Value(
                    'Chương VIP — cần được tác giả cấp quyền để tải offline'),
              ));
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

      final chapters = await _repo.fetchChaptersBatch(accessibleIds);
      final byId = {for (final c in chapters) c.id: c};

      for (final row in accessibleRows) {
        final ch = byId[row.chapterId];
        if (ch != null) {
          await _saveChapter(row, ch);
        } else {
          // Chapter not returned — skip / mark failed.
          await _db.updateDownloadQueueRow(
              row.id,
              DownloadQueueCompanion(
                status: const Value('failed'),
                errorMessage: const Value('Không tìm thấy chương trên máy chủ'),
              ));
        }
      }
    } catch (e, s) {
      // Batch failed — fall back to individual fetches. _processSingle
      // re-reads each row's status, so rows already resolved
      // (completed/failed/cancelled) are skipped automatically.
      AppLogger.warning('DownloadManager._processBatch failed, falling back to single', e, s);
      for (final row in rows) {
        await _processSingle(row);
      }
    }
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
  return DownloadManager(db, repo, api, mangaImageDownloader);
});
