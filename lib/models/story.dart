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
  });

  final String id;
  final String title;
  final String slug;
  final String? coverUrl;
  final String author;
  final List<String> categories;
  final List<String> tags;
  final List<String> contentTypes; // subset of ['text','manga','chat','video']
  final String? synopsis;
  final int? chapterCount;
  final int? wordCount;
  final String? status; // 'ongoing' | 'completed' | 'hiatus'
  final double? rating;
  final int? followers;

  factory StorySummary.fromJson(Map<String, dynamic> json) => StorySummary(
        id: json['id'] as String,
        title: json['title'] as String,
        slug: json['slug'] as String,
        coverUrl: json['cover_url'] as String?,
        author: json['author'] as String? ?? 'Không rõ',
        categories: List<String>.from(json['categories'] as List? ?? const []),
        tags: List<String>.from(json['tags'] as List? ?? const []),
        contentTypes:
            List<String>.from(json['content_types'] as List? ?? const ['text']),
        synopsis: json['synopsis'] as String?,
        chapterCount: (json['chapter_count'] as num?)?.toInt(),
        wordCount: (json['word_count'] as num?)?.toInt(),
        status: json['status'] as String?,
        rating: (json['rating'] as num?)?.toDouble(),
        followers: (json['followers'] as num?)?.toInt(),
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
  });

  final String id;
  final int chapterNumber;
  final String title;
  final String contentType;
  final int contentVersion;
  final bool isPublished;
  final int wordCount;

  factory ChapterSummary.fromJson(Map<String, dynamic> json) => ChapterSummary(
        id: json['id'] as String,
        chapterNumber: (json['chapter_number'] as num).toInt(),
        title: json['title'] as String,
        contentType: json['content_type'] as String,
        contentVersion: (json['content_version'] as num? ?? 1).toInt(),
        isPublished: json['is_published'] as bool? ?? true,
        wordCount: (json['word_count'] as num? ?? 0).toInt(),
      );
}
