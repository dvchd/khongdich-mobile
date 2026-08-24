import 'package:flutter/foundation.dart';

/// Một truyện trong danh sách "Truyện của tôi" của tác giả.
///
/// Mirror `GET /api/v1/mobile/me/stories` (backend
/// `src/api/mobile.rs::MyStoryItem`) — gồm cả nháp/chờ duyệt/riêng tư,
/// mirror dashboard web `/dang-truyen`.
@immutable
class MyStory {
  const MyStory({
    required this.id,
    required this.slug,
    required this.title,
    required this.visibility,
    required this.status,
    required this.contentType,
    required this.chapterCount,
    required this.publishedChapters,
    required this.wordCount,
    required this.updatedAt,
    this.coverUrl,
  });

  final String id;
  final String slug;
  final String title;

  /// `public` | `private` | `draft` | `pending` — mirror badge dashboard
  /// web (dang_truyen/dashboard.html:68-72).
  final String visibility;
  final String status;
  final String contentType;
  final int chapterCount;
  final int publishedChapters;
  final int wordCount;
  final DateTime updatedAt;
  final String? coverUrl;

  /// Nhãn hiển thị tiếng Việt — trùng wording badge web.
  String get visibilityLabel => switch (visibility) {
        'public' => 'Công khai',
        'private' => 'Riêng tư',
        'draft' => 'Nháp',
        'pending' => 'Chờ duyệt',
        _ => visibility,
      };

  factory MyStory.fromJson(Map<String, dynamic> json) => MyStory(
        id: json['id'] as String,
        slug: json['slug'] as String,
        title: json['title'] as String,
        visibility: json['visibility'] as String? ?? 'draft',
        status: json['status'] as String? ?? '',
        contentType: json['content_type'] as String? ?? 'text',
        chapterCount: (json['chapter_count'] as num?)?.toInt() ?? 0,
        publishedChapters: (json['published_chapters'] as num?)?.toInt() ?? 0,
        wordCount: (json['word_count'] as num?)?.toInt() ?? 0,
        updatedAt:
            DateTime.tryParse(json['updated_at'] as String? ?? '') ??
                DateTime.now(),
        coverUrl: (json['cover_url'] as String?)?.takeIfNonEmpty,
      );
}

extension on String? {
  String? get takeIfNonEmpty => (this == null || this!.isEmpty) ? null : this;
}
