import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/network/api_client.dart';
import '../../../core/observability/app_logger.dart';
import '../../../repositories/story_repository.dart';

/// Reads/writes the user's reading progress across the local Drift store
/// and the backend's `PUT /api/v1/reading-progress/{story_id}` endpoint.
///
/// Per `docs/plan-flutter-app.md` §8.4 — the local DB is the source of
/// truth while the user is offline, and the server wins on conflict
/// (last-write-wins). This service also exposes a stream for the
/// "continue reading" section on the home screen.
class ReadingProgressService {
  ReadingProgressService(this._db, this._repo, this._api);

  final AppDatabase _db;
  final StoryRepository _repo;
  final ApiClient _api;

  /// Serialized PUT chain per story — đảm bảo các request lên server
  /// theo ĐÚNG thứ tự người dùng tạo ra. Không có chain này, 2 PUT
  /// bay song song có thể về server ngược thứ tự (PUT ch.6 về trước,
  /// PUT ch.5 về sau) → server giữ chương CŨ trong khi local tưởng đã
  /// sync xong → tiến trình thụt lùi vĩnh viễn.
  final Map<String, Future<void>> _saveChains = {};

  Future<void> markChapterOpened(String storyId, int chapterNumber) async {
    final now = DateTime.now().toIso8601String();
    await _db.upsertReadingProgress(
      ReadingProgressTableCompanion.insert(
        storyId: storyId,
        lastChapter: chapterNumber,
        scrollRatio: const Value(0),
        anchor: const Value(''),
        updatedAt: now,
        synced: const Value(0),
      ),
    );
    _saveToServer(storyId, chapterNumber, 0, '').catchError((Object e, StackTrace s) {
      AppLogger.warning('ReadingProgressService.markChapterOpened sync failed',
          e, s);
    });
  }

  Future<void> markChapterRead(
    String storyId,
    int chapterNumber, {
    double scrollRatio = 1.0,
  }) async {
    final now = DateTime.now().toIso8601String();
    await _db.upsertReadingProgress(
      ReadingProgressTableCompanion.insert(
        storyId: storyId,
        lastChapter: chapterNumber,
        scrollRatio: Value(scrollRatio),
        anchor: const Value(''),
        updatedAt: now,
        synced: const Value(0),
      ),
    );
    _saveToServer(storyId, chapterNumber, scrollRatio, '').catchError((Object e, StackTrace s) {
      AppLogger.warning('ReadingProgressService.markChapterRead sync failed',
          e, s);
    });
  }

  Future<void> _saveToServer(
    String storyId,
    int chapter,
    double ratio,
    String anchor,
  ) async {
    if (!await _api.isAuthenticated()) return;
    // Chain onto the previous save for this story so PUTs reach the
    // server in order. A failed save must not break the chain — errors
    // are logged inside and the next save still runs.
    final prev = _saveChains[storyId] ?? Future<void>.value();
    final next = prev.then((_) => _doSave(storyId, chapter, ratio, anchor));
    _saveChains[storyId] = next;
    await next;
  }

  Future<void> _doSave(
    String storyId,
    int chapter,
    double ratio,
    String anchor,
  ) async {
    try {
      await _repo.saveReadingProgress(
        storyId: storyId,
        chapter: chapter,
        scrollRatio: ratio,
        anchor: anchor,
      );
      // Conditional mark: chỉ đặt synced=1 nếu row local VẪN là chương
      // vừa push. Nếu user đã chuyển sang chương mới hơn trong lúc
      // request đang bay, row mới phải giữ synced=0 để flushPending
      // push lại — trước đây upsert vô điều kiện đã ghi đè chương mới
      // bằng chương cũ + synced=1 → mất tiến trình + không bao giờ
      // flush lại.
      await _db.markProgressSyncedForChapter(storyId, chapter);
    } catch (e, s) {
      AppLogger.warning('ReadingProgressService._saveToServer failed', e, s);
    }
  }

  /// Flush pending reading progress (synced=0) lên server.
  /// Gọi khi:
  /// - App resume (từ background → foreground)
  /// - Sau login thành công
  /// - Sau khi online lại (connectivity change)
  ///
  /// Backend lưu 1 row/user/story (last-write-wins), nên chỉ cần push
  /// row mới nhất per story. Fail silently — retry ở lần flush tiếp theo.
  Future<void> flushPending() async {
    if (!await _api.isAuthenticated()) return;
    try {
      final all = await _db.getAllReadingProgress();
      final pending = all.where((p) => p.synced == 0).toList();
      if (pending.isEmpty) return;
      AppLogger.info('ReadingProgress: flushing ${pending.length} pending rows');

      // Group by storyId, lấy row mới nhất per story (last-write-wins).
      final Map<String, ReadingProgressTableData> latestPerStory = {};
      for (final p in pending) {
        final existing = latestPerStory[p.storyId];
        if (existing == null || p.updatedAt.compareTo(existing.updatedAt) > 0) {
          latestPerStory[p.storyId] = p;
        }
      }

      // Push từng story lên server. Fail 1 row không block các row khác.
      for (final entry in latestPerStory.entries) {
        try {
          await _repo.saveReadingProgress(
            storyId: entry.key,
            chapter: entry.value.lastChapter,
            scrollRatio: entry.value.scrollRatio,
            anchor: entry.value.anchor,
          );
          // Conditional mark (xem _doSave): chỉ synced=1 nếu row local
          // vẫn là chương vừa push — chương mới hơn xuất hiện trong lúc
          // flush thì giữ synced=0 để flush lần sau.
          await _db.markProgressSyncedForChapter(
              entry.key, entry.value.lastChapter);
          AppLogger.info('ReadingProgress: synced story ${entry.key} '
              'chapter ${entry.value.lastChapter}');
        } catch (e, s) {
          AppLogger.warning('ReadingProgress: flush failed for story '
              '${entry.key} (will retry next flush)', e, s);
        }
      }
    } catch (e, s) {
      AppLogger.warning('ReadingProgress: flushPending failed', e, s);
    }
  }

  Future<List<ContinueReadingItem>> refreshContinueReading() async {
    if (!await _api.isAuthenticated()) return const [];
    try {
      return await _repo.fetchContinueReading();
    } catch (e, s) {
      AppLogger.warning('ReadingProgressService.refreshContinueReading', e, s);
      return const [];
    }
  }
}

final readingProgressServiceProvider = Provider<ReadingProgressService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final api = ref.watch(apiClientProvider).maybeWhen(
        data: (c) => c,
        orElse: () => throw StateError('ApiClient not ready'),
      );
  final repo = ref.watch(storyRepositoryProvider);
  return ReadingProgressService(db, repo, api);
});
