import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/features/reader/chapter_reader_screen.dart';
import 'package:khongdich_mobile/models/chapter_content.dart';

/// Regression tests cho bug "nút nghe audio (TTS) biến mất khỏi reader
/// online" — trước đây `chapterReaderScreen` check `chapter is
/// TextChapterContent` trên `AsyncValue` (luôn false) thay vì chapter
/// đã unwrap → headphone button không bao giờ hiện.
///
/// Giờ cả online lẫn offline reader đều dùng `chapterSupportsTts()`
/// (nhận `ChapterContent?`) nên không thể truyền nhầm AsyncValue.
void main() {
  group('chapterSupportsTts', () {
    test('true cho text và visual (Bách khoa)', () {
      expect(chapterSupportsTts(_textChapter()), isTrue);
      expect(chapterSupportsTts(_visualChapter()), isTrue);
    });

    test('false cho manga / chat / video', () {
      expect(chapterSupportsTts(_mangaChapter()), isFalse);
      expect(chapterSupportsTts(_chatChapter()), isFalse);
      expect(chapterSupportsTts(_videoChapter()), isFalse);
    });

    test('false cho null', () {
      expect(chapterSupportsTts(null), isFalse);
    });

    test('chapterMarkdownOrNull trả về markdown cho text/visual, null còn lại',
        () {
      expect(chapterMarkdownOrNull(_textChapter()), '**markdown**');
      expect(chapterMarkdownOrNull(_visualChapter()), '**visual**');
      expect(chapterMarkdownOrNull(_mangaChapter()), isNull);
      expect(chapterMarkdownOrNull(null), isNull);
    });
  });
}

TextChapterContent _textChapter() => TextChapterContent(
      id: 'c1',
      storyId: 's1',
      storyTitle: 'S',
      storySlug: 's',
      chapterNumber: 1,
      title: 'Chương 1',
      contentVersion: 1,
      wordCount: 10,
      isPublished: true,
      prevChapter: null,
      nextChapter: 2,
      updatedAt: DateTime(2026),
      contentMarkdown: '**markdown**',
      contentFormat: 'markdown',
    );

VisualChapterContent _visualChapter() => VisualChapterContent(
      id: 'c2',
      storyId: 's1',
      storyTitle: 'S',
      storySlug: 's',
      chapterNumber: 2,
      title: 'Chương 2',
      contentVersion: 1,
      wordCount: 10,
      isPublished: true,
      prevChapter: 1,
      nextChapter: 3,
      updatedAt: DateTime(2026),
      contentMarkdown: '**visual**',
      contentFormat: 'markdown',
    );

MangaChapterContent _mangaChapter() => MangaChapterContent(
      id: 'c3',
      storyId: 's1',
      storyTitle: 'S',
      storySlug: 's',
      chapterNumber: 3,
      title: 'Chương 3',
      contentVersion: 1,
      wordCount: 0,
      isPublished: true,
      prevChapter: 2,
      nextChapter: null,
      updatedAt: DateTime(2026),
      images: const [MangaPage(url: 'https://x/y.png')],
    );

ChatChapterContent _chatChapter() => ChatChapterContent(
      id: 'c4',
      storyId: 's1',
      storyTitle: 'S',
      storySlug: 's',
      chapterNumber: 4,
      title: 'Chương 4',
      contentVersion: 1,
      wordCount: 0,
      isPublished: true,
      prevChapter: 3,
      nextChapter: null,
      updatedAt: DateTime(2026),
      participants: const [],
      messages: const [],
    );

VideoChapterContent _videoChapter() => VideoChapterContent(
      id: 'c5',
      storyId: 's1',
      storyTitle: 'S',
      storySlug: 's',
      chapterNumber: 5,
      title: 'Chương 5',
      contentVersion: 1,
      wordCount: 0,
      isPublished: true,
      prevChapter: 4,
      nextChapter: null,
      updatedAt: DateTime(2026),
      video: const VideoInfo(provider: 'youtube', videoId: 'abc'),
    );
