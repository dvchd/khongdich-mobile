import '../models/story.dart' show ChapterSummary, StorySummary;

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
    required this.authorId,
    required this.authorUsername,
    required this.authorDisplayName,
    required this.authorAvatar,
    this.isFollowing = false,
    this.lastReadChapter,
    required this.firstChapter,
    required this.bookmark,
    this.commentCount = 0,
    this.danh,
  });
  final StorySummary story;
  final String authorId;
  final String authorUsername;
  final String authorDisplayName;
  final String? authorAvatar;

  /// True when the current user follows this story's author.
  final bool isFollowing;

  /// Chapter number of the current user's reading progress, if any
  /// (drives the "Tiếp tục đọc" button like the web story detail).
  final int? lastReadChapter;
  final int? firstChapter;
  final String? bookmark;

  /// Number of visible comments on the story (same visibility rules as
  /// the feed — moderators/authors see all, users see their own hidden).
  final int commentCount;

  /// Danh hiệu truyện (ảnh tĩnh/động do hệ thống tạo). Chỉ truyện tạo
  /// mới sau khi tính năng ra mắt mới có; null = truyện không có danh.
  final DanhInfo? danh;
}

/// Danh hiệu truyện — backend `models::danh::DanhInfo`
/// (id, name, image_url). Hiển thị dưới tên tác giả, trên badge thể loại.
class DanhInfo {
  const DanhInfo({required this.id, required this.name, required this.imageUrl});

  final int id;
  final String name;
  final String imageUrl;

  factory DanhInfo.fromJson(Map<String, dynamic> json) => DanhInfo(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        imageUrl: json['image_url'] as String? ?? '',
      );
}

/// Một danh hiệu + số truyện công khai (backend `/api/v1/mobile/danh`).
class DanhSummary {
  const DanhSummary({
    required this.id,
    required this.name,
    required this.imageUrl,
    this.storyCount = 0,
  });

  final int id;
  final String name;
  final String imageUrl;
  final int storyCount;

  factory DanhSummary.fromJson(Map<String, dynamic> json) => DanhSummary(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        imageUrl: json['image_url'] as String? ?? '',
        storyCount: (json['story_count'] as num?)?.toInt() ?? 0,
      );
}

/// Truyện mang danh hiệu (backend `/api/v1/mobile/danh/{id}`) — danh +
/// danh sách truyện phân trang.
class DanhStoriesPayload {
  const DanhStoriesPayload({
    required this.danh,
    required this.stories,
    this.total = 0,
    this.page = 1,
    this.perPage = 20,
    this.totalPages = 0,
  });

  final DanhInfo danh;
  final List<StorySummary> stories;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;
}

class SearchResult {
  const SearchResult({
    required this.stories,
    required this.posts,
    this.authors = const [],
    this.total = 0,
    this.page = 1,
    this.perPage = 20,
    this.totalPages = 0,
  });
  final List<StorySummary> stories;
  final List<PostCard> posts;

  /// Kênh tác giả khớp username/display_name (backend `authors`) — hiển
  /// thị trên đầu kết quả tìm kiếm, tap mở trang tác giả.
  final List<AuthorSearchItem> authors;

  /// Tổng truyện khớp + phân trang (backend trả khi có bộ lọc) — cho
  /// nút "Xem thêm" ở màn tìm kiếm.
  final int total;
  final int page;
  final int perPage;
  final int totalPages;
}

/// Kênh tác giả trong kết quả tìm kiếm (backend `/api/v1/search` →
/// mảng `authors`: id, username, display_name, bio, avatar_url,
/// follower_count, story_count).
class AuthorSearchItem {
  const AuthorSearchItem({
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.bio = '',
    this.followerCount = 0,
    this.storyCount = 0,
  });

  final String username;
  final String displayName;
  final String? avatarUrl;
  final String bio;
  final int followerCount;
  final int storyCount;

  /// Tên hiển thị — fallback về username khi display_name trống.
  String get name => displayName.isNotEmpty ? displayName : username;

  factory AuthorSearchItem.fromJson(Map<String, dynamic> json) =>
      AuthorSearchItem(
        username: json['username'] as String? ?? '',
        displayName: json['display_name'] as String? ?? '',
        avatarUrl: (json['avatar_url'] as String?)?.isNotEmpty == true
            ? json['avatar_url'] as String
            : null,
        bio: json['bio'] as String? ?? '',
        followerCount: (json['follower_count'] as num?)?.toInt() ?? 0,
        storyCount: (json['story_count'] as num?)?.toInt() ?? 0,
      );
}

/// Một thể loại truyện (backend models::category::Category).
class CategoryInfo {
  const CategoryInfo({
    required this.id,
    required this.name,
    required this.slug,
    this.description = '',
  });

  final int id;
  final String name;
  final String slug;
  final String description;

