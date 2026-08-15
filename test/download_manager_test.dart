import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/core/database/app_database.dart';
import 'package:khongdich_mobile/core/observability/app_logger.dart';
import 'package:khongdich_mobile/models/chapter_content.dart';
import 'package:khongdich_mobile/models/story.dart';
import 'package:khongdich_mobile/repositories/story_repository.dart';
import 'package:khongdich_mobile/services/download_manager.dart';
import 'package:khongdich_mobile/services/manga_image_downloader.dart';

/// Regression tests cho hàng đợi tải offline — khóa các bug "tải offline
/// không hoạt động":
///   - Batch gửi >50 ids → backend 400 → fallback no-op (guard của
///     _processSingle skip row 'downloading') → 216 rows kẹt vĩnh viễn,
///     nút tải ở story detail bị disable vĩnh viễn.
///   - Chương đã auto_cache bị skip khi user bấm tải → không bao giờ
///     hiện trong Offline Library.
///   - Access-check fail do mạng bị báo nhầm "Chương VIP".
class FakeFetcher implements ChapterFetcher {
  final Map<String, ChapterContent> chapters = {};
  final List<List<String>> batchCalls = [];
  bool failBatch = false;
  ChapterAccess Function(String id)? accessFn;

  @override
  Future<ChapterContent> fetchChapter(String chapterId) async {
    final c = chapters[chapterId];
    if (c == null) throw StateError('no chapter $chapterId');
    return c;
  }

  @override
  Future<ChapterAccess> fetchChapterAccess(String chapterId) async {
    if (accessFn != null) return accessFn!(chapterId);
    return const ChapterAccess(canRead: true, isLocked: false);
  }

  @override
  Future<List<ChapterContent>> fetchChaptersBatch(
      List<String> chapterIds) async {
    batchCalls.add(List.of(chapterIds));
    if (failBatch) throw Exception('backend 400: Tối đa 50 chương mỗi lần');
    return [
      for (final id in chapterIds)
        if (chapters.containsKey(id)) chapters[id]!,
    ];
  }
}

TextChapterContent makeTextChapter(String id, {int number = 1}) {
  return TextChapterContent(
    id: id,
    storyId: 's1',
    storyTitle: 'Truyện test',
    storySlug: 'truyen-test',
    chapterNumber: number,
    title: 'Chương $number',
    contentVersion: 1,
    wordCount: 10,
    isPublished: true,
    prevChapter: number > 1 ? number - 1 : null,
    nextChapter: number + 1,
    updatedAt: DateTime(2026, 1, 1),
    contentMarkdown: 'Nội dung chương $number.',
    contentFormat: 'markdown',
  );
}

ChapterSummary makeSummary(String id, int number) => ChapterSummary(
      id: id,
      chapterNumber: number,
      title: 'Chương $number',
      contentType: 'text',
      contentVersion: 1,
      isPublished: true,
      wordCount: 10,
    );

