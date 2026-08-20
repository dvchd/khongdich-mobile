import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' show BaseAggregate, OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';

/// Offline library screen — kept as a separate route for direct access
/// from Home screen's library icon and Profile screen.
///
/// Uses the same `offlineLibraryStreamProvider` as the Downloads screen's
/// "Đã tải" tab — Drift's `watch()` stream ensures real-time updates.
///
/// This screen is a thin wrapper that re-exports the stream provider
/// from downloads_screen.dart to avoid circular imports.
class OfflineLibraryScreen extends ConsumerWidget {
  const OfflineLibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chaptersAsync = ref.watch(offlineLibraryStreamProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Truyện đã tải'),
        actions: [
          // Lối vào màn Tải xuống (hàng chờ + tiến trình) — trước đây
          // user không biết đi đâu để xem hàng chờ ngoài nút tải-all ở
          // story detail khi đang chạy.
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Xem hàng chờ tải xuống',
            onPressed: () => context.push('/downloads'),
          ),
        ],
      ),
      body: chaptersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Lỗi: $e')),
        data: (chapters) {
          if (chapters.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off, size: 64,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
                  const SizedBox(height: 12),
                  const Text('Chưa có truyện nào được tải.'),
                  const SizedBox(height: 4),
                  Text(
                    'Mở trang chi tiết truyện → nút ⬇ để tải chương.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          final byStory = <String, List<DownloadedChapter>>{};
          for (final ch in chapters) {
            byStory.putIfAbsent(ch.storyId, () => []).add(ch);
          }

          return ListView.builder(
            itemCount: byStory.length,
            itemBuilder: (_, i) {
              final storyId = byStory.keys.elementAt(i);
              final storyChapters = byStory[storyId]!;
              storyChapters.sort(
                  (a, b) => a.chapterNumber.compareTo(b.chapterNumber));
              final first = storyChapters.first;
              return ExpansionTile(
                leading: first.coverUrl != null && first.coverUrl!.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: CachedNetworkImage(
                          imageUrl: first.coverUrl!,
                          width: 40,
                          height: 56,
                          fit: BoxFit.cover,
                          // CachedNetworkImage render được cả khi
                          // OFFLINE (ảnh đã cache khi duyệt online) —
                          // Image.network cũ chỉ hiện icon book khi
                          // không có mạng.
                          errorWidget: (_, _, _) =>
                              const Icon(Icons.book, size: 40),
                        ),
                      )
                    : const Icon(Icons.book, size: 40),
                title: Text(
                  first.storyTitle.isEmpty ? first.storyId : first.storyTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${storyChapters.length} chương đã tải'),
                children: storyChapters.map((ch) {
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFFE11D48).withValues(alpha: 0.12),
                      child: Text('${ch.chapterNumber}',
                          style: const TextStyle(color: Color(0xFFE11D48))),
                    ),
                    title: Text(ch.chapterTitle.isEmpty
                        ? 'Chương ${ch.chapterNumber}'
                        : ch.chapterTitle),
                    subtitle: Text('${ch.wordCount} từ'),
                    trailing: ch.isRead == 1
                        ? const Icon(Icons.check_circle, color: Colors.green, size: 16)
                        : null,
                    onTap: () => context.push('/chapter-offline/${ch.chapterId}'),
                  );
                }).toList(),
              );
            },
          );
        },
      ),
    );
  }
}

/// Shared stream provider — watches downloaded_chapters via Drift's
/// `watch()`. Auto-updates when a new chapter finishes downloading.
///
/// **Filter**: chỉ hiện `manual_download` (user chủ động bấm download).
/// `auto_cache` (prefetch ngầm khi đọc online) bị ẩn — user không thấy
/// "đã download" chương họ chưa bao giờ bấm download.
final offlineLibraryStreamProvider =
    StreamProvider<List<DownloadedChapter>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.downloadedChapters)
        ..where((t) => t.source.equals('manual_download'))
        ..orderBy([(t) => OrderingTerm.desc(t.downloadedAt)]))
      .watch();
});

/// Set of story IDs that have at least one downloaded chapter.
///
/// Derived from [offlineLibraryStreamProvider] so it auto-updates
/// whenever a download finishes. Used by [StoryCard] to render the
/// green "downloaded" badge on covers across all screens
/// (home / search / bookshelf / story detail).
///
/// Trả về CÙNG instance khi membership không đổi — trước đây mỗi emit
/// của Drift stream tạo 1 Set mới → mọi StoryCard phụ thuộc rebuild dù
/// danh sách story đã tải không thay đổi (vd. progress bar đổi).
final downloadedStoryIdsProvider = Provider<Set<String>>((ref) {
  final chapters = ref.watch(offlineLibraryStreamProvider).valueOrNull ?? [];
  final ids = chapters.map((c) => c.storyId).toSet();
  final prev = _lastDownloadedStoryIds;
  _lastDownloadedStoryIds = ids;
  if (prev != null &&
      prev.length == ids.length &&
      prev.containsAll(ids)) {
    return prev;
  }
  return ids;
});

/// Cache cho [downloadedStoryIdsProvider] — xem comment provider.
Set<String>? _lastDownloadedStoryIds;

/// Number of chapters the user has manually downloaded (excludes
/// background auto-cache). Powers the "Đã lưu X chương" hero stat on
/// the home screen; live-updates via Drift `watch()`.
///
/// Dùng `COUNT(*)` ở tầng SQL (selectOnly) thay vì watch() cả bảng rồi
/// đếm — không materialize hàng nghìn rows mỗi khi 1 chương tải xong.
final downloadedChaptersCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final countCol = db.downloadedChapters.chapterId.count();
  final query = db.selectOnly(db.downloadedChapters)
    ..addColumns([countCol])
    ..where(db.downloadedChapters.source.equals('manual_download'));
  return query.watchSingle().map((row) => row.read(countCol) ?? 0);
});
