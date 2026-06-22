import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../models/chapter_content.dart';
import '../models/story.dart';

/// Unified read/write client for the Không Dịch backend's mobile JSON
/// API (mounted at `/api/v1/mobile/*`).
///
/// Every call here goes through the Bearer-JWT-aware [ApiClient].
class StoryRepository {
  StoryRepository(this._api);

  final ApiClient _api;
  Dio get _dio => _api.dio;

  // ─── Stories ────────────────────────────────────────────────────

  /// List stories with filter / sort / pagination.
  /// Hits `GET /api/v1/mobile/stories`.
  Future<PaginatedStories> listStories({
    String sort = 'fresh',
    String? category,
    String? contentType,
    String? status,
    int page = 1,
    int perPage = 20,
    String? seed,
  }) async {
    final r = await _dio.get(
      '/api/v1/mobile/stories',
      queryParameters: {
        'sort': sort,
        if (category != null) 'category': category,
        if (contentType != null) 'content_type': contentType,
        if (status != null) 'status': status,
        'page': page,
        'per_page': perPage,
        if (seed != null) 'seed': seed,
      },
    );
    final data = r.data as Map<String, dynamic>;
    return PaginatedStories(
      stories: [
        for (final s in (data['stories'] as List? ?? const []))
          StorySummary.fromStoryCardJson(s as Map<String, dynamic>),
      ],
      total: (data['total'] as num?)?.toInt() ?? 0,
      page: (data['page'] as num?)?.toInt() ?? page,
      perPage: (data['per_page'] as num?)?.toInt() ?? perPage,
      totalPages: (data['total_pages'] as num?)?.toInt() ?? 0,
    );
  }

  /// Story detail by id or slug.
  /// Hits `GET /api/v1/mobile/stories/{id_or_slug}`.
  Future<StoryDetailPayload> fetchStoryDetail(String idOrSlug) async {
    final r = await _dio.get('/api/v1/mobile/stories/$idOrSlug');
    final data = r.data as Map<String, dynamic>;
    final storyJson = data['story'] as Map<String, dynamic>;
    final story = StorySummary.fromStoryJson(storyJson).copyWith(
      author: (data['author_display_name'] as String?) ??
          (data['author_username'] as String?) ??
          'Không rõ',
      categories: [
        for (final c in (data['categories'] as List? ?? const []))
          ((c as Map<String, dynamic>)['name'] as String?) ?? '',
      ].where((s) => s.isNotEmpty).toList(),
      tags: [
        for (final t in (data['tags'] as List? ?? const []))
          ((t as Map<String, dynamic>)['name'] as String?) ?? '',
      ].where((s) => s.isNotEmpty).toList(),
      synopsis: storyJson['synopsis'] as String?,
    );
    return StoryDetailPayload(
      story: story,
      authorUsername: data['author_username'] as String? ?? '',
      authorDisplayName: data['author_display_name'] as String? ?? '',
      authorAvatar: data['author_avatar'] as String?,
      firstChapter: (data['first_chapter'] as num?)?.toInt(),
      bookmark: data['bookmark'] as String?,
    );
  }

  /// Paginated chapter list for a story.
  /// Hits `GET /api/v1/mobile/stories/{id}/chapters`.
  Future<PaginatedChapters> fetchChapterList(
    String storyId, {
    int page = 1,
    int perPage = 50,
    bool desc = false,
  }) async {
    final r = await _dio.get(
      '/api/v1/mobile/stories/$storyId/chapters',
      queryParameters: {
        'page': page,
        'per_page': perPage,
        if (desc) 'sort': 'desc',
      },
    );
    final data = r.data as Map<String, dynamic>;
    return PaginatedChapters(
      chapters: [
        for (final c in (data['chapters'] as List? ?? const []))
          ChapterSummary.fromJson(c as Map<String, dynamic>),
      ],
      total: (data['total'] as num?)?.toInt() ?? 0,
      page: (data['page'] as num?)?.toInt() ?? page,
      perPage: (data['per_page'] as num?)?.toInt() ?? perPage,
      totalPages: (data['total_pages'] as num?)?.toInt() ?? 0,
    );
  }

