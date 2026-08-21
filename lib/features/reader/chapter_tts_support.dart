import '../../core/markdown/markdown.dart';
import '../../models/chapter_content.dart';

/// Shared TTS-related helpers for chapter content — dùng bởi cả reader
/// screens lẫn [TtsAudioHandler] (resolver chương khi auto-advance).
///
/// Tách riêng khỏi `chapter_reader_screen.dart` để handler không import
/// vòng vào màn hình (chapter_reader_screen import tts_audio_handler).

/// Markdown payload for TTS — `text` and `visual` (Bách khoa) chapters
/// share the text pipeline; manga / chat / video have no TTS.
///
/// Chương `content_format == 'plain'` (WYSIWYG trên web: 1 Enter = ngắt
/// dòng) được convert sang markdown tương đương để TTS ngắt nghỉ đúng
/// cấu trúc đoạn — giống reader render.
String? chapterMarkdownOrNull(ChapterContent? chapter) {
  return switch (chapter) {
    TextChapterContent(:final contentMarkdown, :final contentFormat) =>
      contentFormat == 'plain'
          ? plainTextToMarkdown(contentMarkdown)
          : contentMarkdown,
    VisualChapterContent(:final contentMarkdown, :final contentFormat) =>
      contentFormat == 'plain'
          ? plainTextToMarkdown(contentMarkdown)
          : contentMarkdown,
    _ => null,
  };
}

/// Whether the TTS (headphone) toggle is available for [chapter].
///
/// `text` and `visual` (Bách khoa) chapters share the text pipeline;
/// manga / chat / video have no TTS. Both readers (online + offline)
/// use this to gate the "Nghe audio" button. Previously the online
/// reader checked the provider's `AsyncValue` instead of the unwrapped
/// chapter (`chapter is TextChapterContent` where `chapter` was the
/// AsyncValue) → the check was always false → the headphone button
/// silently disappeared from the online reader.
bool chapterSupportsTts(ChapterContent? chapter) =>
    chapter is TextChapterContent || chapter is VisualChapterContent;
