import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;

import '../core/network/api_client.dart';
import '../models/story.dart';

/// Read-only client for the Không Dịch SSR HTML pages.
///
/// The backend (as of 2026-06) exposes the story/chapter list and detail
/// surface only as server-rendered HTML — there is no JSON route for
/// `GET /api/v1/stories` or `GET /api/v1/stories/{id}/chapters` yet
/// (see `docs/plan-flutter-app.md` §12.2/§12.3, both MISSING).
///
/// Rather than block the mobile app on backend changes, we scrape the
/// SSR pages. The HTML is well-structured (server-rendered Askama
/// templates — see `templates/home.html`, `templates/story/detail.html`,
/// `templates/partials/story_card.html` in the backend repo) so the
/// selectors below are stable.
///
/// When the backend ships JSON endpoints, swap each method here for a
/// `dio.get('/api/v1/stories')` call — the return types are already
/// shaped to match the planned JSON.
class HtmlStoryDataSource {
  HtmlStoryDataSource(this._api);

  final ApiClient _api;
  Dio get _dio => _api.dio;

  /// Home page — banner, hot stories, fresh stories, editor picks.
  /// The same `/` endpoint serves both anonymous and authenticated
  /// users; the server customises the feed when `kd_auth` is set.
  Future<HomePage> fetchHome() async {
    final r = await _dio.get<String>(
      '/',
      options: Options(responseType: ResponseType.json, headers: {'Accept': 'text/html'}),
    );
    final doc = html_parser.parse(r.data ?? '');
    return HomePage(
      hot: _extractStoryCards(doc, '.hot-stories .story-card'),
      fresh: _extractStoryCards(doc, '.fresh-stories .story-card'),
      picks: _extractStoryCards(doc, '.editor-picks .story-card'),
      newChapters: _extractNewChapterEntries(doc),
      continueReading: _extractContinueReading(doc),
    );
  }

  /// Story detail — `/truyen/{slug}`.
  Future<StoryDetail> fetchStoryDetail(String slugOrId) async {
    final r = await _dio.get<String>(
      '/truyen/$slugOrId',
      options: Options(responseType: ResponseType.json, headers: {'Accept': 'text/html'}),
    );
    final doc = html_parser.parse(r.data ?? '');
    return _parseStoryDetail(doc, slugOrId);
  }

  /// Chapter list — rendered server-side at `/truyen/{slug}` (the same
  /// page as detail). The list is paginated via htmx; the initial HTML
  /// ships the first 50, and `/hx/chapter-list/{story_id}` returns the
  /// remaining pages as a fragment.
  Future<List<ChapterSummary>> fetchChapterList(String storyId) async {
    final r = await _dio.get<String>(
      '/hx/chapter-list/$storyId',
      options: Options(responseType: ResponseType.json, headers: {'Accept': 'text/html'}),
    );
    final doc = html_parser.parse(r.data ?? '');
    final rows = doc.querySelectorAll('.chapter-list .chapter-item');
    return rows.map(_parseChapterRow).toList(growable: false);
  }

  /// Discovery / explore page.
  Future<List<StorySummary>> fetchExplore({String? category, int page = 1}) async {
    final path = category == null ? '/kham-pha' : '/the-loai/$category';
    final r = await _dio.get<String>(
      path,
      queryParameters: {'page': page},
      options: Options(responseType: ResponseType.json, headers: {'Accept': 'text/html'}),
    );
    final doc = html_parser.parse(r.data ?? '');
    return _extractStoryCards(doc, '.story-card');
  }

  /// Rankings — `/bxh/{cat}?period=daily|weekly|all`.
  Future<List<StorySummary>> fetchRankings({
    String category = 'all',
    String period = 'daily',
  }) async {
    final r = await _dio.get<String>(
      '/bxh/$category',
      queryParameters: {'period': period},
      options: Options(responseType: ResponseType.json, headers: {'Accept': 'text/html'}),
    );
    final doc = html_parser.parse(r.data ?? '');
    return _extractStoryCards(doc, '.ranking-row, .story-card');
  }

  /// Continue-reading fragment — `/hx/continue-reading`. Requires auth.
  Future<List<ContinueReadingItem>> fetchContinueReading() async {
    try {
      final r = await _dio.get<String>(
        '/hx/continue-reading',
        options: Options(responseType: ResponseType.json, headers: {'Accept': 'text/html'}),
      );
      final doc = html_parser.parse(r.data ?? '');
      return _extractContinueReading(doc);
    } on DioException {
      return const [];
    }
  }

