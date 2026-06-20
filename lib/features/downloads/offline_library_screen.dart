import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';

/// Offline library — lists all downloaded chapters grouped by story.
/// When the user has no network, they can browse and read these
/// chapters entirely offline.
class OfflineLibraryScreen extends ConsumerStatefulWidget {
  const OfflineLibraryScreen({super.key});

  @override
  ConsumerState<OfflineLibraryScreen> createState() =>
      _OfflineLibraryScreenState();
}

final offlineChaptersProvider =
    FutureProvider<List<DownloadedChapter>>((ref) async {
  final db = ref.read(appDatabaseProvider);
  final result = await (db.select(db.downloadedChapters)
        ..orderBy([(t) => OrderingTerm.desc(t.downloadedAt)]))
      .get();
  return result;
});

final downloadedChaptersForStoryProvider =
    FutureProvider.family<List<DownloadedChapter>, String>((ref, storyId) async {
  final db = ref.read(appDatabaseProvider);
  final result = await (db.select(db.downloadedChapters)
        ..where((t) => t.storyId.equals(storyId))
        ..orderBy([(t) => OrderingTerm.asc(t.chapterNumber)]))
      .get();
  return result;
});

class _OfflineLibraryScreenState extends ConsumerState<OfflineLibraryScreen> {
  @override
  void initState() {
    super.initState();
    // Refresh data every time this screen is opened (after downloads, etc.)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(offlineChaptersProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final chaptersAsync = ref.watch(offlineChaptersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Truyện đã tải')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(offlineChaptersProvider),
        child: chaptersAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Lỗi: $e')),
          data: (chapters) {
            if (chapters.isEmpty) {
              return ListView(children: const [
                SizedBox(height: 120),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off, size: 64, color: Colors.grey),
                      SizedBox(height: 12),
                      Text('Chưa có truyện nào được tải.'),
                      SizedBox(height: 4),
                      Text('Mở trang chi tiết truyện → nút tải xuống ⬇',
                          style: TextStyle(fontSize: 13, color: Colors.grey)),
                    ],
                  ),
                ),
              ]);
            }
            // Group by story
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
                  leading: const Icon(Icons.book, size: 40),
                  title: Text(first.storyTitle.isEmpty
                      ? first.storyId
                      : first.storyTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text('${storyChapters.length} chương đã tải'),
                  children: storyChapters.map((ch) {
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            const Color(0xFFE11D48).withValues(alpha: 0.12),
                        child: Text('${ch.chapterNumber}',
                            style: const TextStyle(color: Color(0xFFE11D48))),
                      ),
                      title: Text(ch.chapterTitle.isEmpty
                          ? 'Chương ${ch.chapterNumber}'
                          : ch.chapterTitle),
                      subtitle: Text('${ch.wordCount} từ'),
                      trailing: ch.isRead == 1
                          ? const Icon(Icons.check_circle,
                              color: Colors.green, size: 16)
                          : null,
                      onTap: () => context.push('/chapter-offline/${ch.chapterId}'),
                    );
                  }).toList(),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
