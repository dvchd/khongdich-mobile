import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_bottom_nav.dart';
import '../../repositories/story_repository.dart';
import '../../services/download_manager.dart';
import '../bookshelf/bookshelf_screen.dart' show bookshelfProvider;

/// Stream of download queue rows for a specific story — auto-updates
/// via Drift's `watch()`.
final downloadQueueForStoryProvider =
    StreamProvider.autoDispose.family<List<DownloadQueueData>, String>(
        (ref, storyId) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.downloadQueue)
        ..where((t) => t.storyId.equals(storyId))
        ..orderBy([(t) => OrderingTerm.desc(t.queuedAt)]))
      .watch();
});

/// Stream of downloaded chapters for a specific story — auto-updates
/// via Drift's `watch()`.
///
/// **Filter**: chỉ hiện `manual_download` (user chủ động bấm download).
/// `auto_cache` (prefetch ngầm) bị ẩn — story detail chỉ count chương
/// user thực sự bấm download, không count auto-cache.
final downloadedChaptersForStoryProvider =
    StreamProvider.autoDispose.family<List<DownloadedChapter>, String>(
        (ref, storyId) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.downloadedChapters)
        ..where((t) => t.storyId.equals(storyId))
        ..where((t) => t.source.equals('manual_download'))
        ..orderBy([(t) => OrderingTerm.asc(t.chapterNumber)]))
      .watch();
});

/// VIP status for a story — fetched once when the story detail loads.
/// Provides `is_vip` flag, locked chapter IDs, and whether the user
/// can download offline (only story-wide VIP grants allow offline).
final vipStatusProvider =
    FutureProvider.autoDispose.family<VipStatus, String>((ref, storyId) async {
  final repo = ref.watch(storyRepositoryProvider);
  return repo.fetchVipStatus(storyId);
});

/// Story detail screen. Plan §5.3.
///
/// Hits:
///   - `GET /api/v1/mobile/stories/{slug}` → StoryDetailPayload
///   - `GET /api/v1/mobile/stories/{id}/chapters` → paginated chapter list
class StoryDetailScreen extends ConsumerWidget {
  const StoryDetailScreen({super.key, required this.storySlug});

  final String storySlug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(_storyDetailProvider(storySlug));
    return Scaffold(
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorBody(
          message: '$e',
          onRetry: () => ref.invalidate(_storyDetailProvider(storySlug)),
        ),
        data: (result) => _StoryDetailBody(detail: result.detail, localBookmark: result.localBookmark),
      ),
      // Bottom nav so the user can jump between Home / Search /
      // Bookshelf / Profile directly from the story detail page
      // (this screen lives outside MainShell).
      bottomNavigationBar: const AppBottomNav(currentIndex: -1),
    );
  }
}

class _StoryDetailBody extends ConsumerWidget {
  const _StoryDetailBody({required this.detail, this.localBookmark});
  final StoryDetailPayload detail;
  final String? localBookmark;

