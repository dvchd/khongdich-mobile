import 'package:flutter/foundation.dart';

@immutable
class StorySummary {
  const StorySummary({
    required this.id,
    required this.title,
    required this.slug,
    required this.coverUrl,
    required this.author,
    required this.categories,
    required this.tags,
    required this.contentTypes,
    this.synopsis,
    this.chapterCount,
    this.wordCount,
    this.status,
    this.rating,
    this.followers,
    this.viewCount,
    this.updatedAt,
  });

  /// Construct from a `StoryCard` JSON row (backend `models::story::StoryCard`).
  factory StorySummary.fromStoryCardJson(Map<String, dynamic> json) {
    return StorySummary(
      id: json['id'] as String,
      title: json['title'] as String,
      slug: json['slug'] as String,
      coverUrl: json['cover_url'] as String?,
      author: (json['author_display_name'] as String?) ??
          (json['author_username'] as String?) ??
          'Không rõ',
      categories: const [],
      tags: const [],
      contentTypes: [json['content_type'] as String? ?? 'text'],
      synopsis: json['synopsis'] as String?,
      chapterCount: (json['chapter_count'] as num?)?.toInt(),
      wordCount: null,
      status: json['status'] as String?,
      viewCount: (json['view_count'] as num?)?.toInt(),
      rating: (json['avg_rating'] as num?)?.toDouble(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }

  /// Construct from a `StoryDetail` JSON row (backend
  /// `services::story::detail_by_slug` — returns the full `Story` struct).
  factory StorySummary.fromStoryJson(Map<String, dynamic> json) {
    return StorySummary(
      id: json['id'] as String,
      title: json['title'] as String,
      slug: json['slug'] as String,
      coverUrl: json['cover_url'] as String?,
      author: '', // filled by the parent StoryDetail payload
      categories: const [],
      tags: const [],
      contentTypes: [json['content_type'] as String? ?? 'text'],
      synopsis: json['synopsis'] as String?,
      chapterCount: (json['chapter_count'] as num?)?.toInt(),
      wordCount: (json['word_count'] as num?)?.toInt(),
      status: json['status'] as String?,
      viewCount: (json['view_count'] as num?)?.toInt(),
      rating: double.tryParse(json['avg_rating']?.toString() ?? ''),
      followers: (json['bookmark_count'] as num?)?.toInt(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }

  final String id;
  final String title;
  final String slug;
  final String? coverUrl;
  final String author;
  final List<String> categories;
  final List<String> tags;
  final List<String> contentTypes;
  final String? synopsis;
  final int? chapterCount;
  final int? wordCount;
  final String? status;
  final double? rating;
  final int? followers;
  final int? viewCount;
  final DateTime? updatedAt;

  StorySummary copyWith({
    String? author,
    List<String>? categories,
    List<String>? tags,
    String? synopsis,
  }) =>
      StorySummary(
        id: id,
        title: title,
        slug: slug,
        coverUrl: coverUrl,
        author: author ?? this.author,
        categories: categories ?? this.categories,
        tags: tags ?? this.tags,
        contentTypes: contentTypes,
        synopsis: synopsis ?? this.synopsis,
        chapterCount: chapterCount,
        wordCount: wordCount,
        status: status,
        rating: rating,
        followers: followers,
        viewCount: viewCount,
        updatedAt: updatedAt,
      );
}

@immutable
class ChapterSummary {
  const ChapterSummary({
    required this.id,
    required this.chapterNumber,
    required this.title,
    required this.contentType,
    required this.contentVersion,
    required this.isPublished,
    required this.wordCount,
    this.url,
    this.volumeNumber,
    this.volumeTitle,
  });

  /// Construct from a `ChapterMeta` JSON row (backend
  /// `models::chapter::ChapterMeta`).
  factory ChapterSummary.fromJson(Map<String, dynamic> json) {
    return ChapterSummary(
      id: json['id'] as String,
      chapterNumber: (json['chapter_number'] as num).toInt(),
      title: json['title'] as String,
      // Backend doesn't include content_type on ChapterMeta — we
      // resolve it from the parent StorySummary in the repository.
      contentType: json['content_type'] as String? ?? 'text',
      contentVersion: (json['content_version'] as num? ?? 1).toInt(),
      isPublished: json['is_published'] as bool? ?? true,
      wordCount: (json['word_count'] as num? ?? 0).toInt(),
      url: json['url'] as String?,
      volumeNumber: (json['volume_number'] as num?)?.toInt(),
      volumeTitle: json['volume_title'] as String?,
    );
  }

  final String id;
  final int chapterNumber;
  final String title;
  final String contentType;
  final int contentVersion;
  final bool isPublished;
  final int wordCount;
  final String? url;
  final int? volumeNumber;
  final String? volumeTitle;
}
