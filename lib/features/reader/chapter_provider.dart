import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/observability/app_logger.dart';
import '../../models/chapter_content.dart';
import '../../repositories/story_repository.dart';

/// Loads a single chapter and exposes the discriminated-union content.
/// Plan §5.4 — reader is polymorphic on `content_type`.
///
/// Route shape: `chapterProvider((storySlug, chapterNumber))`.
/// The chapter id is also accepted for the local-DB primary key.
final chapterProvider = FutureProvider.autoDispose
    .family<ChapterContent, ChapterRef>((ref, ref_) async {
  final repo = ref.watch(storyRepositoryProvider);
  try {
    return await repo.fetchChapter(
      storySlug: ref_.storySlug,
      chapterNumber: ref_.chapterNumber,
      chapterId: ref_.chapterId,
    );
  } on DioException catch (e, s) {
    AppLogger.error('chapterProvider: fetch failed', e, s);
    rethrow;
  }
});

/// Reference passed to [chapterProvider].
class ChapterRef {
  const ChapterRef({
    required this.storySlug,
    required this.chapterNumber,
    this.chapterId,
  });
  final String storySlug;
  final int chapterNumber;
  final String? chapterId;

  @override
  bool operator ==(Object other) =>
      other is ChapterRef &&
      other.storySlug == storySlug &&
      other.chapterNumber == chapterNumber;

  @override
  int get hashCode => Object.hash(storySlug, chapterNumber);
}
