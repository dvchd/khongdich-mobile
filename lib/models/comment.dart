import 'package:flutter/foundation.dart';

/// A single comment in the chapter comments feed (regular or
/// paragraph/segment comment). Mirrors the backend's `CommentView` JSON
/// served by `GET /api/v1/mobile/chapters/{id}/comments`.
@immutable
class CommentItem {
  const CommentItem({
    required this.id,
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    required this.content,
    required this.contentHtml,
    required this.likeCount,
    required this.createdAt,
    required this.edited,
    required this.hidden,
    required this.isMine,
    required this.likedByMe,
    this.parentId,
    this.replyToName,
    this.replyToId = '',
    this.replies = const [],
    this.isSegment = false,
    this.quoteText,
    this.paraKey,
    this.segChapterId,
  });

  final String id;
  final String userId;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final String content;
  final String contentHtml;
  final int likeCount;
  final DateTime createdAt;
  final bool edited;
  final bool hidden;
  final bool isMine;
  final bool likedByMe;
  final String? parentId;
  final String? replyToName;

  /// Parent id as string — '' when the comment has no parent (root).
  final String replyToId;
  final List<CommentItem> replies;

  /// True when this is a paragraph-level (segment) comment anchored to
  /// a chapter paragraph.
  final bool isSegment;
  final String? quoteText;
  final String? paraKey;
  final String? segChapterId;

  String get displayAuthor => displayName.isEmpty ? username : displayName;

  factory CommentItem.fromJson(Map<String, dynamic> json) => CommentItem(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    username: json['username'] as String? ?? '',
    displayName: json['display_name'] as String? ?? '',
    avatarUrl: json['avatar_url'] as String?,
    content: json['content'] as String? ?? '',
    contentHtml: json['content_html'] as String? ?? '',
    likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
    createdAt:
        DateTime.tryParse(json['created_at'] as String? ?? '') ??
        DateTime.now(),
    edited: json['edited'] as bool? ?? false,
    hidden: json['hidden'] as bool? ?? false,
    isMine: json['is_mine'] as bool? ?? false,
    likedByMe: json['liked_by_me'] as bool? ?? false,
    parentId: json['parent_id'] as String?,
    replyToName: json['reply_to_name'] as String?,
    replyToId: json['reply_to_id'] as String? ?? '',
    isSegment: json['is_segment'] as bool? ?? false,
    quoteText: json['quote_text'] as String?,
    paraKey: json['para_key'] as String?,
    segChapterId: json['seg_chapter_id'] as String?,
    replies: [
      for (final r in (json['replies'] as List? ?? const []))
        CommentItem.fromJson(r as Map<String, dynamic>),
    ],
  );
}

/// Paginated comment feed wrapper (mirrors the backend list response).
class PaginatedComments {
  const PaginatedComments({
    required this.comments,
    required this.total,
    required this.page,
    required this.perPage,
    required this.totalPages,
  });

  final List<CommentItem> comments;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;

  factory PaginatedComments.fromJson(Map<String, dynamic> json) =>
      PaginatedComments(
        comments: [
          for (final c in (json['comments'] as List? ?? const []))
            CommentItem.fromJson(c as Map<String, dynamic>),
        ],
        total: (json['total'] as num?)?.toInt() ?? 0,
        page: (json['page'] as num?)?.toInt() ?? 1,
        perPage: (json['per_page'] as num?)?.toInt() ?? 20,
        totalPages: (json['total_pages'] as num?)?.toInt() ?? 0,
      );
}

/// Result of posting a comment (regular or segment).
class CommentPostResult {
  const CommentPostResult({required this.id, this.wasHidden = false});
  final String id;

  /// True when the server auto-hidden the comment (spam / banned word).
  final bool wasHidden;
}