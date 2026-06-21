import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
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

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
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
        },
      );

  // ---- Downloaded chapters ----

  Future<DownloadedChapter?> getDownloadedChapter(String chapterId) {
    return (select(downloadedChapters)
          ..where((t) => t.chapterId.equals(chapterId)))
        .getSingleOrNull();
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

  // ---- TTS playback state ----

  Future<TtsPlaybackStateData?> getTtsState(String chapterId) {
    return (select(ttsPlaybackState)
          ..where((t) => t.chapterId.equals(chapterId)))
        .getSingleOrNull();
  }

  Future<void> upsertTtsState(TtsPlaybackStateCompanion entry) {
    return into(ttsPlaybackState).insertOnConflictUpdate(entry);
  }

  // ---- Download queue ----

  Future<List<DownloadQueueData>> getDownloadQueue() {
    return (select(downloadQueue)
          ..orderBy([(t) => OrderingTerm.asc(t.queuedAt)]))
        .get();
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
