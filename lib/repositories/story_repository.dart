import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/api_client.dart';
import '../models/chapter_content.dart';
import '../models/story.dart';

/// Thin wrapper around the backend JSON API.
///
/// Per `docs/plan-flutter-app.md` §10.3. Endpoints marked **NEW** in the
/// plan are implemented here so the app is ready the moment the backend
/// ships them; until then callers fall back to gracefully empty results.
class StoryRepository {
  StoryRepository(this._api);

  final ApiClient _api;
  Dio get _dio => _api.dio;

  Future<List<StorySummary>> listStories({
    String sort = 'hot',
    int page = 1,
    int perPage = 20,
  }) async {
    final r = await _dio.get(
      '/api/v1/stories',
      queryParameters: {'sort': sort, 'page': page, 'per_page': perPage},
    );
    final data = r.data as Map<String, dynamic>;
    final items = (data['stories'] as List?) ?? const [];
    return items
        .map((e) => StorySummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<StorySummary> getStory(String id) async {
    final r = await _dio.get('/api/v1/stories/$id');
    return StorySummary.fromJson(r.data as Map<String, dynamic>);
  }

  Future<List<ChapterSummary>> listChapters(String storyId) async {
    final r = await _dio.get('/api/v1/stories/$storyId/chapters');
    final data = r.data as Map<String, dynamic>;
    final items = (data['chapters'] as List?) ?? const [];
    return items
        .map((e) => ChapterSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ChapterContent> getChapter(String chapterId) async {
    final r = await _dio.get('/api/v1/chapters/$chapterId');
    return ChapterContent.fromJson(r.data as Map<String, dynamic>);
  }

  Future<List<StorySummary>> search(String q) async {
    final r = await _dio.get(
      '/api/v1/search',
      queryParameters: {'q': q},
    );
    final data = r.data as Map<String, dynamic>;
    final items = (data['stories'] as List?) ?? const [];
    return items
        .map((e) => StorySummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

final storyRepositoryProvider = Provider<StoryRepository>((ref) {
  final api = ref.watch(apiClientProvider);
  return StoryRepository(api);
});
