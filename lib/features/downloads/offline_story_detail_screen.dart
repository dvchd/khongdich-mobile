import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_bottom_nav.dart';
import '../story/story_detail_screen.dart' show downloadedChaptersForStoryProvider;

/// Offline story detail — reads downloaded chapters from the local Drift DB
/// and shows cover, author, synopsis, and chapter list. No network required.
class OfflineStoryDetailScreen extends ConsumerWidget {
  const OfflineStoryDetailScreen({super.key, required this.storyId});

  final String storyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chaptersAsync = ref.watch(downloadedChaptersForStoryProvider(storyId));
    return Scaffold(
      body: chaptersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Lỗi: $e')),
        data: (chapters) {
          if (chapters.isEmpty) {
            return const Center(child: Text('Chưa có chương nào.'));
          }
          final first = chapters.first;
          final author = first.storyAuthor ?? '';
          final synopsis = first.storySynopsis ?? '';
          final coverUrl = first.coverUrl;
          final title = first.storyTitle;
          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 120,
                          height: 160,
                          child: coverUrl == null
                              ? Container(
                                  color: AppTheme.primary.withValues(alpha: 0.2),
                                  child: const Icon(Icons.book, size: 48),
                                )
                              : CachedNetworkImage(
                                  imageUrl: coverUrl,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) => Container(
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
                              title,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              author.isNotEmpty ? author : '(Chưa có tác giả)',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 8),
                            Chip(
                              avatar: const Icon(Icons.download_done, size: 16, color: Colors.green),
                              label: Text('${chapters.length} chương đã tải'),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Colors.green.withValues(alpha: 0.1),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (synopsis.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      synopsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
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
                      Text(
                        '${chapters.length} chương',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final ch = chapters[i];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                        child: Text(
                          '${ch.chapterNumber}',
                          style: const TextStyle(color: AppTheme.primary),
                        ),
                      ),
                      title: Text(
                        ch.chapterTitle.isEmpty
                            ? 'Chương ${ch.chapterNumber}'
                            : ch.chapterTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${ch.wordCount} từ'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(Icons.download_done, size: 16, color: Colors.green),
                          ),
                          if (ch.isRead == 1)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Icon(Icons.check_circle, size: 16, color: Colors.green),
                            ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                      onTap: () => context.push('/chapter-offline/${ch.chapterId}'),
                    );
                  },
                  childCount: chapters.length,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );
        },
      ),
      // Bottom nav so the user can jump between Home / Search /
      // Bookshelf / Profile directly from the offline story detail
      // (this screen lives outside MainShell).
      bottomNavigationBar: const AppBottomNav(currentIndex: -1),
    );
  }
}