  /// VIP status for a story — is_vip flag + locked chapter IDs +
  /// whether the current user can download offline (only story-wide
  /// VIP grants allow offline download).
  ///
  /// Hits `GET /api/v1/mobile/stories/{id}/vip-status`.
  Future<VipStatus> fetchVipStatus(String storyId) async {
    try {
      final r = await _dio.get('/api/v1/mobile/stories/$storyId/vip-status');
      return VipStatus.fromJson(r.data as Map<String, dynamic>);
    } on DioException catch (_) {
      // Best-effort — if the endpoint 404s (older backend), assume no VIP.
      return const VipStatus(isVip: false, lockedChapterIds: [], canDownloadOffline: true);
    }
  }

  /// Check whether the current user can read a chapter. Used by the
  /// chapter reader to decide whether to render content or show a
  /// "VIP locked" page.
  ///
  /// Hits `GET /api/v1/mobile/chapters/{id}/access`.
  Future<ChapterAccess> fetchChapterAccess(String chapterId) async {
    try {
      final r = await _dio.get('/api/v1/mobile/chapters/$chapterId/access');
      return ChapterAccess.fromJson(r.data as Map<String, dynamic>);
    } on DioException catch (_) {
      // Best-effort — if the endpoint 404s, assume access granted
      // (older backend without VIP gate).
      return const ChapterAccess(canRead: true, isLocked: false);
    }
  }

  /// Chapter content (discriminated union by content_type).
  /// Hits `GET /api/v1/mobile/chapters/{id}`.
  Future<ChapterContent> fetchChapter(String chapterId) async {
    final r = await _dio.get('/api/v1/mobile/chapters/$chapterId');
    return ChapterContent.fromJson(r.data as Map<String, dynamic>);
  }

  /// Batch fetch multiple chapters (max 50).
  /// Hits `POST /api/v1/mobile/chapters/batch`.
  Future<List<ChapterContent>> fetchChaptersBatch(List<String> chapterIds) async {
    final r = await _dio.post(
      '/api/v1/mobile/chapters/batch',
      data: {'chapter_ids': chapterIds},
    );
    final data = r.data as Map<String, dynamic>;
    return [
      for (final c in (data['chapters'] as List? ?? const []))
        ChapterContent.fromJson(c as Map<String, dynamic>),
    ];
  }

  // ─── Search ─────────────────────────────────────────────────────

  /// Search stories + posts.
  /// Hits the existing `GET /api/v1/search?q=&limit=` endpoint (still
  /// works for unauthenticated clients; CSRF doesn't apply to GET).
  Future<SearchResult> search(String q, {int limit = 20}) async {
    final r = await _dio.get(
      '/api/v1/search',
      queryParameters: {'q': q, 'limit': limit},
    );
    final data = r.data as Map<String, dynamic>;
    return SearchResult(
      stories: [
        for (final s in (data['stories'] as List? ?? const []))
          StorySummary.fromStoryCardJson(s as Map<String, dynamic>),
      ],
      posts: [
        for (final p in (data['posts'] as List? ?? const []))
          PostCard.fromJson(p as Map<String, dynamic>),
      ],
    );
  }

  // ─── Bookmarks ──────────────────────────────────────────────────

  /// List bookmarks by `list_type` (or all if null).
  /// Hits `GET /api/v1/mobile/bookmarks`.
  Future<PaginatedBookmarks> listBookmarks({
    String? listType,
    int page = 1,
    int perPage = 20,
  }) async {
    final r = await _dio.get(
      '/api/v1/mobile/bookmarks',
      queryParameters: {
        if (listType != null) 'list_type': listType,
        'page': page,
        'per_page': perPage,
      },
    );
    final data = r.data as Map<String, dynamic>;
    return PaginatedBookmarks(
      bookmarks: [
        for (final b in (data['bookmarks'] as List? ?? const []))
          BookmarkItem.fromJson(b as Map<String, dynamic>),
      ],
      total: (data['total'] as num?)?.toInt() ?? 0,
      page: (data['page'] as num?)?.toInt() ?? page,
      perPage: (data['per_page'] as num?)?.toInt() ?? perPage,
      totalPages: (data['total_pages'] as num?)?.toInt() ?? 0,
    );
  }

