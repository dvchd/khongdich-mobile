import 'package:flutter/foundation.dart';

/// Discriminated union for chapter content.
///
/// Mirrors `src/api/mobile.rs::ChapterContentResponse`. Each variant
/// corresponds to one backend `content_type` (`text` / `manga` / `chat`
/// / `video`). The mobile reader `switch`-es over this to pick the
/// right view widget.
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'story_id': storyId,
        'story_title': storyTitle,
        'story_slug': storySlug,
        'chapter_number': chapterNumber,
        'title': title,
        'content_type': contentType,
        'content_version': contentVersion,
        'word_count': wordCount,
        'is_published': isPublished,
        'prev_chapter': prevChapter,
        'next_chapter': nextChapter,
        'updated_at': updatedAt.toIso8601String(),
      };

  /// Construct the right variant from a `ChapterContentResponse` JSON
  /// payload (backend `src/api/mobile.rs::get_chapter`).
  factory ChapterContent.fromJson(Map<String, dynamic> json) {
    final common = _CommonFields.fromJson(json);
    final type = json['content_type'] as String;
    return switch (type) {
      'text' => TextChapterContent._fromJson(common, json),
      'manga' => MangaChapterContent._fromJson(common, json),
      'chat' => ChatChapterContent._fromJson(common, json),
      'video' => VideoChapterContent._fromJson(common, json),
      _ => throw ArgumentError.value(type, 'content_type', 'Unknown'),
    };
  }
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
        contentVersion: (json['content_version'] as num? ?? 1).toInt(),
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
  final String contentFormat;
  final String? authorNote;

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
    required this.contentFormat,
    this.authorNote,
  }) : super(contentType: 'text');

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'content_markdown': contentMarkdown,
        'content_format': contentFormat,
        if (authorNote != null) 'author_note': authorNote,
      };

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
        contentFormat: json['content_format'] as String? ?? 'markdown',
        authorNote: json['author_note'] as String?,
      );
}

class MangaPage {
  const MangaPage({required this.url, this.altText, this.caption});
  final String url;
  final String? altText;
  final String? caption;

  Map<String, dynamic> toJson() => {
        'image_url': url,
        if (altText != null) 'alt_text': altText,
        if (caption != null) 'caption': caption,
      };

  factory MangaPage.fromJson(Map<String, dynamic> json) => MangaPage(
        url: json['image_url'] as String,
        altText: (json['alt_text'] as String?)?.takeIfNonEmpty,
        caption: (json['caption'] as String?)?.takeIfNonEmpty,
      );
}

extension on String? {
  String? get takeIfNonEmpty {
    final v = this;
    if (v == null || v.isEmpty) return null;
    return v;
  }
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

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'images': images.map((p) => p.toJson()).toList(),
      };

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
}

class ChatParticipant {
  const ChatParticipant({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.color,
  });
  final String id;
  final String name;
  final String? avatarUrl;
  final String? color;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
        if (color != null) 'color': color,
      };

  factory ChatParticipant.fromJson(Map<String, dynamic> json) =>
      ChatParticipant(
        id: json['id'] as String,
        name: json['name'] as String,
        avatarUrl: json['avatar_url'] as String?,
        color: (json['color'] as String?)?.takeIfNonEmpty,
      );
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.characterId,
    required this.content,
    required this.messageType,
    this.imageUrl,
  });
  final String id;
  final String? characterId;
  final String content;
  final String messageType; // 'dialogue' | 'action' | 'narration' | 'system'
  final String? imageUrl;

  Map<String, dynamic> toJson() => {
        'id': id,
        if (characterId != null) 'character_id': characterId,
        'content': content,
        'message_type': messageType,
        if (imageUrl != null) 'image_url': imageUrl,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        characterId: json['character_id'] as String?,
        content: json['content'] as String,
        messageType: json['message_type'] as String? ?? 'dialogue',
        imageUrl: json['image_url'] as String?,
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

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'participants': participants.map((p) => p.toJson()).toList(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

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
}

class VideoInfo {
  const VideoInfo({
    required this.provider,
    required this.videoId,
    this.caption,
  });
  final String provider; // 'youtube' | 'vimeo' | 'other'
  final String videoId;
  final String? caption;

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'video_id': videoId,
        if (caption != null) 'caption': caption,
      };

  factory VideoInfo.fromJson(Map<String, dynamic> json) => VideoInfo(
        provider: json['provider'] as String? ?? 'youtube',
        videoId: json['video_id'] as String? ?? '',
        caption: (json['caption'] as String?)?.takeIfNonEmpty,
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

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'video': video.toJson(),
        if (captionMarkdown != null) 'content_markdown': captionMarkdown,
      };

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
        video: json['video'] != null
            ? VideoInfo.fromJson(json['video'] as Map<String, dynamic>)
            : const VideoInfo(provider: 'youtube', videoId: ''),
        captionMarkdown: json['content_markdown'] as String?,
      );
}