  String? get _effectiveBookmark => localBookmark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final story = detail.story;
    final chaptersAsync = ref.watch(chapterListProvider(story.id));
    final downloadedAsync = ref.watch(downloadedChaptersForStoryProvider(story.id));
    final queueAsync = ref.watch(downloadQueueForStoryProvider(story.id));
    final vipAsync = ref.watch(vipStatusProvider(story.id));
    final vip = vipAsync.valueOrNull ?? const VipStatus(isVip: false, lockedChapterIds: [], unlockedChapterIds: [], canDownloadOffline: true);
    final queueItems = queueAsync.valueOrNull ?? [];
    final downloadedIds = downloadedAsync.valueOrNull?.map((d) => d.chapterId).toSet() ?? {};
    final downloadedCount = downloadedAsync.valueOrNull?.length ?? 0;
    final totalChapters = story.chapterCount ?? 0;
    final activeDownloads = queueItems.where((q) =>
        q.status == 'pending' || q.status == 'downloading' || q.status == 'retry').length;
    final queueStatus = {for (final q in queueItems) q.chapterId: q.status};
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          title: Text(
            story.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Cover + info row: 3:4 cover on the left, title/author/status
        // on the right. This matches the web story detail layout.
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 3:4 cover image
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 120,
                    height: 160,
                    child: story.coverUrl == null
                        ? Container(
                            color: AppTheme.primary.withValues(alpha: 0.2),
                            child: const Icon(Icons.book, size: 48),
                          )
                        : Image.network(
                            story.coverUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              color: AppTheme.primary.withValues(alpha: 0.2),
                              child: const Icon(Icons.book, size: 48),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        story.title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        story.author,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        children: [
                          if (story.status != null)
                            _StatusChip(status: story.status!),
                          if (vip.isVip)
                            Chip(
                              avatar: const Icon(Icons.workspace_premium,
                                  size: 16, color: Color(0xFFD97706)),
                              label: const Text('VIP',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFFD97706))),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: const Color(0xFFFEF3C7),
                            ),
                          if (_effectiveBookmark != null)
                            _BookmarkChip(listType: _effectiveBookmark!),
                          if (story.chapterCount != null)
                            Chip(
                              label: Text('${story.chapterCount} chương'),
                              visualDensity: VisualDensity.compact,
                            ),
                          if (downloadedCount > 0)
                            Chip(
                              avatar: const Icon(Icons.download_done, size: 16, color: Colors.green),
                              label: Text('$downloadedCount${totalChapters > 0 ? '/$totalChapters' : ''} đã tải'),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Colors.green.withValues(alpha: 0.1),
                            ),
                          if (activeDownloads > 0)
                            Chip(
                              avatar: const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              label: Text('Đang tải $activeDownloads…'),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Colors.blue.withValues(alpha: 0.1),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (story.categories.isNotEmpty) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final cat in story.categories)
                        Chip(
                            label: Text(cat),
                            visualDensity: VisualDensity.compact),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                if (story.tags.isNotEmpty) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in story.tags)
                        Chip(
                          label: Text('#$tag'),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  story.synopsis ?? '(Chưa có giới thiệu)',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: detail.firstChapter == null
                            ? null
                            : () => context.push(
                                '/chapter/${story.id}:${detail.firstChapter}'),
                        icon: const Icon(Icons.menu_book),
                        label: const Text('Bắt đầu đọc'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      icon: Icon(_effectiveBookmark == null
                          ? Icons.bookmark_border
                          : Icons.bookmark),
                      onPressed: () async {
                        final added = await ref
                            .read(bookshelfProvider.notifier)
                            .toggle(
                              story.id,
                              title: story.title,
                              slug: story.slug,
                              coverUrl: story.coverUrl,
                              author: story.author,
                              contentType: story.contentTypes.isNotEmpty
                                  ? story.contentTypes.first
                                  : 'text',
                            );
                        ref.invalidate(_storyDetailProvider(story.slug));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(added
                                  ? 'Đã thêm vào tủ truyện'
                                  : 'Đã xoá khỏi tủ truyện'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        }
                      },
                    ),
                    IconButton.outlined(
                      icon: activeDownloads > 0
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : (downloadedCount > 0
                              ? const Icon(Icons.download_done, color: Colors.green)
                              : const Icon(Icons.download_outlined)),
                      // Download luôn enable — download manager sẽ check
                      // per-chapter access (fetchChapterAccess) và mark
                      // failed cho chapter user không có quyền. Trước đây
                      // disable nút khi vip.isVip && !canDownloadOffline
                      // (chỉ story-wide grant mới cho download) — quá
                      // strict, user có per-chapter grant vẫn không tải
                      // được dù có quyền đọc chapter đó.
                      onPressed: activeDownloads > 0
                          ? null
                          : () async {
                        final repo = ref.read(storyRepositoryProvider);
                        final page = await repo.fetchChapterList(story.id, perPage: 200);
                        if (page.chapters.isEmpty) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Chưa có chương để tải.')),
                            );
                          }
                          return;
                        }
                        // Download tất cả chapters — download manager
                        // sẽ check access per-chapter. Chapter nào user
                        // không có quyền → mark failed với message rõ
                        // ràng, các chapter khác vẫn tải bình thường.
                        final chaptersToDownload = page.chapters;
                        final total = page.chapters.length;
                        final already = downloadedIds.length;
                        final enqueued = await ref.read(downloadManagerProvider).enqueueAllChapters(
                          storyId: story.id,
                          storySlug: story.slug,
                          chapters: chaptersToDownload,
                          coverUrl: story.coverUrl,
                          storyAuthor: story.author,
                          storySynopsis: story.synopsis,
                        );
                        ref.invalidate(downloadedChaptersForStoryProvider(story.id));
                        if (context.mounted) {
                          final msg = enqueued == 0
                              ? 'Đã tải xong $already/$total chương.'
                              : 'Đang tải $enqueued chương (đã có $already/$total).';
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(msg)),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Text(
                  'Danh sách chương',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                chaptersAsync.maybeWhen(
                  data: (page) => Text(
                    '${page.total} chương',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  orElse: () => const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
        chaptersAsync.when(
          loading: () => const SliverFillRemaining(
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => SlFillRemaining(
            child: Center(child: Text('Không tải được chương: $e')),
          ),
          data: (page) => page.chapters.isEmpty
              ? const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('Chưa có chương nào.'),
                    ),
                  ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final c = page.chapters[i];
                      // Only pending / downloading / retry count as
                      // "active in queue" — a `completed` queue row
                      // means the chapter is on disk and should render
                      // the green checkmark, not a spinner.
                      final queueState = queueStatus[c.id];
                      final isActiveInQueue = queueState == 'pending' ||
                          queueState == 'downloading' ||
                          queueState == 'retry';
                      final isDownloaded = downloadedIds.contains(c.id);
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              AppTheme.primary.withValues(alpha: 0.12),
                          child: Text(
                            '${c.chapterNumber}',
                            style: const TextStyle(color: AppTheme.primary),
                          ),
                        ),
                        title: Text(
                          c.title.isEmpty
                              ? 'Chương ${c.chapterNumber}'
                              : c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_contentTypeLabel(story.contentTypes.first)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (vip.isChapterLocked(c.id))
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Icon(
                                  vip.isChapterUnlocked(c.id)
                                      ? Icons.lock_open
                                      : Icons.lock,
                                  size: 16,
                                  color: vip.isChapterUnlocked(c.id)
                                      ? const Color(0xFF10B981) // xanh — đã mở khóa
                                      : const Color(0xFFD97706), // vàng — chưa mở khóa
                                ),
                              ),
                            if (queueState == 'pending')
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(Icons.hourglass_top, size: 16, color: Colors.grey),
                              ),
                            if (queueState == 'downloading')
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            if (isDownloaded && !isActiveInQueue)
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(Icons.download_done, size: 16, color: Colors.green),
                              ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        onTap: () =>
                            context.push('/chapter/${story.id}:${c.chapterNumber}'),
                      );
                    },
                    childCount: page.chapters.length,
                  ),
                ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  String _contentTypeLabel(String type) => switch (type) {
        'text' => 'Truyện text',
        'manga' => 'Manga',
        'chat' => 'Truyện chat',
        'video' => 'Video YouTube',
        _ => type,
      };
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'ongoing' => ('Đang ra', const Color(0xFF16A34A)),
      'completed' => ('Hoàn thành', const Color(0xFF2563EB)),
      'hiatus' => ('Tạm dừng', const Color(0xFFD97706)),
      _ => (status, Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _BookmarkChip extends StatelessWidget {
  const _BookmarkChip({required this.listType});
  final String listType;

  @override
  Widget build(BuildContext context) {
    final label = switch (listType) {
      'reading' => 'Đang đọc',
      'completed' => 'Đã đọc xong',
      'plan_to_read' => 'Sẽ đọc',
      'favorite' => 'Yêu thích',
      _ => listType,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
            color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            const Text('Không tải được truyện'),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Thử lại')),
          ],
        ),
      ),
    );
  }
}

