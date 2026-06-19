import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';
import '../core/network/api_client.dart';
import '../core/observability/app_logger.dart';
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
  }) async {
    final id = await _db.enqueueDownload(DownloadQueueCompanion.insert(
      storyId: storyId,
      storySlug: storySlug,
      chapterId: chapterId,
      chapterNumber: chapterNumber,
      downloadType: downloadType,
      queuedAt: DateTime.now().toIso8601String(),
    ));
    await _emit();
    unawaited(_processQueue());
    return id;
  }

  /// Enqueue every chapter of a story. Caller supplies the chapter list
  /// (already fetched via [StoryRepository.fetchChapterList]).
  Future<void> enqueueAllChapters({
    required String storyId,
    required String storySlug,
    required List<ChapterSummary> chapters,
  }) async {
    for (final cs in chapters) {
      await _db.enqueueDownload(DownloadQueueCompanion.insert(
        storyId: storyId,
        storySlug: storySlug,
        chapterId: cs.id,
        chapterNumber: cs.chapterNumber,
        downloadType: 'chapter',
        queuedAt: DateTime.now().toIso8601String(),
      ));
    }
    await _emit();
    unawaited(_processQueue());
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

    for (final row in pending) {
      try {
        await _db.updateDownloadQueueRow(
            row.id,
            DownloadQueueCompanion(
              status: const Value('downloading'),
              startedAt: Value(DateTime.now().toIso8601String()),
              progress: const Value(0.1),
            ));
        await _emit();

        final chapter = await _repo.fetchChapter(
          storySlug: row.storySlug,
          chapterNumber: row.chapterNumber,
          chapterId: row.chapterId,
        );

        // Serialize to JSON for storage. The shape matches what
        // [ChapterContent.fromJson] expects.
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
        ));

        await _db.updateDownloadQueueRow(
            row.id,
            DownloadQueueCompanion(
              status: const Value('completed'),
              progress: const Value(1.0),
              completedAt: Value(DateTime.now().toIso8601String()),
            ));
        await _emit();
      } catch (e, s) {
        AppLogger.warning('DownloadManager._processQueue failed for row ${row.id}', e, s);
        await _db.updateDownloadQueueRow(
            row.id,
            DownloadQueueCompanion(
              status: const Value('failed'),
              errorMessage: Value(e.toString()),
            ));
        await _emit();
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
