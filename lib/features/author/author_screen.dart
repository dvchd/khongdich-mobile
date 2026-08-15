import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../models/story.dart';
import '../../repositories/story_repository.dart';
import '../home/widgets/story_card.dart';

/// Trang tác giả — hồ sơ + danh sách truyện của tác giả (phân trang).
///
/// Mở bằng cách chạm tên tác giả ở story detail. Đối chiếu trang web
/// `/u/{username}` nhưng tối giản cho mobile: avatar, tên, @username,
/// bio, số người theo dõi + grid truyện 2 cột + nút "Xem thêm".
class AuthorScreen extends ConsumerWidget {
  const AuthorScreen({super.key, required this.username});

  final String username;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(authorProfileProvider(username));
    return Scaffold(
      appBar: AppBar(
        title: state.valueOrNull?.author.name.isNotEmpty == true
            ? Text(
                state.valueOrNull!.author.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : const Text('Tác giả'),
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.person_off_outlined, size: 48),
                const SizedBox(height: 12),
                const Text('Không tìm thấy tác giả hoặc mất kết nối.'),
                const SizedBox(height: 8),
                Text(
                  '$e',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () =>
                      ref.invalidate(authorProfileProvider(username)),
                  child: const Text('Thử lại'),
                ),
              ],
            ),
          ),
        ),
        data: (data) => _AuthorContent(data: data, username: username),
      ),
    );
  }
}

class _AuthorContent extends ConsumerWidget {
  const _AuthorContent({required this.data, required this.username});

  final AuthorProfileData data;
  final String username;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final author = data.author;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return CustomScrollView(
      slivers: [
        // ── Header: avatar + tên + @username + follower count ──
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                  backgroundImage: author.avatarUrl != null
                      ? CachedNetworkImageProvider(author.avatarUrl!)
                      : null,
                  child: author.avatarUrl == null
                      ? Text(
                          author.name.isNotEmpty ? author.name[0] : '?',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primary,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        author.name,
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '@${author.username}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 12,
                        children: [
                          _Stat(label: '${data.totalStories}', value: 'truyện'),
                          if (author.followerCount > 0)
                            _Stat(
                              label: '${author.followerCount}',
                              value: 'người theo dõi',
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
        if (author.bio.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                author.bio,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Text(
              data.totalStories > 0 ? 'Truyện của tác giả' : 'Chưa có truyện',
              style: theme.textTheme.titleMedium,
            ),
          ),
        ),
        if (data.stories.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('Tác giả chưa đăng truyện nào.')),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.52,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final s = data.stories[i];
                  return StoryCard(
                    story: s,
                    onTap: () => context.push('/story/${s.slug}'),
                  );
                },
                childCount: data.stories.length,
              ),
            ),
          ),
        if (data.page < data.totalPages)
          SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                child: OutlinedButton(
                  onPressed: data.loadingMore
                      ? null
                      : () => ref
                          .read(authorProfileProvider(username).notifier)
                          .loadMore(),
                  child: data.loadingMore
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          'Xem thêm (${data.totalStories - data.stories.length} còn lại)',
                        ),
                ),
              ),
            ),
          )
        else
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RichText(
      text: TextSpan(
        style: Theme.of(context).textTheme.bodySmall,
        children: [
          TextSpan(
            text: label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(
            text: ' $value',
            style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }
}

/// Dữ liệu hiển thị của trang tác giả — trang đầu + các trang "Xem thêm".
class AuthorProfileData {
  const AuthorProfileData({
    required this.author,
    required this.stories,
    required this.totalStories,
    required this.page,
    required this.totalPages,
    this.loadingMore = false,
  });

  final AuthorInfo author;
  final List<StorySummary> stories;
  final int totalStories;
  final int page;
  final int totalPages;
  final bool loadingMore;

  AuthorProfileData copyWith({
    List<StorySummary>? stories,
    int? page,
    bool? loadingMore,
  }) =>
      AuthorProfileData(
        author: author,
        stories: stories ?? this.stories,
        totalStories: totalStories,
        page: page ?? this.page,
        totalPages: totalPages,
        loadingMore: loadingMore ?? this.loadingMore,
      );
}

final authorProfileProvider = StateNotifierProvider.autoDispose
    .family<AuthorProfileNotifier, AsyncValue<AuthorProfileData>, String>(
        (ref, username) {
  return AuthorProfileNotifier(ref, username);
});

class AuthorProfileNotifier
    extends StateNotifier<AsyncValue<AuthorProfileData>> {
  AuthorProfileNotifier(this._ref, this.username)
      : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  final String username;

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final profile =
          await _ref.read(storyRepositoryProvider).fetchAuthorProfile(username);
      state = AsyncValue.data(AuthorProfileData(
        author: profile.author,
        stories: profile.stories,
        totalStories: profile.totalStories,
        page: profile.page,
        totalPages: profile.totalPages,
      ));
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.loadingMore) return;
    if (current.page >= current.totalPages) return;
    state = AsyncValue.data(current.copyWith(loadingMore: true));
    try {
      final next = await _ref
          .read(storyRepositoryProvider)
          .fetchAuthorProfile(username, page: current.page + 1);
      state = AsyncValue.data(AuthorProfileData(
        author: current.author,
        stories: [...current.stories, ...next.stories],
        totalStories: next.totalStories,
        page: next.page,
        totalPages: next.totalPages,
      ));
    } catch (_) {
      // Lỗi mạng khi load thêm → giữ dữ liệu hiện có, tắt spinner.
      // User bấm lại "Xem thêm" để retry.
      state = AsyncValue.data(current.copyWith(loadingMore: false));
    }
  }
}
