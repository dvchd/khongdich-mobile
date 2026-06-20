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
  DownloadManager(this._db, this._repo, this._api);

  final AppDatabase _db;
  final StoryRepository _repo;
  // ignore: unused_field
  final ApiClient _api;
  StreamController<List<DownloadQueueData>>? _controller;

  /// Stream of queue state — emits the latest snapshot on every change.
  Stream<List<DownloadQueueData>> watchQueue() {
    _controller ??= StreamController<List<DownloadQueueData>>.broadcast(
      onListen: () {
        unawaited(_emit());
      },
    );
    return _controller!.stream;
  }

  Future<void> _emit() async {
    if (_controller == null || _controller!.isClosed) return;
    final rows = await _db.getDownloadQueue();
    _controller!.add(rows);
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
    final alreadyQueued = queue.any((q) =>
        q.chapterId == chapterId &&
        (q.status == 'pending' || q.status == 'retry' || q.status == 'downloading'));
    if (alreadyQueued) return -1;

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
    await _emit();
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

    int enqueued = 0;
    for (final cs in chapters) {
      // Skip if already downloaded.
      final existing = await _db.getDownloadedChapter(cs.id);
      if (existing != null) continue;
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
      enqueued++;
    }
    await _emit();
    unawaited(_processQueue());
    return enqueued;
  }

  /// Cancel a queued or in-progress download.
  Future<void> cancel(int queueId) async {
    await _db.updateDownloadQueueRow(queueId,
        DownloadQueueCompanion(status: const Value('cancelled')));
    await _emit();
  }

  Future<void> _processQueue() async {
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

  Future<void> _saveChapter(DownloadQueueData row, ChapterContent chapter) async {
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
    ));
    await _db.updateDownloadQueueRow(
        row.id,
        DownloadQueueCompanion(
          status: const Value('completed'),
          progress: const Value(1.0),
          completedAt: Value(DateTime.now().toIso8601String()),
        ));
    await _emit();
  }

  Future<void> _processSingle(DownloadQueueData row) async {
    try {
      final existing = await _db.getDownloadedChapter(row.chapterId);
      if (existing != null) {
        await _db.updateDownloadQueueRow(
            row.id,
            DownloadQueueCompanion(
              status: const Value('completed'),
              progress: const Value(1.0),
              completedAt: Value(DateTime.now().toIso8601String()),
            ));
        await _emit();
        return;
      }

      await _db.updateDownloadQueueRow(
          row.id,
          DownloadQueueCompanion(
            status: const Value('downloading'),
            startedAt: Value(DateTime.now().toIso8601String()),
            progress: const Value(0.1),
          ));
      await _emit();

      final chapter = await _repo.fetchChapter(row.chapterId);
      await _saveChapter(row, chapter);
    } catch (e, s) {
      AppLogger.warning('DownloadManager._processSingle failed for row ${row.id}', e, s);
      await _db.updateDownloadQueueRow(
          row.id,
          DownloadQueueCompanion(
            status: const Value('failed'),
            errorMessage: Value(e.toString()),
          ));
      await _emit();
    }
  }

  Future<void> _processBatch(List<DownloadQueueData> rows) async {
    final chapterIds = rows.map((r) => r.chapterId).toList();
    try {
      // Mark all as downloading.
      for (final row in rows) {
        await _db.updateDownloadQueueRow(
            row.id,
            DownloadQueueCompanion(
              status: const Value('downloading'),
              startedAt: Value(DateTime.now().toIso8601String()),
              progress: const Value(0.3),
            ));
      }
      await _emit();

      final chapters = await _repo.fetchChaptersBatch(chapterIds);
      final byId = {for (final c in chapters) c.id: c};

      for (final row in rows) {
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
          await _emit();
        }
      }
    } catch (e, s) {
      // Batch failed — fall back to individual fetches.
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
  return DownloadManager(db, repo, api);
});
