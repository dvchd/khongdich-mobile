import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Local SQLite schema for the Không Dịch mobile app.
///
/// Plan §8.2 — every table from the plan is declared below as Dart value
/// classes. The on-disk store (Drift + sqlite3_flutter_libs) lands in the
/// Phase-1 "offline reader" milestone; for the MVP scaffold we ship a
/// no-op in-memory stub so the rest of the app compiles + tests cleanly
/// while the schema is locked in.
///
/// When wiring Drift:
///   1. Add `drift_dev` + `build_runner` (already in dev_deps).
///   2. Convert each `*Record` below to a Drift `Table` subclass.
///   3. Run `dart run build_runner build --delete-conflicting-outputs`.
///   4. Replace [AppDatabase] body with the generated `_$AppDatabase`.

// ---- Records (Dart value classes) ----

class DownloadedChapterRecord {
  const DownloadedChapterRecord({
    required this.chapterId,
    required this.storyId,
    required this.storyTitle,
    required this.storySlug,
    required this.chapterNumber,
    required this.chapterTitle,
    required this.contentType,
    required this.contentRaw,
    this.contentVersion = 1,
    this.wordCount = 0,
    required this.downloadedAt,
    this.lastReadAt,
    this.isRead = 0,
  });

  final String chapterId;
  final String storyId;
  final String storyTitle;
  final String storySlug;
  final int chapterNumber;
  final String chapterTitle;
  final String contentType;
  final String contentRaw;
  final int contentVersion;
  final int wordCount;
  final String downloadedAt;
  final String? lastReadAt;
  final int isRead;
}

class DownloadedChapterImageRecord {
  const DownloadedChapterImageRecord({
    this.id,
    required this.chapterId,
    required this.imageUrl,
    required this.localPath,
    this.sortOrder = 0,
  });
  final int? id;
  final String chapterId;
  final String imageUrl;
  final String localPath;
  final int sortOrder;
}

class ReadingProgressRecord {
  const ReadingProgressRecord({
    required this.storyId,
    required this.lastChapter,
    this.scrollRatio = 0,
    this.anchor = '',
    required this.updatedAt,
    this.synced = 1,
  });
  final String storyId;
  final int lastChapter;
  final double scrollRatio;
  final String anchor;
  final String updatedAt;
  final int synced;
}

class LocalBookmarkRecord {
  const LocalBookmarkRecord({
    required this.storyId,
    required this.listType,
    required this.updatedAt,
    this.synced = 1,
  });
  final String storyId;
  final String listType;
  final String updatedAt;
  final int synced;
}

class TtsPlaybackRecord {
  const TtsPlaybackRecord({
    required this.chapterId,
    required this.storyId,
    required this.chapterNumber,
    this.chunkIndex = 0,
    this.isPlaying = 0,
    this.lastPlayedAt,
  });
  final String chapterId;
  final String storyId;
  final int chapterNumber;
  final int chunkIndex;
  final int isPlaying;
  final String? lastPlayedAt;
}

class DownloadQueueRecord {
  const DownloadQueueRecord({
    this.id,
    required this.storyId,
    required this.chapterId,
    required this.chapterNumber,
    required this.downloadType,
    this.status = 'pending',
    this.progress = 0,
    this.errorMessage,
    required this.queuedAt,
    this.startedAt,
    this.completedAt,
  });
  final int? id;
  final String storyId;
  final String chapterId;
  final int chapterNumber;
  final String downloadType;
  final String status;
  final double progress;
  final String? errorMessage;
  final String queuedAt;
  final String? startedAt;
  final String? completedAt;
}

class AppSettingRecord {
  const AppSettingRecord({required this.key, required this.value});
  final String key;
  final String value;
}

// ---- In-memory stub ----

/// MVP in-memory stub. Replaced with a real Drift `_$AppDatabase` once
/// the offline-reader subsystem lands. API matches the planned Drift
/// surface so call sites do not change.
class AppDatabase {
  AppDatabase();

  final Map<String, DownloadedChapterRecord> _chapters = {};
  final Map<String, ReadingProgressRecord> _progress = {};
  final Map<String, LocalBookmarkRecord> _bookmarks = {};
  final Map<String, String> _settings = {};

  Future<DownloadedChapterRecord?> getDownloadedChapter(String chapterId) async {
    return _chapters[chapterId];
  }

  Future<void> upsertDownloadedChapter(DownloadedChapterRecord entry) async {
    _chapters[entry.chapterId] = entry;
  }

  Future<void> markChapterRead(String chapterId) async {
    final existing = _chapters[chapterId];
    if (existing == null) return;
    _chapters[chapterId] = DownloadedChapterRecord(
      chapterId: existing.chapterId,
      storyId: existing.storyId,
      storyTitle: existing.storyTitle,
      storySlug: existing.storySlug,
      chapterNumber: existing.chapterNumber,
      chapterTitle: existing.chapterTitle,
      contentType: existing.contentType,
      contentRaw: existing.contentRaw,
      contentVersion: existing.contentVersion,
      wordCount: existing.wordCount,
      downloadedAt: existing.downloadedAt,
      lastReadAt: existing.lastReadAt,
      isRead: 1,
    );
  }

  Future<ReadingProgressRecord?> getReadingProgress(String storyId) async {
    return _progress[storyId];
  }

  Future<void> upsertReadingProgress(ReadingProgressRecord entry) async {
    _progress[entry.storyId] = entry;
  }

  Future<List<LocalBookmarkRecord>> getBookmarks() async {
    return _bookmarks.values.toList(growable: false);
  }

  Future<void> upsertBookmark(LocalBookmarkRecord entry) async {
    _bookmarks[entry.storyId] = entry;
  }

  Future<void> deleteBookmark(String storyId) async {
    _bookmarks.remove(storyId);
  }

  Future<String?> getSetting(String key) async => _settings[key];

  Future<void> setSetting(String key, String value) async {
    _settings[key] = value;
  }

  Future<void> close() async {}
}

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
