import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/theme/app_theme.dart';
import '../../services/download_manager.dart';
import 'offline_library_screen.dart' show offlineLibraryStreamProvider;

/// Unified download + offline library screen.
///
/// Shows TWO sections in one screen:
///   1. **Đang tải** — active download queue with real-time progress
///   2. **Đã tải xong** — offline library grouped by story
///
/// Both sections auto-update in real-time via Drift's `watch()` stream
/// — no manual refresh needed.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueAsync = ref.watch(downloadQueueStreamProvider);
    final libraryAsync = ref.watch(offlineLibraryStreamProvider);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Tải xuống'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.download), text: 'Đang tải'),
              Tab(icon: Icon(Icons.library_books), text: 'Đã tải'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _QueueTab(queueAsync: queueAsync),
            _LibraryTab(libraryAsync: libraryAsync),
          ],
        ),
      ),
    );
  }
}

// ─── Tab 1: Download Queue ──────────────────────────────────────

/// StreamProvider that watches the download queue via Drift's native
/// `watch()` — auto-updates when any row changes (status, progress).
final downloadQueueStreamProvider =
    StreamProvider<List<DownloadQueueData>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.downloadQueue)
        ..orderBy([(t) => OrderingTerm.desc(t.queuedAt)]))
      .watch();
});

class _QueueTab extends ConsumerWidget {
  const _QueueTab({required this.queueAsync});
  final AsyncValue<List<DownloadQueueData>> queueAsync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return queueAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Lỗi: $e')),
      data: (rows) {
        if (rows.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.download_done_outlined, size: 64,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
                const SizedBox(height: 12),
                const Text('Không có tải xuống nào.'),
                const SizedBox(height: 8),
                Text(
                  'Mở trang chi tiết truyện → nút ⬇ để tải chương.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }

        // Summary header
        final pending = rows.where((r) => r.status == 'pending').length;
        final downloading = rows.where((r) => r.status == 'downloading').length;
        final completed = rows.where((r) => r.status == 'completed').length;
        final failed = rows.where((r) => r.status == 'failed').length;

        return Column(
          children: [
            // Progress summary
            if (pending > 0 || downloading > 0)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Row(
                  children: [
                    if (downloading > 0)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.hourglass_top, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      downloading > 0
                          ? 'Đang tải $downloading chương… ($pending chờ)'
                          : '$pending chương đang chờ tải…',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    Text('$completed đã xong',
                        style: const TextStyle(fontSize: 12)),
                    if (failed > 0) ...[
                      const SizedBox(width: 8),
                      Text('$failed lỗi',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.error)),
                    ],
                  ],
                ),
              ),
            // Queue list
            Expanded(
              child: ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => _DownloadRow(row: rows[i]),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DownloadRow extends ConsumerWidget {
  const _DownloadRow({required this.row});
  final DownloadQueueData row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive = row.status == 'pending' || row.status == 'downloading';
    return ListTile(
      leading: _StatusIcon(status: row.status),
      title: Text(
        'Ch.${row.chapterNumber} — ${row.storySlug}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isActive)
            LinearProgressIndicator(
              value: row.progress > 0 && row.progress < 1 ? row.progress : null,
              minHeight: 4,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
            )
          else
            const SizedBox(height: 4),
          const SizedBox(height: 4),
          Text(
            _statusLabel(),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      trailing: isActive
          ? IconButton(
              icon: const Icon(Icons.cancel_outlined),
              onPressed: () =>
                  ref.read(downloadManagerProvider).cancel(row.id),
            )
          : IconButton(
              icon: Icon(row.status == 'failed'
                  ? Icons.refresh
                  : Icons.delete_outline),
              onPressed: () async {
                if (row.status == 'failed') {
                  await ref.read(downloadManagerProvider).enqueueChapter(
                        storyId: row.storyId,
                        storySlug: row.storySlug,
                        chapterId: row.chapterId,
                        chapterNumber: row.chapterNumber,
                      );
                } else {
                  final db = ref.read(appDatabaseProvider);
                  await db.deleteDownloadQueueRow(row.id);
                }
              },
            ),
    );
  }

  String _statusLabel() {
    return switch (row.status) {
      'pending' => 'Đang chờ…',
      'downloading' =>
        'Đang tải… ${(row.progress * 100).toStringAsFixed(0)}%',
      'completed' => 'Đã tải xong ✓',
      'failed' => 'Lỗi: ${row.errorMessage ?? "không rõ"}',
      'cancelled' => 'Đã huỷ',
      _ => row.status,
    };
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      'pending' => (Icons.hourglass_top, Colors.grey),
      'downloading' => (Icons.downloading, const Color(0xFF2563EB)),
      'completed' => (Icons.check_circle, const Color(0xFF16A34A)),
      'failed' => (Icons.error_outline, AppTheme.primary),
      'cancelled' => (Icons.cancel_outlined, Colors.grey),
      _ => (Icons.help_outline, Colors.grey),
    };
    return Icon(icon, color: color);
  }
}

// ─── Tab 2: Offline Library ─────────────────────────────────────
// offlineLibraryStreamProvider is defined in offline_library_screen.dart
// and imported above. This avoids duplicate provider definitions.

class _LibraryTab extends ConsumerWidget {
  const _LibraryTab({required this.libraryAsync});
  final AsyncValue<List<DownloadedChapter>> libraryAsync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return libraryAsync.when(
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
                first.storyTitle.isEmpty
                    ? first.storyId
                    : first.storyTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
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
                  onTap: () =>
                      context.push('/chapter-offline/${ch.chapterId}'),
                );
              }).toList(),
            );
          },
        );
      },
    );
  }
}