// Short alias for the SliverFillRemaining type — keeps the call sites
// readable without losing the sliver contract.
typedef SlFillRemaining = SliverFillRemaining;

/// Merged detail payload with local bookmark state.
/// Falls back to local Drift bookmarks when the server returns null
/// (e.g. anonymous users).
class _DetailWithBookmark {
  const _DetailWithBookmark({
    required this.detail,
    this.localBookmark,
  });
  final StoryDetailPayload detail;
  final String? localBookmark; // listType if bookmarked locally
}

final _storyDetailProvider = FutureProvider.autoDispose
    .family<_DetailWithBookmark, String>((ref, slug) async {
  final repo = ref.watch(storyRepositoryProvider);
  final db = ref.read(appDatabaseProvider);
  final detail = await repo.fetchStoryDetail(slug);
  // Merge local bookmark state for anonymous / offline users.
  String? localBookmark;
  try {
    final local = await db.getBookmarkForStory(detail.story.id);
    if (local != null) localBookmark = local.listType;
  } catch (_) {}
  return _DetailWithBookmark(
    detail: detail,
    localBookmark: detail.bookmark ?? localBookmark,
  );
});

// chapterListProvider is now defined in repositories/story_repository.dart
// and shared between this screen and the chapter reader's chapter-list
// bottom sheet.
