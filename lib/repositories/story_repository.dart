import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as html_parser;

import '../core/network/api_client.dart';
import '../models/chapter_content.dart';
import '../models/story.dart';
import 'chapter_reader_data_source.dart';
import 'html_story_data_source.dart';

// Re-export DTOs that callers consume via this repository.
export 'html_story_data_source.dart'
    show
        HomePage,
        StoryDetail,
        ContinueReadingItem,
        NewChapterEntry;

/// Unified read/write client for the Không Dịch backend.
class StoryRepository {
  StoryRepository(this._api, this._html, this._chapterReader);

  final ApiClient _api;
  final HtmlStoryDataSource _html;
  final ChapterReaderDataSource _chapterReader;
  Dio get _dio => _api.dio;

  // ---- Reads via HTML scraping ----

  Future<HomePage> fetchHome() => _html.fetchHome();

  Future<StoryDetail> fetchStoryDetail(String slugOrId) =>
      _html.fetchStoryDetail(slugOrId);

  Future<List<ChapterSummary>> fetchChapterList(String storyId) =>
      _html.fetchChapterList(storyId);

  Future<List<StorySummary>> fetchExplore({
    String? category,
    int page = 1,
  }) =>
      _html.fetchExplore(category: category, page: page);

  Future<List<StorySummary>> fetchRankings({
    String category = 'all',
    String period = 'daily',
  }) =>
      _html.fetchRankings(category: category, period: period);

  Future<List<ContinueReadingItem>> fetchContinueReading() =>
      _html.fetchContinueReading();

  Future<ChapterContent> fetchChapter({
    required String storySlug,
    required int chapterNumber,
    String? chapterId,
  }) =>
      _chapterReader.fetchChapter(
        storySlug: storySlug,
        chapterNumber: chapterNumber,
        chapterId: chapterId,
      );

  // ---- Reads via existing JSON endpoints ----

  Future<SearchResult> search(String q, {int limit = 20}) async {
    final r = await _dio.get(
      '/api/v1/search',
      queryParameters: {'q': q, 'limit': limit},
    );
    final data = r.data as Map<String, dynamic>;
    return SearchResult(
      stories: [
        for (final e in (data['stories'] as List? ?? const []))
          _storyCardFromJson(e as Map<String, dynamic>),
      ],
      posts: [
        for (final e in (data['posts'] as List? ?? const []))
          PostCard.fromJson(e as Map<String, dynamic>),
      ],
    );
  }

  StorySummary _storyCardFromJson(Map<String, dynamic> json) {
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
      status: json['status'] as String?,
    );
  }

  // ---- Writes via existing JSON endpoints ----

  Future<BookmarkToggleResult> toggleBookmark(
    String storyId, {
    String listType = 'reading',
  }) async {
    await _api.ensureCsrfCookie();
    final r = await _dio.post(
      '/api/v1/bookmarks/$storyId',
      data: 'list_type=$listType',
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'Origin': _api.baseUrl},
      ),
    );
    final data = r.data as Map<String, dynamic>;
    return BookmarkToggleResult(
      bookmarked: data['bookmarked'] as bool? ?? false,
      listType: data['list_type'] as String? ?? listType,
      bookmarkCount: (data['bookmark_count'] as num?)?.toInt() ?? 0,
    );
  }

  Future<int> saveReadingProgress({
    required String storyId,
    required int chapter,
    double scrollRatio = 0,
    String anchor = '',
  }) async {
    await _api.ensureCsrfCookie();
    final r = await _dio.put(
      '/api/v1/reading-progress/$storyId',
      data: {
        'chapter': chapter,
        'scroll_ratio': scrollRatio,
        'anchor': anchor,
      },
      options: Options(headers: {'Origin': _api.baseUrl}),
    );
    final data = r.data as Map<String, dynamic>;
    return (data['streak'] as num?)?.toInt() ?? 0;
  }

  Future<NotificationListPage> listNotifications() async {
    final r = await _dio.get<String>(
      '/hx/notifications',
      options: Options(
        responseType: ResponseType.json,
        headers: {'Accept': 'text/html'},
      ),
    );
    return NotificationScraper.parse(r.data ?? '');
  }

  Future<void> markNotificationRead(String id) async {
    await _api.ensureCsrfCookie();
    await _dio.put(
      '/api/v1/notifications/$id/read',
      options: Options(headers: {'Origin': _api.baseUrl}),
    );
  }

  Future<void> markAllNotificationsRead() async {
    await _api.ensureCsrfCookie();
    await _dio.put(
      '/api/v1/notifications/read-all',
      options: Options(headers: {'Origin': _api.baseUrl}),
    );
  }

  Future<void> deleteNotification(String id) async {
    await _api.ensureCsrfCookie();
    await _dio.delete(
      '/api/v1/notifications/$id',
      options: Options(headers: {'Origin': _api.baseUrl}),
    );
  }
}

final storyRepositoryProvider = Provider<StoryRepository>((ref) {
  final api = ref.watch(apiClientProvider).maybeWhen(
        data: (c) => c,
        orElse: () => throw StateError('ApiClient not ready'),
      );
  return StoryRepository(
    api,
    HtmlStoryDataSource(api),
    ChapterReaderDataSource(api),
  );
});

// ---- Result DTOs ----

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

  factory PostCard.fromJson(Map<String, dynamic> json) {
    return PostCard(
      id: json['id'] as String,
      title: json['title'] as String,
      slug: json['slug'] as String,
      postType: json['post_type'] as String? ?? 'article',
      coverUrl: json['cover_url'] as String?,
      excerpt: json['excerpt'] as String?,
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
    );
  }
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

class NotificationListPage {
  const NotificationListPage({
    required this.items,
    required this.unreadCount,
  });
  final List<NotificationItem> items;
  final int unreadCount;
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
}

/// Parses the `/hx/notifications` HTML fragment into [NotificationListPage].
class NotificationScraper {
  NotificationScraper._();

  static NotificationListPage parse(String html) {
    final doc = html_parser.parse(html);
    final items = <NotificationItem>[];
    for (final el
        in doc.querySelectorAll('.notification-item, [data-notification-id]')) {
      final id = el.attributes['data-notification-id'] ?? '';
      final type = el.attributes['data-type'] ?? '';
      final title =
          el.querySelector('.title, .notification-title')?.text.trim() ?? '';
      final body =
          el.querySelector('.body, .notification-body')?.text.trim() ?? '';
      final link = el.querySelector('a')?.attributes['href'];
      final isRead = el.classes.contains('read') ||
          el.attributes['data-read'] == 'true';
      final createdAt =
          DateTime.tryParse(el.attributes['data-created-at'] ?? '');
      items.add(NotificationItem(
        id: id,
        type: type,
        title: title,
        body: body,
        link: link,
        isRead: isRead,
        createdAt: createdAt,
      ));
    }
    final unreadText =
        doc.querySelector('.unread-count, [data-unread-count]')?.text ?? '0';
    final unread = int.tryParse(
            RegExp(r'(\d+)').firstMatch(unreadText)?.group(1) ?? '0') ??
        0;
    return NotificationListPage(items: items, unreadCount: unread);
  }
}
