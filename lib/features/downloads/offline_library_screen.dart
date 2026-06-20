import 'package:drift/drift.dart' show OrderingTerm;
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
      appBar: AppBar(title: const Text('Truyện đã tải')),
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
                        child: Image.network(
                          first.coverUrl!,
                          width: 40,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
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
final offlineLibraryStreamProvider =
    StreamProvider<List<DownloadedChapter>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.downloadedChapters)
        ..orderBy([(t) => OrderingTerm.desc(t.downloadedAt)]))
      .watch();
});