/// Chờ tới khi không còn row active (pending/retry/downloading) hoặc
/// timeout — `_processQueue` chạy unawaited nên test phải poll DB.
Future<void> waitForQueueDone(AppDatabase db) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final rows = await db.getDownloadQueue();
    final active = rows
        .where((r) =>
            r.status == 'pending' ||
            r.status == 'retry' ||
            r.status == 'downloading')
        .toList();
    if (active.isEmpty) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('Queue không xong trong 10s: '
          '${rows.map((r) => '${r.chapterId}=${r.status}').toList()}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppLogger.init();

  late AppDatabase db;
  late FakeFetcher fetcher;
  late DownloadManager mgr;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    fetcher = FakeFetcher();
    mgr = DownloadManager(db, fetcher, null, MangaImageDownloader(db));
  });

  tearDown(() => db.close());

  test('batch >50 chương chia chunk ≤50 và hoàn thành hết', () async {
    for (var i = 1; i <= 60; i++) {
      fetcher.chapters['c$i'] = makeTextChapter('c$i', number: i);
    }
    final enqueued = await mgr.enqueueAllChapters(
      storyId: 's1',
      storySlug: 'truyen-test',
      chapters: [for (var i = 1; i <= 60; i++) makeSummary('c$i', i)],
      storyTitle: 'Truyện test',
    );
    expect(enqueued, 60);
    await waitForQueueDone(db);

    // Chunk 50 + 10 — không gửi 1 lần 60 ids (backend cap 50).
    expect(fetcher.batchCalls.length, 2);
    expect(fetcher.batchCalls[0].length, 50);
    expect(fetcher.batchCalls[1].length, 10);

    final downloaded = await db.getDownloadedChaptersForStory('s1');
    expect(downloaded.length, 60);
    expect(
      downloaded.every((d) => d.source == 'manual_download'),
      true,
      reason: 'tải chủ động phải là manual_download (hiện Offline Library)',
    );
    final queue = await db.getDownloadQueue();
    expect(queue.every((q) => q.status == 'completed'), true);
  });

  test('batch fail → fallback vẫn tải xong từng chương (không kẹt downloading)', () async {
    // Bug cũ: _processBatch đánh dấu tất cả 'downloading' rồi batch 400
    // → fallback _processSingle skip hết vì guard chỉ nhận pending/retry
    // → toàn queue kẹt 'downloading' vĩnh viễn.
    fetcher.failBatch = true;
    for (var i = 1; i <= 3; i++) {
      fetcher.chapters['c$i'] = makeTextChapter('c$i', number: i);
    }
    await mgr.enqueueAllChapters(
      storyId: 's1',
      storySlug: 'truyen-test',
      chapters: [for (var i = 1; i <= 3; i++) makeSummary('c$i', i)],
      storyTitle: 'Truyện test',
    );
    await waitForQueueDone(db);

    final queue = await db.getDownloadQueue();
    expect(queue.every((q) => q.status == 'completed'), true,
        reason: 'fallback phải tải xong từng chương, không để kẹt');
    expect(fetcher.batchCalls.length, 1); // lần batch đầu fail
    final downloaded = await db.getDownloadedChaptersForStory('s1');
    expect(downloaded.length, 3);
  });

  test('row kẹt "downloading" từ session trước vẫn được xử lý khi recover', () async {
    // Mô phỏng app bị kill giữa batch → row còn 'downloading' 0.3.
    final id = await db.enqueueDownload(DownloadQueueCompanion.insert(
      storyId: 's1',
      storySlug: 'truyen-test',
      storyTitle: const Value('Truyện test'),
      chapterId: 'c1',
      chapterNumber: 1,
      downloadType: 'chapter',
      queuedAt: DateTime.now().toIso8601String(),
    ));
    await db.updateDownloadQueueRow(
      id,
      DownloadQueueCompanion(status: const Value('downloading')),
    );
    fetcher.chapters['c1'] = makeTextChapter('c1', number: 1);

    await mgr.recoverInterrupted();
    await waitForQueueDone(db);

    expect((await db.getDownloadQueueRow(id))!.status, 'completed');
    expect((await db.getDownloadedChapter('c1')) != null, true);
  });

  test('enqueueChapter promote auto_cache → manual_download (hiện Offline Library)', () async {
    await db.upsertDownloadedChapter(DownloadedChaptersCompanion.insert(
      chapterId: 'c1',
      storyId: 's1',
      storyTitle: 'Truyện test',
      storySlug: 'truyen-test',
      chapterNumber: 1,
      chapterTitle: 'Chương 1',
      contentType: 'text',
      contentRaw: '{}',
      downloadedAt: DateTime.now().toIso8601String(),
      source: const Value('auto_cache'),
    ));

    final r = await mgr.enqueueChapter(
      storyId: 's1',
      storySlug: 'truyen-test',
      chapterId: 'c1',
      chapterNumber: 1,
      storyTitle: 'Truyện test',
    );
    expect(r, -1); // không enqueue thêm — đã có trong DB

    final row = await db.getDownloadedChapter('c1');
    expect(row!.source, 'manual_download',
        reason: 'user bấm tải = ý chủ động → phải thoát khỏi auto_cache');
  });

  test('enqueueAllChapters promote auto_cache của cả truyện', () async {
    // Chương 1 đã auto_cache (đọc online trước), chương 2 chưa có gì.
    await db.upsertDownloadedChapter(DownloadedChaptersCompanion.insert(
      chapterId: 'c1',
      storyId: 's1',
      storyTitle: 'Truyện test',
      storySlug: 'truyen-test',
      chapterNumber: 1,
      chapterTitle: 'Chương 1',
      contentType: 'text',
      contentRaw: '{}',
      downloadedAt: DateTime.now().toIso8601String(),
      source: const Value('auto_cache'),
    ));
    fetcher.chapters['c2'] = makeTextChapter('c2', number: 2);

    final enqueued = await mgr.enqueueAllChapters(
      storyId: 's1',
      storySlug: 'truyen-test',
      chapters: [makeSummary('c1', 1), makeSummary('c2', 2)],
      storyTitle: 'Truyện test',
    );
    expect(enqueued, 1); // chỉ c2 cần tải
    await waitForQueueDone(db);

    expect((await db.getDownloadedChapter('c1'))!.source, 'manual_download');
    expect((await db.getDownloadedChapter('c2'))!.source, 'manual_download');
  });

  test('access-check fail do mạng → message mạng, không nhầm "Chương VIP"', () async {
    fetcher.accessFn = (_) => const ChapterAccess(
        canRead: false, isLocked: true, reason: 'access_check_failed');
    await mgr.enqueueChapter(
      storyId: 's1',
      storySlug: 'truyen-test',
      chapterId: 'c1',
      chapterNumber: 1,
      storyTitle: 'Truyện test',
    );
    await waitForQueueDone(db);

    final rows = await db.getDownloadQueue();
    expect(rows.single.status, 'failed');
    expect(rows.single.errorMessage, contains('kiểm tra mạng'));
  });

  test('chương VIP không có quyền → message VIP rõ ràng', () async {
    fetcher.accessFn = (_) => const ChapterAccess(
        canRead: false, isLocked: true, reason: 'vip_locked');
    await mgr.enqueueChapter(
      storyId: 's1',
      storySlug: 'truyen-test',
      chapterId: 'c1',
      chapterNumber: 1,
      storyTitle: 'Truyện test',
    );
    await waitForQueueDone(db);

    final rows = await db.getDownloadQueue();
    expect(rows.single.status, 'failed');
    expect(rows.single.errorMessage, contains('Chương VIP'));
  });

  test('queue row lưu storyTitle để màn Tải xuống hiển thị tên truyện', () async {
    fetcher.chapters['c1'] = makeTextChapter('c1', number: 1);
    await mgr.enqueueChapter(
      storyId: 's1',
      storySlug: 'truyen-test',
      chapterId: 'c1',
      chapterNumber: 1,
      storyTitle: 'Truyện test',
    );
    await waitForQueueDone(db);

    final row = (await db.getDownloadQueue()).single;
    expect(row.storyTitle, 'Truyện test');
  });
}
