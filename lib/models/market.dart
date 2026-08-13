import 'package:flutter/foundation.dart';

import 'story.dart';

/// Chợ Phiên section payload — mirrors `GET /api/v1/mobile/market`.
///
/// Unlike the web `load_section` (which hides the section when closed),
/// the mobile endpoint always answers: `open: false` + empty rails lets
/// the app render a "đóng cửa" state without a second request.
@immutable
class MarketSection {
  const MarketSection({
    required this.open,
    required this.masterUsername,
    required this.masterDisplayName,
    required this.masterAvatar,
    required this.stories,
    required this.messages,
  });

  final bool open;
  final String? masterUsername;
  final String? masterDisplayName;
  final String? masterAvatar;
  final List<StorySummary> stories;
  final List<MarketMessage> messages;

  factory MarketSection.fromJson(Map<String, dynamic> json) => MarketSection(
    open: json['open'] as bool? ?? false,
    masterUsername: json['master_username'] as String?,
    masterDisplayName: json['master_display_name'] as String?,
    masterAvatar: json['master_avatar'] as String?,
    stories: [
      for (final s in (json['stories'] as List? ?? const []))
        StorySummary.fromStoryCardJson(s as Map<String, dynamic>),
    ],
    messages: [
      for (final m in (json['messages'] as List? ?? const []))
        MarketMessage.fromJson(m as Map<String, dynamic>),
    ],
  );

  /// `master_display_name` if set, else username, else null.
  String? get masterName => masterDisplayName ?? masterUsername;
}

/// A single Họp Chợ chat message — mirrors the backend's `ChatMessage`.
@immutable
class MarketMessage {
  const MarketMessage({
    required this.id,
    required this.userId,
    required this.content,
    required this.createdAt,
    required this.displayName,
    required this.username,
    this.avatarUrl,
    this.contentHtml,
    this.storyId,
    this.storyTitle,
    this.storySlug,
  });

  final String id;
  final String userId;
  final String content;
  final DateTime createdAt;
  final String displayName;
  final String username;
  final String? avatarUrl;

  /// Server-rendered HTML with `<img class="custom-emoji…">` tags —
  /// [EmojiText] parses it to reproduce the web's emoji rendering.
  final String? contentHtml;
  final String? storyId;
  final String? storyTitle;
  final String? storySlug;

  factory MarketMessage.fromJson(Map<String, dynamic> json) => MarketMessage(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    content: json['content'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['created_at'] as String? ?? '') ??
        DateTime.now(),
    displayName: json['display_name'] as String? ?? '',
    username: json['username'] as String? ?? '',
    avatarUrl: json['avatar_url'] as String?,
    contentHtml: json['content_html'] as String?,
    storyId: json['story_id'] as String?,
    storyTitle: json['story_title'] as String?,
    storySlug: json['story_slug'] as String?,
  );

  /// Relative time label, e.g. "2 phút trước" — same rules as the
  /// backend's `ChatMessage::rel_time()`.
  String relTime([DateTime? now]) {
    final diff = (now ?? DateTime.now()).difference(createdAt);
    if (diff.inMinutes < 1) return 'vừa xong';
    if (diff.inMinutes < 60) return '${diff.inMinutes} phút trước';
    if (diff.inHours < 24) return '${diff.inHours} giờ trước';
    if (diff.inDays < 7) return '${diff.inDays} ngày trước';
    final d = createdAt;
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year}';
  }
}
