import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../models/story.dart';
import '../../repositories/story_repository.dart';

/// Story detail screen. Plan §5.3.
class StoryDetailScreen extends ConsumerWidget {
  const StoryDetailScreen({super.key, required this.storyId});

  final String storyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storyAsync = ref.watch(_storyProvider(storyId));
    final chaptersAsync = ref.watch(_chaptersProvider(storyId));
    return Scaffold(
      body: storyAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Lỗi: $e')),
        data: (story) => CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 220,
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
                        errorBuilder: (_, __, ___) => Container(
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
                    Text(story.author,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final cat in story.categories)
                          Chip(label: Text(cat)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      story.synopsis ?? '(Chưa có giới thiệu)',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () {
                        // Jump to the first chapter when available.
                        final chapters = chaptersAsync.maybeWhen(
                          data: (list) => list,
                          orElse: () => <ChapterSummary>[],
                        );
                        if (chapters.isEmpty) return;
                        context.push('/chapter/${chapters.first.id}');
                      },
                      icon: const Icon(Icons.menu_book),
                      label: const Text('Bắt đầu đọc'),
                    ),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: Divider()),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverToBoxAdapter(
                child: Text(
                  'Danh sách chương',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            chaptersAsync.when(
              loading: () => const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => SliverFillRemaining(
                child: Center(child: Text('Không tải được: $e')),
              ),
              data: (chapters) => SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final c = chapters[i];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                        child: Text('${c.chapterNumber}',
                            style: const TextStyle(color: AppTheme.primary)),
                      ),
                      title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_contentTypeLabel(c.contentType)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/chapter/${c.id}'),
                    );
                  },
                  childCount: chapters.length,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
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

final _storyProvider =
    FutureProvider.autoDispose.family<StorySummary, String>((ref, id) async {
  final repo = ref.watch(storyRepositoryProvider);
  return repo.getStory(id);
});

final _chaptersProvider =
    FutureProvider.autoDispose.family<List<ChapterSummary>, String>(
        (ref, id) async {
  final repo = ref.watch(storyRepositoryProvider);
  return repo.listChapters(id);
});