  factory CategoryInfo.fromJson(Map<String, dynamic> json) => CategoryInfo(
    id: (json['id'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '',
    slug: json['slug'] as String? ?? '',
    description: json['description'] as String? ?? '',
  );
}

/// Một tag + số truyện công khai gắn tag đó.
class TagInfo {
  const TagInfo({
    required this.name,
    required this.slug,
    this.storyCount = 0,
  });

  final String name;
  final String slug;
  final int storyCount;

  factory TagInfo.fromJson(Map<String, dynamic> json) => TagInfo(
    name: json['name'] as String? ?? '',
    slug: json['slug'] as String? ?? '',
    storyCount: (json['story_count'] as num?)?.toInt() ?? 0,
  );
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
    author:
        (json['author_display_name'] as String?) ??
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
        updatedAt:
            DateTime.tryParse(json['updated_at'] as String? ?? '') ??
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
    this.trustScore = 0,
  });
  final String id;
  final String username;
  final String displayName;
  final String email;
  final String role;
  final String? avatarUrl;
  final int readingStreak;
  final int unreadNotificationCount;

  /// Điểm uy tín (0-100) — backend `users.trust_score`. Tài khoản mới
  /// bắt đầu 50; đăng truyện chất lượng tăng, vi phạm quy định bị trừ.
  final int trustScore;

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
    trustScore: (json['trust_score'] as num?)?.toInt() ?? 0,
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
  const SyncBookmarkItem({required this.storyId, required this.listType});
  final String storyId;
  final String listType;
}

// ─── VIP DTOs ────────────────────────────────────────────────────────

/// Hồ sơ công khai của một tác giả (backend PublicAuthorProfile).
class AuthorInfo {
  const AuthorInfo({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.bio = '',
    this.followerCount = 0,
    this.isFollowing = false,
    this.trustScore = 0,
  });

  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final String bio;
  final int followerCount;

  /// Điểm uy tín 0-100 (`trust_score`) — công khai như web /u/{username}.
  /// Endpoint cũ không trả field này → mặc định 0 (badge sẽ bị ẩn).
  final int trustScore;

  /// True when the current user follows this author (màn hình tác giả).
  final bool isFollowing;

  /// Tên hiển thị — fallback về username khi display_name trống.
  String get name => displayName.isNotEmpty ? displayName : username;

  factory AuthorInfo.fromJson(Map<String, dynamic> json) => AuthorInfo(
        id: json['id'] as String,
        username: json['username'] as String,
        displayName: json['display_name'] as String? ?? '',
        avatarUrl: (json['avatar_url'] as String?)?.isNotEmpty == true
            ? json['avatar_url'] as String
            : null,
        bio: json['bio'] as String? ?? '',
        followerCount: (json['follower_count'] as num?)?.toInt() ?? 0,
        isFollowing: json['is_following'] as bool? ?? false,
        trustScore: (json['trust_score'] as num?)?.toInt() ?? 0,
      );
}

/// Trang hồ sơ tác giả: thông tin + danh sách truyện (phân trang).
class AuthorProfile {
  const AuthorProfile({
    required this.author,
    required this.stories,
    required this.totalStories,
    required this.page,
    required this.perPage,
    required this.totalPages,
  });

  final AuthorInfo author;
  final List<StorySummary> stories;
  final int totalStories;
  final int page;
  final int perPage;
  final int totalPages;

  factory AuthorProfile.fromJson(Map<String, dynamic> json) => AuthorProfile(
        author: AuthorInfo.fromJson(json['author'] as Map<String, dynamic>),
        stories: [
          for (final s in (json['stories'] as List? ?? const []))
            StorySummary.fromStoryCardJson(s as Map<String, dynamic>),
        ],
        totalStories: (json['total_stories'] as num?)?.toInt() ?? 0,
        page: (json['page'] as num?)?.toInt() ?? 1,
        perPage: (json['per_page'] as num?)?.toInt() ?? 20,
        totalPages: (json['total_pages'] as num?)?.toInt() ?? 0,
      );
}

/// VIP status of a story from the reader's perspective.
///
/// `is_vip` — story has been approved as VIP by an admin.
/// `locked_chapter_ids` — chapters the author has marked as VIP-only.
/// `unlocked_chapter_ids` — locked chapters the current user CAN read
///   (has been granted access). Used to show 🔓 instead of 🔒.
/// `can_download_offline` — reader has a story-wide VIP grant (only
///   story-wide grants can download offline; per-chapter grants are
///   online-only by policy).
class VipStatus {
  const VipStatus({
    required this.isVip,
    required this.lockedChapterIds,
    required this.unlockedChapterIds,
    required this.canDownloadOffline,
  });
  final bool isVip;
  final List<String> lockedChapterIds;
  final List<String> unlockedChapterIds;
  final bool canDownloadOffline;

  factory VipStatus.fromJson(Map<String, dynamic> json) => VipStatus(
    isVip: json['is_vip'] as bool? ?? false,
    lockedChapterIds: [
      for (final id in (json['locked_chapter_ids'] as List? ?? const []))
        id.toString(),
    ],
    unlockedChapterIds: [
      for (final id in (json['unlocked_chapter_ids'] as List? ?? const []))
        id.toString(),
    ],
    canDownloadOffline: json['can_download_offline'] as bool? ?? true,
  );

  /// Convenience: is the given chapter VIP-locked?
  bool isChapterLocked(String chapterId) =>
      lockedChapterIds.contains(chapterId);

  /// Convenience: is the given chapter VIP-locked AND the user has
  /// been granted access to read it?
  bool isChapterUnlocked(String chapterId) =>
      unlockedChapterIds.contains(chapterId);
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
