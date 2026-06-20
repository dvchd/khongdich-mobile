import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../repositories/story_repository.dart';
import '../../services/download_manager.dart';
import '../bookshelf/bookshelf_screen.dart' show bookshelfProvider;

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
        data: (detail) => _StoryDetailBody(detail: detail),
      ),
    );
  }
}

class _StoryDetailBody extends ConsumerWidget {
  const _StoryDetailBody({required this.detail});
  final StoryDetailPayload detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final story = detail.story;
    final chaptersAsync = ref.watch(chapterListProvider(story.id));
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
                          if (detail.bookmark != null)
                            _BookmarkChip(listType: detail.bookmark!),
                          if (story.chapterCount != null)
                            Chip(
                              label: Text('${story.chapterCount} chương'),
                              visualDensity: VisualDensity.compact,
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
                      icon: Icon(detail.bookmark == null
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
                      icon: const Icon(Icons.download_outlined),
                      onPressed: () async {
                        // Fetch chapter list and enqueue all for download.
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
                        await ref.read(downloadManagerProvider).enqueueAllChapters(
                          storyId: story.id,
                          storySlug: story.slug,
                          chapters: page.chapters,
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Đang tải ${page.chapters.length} chương...'),
                              action: SnackBarAction(
                                label: 'Xem',
                                onPressed: () => context.push('/downloads'),
                              ),
                            ),
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
                        trailing: const Icon(Icons.chevron_right),
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

final _storyDetailProvider = FutureProvider.autoDispose
    .family<StoryDetailPayload, String>((ref, slug) async {
  final repo = ref.watch(storyRepositoryProvider);
  return repo.fetchStoryDetail(slug);
});

// chapterListProvider is now defined in repositories/story_repository.dart
// and shared between this screen and the chapter reader's chapter-list
// bottom sheet.
