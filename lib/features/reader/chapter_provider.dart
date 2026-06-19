import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/observability/app_logger.dart';
import '../../models/chapter_content.dart';
import '../../repositories/story_repository.dart';

/// Loads a single chapter and exposes the discriminated-union content.
/// Plan §5.4 — reader is polymorphic on `content_type`.
final chapterProvider =
    FutureProvider.autoDispose.family<ChapterContent, String>((ref, id) async {
  final repo = ref.watch(storyRepositoryProvider);
  try {
    return await repo.getChapter(id);
  } on DioException catch (e, s) {
    AppLogger.error('chapterProvider: fetch failed', e, s);
    rethrow;
  }
});
