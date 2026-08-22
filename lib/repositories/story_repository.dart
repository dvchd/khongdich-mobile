import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../models/chapter_content.dart';
import '../models/comment.dart';
import '../models/review.dart';
import '../models/story.dart';

/// Interface tối thiểu mà [DownloadManager] cần từ repository — tách
/// để test hàng đợi tải với fake (không phụ thuộc Dio/backend thật).
abstract class ChapterFetcher {
  Future<ChapterContent> fetchChapter(String chapterId);
  Future<ChapterAccess> fetchChapterAccess(String chapterId);
  Future<List<ChapterContent>> fetchChaptersBatch(List<String> chapterIds);

  /// Strict variant của fetchVipStatus — THROW khi fetch fail thay vì
  /// nuốt lỗi (DownloadManager cần biết "không xác định được" để
  /// fallback về check access per chapter — fail-closed).
  Future<VipStatus> fetchVipStatusStrict(String storyId);
}

/// Unified read/write client for the Không Dịch backend's mobile JSON
/// API (mounted at `/api/v1/mobile/*`).
///
/// Every call here goes through the Bearer-JWT-aware [ApiClient].
class StoryRepository implements ChapterFetcher {
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
    final categories = [
      for (final c in (data['categories'] as List? ?? const []))
        ((c as Map<String, dynamic>)['name'] as String?) ?? '',
    ].where((s) => s.isNotEmpty).toList();
    final categorySlugs = [
      for (final c in (data['categories'] as List? ?? const []))
        ((c as Map<String, dynamic>)['slug'] as String?) ?? '',
    ].where((s) => s.isNotEmpty).toList();
    final tags = [
      for (final t in (data['tags'] as List? ?? const []))
        ((t as Map<String, dynamic>)['name'] as String?) ?? '',
    ].where((s) => s.isNotEmpty).toList();
    final tagSlugs = [
      for (final t in (data['tags'] as List? ?? const []))
        ((t as Map<String, dynamic>)['slug'] as String?) ?? '',
    ].where((s) => s.isNotEmpty).toList();
    final story = StorySummary.fromStoryJson(storyJson).copyWith(
      author:
          (data['author_display_name'] as String?) ??
          (data['author_username'] as String?) ??
          'Không rõ',
      categories: categories,
      tags: tags,
      categorySlugs: categorySlugs,
      tagSlugs: tagSlugs,
      synopsis: storyJson['synopsis'] as String?,
    );
    return StoryDetailPayload(
      story: story,
      authorId: data['author_id'] as String? ?? '',
      authorUsername: data['author_username'] as String? ?? '',
      authorDisplayName: data['author_display_name'] as String? ?? '',
      authorAvatar: data['author_avatar'] as String?,
      isFollowing: data['is_following'] as bool? ?? false,
      lastReadChapter: (data['last_read_chapter'] as num?)?.toInt(),
      firstChapter: (data['first_chapter'] as num?)?.toInt(),
      bookmark: data['bookmark'] as String?,
      commentCount: (data['comment_count'] as num?)?.toInt() ?? 0,
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
      return await fetchVipStatusStrict(storyId);
    } on DioException catch (_) {
      // Best-effort — if the endpoint 404s (older backend), assume no VIP.
      return const VipStatus(
        isVip: false,
        lockedChapterIds: [],
        unlockedChapterIds: [],
        canDownloadOffline: true,
      );
    }
  }

  /// Strict variant — THROW khi fetch fail. DownloadManager dùng bản
  /// này: nếu không xác định được lockedChapterIds thì phải fallback
  /// về check access per chapter (fail-closed), không được skip check
  /// (dữ liệu VIP có thể bị lộ).
  @override
  Future<VipStatus> fetchVipStatusStrict(String storyId) async {
    final r = await _dio.get('/api/v1/mobile/stories/$storyId/vip-status');
    return VipStatus.fromJson(r.data as Map<String, dynamic>);
  }

  /// Check whether the current user can read a chapter. Used by the
  /// chapter reader to decide whether to render content or show a
  /// "VIP locked" page.
  ///
  /// Hits `GET /api/v1/mobile/chapters/{id}/access`.
  ///
  /// Fail-closed: on network error / 5xx, return `canRead: false` so the
  /// reader shows the VIP-locked screen instead of leaking content. Only
  /// 404 (legacy backend without the endpoint) defaults to access granted.
  @override
  Future<ChapterAccess> fetchChapterAccess(String chapterId) async {
    try {
      final r = await _dio.get('/api/v1/mobile/chapters/$chapterId/access');
      return ChapterAccess.fromJson(r.data as Map<String, dynamic>);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404) {
        // Legacy backend without VIP gate — assume access granted.
        return const ChapterAccess(canRead: true, isLocked: false);
      }
      // Network error / 5xx / timeout — fail CLOSED to avoid leaking
      // VIP content on transient failures. The reader will show the
      // VIP-locked screen; user can retry when network stabilizes.
      return const ChapterAccess(
        canRead: false,
        isLocked: true,
        reason: 'access_check_failed',
      );
    }
  }

  /// Chapter content (discriminated union by content_type).
  /// Hits `GET /api/v1/mobile/chapters/{id}`.
  @override
  Future<ChapterContent> fetchChapter(String chapterId) async {
    final r = await _dio.get('/api/v1/mobile/chapters/$chapterId');
    return ChapterContent.fromJson(r.data as Map<String, dynamic>);
  }

  /// Batch fetch multiple chapters (max 50).
  /// Hits `POST /api/v1/mobile/chapters/batch`.
  @override
  Future<List<ChapterContent>> fetchChaptersBatch(
    List<String> chapterIds,
  ) async {
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

  /// Fetch ALL chapters of a story, looping backend pages.
  ///
  /// The backend caps `per_page` at 200 (mobile.rs clamps 1..200), so a
  /// single `fetchChapterList(perPage: 200)` silently truncates stories
  /// with more than 200 chapters — the reader then fails to resolve
  /// chapters beyond the cap ("Chapter N not found"). This helper walks
  /// every page and merges them, keeping chapter order (chapter_number).
  Future<List<ChapterSummary>> fetchAllChapters(String storyId) async {
    const perPage = 200;
    final page = await fetchChapterList(storyId, perPage: perPage);
    if (page.chapters.length >= page.total || page.totalPages <= 1) {
      return page.chapters;
    }
    // Fetch các trang còn lại SONG SONG (giới hạn concurrency 6) — trước
    // đây await tuần tự từng trang: truyện 2000+ chương = 10+ round-trip
    // nối tiếp, mở story detail phải chờ cả chuỗi.
    const maxConcurrent = 6;
    final remaining = <List<ChapterSummary>>[];
    var nextPage = 2;
    Future<void> worker() async {
      while (true) {
        final p = nextPage++;
        if (p > page.totalPages) return;
        final res = await fetchChapterList(storyId, page: p, perPage: perPage);
        remaining.add(res.chapters);
      }
    }

    await Future.wait([
      for (var i = 0; i < maxConcurrent && i < page.totalPages - 1; i++)
        worker(),
    ]);
    final all = <ChapterSummary>[...page.chapters];
    for (final list in remaining) {
      all.addAll(list);
    }
    // Sort by chapter number — page boundaries can split a volume group,
    // and older stories may have been renumbered after caching.
    all.sort((a, b) => a.chapterNumber.compareTo(b.chapterNumber));
    return all;
  }

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

  /// Hồ sơ tác giả + danh sách truyện của họ (phân trang).
  /// Hits `GET /api/v1/mobile/users/{username}`.
  Future<AuthorProfile> fetchAuthorProfile(
    String username, {
    int page = 1,
    int perPage = 20,
  }) async {
    final r = await _dio.get(
      '/api/v1/mobile/users/$username',
      queryParameters: {'page': page, 'per_page': perPage},
    );
    return AuthorProfile.fromJson(r.data as Map<String, dynamic>);
  }

  // ─── Comments ────────────────────────────────────────────────────

  /// Merged comment feed (regular + segment comments) for one chapter.
  /// Hits `GET /api/v1/mobile/chapters/{id}/comments`.
  Future<PaginatedComments> fetchChapterComments(
    String chapterId, {
    int page = 1,
    int perPage = 20,
    String sort = 'newest',
  }) async {
    final r = await _dio.get(
      '/api/v1/mobile/chapters/$chapterId/comments',
      queryParameters: {'page': page, 'per_page': perPage, 'sort': sort},
    );
    return PaginatedComments.fromJson(r.data as Map<String, dynamic>);
  }

  /// Post a comment on a chapter (root or reply via [parentId]).
  /// Hits `POST /api/v1/mobile/chapters/{id}/comments`.
  Future<CommentPostResult> postChapterComment(
    String chapterId, {
    required String content,
    String? parentId,
  }) async {
    final r = await _dio.post(
      '/api/v1/mobile/chapters/$chapterId/comments',
      data: {'content': content, if (parentId != null) 'parent_id': parentId},
    );
    final data = r.data as Map<String, dynamic>;
    return CommentPostResult(
      id: data['id'] as String,
      wasHidden: data['was_hidden'] as bool? ?? false,
    );
  }

  /// Post a paragraph-level (segment) comment. `paraKey` may be empty —
  /// the backend then resolves the anchor from the exact paragraph text
  /// (mobile renderers can't compute the server's FNV-1a key).
  /// Hits `POST /api/v1/mobile/chapters/{id}/segment-comments`.
  Future<CommentPostResult> postSegmentComment({
    required String chapterId,
    String paraKey = '',
    required String quoteText,
    required String content,
    String? parentId,
  }) async {
    final r = await _dio.post(
      '/api/v1/mobile/chapters/$chapterId/segment-comments',
      data: {
        'chapter_id': chapterId,
        'para_key': paraKey,
        'quote_text': quoteText,
        'content': content,
        if (parentId != null) 'parent_id': parentId,
      },
    );
    final data = r.data as Map<String, dynamic>;
    return CommentPostResult(
      id: data['id'] as String,
      wasHidden: data['was_hidden'] as bool? ?? false,
    );
  }

  /// Story detail comments — merged feed (regular + segment) scoped to
  /// the whole story like the web story detail page.
  /// Hits `GET /api/v1/mobile/stories/{id}/comments`.
  Future<PaginatedComments> fetchStoryComments(
    String storyId, {
    int page = 1,
    int perPage = 20,
    String sort = 'newest',
  }) async {
    final r = await _dio.get(
      '/api/v1/mobile/stories/$storyId/comments',
      queryParameters: {'page': page, 'per_page': perPage, 'sort': sort},
    );
    return PaginatedComments.fromJson(r.data as Map<String, dynamic>);
  }

  /// Post a comment on a story (root or reply via [parentId]).
  /// Hits `POST /api/v1/mobile/stories/{id}/comments`.
  Future<CommentPostResult> postStoryComment(
    String storyId, {
    required String content,
    String? parentId,
  }) async {
    final r = await _dio.post(
      '/api/v1/mobile/stories/$storyId/comments',
      data: {'content': content, if (parentId != null) 'parent_id': parentId},
    );
    final data = r.data as Map<String, dynamic>;
    return CommentPostResult(
      id: data['id'] as String,
      wasHidden: data['was_hidden'] as bool? ?? false,
    );
  }

  /// Post a reader suggestion (góp ý sửa đoạn) for a paragraph. Like
  /// segment comments, `paraKey` may be empty — the backend resolves the
  /// anchor from the quote text.
  /// Hits `POST /api/v1/mobile/chapters/{id}/suggestions`.
  Future<void> postSuggestion({
    required String chapterId,
    String paraKey = '',
    required String quoteText,
    required String suggestedText,
  }) async {
    await _dio.post(
      '/api/v1/mobile/chapters/$chapterId/suggestions',
      data: {
        'chapter_id': chapterId,
        'para_key': paraKey,
        'quote_text': quoteText,
        'suggested_text': suggestedText,
      },
    );
  }

  /// Toggle a like on a regular comment.
  /// Hits `POST /api/v1/mobile/comments/{id}/like`.
  Future<(bool liked, int count)> toggleCommentLike(String commentId) async {
    final r = await _dio.post('/api/v1/mobile/comments/$commentId/like');
    final data = r.data as Map<String, dynamic>;
    return (
      data['liked'] as bool? ?? false,
      (data['count'] as num?)?.toInt() ?? 0,
    );
  }

  /// Toggle a like on a segment (paragraph) comment.
  /// Hits `POST /api/v1/mobile/segment-comments/{id}/like`.
  Future<(bool liked, int count)> toggleSegmentCommentLike(
    String commentId,
  ) async {
    final r = await _dio.post('/api/v1/mobile/segment-comments/$commentId/like');
    final data = r.data as Map<String, dynamic>;
    return (
      data['liked'] as bool? ?? false,
      (data['count'] as num?)?.toInt() ?? 0,
    );
  }

  /// Delete a comment — own comments or moderator.
  /// Hits `DELETE /api/v1/mobile/comments/{id}`.
  Future<void> deleteComment(String commentId) async {
    await _dio.delete('/api/v1/mobile/comments/$commentId');
  }

  /// Delete a segment (paragraph) comment.
  /// Hits `DELETE /api/v1/mobile/segment-comments/{id}`.
  Future<void> deleteSegmentComment(String commentId) async {
    await _dio.delete('/api/v1/mobile/segment-comments/$commentId');
  }

  /// Edit the caller's own comment (regular). The server re-runs the
  /// moderation filter; edited spam/flagged content gets auto-hidden.
  /// Hits `PUT /api/v1/mobile/comments/{id}`.
  Future<CommentEditResult> editComment(
    String commentId, {
    required String content,
  }) async {
    final r = await _dio.put(
      '/api/v1/mobile/comments/$commentId',
      data: {'content': content},
    );
    return CommentEditResult.fromJson(r.data as Map<String, dynamic>);
  }

  /// Edit the caller's own segment (paragraph) comment.
  /// Hits `PUT /api/v1/mobile/segment-comments/{id}`.
  Future<CommentEditResult> editSegmentComment(
    String commentId, {
    required String content,
  }) async {
    final r = await _dio.put(
      '/api/v1/mobile/segment-comments/$commentId',
      data: {'content': content},
    );
    return CommentEditResult.fromJson(r.data as Map<String, dynamic>);
  }

  /// Hide a comment (story author or moderator) — cascades to the whole
  /// reply subtree when hiding a root.
  /// Hits `POST /api/v1/mobile/comments/{id}/hide`.
  Future<void> hideComment(String commentId) async {
    await _dio.post('/api/v1/mobile/comments/$commentId/hide');
  }

  /// Restore a hidden comment.
  /// Hits `POST /api/v1/mobile/comments/{id}/unhide`.
  Future<void> unhideComment(String commentId) async {
    await _dio.post('/api/v1/mobile/comments/$commentId/unhide');
  }

  /// Hide a segment (paragraph) comment (story author or moderator).
  /// Hits `POST /api/v1/mobile/segment-comments/{id}/hide`.
  Future<void> hideSegmentComment(String commentId) async {
    await _dio.post('/api/v1/mobile/segment-comments/$commentId/hide');
  }

  /// Restore a hidden segment comment.
  /// Hits `POST /api/v1/mobile/segment-comments/{id}/unhide`.
  Future<void> unhideSegmentComment(String commentId) async {
    await _dio.post('/api/v1/mobile/segment-comments/$commentId/unhide');
  }

  /// Pin a root comment on the caller's own story (author or moderator).
  /// Hits `POST /api/v1/mobile/comments/{id}/pin`. The server enforces the
  /// max-3-pins rule and rejects replies/hidden comments with the error
  /// message in the response body.
  Future<void> pinComment(String commentId) async {
    await _dio.post('/api/v1/mobile/comments/$commentId/pin');
  }

  /// Remove a pin. Hits `POST /api/v1/mobile/comments/{id}/unpin`.
  Future<void> unpinComment(String commentId) async {
    await _dio.post('/api/v1/mobile/comments/$commentId/unpin');
  }

  // ─── Reviews (đánh giá truyện) ─────────────────────────────────

  /// Paginated review list + story aggregates + `my_rating` (the caller's
  /// own rating, null when they haven't reviewed this story yet).
  /// Hits `GET /api/v1/mobile/stories/{id}/reviews`.
  Future<ReviewsFeed> fetchStoryReviews(
    String storyId, {
    int page = 1,
  }) async {
    final r = await _dio.get(
      '/api/v1/mobile/stories/$storyId/reviews',
      queryParameters: {'page': page},
    );
    return ReviewsFeed.fromJson(r.data as Map<String, dynamic>);
  }

  /// Create or update the caller's review (upsert — one review per user
  /// per story). Returns the fresh aggregates to update the UI in place.
  /// Hits `POST /api/v1/mobile/stories/{id}/reviews`.
  Future<(double avgRating, int reviewCount)> upsertReview({
    required String storyId,
    required int rating,
    required String content,
  }) async {
    final r = await _dio.post(
      '/api/v1/mobile/stories/$storyId/reviews',
      data: {'rating': rating, 'content': content},
    );
    final data = r.data as Map<String, dynamic>;
    return (
      (data['avg_rating'] as num?)?.toDouble() ?? 0,
      (data['review_count'] as num?)?.toInt() ?? 0,
    );
  }

  // ─── Follow author + Report ────────────────────────────────────

  /// Toggle theo dõi một tác giả. Returns (following, followerCount).
  /// Hits `POST /api/v1/mobile/follows/{author_id}`.
  Future<(bool following, int followerCount)> toggleFollow(
    String authorId,
  ) async {
    final r = await _dio.post('/api/v1/mobile/follows/$authorId');
    final data = r.data as Map<String, dynamic>;
    return (
      data['following'] as bool? ?? false,
      (data['follower_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// Báo cáo vi phạm (story/chapter/comment/user).
  /// Hits `POST /api/v1/mobile/reports`.
  Future<void> submitReport({
    required String targetType,
    required String targetId,
    required String reason,
    String? description,
  }) async {
    await _dio.post(
      '/api/v1/mobile/reports',
      data: {
        'target_type': targetType,
        'target_id': targetId,
        'reason': reason,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
      },
    );
  }

  // ─── Discover: ranking / categories / tags ─────────────────────

  /// BXH truyện hot theo kỳ (period: day|week|month|all).
  /// Hits `GET /api/v1/mobile/ranking`.
  Future<PaginatedStories> fetchRanking({String period = 'all'}) async {
    final r = await _dio.get(
      '/api/v1/mobile/ranking',
      queryParameters: {'period': period},
    );
    final data = r.data as Map<String, dynamic>;
    return PaginatedStories(
      stories: [
        for (final s in (data['stories'] as List? ?? const []))
          StorySummary.fromStoryCardJson(s as Map<String, dynamic>),
      ],
      total: (data['stories'] as List?)?.length ?? 0,
      page: 1,
      perPage: (data['stories'] as List?)?.length ?? 0,
      totalPages: 1,
    );
  }

  /// BXH truyện VIP theo kỳ.
  /// Hits `GET /api/v1/mobile/ranking/vip`.
  Future<List<StorySummary>> fetchRankingVip({String period = 'all'}) async {
    final r = await _dio.get(
      '/api/v1/mobile/ranking/vip',
      queryParameters: {'period': period},
    );
    final data = r.data as Map<String, dynamic>;
    return [
      for (final s in (data['stories'] as List? ?? const []))
        StorySummary.fromStoryCardJson(s as Map<String, dynamic>),
    ];
  }

  /// Danh sách thể loại (cho màn browse thể loại).
  /// Hits `GET /api/v1/mobile/categories`.
  Future<List<CategoryInfo>> fetchCategories() async {
    final r = await _dio.get('/api/v1/mobile/categories');
    final data = r.data as Map<String, dynamic>;
    return [
      for (final c in (data['categories'] as List? ?? const []))
        CategoryInfo.fromJson(c as Map<String, dynamic>),
    ];
  }

  /// Danh sách tag kèm số truyện công khai.
  /// Hits `GET /api/v1/mobile/tags`.
  Future<List<TagInfo>> fetchTags() async {
    final r = await _dio.get('/api/v1/mobile/tags');
    final data = r.data as Map<String, dynamic>;
    return [
      for (final t in (data['tags'] as List? ?? const []))
        TagInfo.fromJson(t as Map<String, dynamic>),
    ];
  }

  /// Truyện theo thể loại (sort: newest|views|rating|chapters).
  /// Hits `GET /api/v1/mobile/stories/by-category/{slug}`.
  Future<PaginatedStories> fetchStoriesByCategory(
    String slug, {
    String sort = 'newest',
    int page = 1,
    int perPage = 20,
  }) async {
    final r = await _dio.get(
      '/api/v1/mobile/stories/by-category/$slug',
      queryParameters: {'sort': sort, 'page': page, 'per_page': perPage},
    );
    final data = r.data as Map<String, dynamic>;
    return PaginatedStories(
      stories: [
        for (final s in (data['stories'] as List? ?? const []))
          StorySummary.fromStoryCardJson(s as Map<String, dynamic>),
      ],
      total: (data['total'] as num?)?.toInt() ?? 0,
      page: (data['page'] as num?)?.toInt() ?? 1,
      perPage: (data['per_page'] as num?)?.toInt() ?? perPage,
      totalPages: (data['total_pages'] as num?)?.toInt() ?? 0,
    );
  }

  /// Truyện theo tag.
  /// Hits `GET /api/v1/mobile/stories/by-tag/{slug}`.
  Future<PaginatedStories> fetchStoriesByTag(
    String slug, {
    int page = 1,
    int perPage = 20,
  }) async {
    final r = await _dio.get(
      '/api/v1/mobile/stories/by-tag/$slug',
      queryParameters: {'page': page, 'per_page': perPage},
    );
    final data = r.data as Map<String, dynamic>;
    return PaginatedStories(
      stories: [
        for (final s in (data['stories'] as List? ?? const []))
          StorySummary.fromStoryCardJson(s as Map<String, dynamic>),
      ],
      total: (data['total'] as num?)?.toInt() ?? 0,
      page: (data['page'] as num?)?.toInt() ?? 1,
      perPage: (data['per_page'] as num?)?.toInt() ?? perPage,
      totalPages: (data['total_pages'] as num?)?.toInt() ?? 0,
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
      data: {'chapter': chapter, 'scroll_ratio': scrollRatio, 'anchor': anchor},
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
    // Mobile route (Bearer JWT, no CSRF) — the web copy under
    // /api/v1/notifications/* is CSRF-guarded and unreachable from a
    // cookie-less native client.
    await _dio.put('/api/v1/mobile/notifications/$id/read');
  }

  Future<void> markAllNotificationsRead() async {
    await _dio.put('/api/v1/mobile/notifications/read-all');
  }

  Future<void> deleteNotification(String id) async {
    await _dio.delete('/api/v1/mobile/notifications/$id');
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
      expiresAt:
          DateTime.tryParse(data['expires_at'] as String? ?? '') ??
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
  // FCM push đã bị bỏ — app dùng in-app notifications (GET /api/v1/mobile/
  // notifications) thay vì FCM. Khi cần push lại: re-add firebase_messaging,
  // registerPushToken() method, và backend push_devices table + FCM sender.
}

final storyRepositoryProvider = Provider<StoryRepository>((ref) {
  final api = ref
      .watch(apiClientProvider)
      .maybeWhen(
        data: (c) => c,
        orElse: () => throw StateError('ApiClient not ready'),
      );
  return StoryRepository(api);
});

/// Paginated chapter list for a story. Shared by story detail screen
/// and the chapter reader's chapter-list bottom sheet.
///
/// `fetchAllChapters` walks every backend page — the backend caps
/// `per_page` at 200, so single-page fetches truncate long stories.
final chapterListProvider = FutureProvider.autoDispose
    .family<List<ChapterSummary>, String>((ref, storyId) async {
      final repo = ref.watch(storyRepositoryProvider);
      return repo.fetchAllChapters(storyId);
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
    required this.authorId,
    required this.authorUsername,
    required this.authorDisplayName,
    required this.authorAvatar,
    this.isFollowing = false,
    this.lastReadChapter,
    required this.firstChapter,
    required this.bookmark,
    this.commentCount = 0,
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
}

class SearchResult {
  const SearchResult({required this.stories, required this.posts});
  final List<StorySummary> stories;
  final List<PostCard> posts;
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
