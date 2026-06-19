import 'package:flutter/foundation.dart';

/// Discriminated union for chapter content.
///
/// Per `docs/plan-flutter-app.md` §4.3 / §12.2 — the backend returns a
/// different JSON shape per `content_type`. We model that as a sealed
/// Dart class so the reader can `switch` exhaustively over the four
/// variants (text / manga / chat / video).
@immutable
sealed class ChapterContent {
  const ChapterContent({
    required this.id,
    required this.storyId,
    required this.storyTitle,
    required this.storySlug,
    required this.chapterNumber,
    required this.title,
    required this.contentType,
    required this.contentVersion,
    required this.wordCount,
    required this.isPublished,
    required this.prevChapter,
    required this.nextChapter,
    required this.updatedAt,
  });

  final String id;
  final String storyId;
  final String storyTitle;
  final String storySlug;
  final int chapterNumber;
  final String title;
  final String contentType;
  final int contentVersion;
  final int wordCount;
  final bool isPublished;
  final int? prevChapter;
  final int? nextChapter;
  final DateTime updatedAt;

  factory ChapterContent.fromJson(Map<String, dynamic> json) {
    final type = json['content_type'] as String;
    final common = _CommonFields.fromJson(json);
    return switch (type) {
      'text' => TextChapterContent._fromJson(common, json),
      'manga' => MangaChapterContent._fromJson(common, json),
      'chat' => ChatChapterContent._fromJson(common, json),
      'video' => VideoChapterContent._fromJson(common, json),
      _ => throw ArgumentError.value(type, 'content_type', 'Unknown'),
    };
  }

  Map<String, dynamic> toJson();
}

class _CommonFields {
  final String id;
  final String storyId;
  final String storyTitle;
  final String storySlug;
  final int chapterNumber;
  final String title;
  final String contentType;
  final int contentVersion;
  final int wordCount;
  final bool isPublished;
  final int? prevChapter;
  final int? nextChapter;
  final DateTime updatedAt;

  const _CommonFields({
    required this.id,
    required this.storyId,
    required this.storyTitle,
    required this.storySlug,
    required this.chapterNumber,
    required this.title,
    required this.contentType,
    required this.contentVersion,
    required this.wordCount,
    required this.isPublished,
    required this.prevChapter,
    required this.nextChapter,
    required this.updatedAt,
  });

