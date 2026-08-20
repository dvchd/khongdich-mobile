import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

/// Local SQLite schema for the Không Dịch mobile app.
///
/// Per `docs/plan-flutter-app.md` §8.2 — every table from the plan is
/// declared here as a Drift `Table` subclass. The schema is the source of
/// truth for the offline reader, download manager, reading-progress
/// cache, bookmarks cache, and TTS playback state.
///
/// Schema version starts at 1. Future changes go through [migration]'s
/// `onUpgrade` callback with `ALTER TABLE` statements or Drift's schema
/// diff helpers.

/// `downloaded_chapters` — Plan §8.2.
///
/// Stores raw markdown (for text) or structured JSON (for manga/chat/video)
/// so the reader can render a chapter with zero network round-trips.
class DownloadedChapters extends Table {
  TextColumn get chapterId => text()();
  TextColumn get storyId => text()();
  TextColumn get storyTitle => text()();
  TextColumn get storySlug => text()();
  IntColumn get chapterNumber => integer()();
  TextColumn get chapterTitle => text()();
  TextColumn get contentType => text()(); // text|manga|chat|video
  TextColumn get contentRaw => text()();
  IntColumn get contentVersion => integer().withDefault(const Constant(1))();
  IntColumn get wordCount => integer().withDefault(const Constant(0))();
  TextColumn get downloadedAt => text()();
  TextColumn get lastReadAt => text().nullable()();
  IntColumn get isRead => integer().withDefault(const Constant(0))();
  TextColumn get coverUrl => text().nullable()();
  TextColumn get storyAuthor => text().nullable()();
  TextColumn get storySynopsis => text().nullable()();
  /// 'manual_download' (user bấm download) hoặc 'auto_cache' (prefetch
  /// ngầm khi đọc online). Auto-cache bị LRU evict (giữ 20 chương gần
  /// nhất per story) và bị filter khỏi Offline Library UI.
  TextColumn get source => text().withDefault(const Constant('manual_download'))();

  @override
  Set<Column> get primaryKey => {chapterId};
}

/// `downloaded_chapter_images` — Plan §8.2.
class DownloadedChapterImages extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get chapterId => text()();
  TextColumn get imageUrl => text()();
  TextColumn get localPath => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// `reading_progress` — Plan §8.2. Mirrors the backend `reading_progress`
/// table (migration 014 in the backend repo).
class ReadingProgressTable extends Table {
  TextColumn get storyId => text()();
  IntColumn get lastChapter => integer()();
  RealColumn get scrollRatio => real().withDefault(const Constant(0))();
  TextColumn get anchor => text().withDefault(const Constant(''))();
  TextColumn get updatedAt => text()();
  IntColumn get synced => integer().withDefault(const Constant(1))();

  @override
  Set<Column> get primaryKey => {storyId};
}

/// `local_bookmarks` — Plan §8.2. Cache of server-side bookmarks for
/// offline browsing. Stores enough story metadata (title, slug, cover,
/// author, content_type) so the bookshelf can render cards without
/// fetching each story's detail from the server.
class LocalBookmarks extends Table {
  TextColumn get storyId => text()();
  TextColumn get listType => text()(); // reading|completed|plan_to_read|favorite
  TextColumn get storyTitle => text().withDefault(const Constant(''))();
  TextColumn get storySlug => text().withDefault(const Constant(''))();
  TextColumn get coverUrl => text().nullable()();
  TextColumn get author => text().withDefault(const Constant(''))();
  TextColumn get contentType => text().withDefault(const Constant('text'))();
  TextColumn get updatedAt => text()();
  IntColumn get synced => integer().withDefault(const Constant(1))();

  @override
  Set<Column> get primaryKey => {storyId};
}

/// `tts_playback_state` — Plan §8.2.
class TtsPlaybackState extends Table {
  TextColumn get chapterId => text()();
  TextColumn get storyId => text()();
  IntColumn get chapterNumber => integer()();
  IntColumn get chunkIndex => integer().withDefault(const Constant(0))();
  IntColumn get isPlaying => integer().withDefault(const Constant(0))();
  TextColumn get lastPlayedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {chapterId};
}

/// `download_queue` — Plan §8.2.
class DownloadQueue extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get storyId => text()();
  TextColumn get storySlug => text()();
  TextColumn get storyTitle => text().withDefault(const Constant(''))();
  TextColumn get chapterId => text()();
  IntColumn get chapterNumber => integer()();
  TextColumn get downloadType => text()(); // chapter|chapter_with_images
  TextColumn get status => text().withDefault(const Constant('pending'))();
  RealColumn get progress => real().withDefault(const Constant(0))();
  TextColumn get errorMessage => text().nullable()();
  TextColumn get queuedAt => text()();
  TextColumn get startedAt => text().nullable()();
  TextColumn get completedAt => text().nullable()();
  TextColumn get coverUrl => text().nullable()();
  TextColumn get storyAuthor => text().nullable()();
  TextColumn get storySynopsis => text().nullable()();
}

