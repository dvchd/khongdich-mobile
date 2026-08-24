import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../models/my_story.dart';
import '../../repositories/story_repository.dart';

/// Danh sách truyện của tác giả đang đăng nhập (gồm nháp/chờ duyệt) —
/// mirror dashboard web `/dang-truyen`. Tap 1 truyện → mở story detail
/// thường (backend đã cho author xem draft qua Bearer JWT).
class MyStoriesScreen extends ConsumerWidget {
  const MyStoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storiesAsync = ref.watch(myStoriesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Truyện của tôi')),
      body: storiesAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorView(
          message: 'Không tải được danh sách truyện.',
          onRetry: () => ref.invalidate(myStoriesProvider),
        ),
        data: (stories) {
          if (stories.isEmpty) return const _EmptyView();
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(myStoriesProvider),
            child: ListView.separated(
              itemCount: stories.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _MyStoryTile(story: stories[i]),
            ),
          );
        },
      ),
    );
  }
}

/// Provider danh sách truyện của tôi. autoDispose + invalidate để pull-
/// to-refresh và nút "Thử lại" refetch.
final myStoriesProvider =
    FutureProvider.autoDispose<List<MyStory>>((ref) async {
  final repo = ref.watch(storyRepositoryProvider);
  return repo.fetchMyStories();
});

class _MyStoryTile extends StatelessWidget {
  const _MyStoryTile({required this.story});
  final MyStory story;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 48,
          height: 64,
          child: story.coverUrl != null
              ? CachedNetworkImage(
                  imageUrl: story.coverUrl!,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child:
                        Icon(Icons.menu_book_outlined, size: 20, color: theme.hintColor),
                  ),
                )
              : Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(Icons.menu_book_outlined,
                      size: 20, color: theme.hintColor),
                ),
        ),
      ),
      title: Text(
        story.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            _VisibilityChip(visibility: story.visibility),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '${story.publishedChapters}/${story.chapterCount} chương',
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/story/${story.slug}'),
    );
  }
}

/// Chip trạng thái — màu mirror badge dashboard web: công khai xanh,
/// nháp vàng đất, chờ duyệt vàng tươi, riêng tư xám.
class _VisibilityChip extends StatelessWidget {
  const _VisibilityChip({required this.visibility});
  final String visibility;

  String get _label => switch (visibility) {
        'public' => 'Công khai',
        'private' => 'Riêng tư',
        'draft' => 'Nháp',
        'pending' => 'Chờ duyệt',
        _ => visibility,
      };

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (visibility) {
      'public' => (const Color(0xFF22C55E), Colors.white),
      'draft' => (const Color(0xFFF59E0B), Colors.white),
      'pending' => (const Color(0xFFEAB308), Colors.black),
      _ => (Colors.grey.shade400, Colors.white),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        _label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

class _EmptyView extends ConsumerWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.edit_note_outlined, size: 56, color: theme.hintColor),
            const SizedBox(height: 12),
            Text('Bạn chưa có truyện nào',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Soạn và đăng truyện trên web — truyện của bạn sẽ hiện ở đây '
              '(kể cả bản nháp).',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                final base = ref.read(apiClientProvider).value?.baseUrl ??
                    'https://khongdich.com';
                final uri = Uri.parse('$base/dang-truyen');
                try {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Không mở được trình duyệt: $uri')),
                    );
                  }
                }
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Đăng truyện trên web'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: AppTheme.primary),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }
}
