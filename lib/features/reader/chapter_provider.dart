import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chapter_content.dart';
import '../../repositories/story_repository.dart';

/// Loads a single chapter by id and exposes the discriminated-union
/// content. Plan §5.4 — reader is polymorphic on `content_type`.
///
/// The route passes a [ChapterRef] (storyId + chapterNumber). The
/// provider turns that into a chapter id via the chapter list, then
/// fetches the content.
final chapterProvider =
    FutureProvider.autoDispose.family<ChapterContent, ChapterRef>(
        (ref, ref_) async {
  final repo = ref.watch(storyRepositoryProvider);
  // Resolve the chapter id from (story_id, chapter_number) via the
  // chapter list endpoint. We request the page that contains this
  // chapter — small stories fit on page 1.
  final page = await repo.fetchChapterList(ref_.storyId, perPage: 200);
  final match = page.chapters
      .where((c) => c.chapterNumber == ref_.chapterNumber)
      .firstOrNull;
  if (match == null) {
    throw StateError(
        'Chapter ${ref_.chapterNumber} not found in story ${ref_.storyId}');
  }
  return repo.fetchChapter(match.id);
});

/// Reference passed to [chapterProvider].
class ChapterRef {
  const ChapterRef({
    required this.storyId,
    required this.chapterNumber,
  });
  final String storyId;
  final int chapterNumber;

  @override
  bool operator ==(Object other) =>
      other is ChapterRef &&
      other.storyId == storyId &&
      other.chapterNumber == chapterNumber;

  @override
  int get hashCode => Object.hash(storyId, chapterNumber);
}