  /// Toggle a bookmark on/off.
  /// Hits `POST /api/v1/mobile/bookmarks/{story_id}`.
  Future<BookmarkToggleResult> toggleBookmark(
    String storyId, {
    String listType = 'reading',
  }) async {
    final r = await _dio.post(
      '/api/v1/mobile/bookmarks/$storyId',
      data: {'list_type': listType},
    );
    final data = r.data as Map<String, dynamic>;
    return BookmarkToggleResult(
      bookmarked: data['bookmarked'] as bool? ?? false,
      listType: data['list_type'] as String? ?? listType,
      bookmarkCount: (data['bookmark_count'] as num?)?.toInt() ?? 0,
    );
  }

  // ─── Reading progress ───────────────────────────────────────────

  /// Continue-reading list (last 50 items).
  /// Hits `GET /api/v1/mobile/reading-progress`.
  Future<List<ContinueReadingItem>> fetchContinueReading() async {
    final r = await _dio.get('/api/v1/mobile/reading-progress');
    final data = r.data as Map<String, dynamic>;
    return [
      for (final item in (data['items'] as List? ?? const []))
        ContinueReadingItem.fromJson(item as Map<String, dynamic>),
    ];
  }

  /// Save reading progress for one story.
  /// Hits `PUT /api/v1/mobile/reading-progress/{story_id}`.
  Future<int> saveReadingProgress({
    required String storyId,
    required int chapter,
    double scrollRatio = 0,
    String anchor = '',
  }) async {
    final r = await _dio.put(
      '/api/v1/mobile/reading-progress/$storyId',
      data: {
        'chapter': chapter,
        'scroll_ratio': scrollRatio,
        'anchor': anchor,
      },
    );
    final data = r.data as Map<String, dynamic>;
    return (data['streak'] as num?)?.toInt() ?? 0;
  }

  // ─── Notifications ──────────────────────────────────────────────

