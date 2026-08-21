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
    this.categorySlugs = const [],
    this.tagSlugs = const [],
    required this.contentTypes,
    this.synopsis,
    this.chapterCount,
    this.wordCount,
    this.status,
    this.rating,
    this.reviewCount = 0,
    this.followers,
    this.viewCount,
    this.updatedAt,
    this.isVip = false,
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
      categorySlugs: const [],
      tagSlugs: const [],
      contentTypes: [json['content_type'] as String? ?? 'text'],
      synopsis: json['synopsis'] as String?,
      chapterCount: (json['chapter_count'] as num?)?.toInt(),
      wordCount: null,
      status: json['status'] as String?,
      viewCount: (json['view_count'] as num?)?.toInt(),
      rating: (json['avg_rating'] as num?)?.toDouble(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
      isVip: json['is_vip'] as bool? ?? false,
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
      categorySlugs: const [],
      tagSlugs: const [],
      contentTypes: [json['content_type'] as String? ?? 'text'],
      synopsis: json['synopsis'] as String?,
      chapterCount: (json['chapter_count'] as num?)?.toInt(),
      wordCount: (json['word_count'] as num?)?.toInt(),
      status: json['status'] as String?,
      viewCount: (json['view_count'] as num?)?.toInt(),
      rating: double.tryParse(json['avg_rating']?.toString() ?? ''),
      reviewCount: (json['review_count'] as num?)?.toInt() ?? 0,
      followers: (json['bookmark_count'] as num?)?.toInt(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
      isVip: json['is_vip'] as bool? ?? false,
    );
  }

  final String id;
  final String title;
  final String slug;
  final String? coverUrl;
  final String author;
  final List<String> categories;
  final List<String> tags;
  /// Slug song song với [categories]/[tags] — dùng cho navigation browse.
  /// Chỉ có ở payload detail (story cards không kèm slug).
  final List<String> categorySlugs;
  final List<String> tagSlugs;
  final List<String> contentTypes;
  final String? synopsis;
  final int? chapterCount;
  final int? wordCount;
  final String? status;
  final double? rating;
  final int? followers;
  final int? viewCount;
  final DateTime? updatedAt;
  /// True if the story is currently VIP (admin-approved). Parsed from
  /// `is_vip` field in the backend's StoryCard JSON response.
  final bool isVip;

  /// Number of story reviews (đánh giá). Always 0 on story cards; parsed
  /// from the story detail payload.
  final int reviewCount;

  StorySummary copyWith({
    String? author,
    List<String>? categories,
    List<String>? tags,
    List<String>? categorySlugs,
    List<String>? tagSlugs,
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
        categorySlugs: categorySlugs ?? this.categorySlugs,
        tagSlugs: tagSlugs ?? this.tagSlugs,
        contentTypes: contentTypes,
        synopsis: synopsis ?? this.synopsis,
        chapterCount: chapterCount,
        wordCount: wordCount,
        status: status,
        rating: rating,
        reviewCount: reviewCount,
        followers: followers,
        viewCount: viewCount,
        updatedAt: updatedAt,
        isVip: isVip,
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
    this.updatedAt,
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
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
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

  /// Lần cuối chương được sửa (backend `chapters.updated_at`). Dùng để
  /// phát hiện chapter cache stale: tác giả sửa chương → updated_at đổi
  /// → mobile phải refetch thay vì dùng cache cũ.
  final DateTime? updatedAt;
  final String? url;
  final int? volumeNumber;
  final String? volumeTitle;
}