/// `app_settings` — Plan §8.2. Key/value store for reader prefs, theme
/// mode, cache cap, etc.
class AppSettingsTable extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [
  DownloadedChapters,
  DownloadedChapterImages,
  ReadingProgressTable,
  LocalBookmarks,
  TtsPlaybackState,
  DownloadQueue,
  AppSettingsTable,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  /// Constructor cho test — dùng executor do test cung cấp (thường là
  /// `NativeDatabase.memory()`), không đụng path_provider.
  @visibleForTesting
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          for (final stmt in _indexStatements) {
            await m.database.customStatement(stmt);
          }
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // v2: added storyTitle, storySlug, coverUrl, author,
            // contentType columns to local_bookmarks.
            await m.addColumn(localBookmarks, localBookmarks.storyTitle);
            await m.addColumn(localBookmarks, localBookmarks.storySlug);
            await m.addColumn(localBookmarks, localBookmarks.coverUrl);
            await m.addColumn(localBookmarks, localBookmarks.author);
            await m.addColumn(localBookmarks, localBookmarks.contentType);
          }
          if (from < 3) {
            // v3: added coverUrl to downloaded_chapters and download_queue.
            await m.addColumn(downloadedChapters, downloadedChapters.coverUrl);
            await m.addColumn(downloadQueue, downloadQueue.coverUrl);
          }
          if (from < 4) {
            // v4: added storyAuthor, storySynopsis to
            // downloaded_chapters and download_queue.
            await m.addColumn(downloadedChapters, downloadedChapters.storyAuthor);
            await m.addColumn(downloadedChapters, downloadedChapters.storySynopsis);
            await m.addColumn(downloadQueue, downloadQueue.storyAuthor);
            await m.addColumn(downloadQueue, downloadQueue.storySynopsis);
          }
          if (from < 5) {
            // v5: added 'source' column to downloaded_chapters.
            // 'manual_download' (user bấm download) hoặc 'auto_cache'
            // (prefetch ngầm khi đọc online). Auto-cache bị LRU evict
            // và filter khỏi Offline Library UI.
            await m.addColumn(downloadedChapters, downloadedChapters.source);
          }
          if (from < 6) {
            // v6: added 'storyTitle' to download_queue — hàng chờ hiển
            // thị tên truyện thay vì slug thô.
            await m.addColumn(downloadQueue, downloadQueue.storyTitle);
          }
          if (from < 7) {
            // v7: performance indexes on hot query paths (offline reader,
            // TTS resolve, LRU evict, download queue status polling).
            for (final stmt in _indexStatements) {
              await m.database.customStatement(stmt);
            }
          }
        },
      );

  /// Indexes on the hot lookup columns. Drift's `@TableIndex` would also
  /// need a matching schema bump — raw `CREATE INDEX IF NOT EXISTS` keeps
  /// this idempotent across create/upgrade.
  static const List<String> _indexStatements = [
    'CREATE INDEX IF NOT EXISTS idx_downloaded_chapters_story_num '
        'ON downloaded_chapters (story_id, chapter_number)',
    'CREATE INDEX IF NOT EXISTS idx_downloaded_chapters_story_source '
        'ON downloaded_chapters (story_id, source)',
    'CREATE INDEX IF NOT EXISTS idx_downloaded_images_chapter '
        'ON downloaded_chapter_images (chapter_id, sort_order)',
    'CREATE INDEX IF NOT EXISTS idx_download_queue_status '
        'ON download_queue (status)',
  ];

  // ---- Downloaded chapters ----

  Future<DownloadedChapter?> getDownloadedChapter(String chapterId) {
    return (select(downloadedChapters)
          ..where((t) => t.chapterId.equals(chapterId)))
        .getSingleOrNull();
  }

  /// Lấy chapter đã download/cache. Nếu `manualOnly = true`, chỉ trả
  /// manual_download (filter auto_cache khỏi Offline Library UI).
  Future<DownloadedChapter?> getDownloadedChapterFiltered(
      String chapterId, {bool manualOnly = false}) {
    final q = select(downloadedChapters)
      ..where((t) => t.chapterId.equals(chapterId));
    if (manualOnly) {
      q.where((t) => t.source.equals('manual_download'));
    }
    return q.getSingleOrNull();
  }

  /// LRU evict: xóa auto_cache cũ nhất per story, giữ tối đa `keep`
  /// chương gần nhất. Gọi sau khi insert auto-cache mới.
  Future<int> evictOldAutoCache(String storyId, {int keep = 20}) {
    return customUpdate(
      'DELETE FROM downloaded_chapters WHERE story_id = ? AND source = ? '
      'AND chapter_id NOT IN ('
      '  SELECT chapter_id FROM downloaded_chapters '
      '  WHERE story_id = ? AND source = ? '
      '  ORDER BY COALESCE(last_read_at, downloaded_at) DESC '
      '  LIMIT ?'
      ')',
      variables: [
        Variable<String>(storyId),
        const Variable<String>('auto_cache'),
        Variable<String>(storyId),
        const Variable<String>('auto_cache'),
        Variable<int>(keep),
      ],
      updates: {downloadedChapters},
    );
  }

  Future<List<DownloadedChapter>> getDownloadedChaptersForStory(
          String storyId) {
    return (select(downloadedChapters)
          ..where((t) => t.storyId.equals(storyId))
          ..orderBy([(t) => OrderingTerm.asc(t.chapterNumber)]))
        .get();
  }

  Future<void> upsertDownloadedChapter(DownloadedChaptersCompanion entry) {
    return into(downloadedChapters).insertOnConflictUpdate(entry);
  }

  Future<void> deleteDownloadedChapter(String chapterId) {
    return (delete(downloadedChapters)
          ..where((t) => t.chapterId.equals(chapterId)))
        .go();
  }

  Future<void> deleteAllDownloadedChapters() {
    return delete(downloadedChapters).go();
  }

  Future<void> deleteDownloadedChaptersForStory(String storyId) {
    return (delete(downloadedChapters)
          ..where((t) => t.storyId.equals(storyId)))
        .go();
  }

  Future<void> markChapterRead(String chapterId) {
    return (update(downloadedChapters)
          ..where((t) => t.chapterId.equals(chapterId)))
        .write(DownloadedChaptersCompanion(
      isRead: const Value(1),
      lastReadAt: Value(DateTime.now().toIso8601String()),
    ));
  }

  /// Promote một chương auto_cache → manual_download (user chủ động
  /// bấm tải → chương phải hiện trong Offline Library, không bị LRU
  /// evict). Gọi khi user bấm tải chương đã được prefetch ngầm.
  Future<void> promoteChapterToManual(String chapterId) {
    return (update(downloadedChapters)
          ..where((t) => t.chapterId.equals(chapterId)))
        .write(DownloadedChaptersCompanion(
      source: const Value('manual_download'),
    ));
  }

  /// Promote toàn bộ auto_cache của một story thành manual_download.
  /// Gọi khi user bấm "tải toàn bộ" — ý muốn cả truyện offline.
  Future<void> promoteStoryAutoCacheToManual(String storyId) {
    return (update(downloadedChapters)
          ..where((t) => t.storyId.equals(storyId)))
        .write(DownloadedChaptersCompanion(
      source: const Value('manual_download'),
    ));
  }

  // ---- Downloaded chapter images (manga offline) ----

  /// Insert / replace a row mapping a remote image URL to its local
  /// file path for a downloaded manga chapter.
  Future<void> upsertDownloadedImage(
      DownloadedChapterImagesCompanion entry) {
    return into(downloadedChapterImages).insertOnConflictUpdate(entry);
  }

  /// Stream of locally-downloaded image mappings for a chapter.
  /// Used by the offline manga reader to swap remote URLs → local
  /// file paths before rendering.
  Future<List<DownloadedChapterImage>> getDownloadedImagesForChapter(
      String chapterId) {
    return (select(downloadedChapterImages)
          ..where((t) => t.chapterId.equals(chapterId))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  /// Delete all locally-downloaded image mappings for a chapter.
  /// Called when the user deletes a downloaded chapter so we don't
  /// leave orphaned image files on disk.
  Future<void> deleteDownloadedImagesForChapter(String chapterId) {
    return (delete(downloadedChapterImages)
          ..where((t) => t.chapterId.equals(chapterId)))
        .go();
  }

  /// Delete the image mapping rows for a single URL of a chapter.
  /// Used before re-inserting so a re-download never leaves duplicate
  /// rows (the table has no unique constraint on chapterId+imageUrl).
  Future<void> deleteDownloadedImageByUrl(String chapterId, String imageUrl) {
    return (delete(downloadedChapterImages)
          ..where((t) => t.chapterId.equals(chapterId) & t.imageUrl.equals(imageUrl)))
        .go();
  }

  /// Xoá toàn bộ image mappings — dùng khi đăng xuất / xoá tất cả
  /// truyện đã tải (cùng với xoá thư mục ảnh trên disk).
  Future<void> clearDownloadedImages() => delete(downloadedChapterImages).go();

  // ---- Reading progress ----

  Future<ReadingProgressTableData?> getReadingProgress(String storyId) {
    return (select(readingProgressTable)
          ..where((t) => t.storyId.equals(storyId)))
        .getSingleOrNull();
  }

  Future<List<ReadingProgressTableData>> getAllReadingProgress() {
    return (select(readingProgressTable)
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
  }

  Future<void> upsertReadingProgress(ReadingProgressTableCompanion entry) {
    return into(readingProgressTable).insertOnConflictUpdate(entry);
  }

  /// Đánh dấu synced=1 CHỈ khi row hiện tại vẫn ở [lastChapter].
  ///
  /// Đây là conditional update chống race: sau khi PUT lên server hoàn
  /// tất, nếu user đã chuyển sang chương mới hơn (row đã đổi) thì không
  /// được ghi synced=1 cho chương cũ — nếu không, tiến trình mới sẽ bị
  /// tưởng đã sync trong khi server đang giữ chương cũ.
  Future<void> markProgressSyncedForChapter(
      String storyId, int lastChapter) {
    return (update(readingProgressTable)
          ..where((t) =>
              t.storyId.equals(storyId) & t.lastChapter.equals(lastChapter)))
        .write(ReadingProgressTableCompanion(synced: const Value(1)));
  }

  /// Xoá toàn bộ reading progress local — dùng khi đăng xuất để không
  /// lộ tiến trình đọc của user trước cho user sau (shared device).
  Future<void> clearAllReadingProgress() => delete(readingProgressTable).go();

  // ---- Bookmarks ----

  Future<List<LocalBookmark>> getBookmarks() => select(localBookmarks).get();

  Future<LocalBookmark?> getBookmarkForStory(String storyId) {
    return (select(localBookmarks)
          ..where((t) => t.storyId.equals(storyId)))
        .getSingleOrNull();
  }

  Future<List<LocalBookmark>> getBookmarksByType(String listType) {
    return (select(localBookmarks)
          ..where((t) => t.listType.equals(listType)))
        .get();
  }

  Future<void> upsertBookmark(LocalBookmarksCompanion entry) {
    return into(localBookmarks).insertOnConflictUpdate(entry);
  }

  Future<void> deleteBookmark(String storyId) {
    return (delete(localBookmarks)..where((t) => t.storyId.equals(storyId)))
        .go();
  }

  /// Xoá toàn bộ bookmark local — dùng khi đăng xuất để không lộ dữ
  /// liệu của user trước cho user sau (shared device).
  Future<void> clearAllBookmarks() => delete(localBookmarks).go();

  // ---- TTS playback state ----

  Future<TtsPlaybackStateData?> getTtsState(String chapterId) {
    return (select(ttsPlaybackState)
          ..where((t) => t.chapterId.equals(chapterId)))
        .getSingleOrNull();
  }

  Future<void> upsertTtsState(TtsPlaybackStateCompanion entry) {
    return into(ttsPlaybackState).insertOnConflictUpdate(entry);
  }

  /// Xoá toàn bộ TTS playback state — dùng khi đăng xuất (đảm bảo user
  /// sau không tiếp tục nghe chương của user trước).
  Future<void> clearAllTtsState() => delete(ttsPlaybackState).go();

  // ---- Download queue ----

  Future<List<DownloadQueueData>> getDownloadQueue() {
    return (select(downloadQueue)
          ..orderBy([(t) => OrderingTerm.asc(t.queuedAt)]))
        .get();
  }

  Future<DownloadQueueData?> getDownloadQueueRow(int id) {
    return (select(downloadQueue)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Reset các row kẹt ở trạng thái 'downloading' (app bị kill giữa
  /// chừng) về 'retry' để download manager xử lý lại khi khởi động.
  Future<void> resetStuckDownloadingRows() {
    return (update(downloadQueue)..where((t) => t.status.equals('downloading')))
        .write(DownloadQueueCompanion(status: const Value('retry')));
  }

  Future<int> enqueueDownload(DownloadQueueCompanion entry) {
    return into(downloadQueue).insert(entry);
  }

  Future<void> updateDownloadQueueRow(
      int id, DownloadQueueCompanion entry) {
    return (update(downloadQueue)..where((t) => t.id.equals(id)))
        .write(entry);
  }

  Future<void> deleteDownloadQueueRow(int id) {
    return (delete(downloadQueue)..where((t) => t.id.equals(id))).go();
  }

  Future<void> clearDownloadQueue() {
    return delete(downloadQueue).go();
  }

  // ---- Settings ----

  Future<String?> getSetting(String key) async {
    final row = await (select(appSettingsTable)
          ..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) {
    return into(appSettingsTable).insertOnConflictUpdate(
      AppSettingsTableCompanion(key: Value(key), value: Value(value)),
    );
  }
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'khongdich.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

/// Provider for the singleton [AppDatabase].
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
