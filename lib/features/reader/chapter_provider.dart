import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
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

/// Chương kế bị VIP-khoá → ghost "cuộn hết chương đọc tiếp" không tải.
/// Throw bằng TYPE này (không phải StateError chứa chữ "VIP") để UI bắt
/// bằng `e is VipChapterLockedException` thay vì so khớp chuỗi lỗi.
class VipChapterLockedException implements Exception {
  const VipChapterLockedException(this.chapterNumber);

  final int chapterNumber;

  @override
  String toString() =>
      'Chương $chapterNumber là chương VIP — không tải ngầm.';
}

/// Chương đã tồn tại trong `downloaded_chapters` (manual_download hoặc
/// auto_cache)? Dùng bởi `_AccessGate` của reader online: access check
/// (API) fail vì mất mạng → chương ĐÃ TẢI được phép đọc (user đã có
/// quyền từ lúc tải — download manager + fetch thành công trước đó đều
/// đã qua VIP gate). Fail-closed vẫn giữ nguyên với chương chưa tải.
final chapterDownloadedProvider =
    StreamProvider.autoDispose.family<bool, String>((ref, chapterId) async* {
  final db = ref.watch(appDatabaseProvider);
  final query = db.select(db.downloadedChapters)
    ..where((t) => t.chapterId.equals(chapterId));
  await for (final rows in query.watch()) {
    yield rows.isNotEmpty;
  }
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
    throw VipChapterLockedException(ref_.chapterNumber);
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
