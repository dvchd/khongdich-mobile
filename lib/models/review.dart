import 'package:flutter/foundation.dart';

/// A single story review (đánh giá truyện). Mirrors the backend's
/// `ReviewView` JSON served by `GET /api/v1/mobile/stories/{id}/reviews`.
@immutable
class ReviewItem {
  const ReviewItem({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    required this.rating,
    required this.content,
    required this.contentHtml,
    required this.createdAt,
  });

  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;

  /// 1–5 stars.
  final int rating;
  final String content;
  final String contentHtml;
  final DateTime createdAt;

  String get displayAuthor => displayName.isEmpty ? username : displayName;

  factory ReviewItem.fromJson(Map<String, dynamic> json) => ReviewItem(
    id: json['id'] as String,
    username: json['username'] as String? ?? '',
    displayName: json['display_name'] as String? ?? '',
    avatarUrl: json['avatar_url'] as String?,
    rating: (json['rating'] as num?)?.toInt() ?? 0,
    content: json['content'] as String? ?? '',
    contentHtml: json['content_html'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['created_at'] as String? ?? '') ??
        DateTime.now(),
  );
}

/// Paginated review feed wrapper with story aggregates and the caller's
/// own rating (for pre-filling the review form).
@immutable
class ReviewsFeed {
  const ReviewsFeed({
    required this.reviews,
    required this.total,
    required this.page,
    required this.perPage,
    required this.totalPages,
    this.avgRating = 0,
    this.reviewCount = 0,
    this.myRating,
  });

  final List<ReviewItem> reviews;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;

  /// Story-wide average rating (0 when no reviews yet).
  final double avgRating;

  /// Number of reviews for the story.
  final int reviewCount;

  /// The current user's own rating (1–5) or null when they haven't
  /// reviewed this story yet.
  final int? myRating;

  factory ReviewsFeed.fromJson(Map<String, dynamic> json) => ReviewsFeed(
    reviews: [
      for (final r in (json['reviews'] as List? ?? const []))
        ReviewItem.fromJson(r as Map<String, dynamic>),
    ],
    total: (json['total'] as num?)?.toInt() ?? 0,
    page: (json['page'] as num?)?.toInt() ?? 1,
    perPage: (json['per_page'] as num?)?.toInt() ?? 20,
    totalPages: (json['total_pages'] as num?)?.toInt() ?? 0,
    avgRating: (json['avg_rating'] as num?)?.toDouble() ?? 0,
    reviewCount: (json['review_count'] as num?)?.toInt() ?? 0,
    myRating: (json['my_rating'] as num?)?.toInt(),
  );
}