import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chapter_content.dart';
import '../../services/chapter_cache_service.dart';

/// Loads a single chapter by id and exposes the discriminated-union
/// content. Plan §5.4 — reader is polymorphic on `content_type`.
///
/// The route passes a [ChapterRef] (storyId + chapterNumber). The
/// provider turns that into a chapter id via the chapter list, then
/// fetches the content.
///
/// **Cache**: route qua [ChapterCacheService] — check memory cache trước
/// (instant return nếu hit), fallback API. Khi user next/prev, chương
/// kế tiếp thường đã được prefetch → không loading spinner.
final chapterProvider =
    FutureProvider.autoDispose.family<ChapterContent, ChapterRef>(
        (ref, ref_) async {
  final cache = ref.watch(chapterCacheServiceProvider);
  return cache.getChapter(
    storyId: ref_.storyId,
    chapterNumber: ref_.chapterNumber,
  );
});

/// Lấy chương kế cho ghost "cuộn hết chương → hiện chương sau" ở reader
/// cuộn dọc. Chương này thường đã được prefetch (xem ChapterCacheService
/// .prefetchNext) → resolve instant, không thêm spinner. Chặn chương VIP
/// (user không có quyền không được tải ngầm vào cache).
final nextChapterGhostProvider =
    FutureProvider.autoDispose.family<ChapterContent, ChapterRef>(
        (ref, ref_) async {
  final cache = ref.watch(chapterCacheServiceProvider);
  if (await cache.isChapterLocked(
    storyId: ref_.storyId,
    chapterNumber: ref_.chapterNumber,
  )) {
    throw StateError('Chương VIP — ghost không tải.');
  }
  return cache.getChapter(
    storyId: ref_.storyId,
    chapterNumber: ref_.chapterNumber,
  );
});

/// Reference used by [chapterProvider] / [nextChapterGhostProvider].
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