  factory _CommonFields.fromJson(Map<String, dynamic> json) => _CommonFields(
        id: json['id'] as String,
        storyId: json['story_id'] as String,
        storyTitle: json['story_title'] as String,
        storySlug: json['story_slug'] as String,
        chapterNumber: (json['chapter_number'] as num).toInt(),
        title: json['title'] as String,
        contentType: json['content_type'] as String,
        contentVersion: (json['content_version'] as num).toInt(),
        wordCount: (json['word_count'] as num? ?? 0).toInt(),
        isPublished: json['is_published'] as bool? ?? true,
        prevChapter: (json['prev_chapter'] as num?)?.toInt(),
        nextChapter: (json['next_chapter'] as num?)?.toInt(),
        updatedAt:
            DateTime.tryParse(json['updated_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

class TextChapterContent extends ChapterContent {
  final String contentMarkdown;

  const TextChapterContent({
    required super.id,
    required super.storyId,
    required super.storyTitle,
    required super.storySlug,
    required super.chapterNumber,
    required super.title,
    required super.contentVersion,
    required super.wordCount,
    required super.isPublished,
    required super.prevChapter,
    required super.nextChapter,
    required super.updatedAt,
    required this.contentMarkdown,
  }) : super(contentType: 'text');

  factory TextChapterContent._fromJson(
    _CommonFields c,
    Map<String, dynamic> json,
  ) =>
      TextChapterContent(
        id: c.id,
        storyId: c.storyId,
        storyTitle: c.storyTitle,
        storySlug: c.storySlug,
        chapterNumber: c.chapterNumber,
        title: c.title,
        contentVersion: c.contentVersion,
        wordCount: c.wordCount,
        isPublished: c.isPublished,
        prevChapter: c.prevChapter,
        nextChapter: c.nextChapter,
        updatedAt: c.updatedAt,
        contentMarkdown: json['content_markdown'] as String? ?? '',
      );

  @override
  Map<String, dynamic> toJson() => {
        'content_type': 'text',
        'id': id,
        'story_id': storyId,
        'story_title': storyTitle,
        'story_slug': storySlug,
        'chapter_number': chapterNumber,
        'title': title,
        'content_version': contentVersion,
        'word_count': wordCount,
        'is_published': isPublished,
        'prev_chapter': prevChapter,
        'next_chapter': nextChapter,
        'updated_at': updatedAt.toIso8601String(),
        'content_markdown': contentMarkdown,
      };
}

class MangaPage {
  const MangaPage({required this.url, this.width, this.height});
  final String url;
  final int? width;
  final int? height;

  factory MangaPage.fromJson(Map<String, dynamic> json) => MangaPage(
        url: json['url'] as String,
        width: (json['width'] as num?)?.toInt(),
        height: (json['height'] as num?)?.toInt(),
      );
}

class MangaChapterContent extends ChapterContent {
  final List<MangaPage> images;

  const MangaChapterContent({
    required super.id,
    required super.storyId,
    required super.storyTitle,
    required super.storySlug,
    required super.chapterNumber,
    required super.title,
    required super.contentVersion,
    required super.wordCount,
    required super.isPublished,
    required super.prevChapter,
    required super.nextChapter,
    required super.updatedAt,
    required this.images,
  }) : super(contentType: 'manga');

  factory MangaChapterContent._fromJson(
    _CommonFields c,
    Map<String, dynamic> json,
  ) =>
      MangaChapterContent(
        id: c.id,
        storyId: c.storyId,
        storyTitle: c.storyTitle,
        storySlug: c.storySlug,
        chapterNumber: c.chapterNumber,
        title: c.title,
        contentVersion: c.contentVersion,
        wordCount: c.wordCount,
        isPublished: c.isPublished,
        prevChapter: c.prevChapter,
        nextChapter: c.nextChapter,
        updatedAt: c.updatedAt,
        images: [
          for (final p in (json['images'] as List? ?? const []))
            MangaPage.fromJson(p as Map<String, dynamic>),
        ],
      );

  @override
  Map<String, dynamic> toJson() => {
        'content_type': 'manga',
        'id': id,
        'story_id': storyId,
        'story_title': storyTitle,
        'story_slug': storySlug,
        'chapter_number': chapterNumber,
        'title': title,
        'content_version': contentVersion,
        'word_count': wordCount,
        'is_published': isPublished,
        'prev_chapter': prevChapter,
        'next_chapter': nextChapter,
        'updated_at': updatedAt.toIso8601String(),
        'images': [for (final p in images) {'url': p.url, 'width': p.width, 'height': p.height}],
      };
}

class ChatParticipant {
  const ChatParticipant({
    required this.id,
    required this.name,
    this.avatar,
    this.color,
  });
  final String id;
  final String name;
  final String? avatar;
  final String? color;

  factory ChatParticipant.fromJson(Map<String, dynamic> json) =>
      ChatParticipant(
        id: json['id'] as String,
        name: json['name'] as String,
        avatar: json['avatar'] as String?,
        color: json['color'] as String?,
      );
}

class ChatMessage {
  const ChatMessage({
    required this.speakerId,
    required this.text,
    required this.side,
  });
  final String? speakerId;
  final String text;
  final String side; // 'left' | 'right' | 'narration'

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        speakerId: json['speaker_id'] as String?,
        text: json['text'] as String,
        side: json['side'] as String? ?? 'left',
      );
}

class ChatChapterContent extends ChapterContent {
  final List<ChatParticipant> participants;
  final List<ChatMessage> messages;

  const ChatChapterContent({
    required super.id,
    required super.storyId,
    required super.storyTitle,
    required super.storySlug,
    required super.chapterNumber,
    required super.title,
    required super.contentVersion,
    required super.wordCount,
    required super.isPublished,
    required super.prevChapter,
    required super.nextChapter,
    required super.updatedAt,
    required this.participants,
    required this.messages,
  }) : super(contentType: 'chat');

  factory ChatChapterContent._fromJson(
    _CommonFields c,
    Map<String, dynamic> json,
  ) =>
      ChatChapterContent(
        id: c.id,
        storyId: c.storyId,
        storyTitle: c.storyTitle,
        storySlug: c.storySlug,
        chapterNumber: c.chapterNumber,
        title: c.title,
        contentVersion: c.contentVersion,
        wordCount: c.wordCount,
        isPublished: c.isPublished,
        prevChapter: c.prevChapter,
        nextChapter: c.nextChapter,
        updatedAt: c.updatedAt,
        participants: [
          for (final p in (json['participants'] as List? ?? const []))
            ChatParticipant.fromJson(p as Map<String, dynamic>),
        ],
        messages: [
          for (final m in (json['messages'] as List? ?? const []))
            ChatMessage.fromJson(m as Map<String, dynamic>),
        ],
      );

  @override
  Map<String, dynamic> toJson() => {
        'content_type': 'chat',
        'id': id,
        'story_id': storyId,
        'story_title': storyTitle,
        'story_slug': storySlug,
        'chapter_number': chapterNumber,
        'title': title,
        'content_version': contentVersion,
        'word_count': wordCount,
        'is_published': isPublished,
        'prev_chapter': prevChapter,
        'next_chapter': nextChapter,
        'updated_at': updatedAt.toIso8601String(),
        'participants': [
          for (final p in participants)
            {'id': p.id, 'name': p.name, 'avatar': p.avatar, 'color': p.color},
        ],
        'messages': [
          for (final m in messages)
            {'speaker_id': m.speakerId, 'text': m.text, 'side': m.side},
        ],
      };
}

class VideoInfo {
  const VideoInfo({
    required this.provider,
    required this.videoId,
    this.startSeconds = 0,
    this.endSeconds,
  });
  final String provider; // 'youtube' (only one supported per plan §12.2)
  final String videoId;
  final int startSeconds;
  final int? endSeconds;

  factory VideoInfo.fromJson(Map<String, dynamic> json) => VideoInfo(
        provider: json['provider'] as String? ?? 'youtube',
        videoId: json['video_id'] as String,
        startSeconds: (json['start_seconds'] as num? ?? 0).toInt(),
        endSeconds: (json['end_seconds'] as num?)?.toInt(),
      );
}

class VideoChapterContent extends ChapterContent {
  final VideoInfo video;
  final String? captionMarkdown;

  const VideoChapterContent({
    required super.id,
    required super.storyId,
    required super.storyTitle,
    required super.storySlug,
    required super.chapterNumber,
    required super.title,
    required super.contentVersion,
    required super.wordCount,
    required super.isPublished,
    required super.prevChapter,
    required super.nextChapter,
    required super.updatedAt,
    required this.video,
    this.captionMarkdown,
  }) : super(contentType: 'video');

  factory VideoChapterContent._fromJson(
    _CommonFields c,
    Map<String, dynamic> json,
  ) =>
      VideoChapterContent(
        id: c.id,
        storyId: c.storyId,
        storyTitle: c.storyTitle,
        storySlug: c.storySlug,
        chapterNumber: c.chapterNumber,
        title: c.title,
        contentVersion: c.contentVersion,
        wordCount: c.wordCount,
        isPublished: c.isPublished,
        prevChapter: c.prevChapter,
        nextChapter: c.nextChapter,
        updatedAt: c.updatedAt,
        video: VideoInfo.fromJson(json['video'] as Map<String, dynamic>),
        captionMarkdown: json['caption_markdown'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'content_type': 'video',
        'id': id,
        'story_id': storyId,
        'story_title': storyTitle,
        'story_slug': storySlug,
        'chapter_number': chapterNumber,
        'title': title,
        'content_version': contentVersion,
        'word_count': wordCount,
        'is_published': isPublished,
        'prev_chapter': prevChapter,
        'next_chapter': nextChapter,
        'updated_at': updatedAt.toIso8601String(),
        'video': {
          'provider': video.provider,
          'video_id': video.videoId,
          'start_seconds': video.startSeconds,
          'end_seconds': video.endSeconds,
        },
        if (captionMarkdown != null) 'caption_markdown': captionMarkdown,
      };
}