  // ---- HTML parsing helpers ----

  List<StorySummary> _extractStoryCards(html_dom.Document doc, String selector) {
    final nodes = doc.querySelectorAll(selector);
    return nodes.map(_parseStoryCard).whereType<StorySummary>().toList();
  }

  StorySummary? _parseStoryCard(html_dom.Element el) {
    final link = el.querySelector('a[href*="/truyen/"]')?.attributes['href'];
    if (link == null) return null;
    final slug = _slugFromUrl(link);
    if (slug == null) return null;
    final title = el.querySelector('.story-title, .title, h3, h4')?.text.trim() ??
        el.attributes['title'] ??
        slug;
    final author = el.querySelector('.author, .story-author')?.text.trim() ?? '';
    final cover = el.querySelector('img')?.attributes['src'];
    final contentType = el.attributes['data-content-type'] ??
        el.querySelector('[data-content-type]')?.attributes['data-content-type'] ??
        'text';
    return StorySummary(
      id: el.attributes['data-story-id'] ?? slug,
      title: title,
      slug: slug,
      coverUrl: cover == null ? null : _absoluteUrl(cover),
      author: author.isEmpty ? 'Không rõ' : author,
      categories: const [],
      tags: const [],
      contentTypes: [contentType],
    );
  }

  StoryDetail _parseStoryDetail(html_dom.Document doc, String slugOrId) {
    final storyEl = doc.querySelector('.story-detail, [data-story-id]');
    final storyId = storyEl?.attributes['data-story-id'] ?? slugOrId;
    final title = doc.querySelector('h1.story-title, h1')?.text.trim() ?? slugOrId;
    final author = doc.querySelector('.author-name, .story-author a')?.text.trim() ??
        'Không rõ';
    final cover = doc.querySelector('.story-cover img, .cover img')?.attributes['src'];
    final synopsis =
        doc.querySelector('.story-synopsis, .synopsis')?.text.trim();
    final categories = doc
        .querySelectorAll('.story-categories a, .categories a')
        .map((e) => e.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final tags = doc
        .querySelectorAll('.story-tags a, .tags a')
        .map((e) => e.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final status =
        doc.querySelector('.story-status, [data-status]')?.text.trim();
    final contentType =
        storyEl?.attributes['data-content-type'] ?? 'text';
    final chapters = doc
        .querySelectorAll('.chapter-list .chapter-item')
        .map(_parseChapterRow)
        .toList();
    return StoryDetail(
      story: StorySummary(
        id: storyId,
        title: title,
        slug: slugOrId,
        coverUrl: cover == null ? null : _absoluteUrl(cover),
        author: author,
        categories: categories,
        tags: tags,
        contentTypes: [contentType],
        synopsis: synopsis,
        status: status,
      ),
      chapters: chapters,
    );
  }

  ChapterSummary _parseChapterRow(html_dom.Element el) {
    final link = el.querySelector('a');
    final href = link?.attributes['href'] ?? '';
    final id = _chapterIdFromUrl(href) ?? el.attributes['data-chapter-id'] ?? href;
    final title = link?.text.trim() ??
        el.querySelector('.chapter-title')?.text.trim() ??
        'Chương';
    final numMatch = RegExp(r'chuong-(\d+)|chapter-(\d+)|(\d+)')
        .firstMatch(href);
    final chapterNumber = int.tryParse(
            numMatch?.group(1) ?? numMatch?.group(2) ?? numMatch?.group(3) ?? '0') ??
        0;
    return ChapterSummary(
      id: id,
      chapterNumber: chapterNumber,
      title: title,
      contentType: el.attributes['data-content-type'] ?? 'text',
      contentVersion: int.tryParse(el.attributes['data-content-version'] ?? '') ?? 1,
      isPublished: el.attributes['data-published'] != 'false',
      wordCount: int.tryParse(el.attributes['data-word-count'] ?? '') ?? 0,
      url: href.isEmpty ? null : _absoluteUrl(href),
    );
  }

  List<NewChapterEntry> _extractNewChapterEntries(html_dom.Document doc) {
    final nodes = doc.querySelectorAll('.new-chapters .new-chapter-item');
    return nodes.map((el) {
      final storyLink = el.querySelector('a[href*="/truyen/"]');
      final storySlug = _slugFromUrl(storyLink?.attributes['href'] ?? '');
      final chapterLink = el.querySelector('a[href*="/chuong/"]');
      return NewChapterEntry(
        storyId: storySlug ?? '',
        storyTitle: el.querySelector('.story-title')?.text.trim() ?? storySlug ?? '',
        storySlug: storySlug ?? '',
        chapterId: _chapterIdFromUrl(chapterLink?.attributes['href'] ?? '') ?? '',
        chapterNumber: int.tryParse(
                RegExp(r'chuong-(\d+)|/(\d+)$').firstMatch(chapterLink?.attributes['href'] ?? '')?.group(1) ??
                    '') ??
            0,
        chapterTitle: chapterLink?.text.trim() ?? '',
        coverUrl: null,
      );
    }).where((e) => e.storySlug.isNotEmpty).toList();
  }

  List<ContinueReadingItem> _extractContinueReading(html_dom.Document doc) {
    final nodes = doc.querySelectorAll('.continue-reading-item, .continue-item');
    return nodes.map((el) {
      final link = el.querySelector('a[href*="/truyen/"]');
      final slug = _slugFromUrl(link?.attributes['href'] ?? '');
      final title = el.querySelector('.story-title')?.text.trim() ?? slug ?? '';
      final cover = el.querySelector('img')?.attributes['src'];
      final label =
          el.querySelector('.chapter-label')?.text.trim() ?? 'Ch.1';
      return ContinueReadingItem(
        storyId: slug ?? '',
        storyTitle: title,
        storySlug: slug ?? '',
        coverUrl: cover == null ? null : _absoluteUrl(cover),
        contentType: el.attributes['data-content-type'] ?? 'text',
        lastChapter: int.tryParse(
                RegExp(r'(\d+)').firstMatch(label)?.group(1) ?? '') ??
            1,
        totalChapters: int.tryParse(
                el.attributes['data-total-chapters'] ?? '') ??
            1,
        chapterLabel: label,
      );
    }).where((e) => e.storySlug.isNotEmpty).toList();
  }

  String? _slugFromUrl(String url) {
    final m = RegExp(r'/truyen/([^/?#]+)').firstMatch(url);
    return m?.group(1);
  }

  String? _chapterIdFromUrl(String url) {
    final m = RegExp(r'/chuong/([^/?#]+)').firstMatch(url);
    return m?.group(1);
  }

  String _absoluteUrl(String maybeRelative) {
    if (maybeRelative.startsWith('http://') ||
        maybeRelative.startsWith('https://')) {
      return maybeRelative;
    }
    if (maybeRelative.startsWith('//')) {
      return 'https:$maybeRelative';
    }
    if (maybeRelative.startsWith('/')) {
      return '${_api.baseUrl}$maybeRelative';
    }
    return '${_api.baseUrl}/$maybeRelative';
  }
}

final htmlStoryDataSourceProvider = Provider<HtmlStoryDataSource>((ref) {
  final api = ref.watch(apiClientProvider).maybeWhen(
        data: (c) => c,
        orElse: () => throw StateError('ApiClient not ready'),
      );
  return HtmlStoryDataSource(api);
});

/// Aggregated home-page feed.
class HomePage {
  const HomePage({
    required this.hot,
    required this.fresh,
    required this.picks,
    required this.newChapters,
    required this.continueReading,
  });
  final List<StorySummary> hot;
  final List<StorySummary> fresh;
  final List<StorySummary> picks;
  final List<NewChapterEntry> newChapters;
  final List<ContinueReadingItem> continueReading;
}

class NewChapterEntry {
  const NewChapterEntry({
    required this.storyId,
    required this.storyTitle,
    required this.storySlug,
    required this.chapterId,
    required this.chapterNumber,
    required this.chapterTitle,
    required this.coverUrl,
  });
  final String storyId;
  final String storyTitle;
  final String storySlug;
  final String chapterId;
  final int chapterNumber;
  final String chapterTitle;
  final String? coverUrl;
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
  });
  final String storyId;
  final String storyTitle;
  final String storySlug;
  final String? coverUrl;
  final String contentType;
  final int lastChapter;
  final int totalChapters;
  final String chapterLabel;
}

/// Story detail payload — the story summary + the chapter list (initial
/// page rendered server-side).
class StoryDetail {
  const StoryDetail({required this.story, required this.chapters});
  final StorySummary story;
  final List<ChapterSummary> chapters;
}