  /// Paginated notifications list.
  /// Hits `GET /api/v1/mobile/notifications`.
  Future<PaginatedNotifications> listNotifications({
    int page = 1,
    int perPage = 20,
  }) async {
    final r = await _dio.get(
      '/api/v1/mobile/notifications',
      queryParameters: {'page': page, 'per_page': perPage},
    );
    final data = r.data as Map<String, dynamic>;
    return PaginatedNotifications(
      notifications: [
        for (final n in (data['notifications'] as List? ?? const []))
          NotificationItem.fromJson(n as Map<String, dynamic>),
      ],
      total: (data['total'] as num?)?.toInt() ?? 0,
      unread: (data['unread'] as num?)?.toInt() ?? 0,
      page: (data['page'] as num?)?.toInt() ?? page,
      perPage: (data['per_page'] as num?)?.toInt() ?? perPage,
      totalPages: (data['total_pages'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> markNotificationRead(String id) async {
    // Existing endpoint — works with Bearer JWT too since it goes
    // through the same AuthUser extractor.
    await _dio.put('/api/v1/notifications/$id/read');
  }

  Future<void> markAllNotificationsRead() async {
    await _dio.put('/api/v1/notifications/read-all');
  }

  Future<void> deleteNotification(String id) async {
    await _dio.delete('/api/v1/notifications/$id');
  }

  // ─── Auth ───────────────────────────────────────────────────────

  /// Exchange a Google id_token for a server-issued JWT.
  /// Hits `POST /api/v1/mobile/auth/token`.
  Future<AuthTokenResponse> exchangeGoogleIdToken(String idToken) async {
    final r = await _dio.post(
      '/api/v1/mobile/auth/token',
      data: {'id_token': idToken, 'platform': 'android'},
    );
    final data = r.data as Map<String, dynamic>;
    final token = data['token'] as String;
    await _api.writeJwt(token);
    return AuthTokenResponse(
      token: token,
      user: CurrentUser.fromJson(data['user'] as Map<String, dynamic>),
      expiresAt: DateTime.tryParse(data['expires_at'] as String? ?? '') ??
          DateTime.now().add(const Duration(hours: 24)),
    );
  }

  /// Fetch the current user (verifies the JWT is still valid).
  /// Hits `GET /api/v1/mobile/auth/me`.
  Future<CurrentUser> fetchMe() async {
    final r = await _dio.get('/api/v1/mobile/auth/me');
    final data = r.data as Map<String, dynamic>;
    return CurrentUser.fromJson(data['user'] as Map<String, dynamic>);
  }

  // ─── Sync ───────────────────────────────────────────────────────

  /// Batch sync — push local progress + bookmarks, pull server state.
  /// Hits `POST /api/v1/mobile/sync`.
  Future<SyncResponse> sync({
    List<SyncProgressItem> progress = const [],
    List<SyncBookmarkItem> bookmarks = const [],
  }) async {
    final r = await _dio.post(
      '/api/v1/mobile/sync',
      data: {
        'reading_progress': [
          for (final p in progress)
            {
              'story_id': p.storyId,
              'chapter': p.chapter,
              if (p.scrollRatio != null) 'scroll_ratio': p.scrollRatio,
              if (p.anchor != null) 'anchor': p.anchor,
            },
        ],
        'bookmarks': [
          for (final b in bookmarks)
            {'story_id': b.storyId, 'list_type': b.listType},
        ],
      },
    );
    final data = r.data as Map<String, dynamic>;
    return SyncResponse(
      readingProgress: [
        for (final item in (data['reading_progress'] as List? ?? const []))
          ContinueReadingItem.fromJson(item as Map<String, dynamic>),
      ],
      bookmarks: [
        for (final b in (data['bookmarks'] as List? ?? const []))
          BookmarkItem.fromJson(b as Map<String, dynamic>),
      ],
      unreadCount: (data['unread_count'] as num?)?.toInt() ?? 0,
    );
  }

  // ─── Push ───────────────────────────────────────────────────────

  /// Register an FCM token with the server (currently a no-op on the
  /// backend — the token is logged but not persisted until the
  /// `push_devices` migration + FCM crate ship).
  /// Hits `POST /api/v1/mobile/push/register`.
  Future<void> registerPushToken(String token, {String platform = 'android'}) async {
    await _dio.post(
      '/api/v1/mobile/push/register',
      data: {'token': token, 'platform': platform},
    );
  }
}

final storyRepositoryProvider = Provider<StoryRepository>((ref) {
  final api = ref.watch(apiClientProvider).maybeWhen(
        data: (c) => c,
        orElse: () => throw StateError('ApiClient not ready'),
      );
  return StoryRepository(api);
});

/// Paginated chapter list for a story. Shared by story detail screen
/// and the chapter reader's chapter-list bottom sheet.
final chapterListProvider = FutureProvider.autoDispose
    .family<PaginatedChapters, String>((ref, storyId) async {
  final repo = ref.watch(storyRepositoryProvider);
  return repo.fetchChapterList(storyId, perPage: 200);
});

// ─── DTOs ──────────────────────────────────────────────────────────

class PaginatedStories {
  const PaginatedStories({
    required this.stories,
    required this.total,
    required this.page,
    required this.perPage,
    required this.totalPages,
  });
  final List<StorySummary> stories;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;
}

class PaginatedChapters {
  const PaginatedChapters({
    required this.chapters,
    required this.total,
    required this.page,
    required this.perPage,
    required this.totalPages,
  });
  final List<ChapterSummary> chapters;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;
}

class StoryDetailPayload {
  const StoryDetailPayload({
    required this.story,
    required this.authorUsername,
    required this.authorDisplayName,
    required this.authorAvatar,
    required this.firstChapter,
    required this.bookmark,
  });
  final StorySummary story;
  final String authorUsername;
  final String authorDisplayName;
  final String? authorAvatar;
  final int? firstChapter;
  final String? bookmark;
}

class SearchResult {
  const SearchResult({required this.stories, required this.posts});
  final List<StorySummary> stories;
  final List<PostCard> posts;
}

class PostCard {
  const PostCard({
    required this.id,
    required this.title,
    required this.slug,
    required this.postType,
    this.coverUrl,
    this.excerpt,
    this.publishedAt,
  });
  final String id;
  final String title;
  final String slug;
  final String postType;
  final String? coverUrl;
  final String? excerpt;
  final DateTime? publishedAt;

  factory PostCard.fromJson(Map<String, dynamic> json) => PostCard(
        id: json['id'] as String,
        title: json['title'] as String,
        slug: json['slug'] as String,
        postType: json['post_type'] as String? ?? 'article',
        coverUrl: json['cover_url'] as String?,
        excerpt: json['excerpt'] as String?,
        publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
      );
}

class PaginatedBookmarks {
  const PaginatedBookmarks({
    required this.bookmarks,
    required this.total,
    required this.page,
    required this.perPage,
    required this.totalPages,
  });
  final List<BookmarkItem> bookmarks;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;
}

class BookmarkItem {
  const BookmarkItem({
    required this.storyId,
    required this.title,
    required this.slug,
    required this.coverUrl,
    required this.author,
    required this.listType,
    required this.contentType,
    required this.chapterCount,
    required this.bookmarkedAt,
  });
  final String storyId;
  final String title;
  final String slug;
  final String? coverUrl;
  final String author;
  final String listType;
  final String contentType;
  final int? chapterCount;
  final DateTime bookmarkedAt;

  factory BookmarkItem.fromJson(Map<String, dynamic> json) => BookmarkItem(
        storyId: json['id'] as String,
        title: json['title'] as String,
        slug: json['slug'] as String,
        coverUrl: json['cover_url'] as String?,
        author: (json['author_display_name'] as String?) ??
            (json['author_username'] as String?) ??
            'Không rõ',
        listType: json['bookmark_list_type'] as String? ?? 'reading',
        contentType: json['content_type'] as String? ?? 'text',
        chapterCount: (json['chapter_count'] as num?)?.toInt(),
        bookmarkedAt:
            DateTime.tryParse(json['bookmark_created_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

class BookmarkToggleResult {
  const BookmarkToggleResult({
    required this.bookmarked,
    required this.listType,
    required this.bookmarkCount,
  });
  final bool bookmarked;
  final String listType;
  final int bookmarkCount;
}

class ContinueReadingItem {
  const ContinueReadingItem({
    required this.storyId,
    required this.storyTitle,
    required this.storySlug,
    required this.coverUrl,
    required this.contentType,
    required this.lastChapter,
    required this.totalChapters,
    required this.chapterLabel,
    required this.updatedAt,
  });
  final String storyId;
  final String storyTitle;
  final String storySlug;
  final String? coverUrl;
  final String contentType;
  final int lastChapter;
  final int totalChapters;
  final String chapterLabel;
  final DateTime updatedAt;

  factory ContinueReadingItem.fromJson(Map<String, dynamic> json) =>
      ContinueReadingItem(
        storyId: json['story_id'] as String,
        storyTitle: json['story_title'] as String,
        storySlug: json['story_slug'] as String,
        coverUrl: json['cover_url'] as String?,
        contentType: json['content_type'] as String? ?? 'text',
        lastChapter: (json['last_chapter'] as num?)?.toInt() ?? 1,
        totalChapters: (json['total_chapters'] as num?)?.toInt() ?? 1,
        chapterLabel: json['chapter_label'] as String? ?? '',
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

class PaginatedNotifications {
  const PaginatedNotifications({
    required this.notifications,
    required this.total,
    required this.unread,
    required this.page,
    required this.perPage,
    required this.totalPages,
  });
  final List<NotificationItem> notifications;
  final int total;
  final int unread;
  final int page;
  final int perPage;
  final int totalPages;
}

class NotificationItem {
  const NotificationItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.link,
    this.isRead = false,
    this.createdAt,
  });
  final String id;
  final String type;
  final String title;
  final String body;
  final String? link;
  final bool isRead;
  final DateTime? createdAt;

  factory NotificationItem.fromJson(Map<String, dynamic> json) =>
      NotificationItem(
        id: json['id'] as String,
        type: json['notification_type'] as String? ?? '',
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        link: json['link'] as String?,
        isRead: json['is_read'] as bool? ?? false,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      );
}

class AuthTokenResponse {
  const AuthTokenResponse({
    required this.token,
    required this.user,
    required this.expiresAt,
  });
  final String token;
  final CurrentUser user;
  final DateTime expiresAt;
}

class CurrentUser {
  const CurrentUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.email,
    required this.role,
    this.avatarUrl,
    this.readingStreak = 0,
    this.unreadNotificationCount = 0,
  });
  final String id;
  final String username;
  final String displayName;
  final String email;
  final String role;
  final String? avatarUrl;
  final int readingStreak;
  final int unreadNotificationCount;

  factory CurrentUser.fromJson(Map<String, dynamic> json) => CurrentUser(
        id: json['id'] as String,
        username: json['username'] as String? ?? '',
        displayName: json['display_name'] as String? ?? '',
        email: json['email'] as String? ?? '',
        role: json['role'] as String? ?? 'reader',
        avatarUrl: json['avatar_url'] as String?,
        readingStreak: (json['reading_streak'] as num?)?.toInt() ?? 0,
        unreadNotificationCount:
            (json['unread_notification_count'] as num?)?.toInt() ?? 0,
      );
}

class SyncResponse {
  const SyncResponse({
    required this.readingProgress,
    required this.bookmarks,
    required this.unreadCount,
  });
  final List<ContinueReadingItem> readingProgress;
  final List<BookmarkItem> bookmarks;
  final int unreadCount;
}

class SyncProgressItem {
  const SyncProgressItem({
    required this.storyId,
    required this.chapter,
    this.scrollRatio,
    this.anchor,
  });
  final String storyId;
  final int chapter;
  final double? scrollRatio;
  final String? anchor;
}

class SyncBookmarkItem {
  const SyncBookmarkItem({
    required this.storyId,
    required this.listType,
  });
  final String storyId;
  final String listType;
}

// ─── VIP DTOs ────────────────────────────────────────────────────────

/// VIP status of a story from the reader's perspective.
///
/// `is_vip` — story has been approved as VIP by an admin.
/// `locked_chapter_ids` — chapters the author has marked as VIP-only.
/// `can_download_offline` — reader has a story-wide VIP grant (only
///   story-wide grants can download offline; per-chapter grants are
///   online-only by policy).
class VipStatus {
  const VipStatus({
    required this.isVip,
    required this.lockedChapterIds,
    required this.canDownloadOffline,
  });
  final bool isVip;
  final List<String> lockedChapterIds;
  final bool canDownloadOffline;

  factory VipStatus.fromJson(Map<String, dynamic> json) => VipStatus(
        isVip: json['is_vip'] as bool? ?? false,
        lockedChapterIds: [
          for (final id in (json['locked_chapter_ids'] as List? ?? const []))
            id.toString(),
        ],
        canDownloadOffline: json['can_download_offline'] as bool? ?? true,
      );

  /// Convenience: is the given chapter VIP-locked?
  bool isChapterLocked(String chapterId) =>
      lockedChapterIds.contains(chapterId);
}

/// Result of a chapter access check.
class ChapterAccess {
  const ChapterAccess({
    required this.canRead,
    required this.isLocked,
    this.reason,
  });
  final bool canRead;
  final bool isLocked;
  /// 'granted' | 'vip_locked' | 'not_found' | null
  final String? reason;

  factory ChapterAccess.fromJson(Map<String, dynamic> json) => ChapterAccess(
        canRead: json['can_read'] as bool? ?? true,
        isLocked: json['is_locked'] as bool? ?? false,
        reason: json['reason'] as String?,
      );
}
