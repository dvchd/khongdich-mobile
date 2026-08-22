import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/app_image_cache.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/app_bottom_nav.dart';
import '../../features/tts/tts_now_playing_bar.dart';
import '../story/story_detail_screen.dart' show downloadedChaptersForStoryProvider;
import 'offline_library_screen.dart' show offlineStoriesMapProvider;

/// Offline story detail — reads downloaded chapters from the local Drift DB
/// and shows cover, author, synopsis, and chapter list. No network required.
class OfflineStoryDetailScreen extends ConsumerWidget {
  const OfflineStoryDetailScreen({super.key, required this.storyId});

  final String storyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chaptersAsync = ref.watch(downloadedChaptersForStoryProvider(storyId));
    final offlineStory = ref.watch(offlineStoriesMapProvider).value?[storyId];
    return Scaffold(
      body: chaptersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Lỗi: $e')),
        data: (chapters) {
          if (chapters.isEmpty) {
            return const Center(child: Text('Chưa có chương nào.'));
          }
          final first = chapters.first;
          // Snapshot offline_stories (tải kèm khi download) ưu tiên hơn
          // metadata gắn theo từng chương — đầy đủ hơn (thể loại, thống
          // kê, bìa local) và hiển thị y hệt online khi mất mạng.
          final author = offlineStory?.author.isNotEmpty == true
              ? offlineStory!.author
              : (first.storyAuthor ?? '');
          final synopsis = offlineStory?.synopsis.isNotEmpty == true
              ? offlineStory!.synopsis
              : (first.storySynopsis ?? '');
          final coverUrl = offlineStory?.coverUrl ?? first.coverUrl;
          final coverLocal = offlineStory?.coverLocalPath;
          final title = offlineStory?.title.isNotEmpty == true
              ? offlineStory!.title
              : first.storyTitle;
          final categories = offlineStory == null
              ? const <String>[]
              : (jsonDecode(offlineStory.categoriesJson) as List)
                  .cast<String>();
          final tags = offlineStory == null
              ? const <String>[]
              : (jsonDecode(offlineStory.tagsJson) as List).cast<String>();
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Bìa to căn giữa 3:4 như story detail online —
                      // file LOCAL nếu đã tải kèm khi download.
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: AspectRatio(
                            aspectRatio: 3 / 4,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: coverLocal != null &&
                                      File(coverLocal).existsSync()
                                  ? Image.file(
                                      File(coverLocal),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) =>
                                          _coverFallback(context),
                                    )
                                  : coverUrl == null
                                      ? _coverFallback(context)
                                      : CachedNetworkImage(
                                          imageUrl: coverUrl,
                                          cacheManager:
                                              AppImageCache.instance,
                                          fit: BoxFit.cover,
                                          memCacheWidth: 720,
                                          errorWidget: (_, _, _) =>
                                              _coverFallback(context),
                                        ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        author.isNotEmpty ? author : '(Chưa có tác giả)',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (offlineStory != null) ...[
                            _Pill(
                              icon: Icons.download_done,
                              iconColor: const Color(0xFF16A34A),
                              background: const Color(0xFF16A34A)
                                  .withValues(alpha: 0.12),
                              label:
                                  '${chapters.length}/${offlineStory.chapterCount} chương đã tải',
                            ),
                            if (offlineStory.status.isNotEmpty)
                              _Pill(
                                label: switch (offlineStory.status) {
                                  'ongoing' => 'Đang ra',
                                  'completed' => 'Hoàn thành',
                                  'hiatus' => 'Tạm dừng',
                                  _ => offlineStory.status,
                                },
                                iconColor: const Color(0xFF2563EB),
                                background: const Color(0xFF2563EB)
                                    .withValues(alpha: 0.12),
                              ),
                          ] else
                            _Pill(
                              icon: Icons.download_done,
                              iconColor: const Color(0xFF16A34A),
                              background: const Color(0xFF16A34A)
                                  .withValues(alpha: 0.12),
                              label: '${chapters.length} chương đã tải',
                            ),
                        ],
                      ),
                      if (offlineStory != null &&
                          (offlineStory.rating > 0 ||
                              offlineStory.viewCount > 0 ||
                              offlineStory.wordCount > 0)) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 14,
                          runSpacing: 4,
                          children: [
                            if (offlineStory.rating > 0)
                              _stat(
                                context,
                                Icons.star_rounded,
                                offlineStory.rating.toStringAsFixed(1),
                              ),
                            if (offlineStory.viewCount > 0)
                              _stat(
                                context,
                                Icons.visibility_outlined,
                                '${formatCount(offlineStory.viewCount)} đọc',
                              ),
                            if (offlineStory.wordCount > 0)
                              _stat(
                                context,
                                Icons.edit_outlined,
                                '${formatCount(offlineStory.wordCount)} từ',
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (categories.isNotEmpty || tags.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final c in categories)
                          _GenrePill(label: c, isTag: false),
                        for (final t in tags) _GenrePill(label: t, isTag: true),
                      ],
                    ),
                  ),
                ),
              if (synopsis.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      synopsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(height: 1.6),
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
      // (this screen lives outside MainShell). TTS now-playing bar nằm
      // trong slot này (trên menu) — vị trí thực, không đè nội dung.
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const TtsNowPlayingBar(),
          const AppBottomNav(currentIndex: -1),
        ],
      ),
    );
  }
}

Widget _coverFallback(BuildContext context) {
  return Container(
    color: AppTheme.primary.withValues(alpha: 0.2),
    alignment: Alignment.center,
    child: const Icon(Icons.book, size: 48),
  );
}

Widget _stat(BuildContext context, IconData icon, String label) {
  final scheme = Theme.of(context).colorScheme;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 15, color: scheme.primary.withValues(alpha: 0.7)),
      const SizedBox(width: 4),
      Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
        ),
      ),
    ],
  );
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.iconColor,
    required this.background,
    this.icon,
  });
  final String label;
  final IconData? icon;
  final Color iconColor;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: iconColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: iconColor,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _GenrePill extends StatelessWidget {
  const _GenrePill({required this.label, required this.isTag});
  final String label;
  final bool isTag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isTag
            ? scheme.surfaceContainerHigh
            : scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: isTag ? FontWeight.w500 : FontWeight.w600,
          color: isTag ? scheme.onSurfaceVariant : scheme.primary,
          height: 1.2,
        ),
      ),
    );
  }
}
