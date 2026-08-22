import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/core/database/app_database.dart';
import 'package:khongdich_mobile/models/chapter_content.dart';
import 'package:khongdich_mobile/models/story.dart';
import 'package:khongdich_mobile/repositories/story_repository.dart';
import 'package:khongdich_mobile/services/chapter_cache_service.dart';

/// Repo giả "mất mạng": fetchAllChapters throw — mô phỏng offline.
class _OfflineRepo implements StoryRepository {
  @override
  Future<List<ChapterSummary>> fetchAllChapters(String storyId) async {
    throw Exception('network down');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Map<String, dynamic> _chapterJson(int number) => {
      'id': 'ch-$number',
      'story_id': 's1',
      'story_title': 'Truyện test',
      'story_slug': 'truyen-test',
      'chapter_number': number,
      'title': 'Chương $number',
      'content_type': 'text',
      'content_version': 1,
      'word_count': 10,
      'is_published': true,
      'updated_at': '2026-01-01T00:00:00Z',
      'content_markdown': 'Nội dung chương $number.',
      'content_format': 'markdown',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ChapterCacheService cache;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = ChapterCacheService(_OfflineRepo(), db);
  });

  tearDown(() => db.close());

  Future<void> seedChapter(int number) => db.upsertDownloadedChapter(
        DownloadedChaptersCompanion.insert(
          chapterId: 'ch-$number',
          storyId: 's1',
          storyTitle: 'Truyện test',
          storySlug: 'truyen-test',
          chapterNumber: number,
          chapterTitle: 'Chương $number',
          contentType: 'text',
          contentRaw: jsonEncode(_chapterJson(number)),
          downloadedAt: '2026-01-01T00:00:00Z',
          source: const Value('manual_download'),
        ),
      );

  group('ChapterCacheService offline DB fallback', () {
    test('mất mạng + chương ĐÃ TẢI → đọc từ DB (không throw)', () async {
      await seedChapter(1);
      final chapter = await cache.getChapter(storyId: 's1', chapterNumber: 1);
      expect(chapter.id, 'ch-1');
      expect(chapter.chapterNumber, 1);
      expect(chapter, isA<TextChapterContent>());
      expect((chapter as TextChapterContent).contentMarkdown,
          'Nội dung chương 1.');
    });

    test('mất mạng + chương CHƯA tải → rethrow lỗi mạng gốc', () async {
      expect(
        () => cache.getChapter(storyId: 's1', chapterNumber: 2),
        throwsA(isA<Exception>()),
      );
    });

    test('chapter list fail → tryGetChapterList trả null, không crash',
        () async {
      expect(await cache.tryGetChapterList('s1'), isNull);
    });

    test('chapter list fail → isChapterLocked trả false, không chặn ghost',
        () async {
      cache.setLockedChapterIds({'locked-id'});
      expect(
        await cache.isChapterLocked(storyId: 's1', chapterNumber: 1),
        isFalse,
      );
    });
  });
}
