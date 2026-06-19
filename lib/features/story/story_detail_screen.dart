import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../repositories/story_repository.dart';

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
    final chaptersAsync = ref.watch(_chapterListProvider(story.id));
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          expandedHeight: 260,
          flexibleSpace: FlexibleSpaceBar(
            title: Text(
              story.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            background: story.coverUrl == null
                ? Container(color: AppTheme.primary.withValues(alpha: 0.2))
                : Image.network(
                    story.coverUrl!,
                    fit: BoxFit.cover,
                    color: Colors.black.withValues(alpha: 0.4),
                    colorBlendMode: BlendMode.darken,
                    errorBuilder: (_, _, _) => Container(
                      color: AppTheme.primary.withValues(alpha: 0.2),
                    ),
                  ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        story.author,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (story.status != null)
                      _StatusChip(status: story.status!),
                    if (detail.bookmark != null) ...[
                      const SizedBox(width: 6),
                      _BookmarkChip(listType: detail.bookmark!),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                if (story.categories.isNotEmpty)
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
                if (story.tags.isNotEmpty) ...[
                  const SizedBox(height: 6),
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
                ],
                const SizedBox(height: 12),
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
                        await ref
                            .read(storyRepositoryProvider)
                            .toggleBookmark(story.id);
                        ref.invalidate(_storyDetailProvider(story.slug));
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

final _chapterListProvider = FutureProvider.autoDispose
    .family<PaginatedChapters, String>((ref, storyId) async {
  final repo = ref.watch(storyRepositoryProvider);
  return repo.fetchChapterList(storyId, perPage: 100);
});
