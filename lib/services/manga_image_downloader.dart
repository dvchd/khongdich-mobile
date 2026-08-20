import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/database/app_database.dart';
import '../core/observability/app_logger.dart';

/// Downloads manga chapter images to local storage and records the
/// mapping in the `downloaded_chapter_images` table.
///
/// Used by [DownloadManager] when saving a manga chapter — without
/// this, the offline manga reader would still try to fetch images
/// from the remote URL via `CachedNetworkImage`, which fails when
/// the device is offline.
///
/// File layout:
///   `<appSupportDir>/manga/<chapterId>/<sortOrder>-<sha1-of-url>.jpg`
///
/// We use a hash of the URL for the filename so re-downloads are
/// idempotent (same URL → same file → no duplicates).
class MangaImageDownloader {
  MangaImageDownloader(this._db);

  final AppDatabase _db;

  /// Shared HTTP client — trước đây mỗi ảnh tạo một `HttpClient` mới →
  /// DNS + TLS handshake lại từ đầu, không reuse connection. Chương
  /// manga 50-100 ảnh phải handshake 50-100 lần.
  HttpClient? _client;
  bool _disposed = false;

  static const int _maxConcurrent = 4;

  HttpClient get _http => _client ??= HttpClient();

  /// Giải phóng connection pool — gọi khi provider dispose.
  void close() {
    _disposed = true;
    _client?.close(force: true);
    _client = null;
  }

  /// Download every image in [imageUrls] for chapter [chapterId].
  ///
  /// Skips URLs that already have a local mapping in the DB. Returns
  /// the number of images actually downloaded (i.e. excluding the
  /// ones already on disk).
  Future<int> downloadImages({
    required String chapterId,
    required List<String> imageUrls,
  }) async {
    if (imageUrls.isEmpty) return 0;

    final existing = await _db.getDownloadedImagesForChapter(chapterId);
    final existingUrls = {for (final e in existing) e.imageUrl};
    final toDownload = imageUrls
        .asMap()
        .entries
        .where((e) => !existingUrls.contains(e.value))
        .toList();
    if (toDownload.isEmpty) return 0;

    final dir = await _mangaDirFor(chapterId);
    // Tải song song với worker pool giới hạn [_maxConcurrent] — trước
    // đây tuần tự từng ảnh: chương manga 100 ảnh mất vài phút.
    var downloaded = 0;
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= toDownload.length || _disposed) return;
        final entry = toDownload[index];
        final url = entry.value;
        final sortOrder = entry.key;
        try {
          final filePath = p.join(dir.path, '$sortOrder-${_hash(url)}.jpg');
          final file = File(filePath);
          if (!await file.exists()) {
            final bytes = await _fetchBytes(url);
            await file.writeAsBytes(bytes, flush: true);
          }
          // Bảng downloaded_chapter_images không có unique constraint
          // (chỉ autoIncrement PK) nên `insertOnConflictUpdate` không bao
          // giờ conflict → re-download để lại duplicate rows. Xoá mapping
          // cũ của URL này trước khi insert.
          await _db.deleteDownloadedImageByUrl(chapterId, url);
          await _db.upsertDownloadedImage(
            DownloadedChapterImagesCompanion.insert(
              chapterId: chapterId,
              imageUrl: url,
              localPath: filePath,
              sortOrder: Value(sortOrder),
            ),
          );
          downloaded++;
        } catch (e, s) {
          // Don't abort the whole batch — log and continue. The reader
          // will fall back to the remote URL for the failed images.
          AppLogger.warning(
            'MangaImageDownloader: failed to download image $url',
            e,
            s,
          );
        }
      }
    }

    await Future.wait([
      for (var i = 0;
          i < _maxConcurrent && i < toDownload.length;
          i++)
        worker(),
    ]);
    AppLogger.info(
      'MangaImageDownloader: downloaded $downloaded/${toDownload.length} images for chapter $chapterId',
    );
    return downloaded;
  }

  /// Resolve a remote image URL to a local file path if we have one
  /// cached. Returns `null` if the image isn't downloaded locally.
  Future<String?> resolveLocalPath({
    required String chapterId,
    required String imageUrl,
  }) async {
    final rows = await _db.getDownloadedImagesForChapter(chapterId);
    for (final r in rows) {
      if (r.imageUrl == imageUrl) {
        // Verify the file still exists on disk — it may have been
        // evicted by the OS or manually deleted.
        if (await File(r.localPath).exists()) {
          return r.localPath;
        }
        return null;
      }
    }
    return null;
  }

  /// Delete all locally-cached images for a chapter. Called when the
  /// user deletes the downloaded chapter.
  Future<void> deleteImagesForChapter(String chapterId) async {
    final rows = await _db.getDownloadedImagesForChapter(chapterId);
    for (final r in rows) {
      try {
        final file = File(r.localPath);
        if (await file.exists()) await file.delete();
      } catch (_) {
        /* best-effort */
      }
    }
    await _db.deleteDownloadedImagesForChapter(chapterId);
    // Also remove the chapter's manga directory if it's now empty.
    try {
      final dir = await _mangaDirFor(chapterId);
      if (await dir.exists()) {
        if (await dir.list().isEmpty) await dir.delete();
      }
    } catch (_) {
      /* best-effort */
    }
  }

  /// Xoá TOÀN BỘ ảnh manga đã tải + mappings. Gọi khi đăng xuất hoặc
  /// "xoá tất cả truyện đã tải" — trước đây 2 luồng này chỉ xoá bảng
  /// downloaded_chapters nên file ảnh (hàng trăm MB) + rows trong
  /// downloaded_chapter_images bị bỏ lại vĩnh viễn trên disk.
  Future<void> deleteAllImages() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory(p.join(base.path, 'manga'));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e, s) {
      AppLogger.warning('MangaImageDownloader.deleteAllImages failed', e, s);
    }
    await _db.clearDownloadedImages();
  }

  Future<Directory> _mangaDirFor(String chapterId) async {
    final base = await getApplicationSupportDirectory();
    // Sanitize chapterId before using it as a path component. Normally
    // chapterId is a UUID, but a compromised or malicious backend could
    // return "../../cache" → p.join would produce a path escaping the
    // manga/ directory → arbitrary file write within the app's support
    // directory. Strip any character that isn't a safe path identifier.
    final safe = chapterId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final dir = Directory(p.join(base.path, 'manga', safe));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Fetch the raw bytes of an image URL. Uses Dart's built-in HTTP
  /// client so we don't pull in another dependency. The backend serves
  /// images via MinIO / CDN so no special headers are needed.
  Future<List<int>> _fetchBytes(String url) async {
    final client = _http;
    try {
      client.connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode} when fetching $url');
      }
      final builder = await resp.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      return builder;
    } catch (e) {
      // Connection của shared client có thể bị lỗi giữa chừng (mạng đổi
      // DNS/emulator) — recreate pool để lần sau không dính connection cũ.
      _client?.close(force: true);
      _client = null;
      rethrow;
    }
  }

  /// Stable short hash for filename generation. Not cryptographic —
  /// just needs to be deterministic and collision-resistant enough
  /// to avoid file overwrites when URLs differ.
  String _hash(String input) {
    var h = 0xcbf29ce484222325;
    for (final c in input.codeUnits) {
      h ^= c;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16);
  }
}

final mangaImageDownloaderProvider = Provider<MangaImageDownloader>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final downloader = MangaImageDownloader(db);
  ref.onDispose(downloader.close);
  return downloader;
});
