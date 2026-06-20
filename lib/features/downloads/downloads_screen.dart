import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/theme/app_theme.dart';
import '../../services/download_manager.dart';

/// Download queue screen. Plan §5.5.
///
/// Lists every entry in the [DownloadQueue] table, with live updates from
/// [DownloadManager.watchQueue]. Tapping a failed row lets the user
/// retry; swiping lets them cancel/remove.
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(downloadQueueProvider.notifier).refresh());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(downloadQueueProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Tải xuống')),
      body: Column(
        children: [
          // Quick link to offline library
          Material(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: InkWell(
              onTap: () => context.push('/offline-library'),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                child: const Row(
                  children: [
                    Icon(Icons.library_books, size: 28),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Đọc truyện đã tải',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          Text('Mở thư viện offline',
                              style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: state.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Lỗi: $e')),
              data: (rows) => rows.isEmpty
                  ? const _EmptyState()
                  : ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) => _DownloadRow(row: rows[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadRow extends ConsumerWidget {
  const _DownloadRow({required this.row});
  final DownloadQueueData row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          LinearProgressIndicator(
            value: row.progress.clamp(0.0, 1.0),
            minHeight: 4,
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 4),
          Text(
            _statusLabel(row.status, row.errorMessage),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      trailing: row.status == 'failed'
          ? IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => ref
                  .read(downloadManagerProvider)
                  .enqueueChapter(
                    storyId: row.storyId,
                    storySlug: row.storySlug,
                    chapterId: row.chapterId,
                    chapterNumber: row.chapterNumber,
                  ),
            )
          : row.status == 'downloading' || row.status == 'pending'
              ? IconButton(
                  icon: const Icon(Icons.cancel_outlined),
                  onPressed: () =>
                      ref.read(downloadManagerProvider).cancel(row.id),
                )
              : IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final db = ref.read(appDatabaseProvider);
                    await db.deleteDownloadQueueRow(row.id);
                    ref.read(downloadQueueProvider.notifier).refresh();
                  },
                ),
    );
  }

  String _statusLabel(String status, String? error) {
    return switch (status) {
      'pending' => 'Đang chờ…',
      'downloading' => 'Đang tải… ${(row.progress * 100).toStringAsFixed(0)}%',
      'completed' => 'Đã tải xong',
      'failed' => 'Lỗi: ${error ?? "không rõ"}',
      'cancelled' => 'Đã huỷ',
      _ => status,
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
      'downloading' =>
        (Icons.downloading, const Color(0xFF2563EB)),
      'completed' => (Icons.check_circle, const Color(0xFF16A34A)),
      'failed' => (Icons.error_outline, AppTheme.primary),
      'cancelled' => (Icons.cancel_outlined, Colors.grey),
      _ => (Icons.help_outline, Colors.grey),
    };
    return Icon(icon, color: color);
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.download_done_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          const Text('Chưa có tải xuống nào.'),
          const SizedBox(height: 4),
          Text(
            'Mở trang chi tiết truyện và nhấn "Tải xuống" để lưu chương.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---- State ----

final downloadQueueProvider =
    StateNotifierProvider<DownloadQueueNotifier, AsyncValue<List<DownloadQueueData>>>(
  (ref) => DownloadQueueNotifier(ref),
);

class DownloadQueueNotifier
    extends StateNotifier<AsyncValue<List<DownloadQueueData>>> {
  DownloadQueueNotifier(this._ref) : super(const AsyncValue.loading());
  final Ref _ref;

  Future<void> refresh() async {
    try {
      final db = _ref.read(appDatabaseProvider);
      state = AsyncValue.data(await db.getDownloadQueue());
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }
}
