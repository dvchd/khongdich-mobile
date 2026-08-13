import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/story.dart';
import '../../repositories/story_repository.dart';
import '../bookshelf/bookshelf_screen.dart'
    show bookshelfTabIntentProvider, kBookshelfDownloadedTabIndex;
import 'publish_web_sheet.dart';
import 'widgets/home_hero.dart';
import 'widgets/market_section.dart';
import 'widgets/story_card.dart';
import 'widgets/story_section.dart';

/// Home / discovery feed. Plan §5.2.
///
/// Hits `GET /api/v1/mobile/stories?sort=hot|fresh|completed|picks` for
/// each section. Authenticated users also see a "Đọc tiếp" strip from
/// `GET /api/v1/mobile/reading-progress`.
///
/// Mobile-first UX: the hero highlights offline reading/listening (with
/// a live downloaded-chapter count), quick actions (Tủ truyện / Đã tải
/// / Đăng truyện), and story rails — publishing guidance lives in the
/// docs sheet (`PublishWebSheet`): the app is read-only for stories.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _redirected = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(homeProvider.notifier).refresh());
  }

  void _maybeRedirectOffline() {
    if (_redirected) return;
    _redirected = true;
    // Set the tab intent to the "Downloaded" tab (last index in the
    // bookshelf) so the user lands on their offline library directly
    // when the home feed can't load.
    ref.read(bookshelfTabIntentProvider.notifier).state =
        kBookshelfDownloadedTabIndex;
    context.go('/bookshelf');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeProvider);
    // On first error (offline), auto-redirect to bookshelf downloaded tab
    state.whenOrNull(
      error: (_, __) => Future.microtask(_maybeRedirectOffline),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Không Dịch'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_note),
            tooltip: 'Đăng truyện (web)',
            onPressed: () => showPublishWebSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () => context.push('/notifications'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(homeProvider.notifier).refresh(),
        child: state.when(
          loading: () => const _LoadingList(),
          error: (e, _) => _OfflineOrErrorState(
            message: '$e',
            onRetry: () => ref.read(homeProvider.notifier).refresh(),
          ),
          data: (home) => _HomeContent(home: home),
        ),
      ),
    );
  }
}

class _HomeContent extends ConsumerWidget {
  const _HomeContent({required this.home});
  final HomeFeed home;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasAny = home.continueReading.isNotEmpty ||
        home.hot.isNotEmpty ||
        home.fresh.isNotEmpty ||
        home.completed.isNotEmpty ||
        home.picks.isNotEmpty;
    return ListView(
      children: [
        const HomeHero(),
        // Chợ Phiên — hidden while the chợ is closed (best-effort fetch,
        // mirrors the web home section).
        ref.watch(homeMarketProvider).whenData((section) {
          if (section == null) return const SizedBox.shrink();
          return MarketHomeSection(section: section);
        }).value ?? const SizedBox.shrink(),
        if (home.continueReading.isNotEmpty)
          StorySection(
            title: 'Đọc tiếp',
            icon: Icons.history,
            trailing: '${home.continueReading.length}',
            items: [
              for (final c in home.continueReading)
                StoryCard(
                  story: _summaryFromContinue(c),
                  onTap: () =>
                      context.push('/chapter/${c.storyId}:${c.lastChapter}'),
                  badge: c.chapterLabel,
                ),
            ],
          ),
        if (home.hot.isNotEmpty)
          StorySection(
            title: 'Đang hot',
            icon: Icons.local_fire_department,
            trailing: '${home.hot.length} truyện',
            items: [
              for (final s in home.hot)
                StoryCard(story: s, onTap: () => _openStory(context, s.slug)),
            ],
          ),
        if (home.fresh.isNotEmpty)
          StorySection(
            title: 'Truyện mới',
            icon: Icons.fiber_new,
            trailing: '${home.fresh.length} truyện',
            items: [
              for (final s in home.fresh)
                StoryCard(story: s, onTap: () => _openStory(context, s.slug)),
            ],
          ),
        if (home.completed.isNotEmpty)
          StorySection(
            title: 'Hoàn thành',
            icon: Icons.task_alt,
            trailing: '${home.completed.length} truyện',
            items: [
              for (final s in home.completed)
                StoryCard(story: s, onTap: () => _openStory(context, s.slug)),
            ],
          ),
        if (home.picks.isNotEmpty)
          StorySection(
            title: 'Tuyển chọn',
            icon: Icons.workspace_premium,
            trailing: '${home.picks.length} truyện',
            items: [
              for (final s in home.picks)
                StoryCard(story: s, onTap: () => _openStory(context, s.slug)),
            ],
          ),
        if (!hasAny) const _EmptyState(),
        const _PublishReminder(),
        const SizedBox(height: 24),
      ],
    );
  }

  void _openStory(BuildContext context, String slug) {
    context.push('/story/$slug');
  }

  StorySummary _summaryFromContinue(ContinueReadingItem c) {
    return StorySummary(
      id: c.storyId,
      title: c.storyTitle,
      slug: c.storySlug,
      coverUrl: c.coverUrl,
      author: '',
      categories: const [],
      tags: const [],
      contentTypes: [c.contentType],
    );
  }
}

/// Calm footer reminder: publishing happens on the web, the app is for
/// reading (offline + TTS). Tapping opens the guidance sheet.
class _PublishReminder extends StatelessWidget {
  const _PublishReminder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => showPublishWebSheet(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_stories_outlined, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Muốn đăng truyện của riêng bạn? Việc đăng & quản lý '
                    'truyện được thực hiện trên web — app chỉ dành cho '
                    'việc đọc (online, offline & nghe TTS).',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.75),
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: scheme.onSurface.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 64,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            'Không có nội dung để hiển thị.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Kéo xuống để thử lại.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Error state that also offers a "read offline" button when the
/// network is down. This is the key UX fix: instead of just showing
/// "Không tải được dữ liệu", we redirect the user to their offline
/// library so they can keep reading downloaded chapters.
class _OfflineOrErrorState extends StatelessWidget {
  const _OfflineOrErrorState({
    required this.message,
    required this.onRetry,
  });
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 100),
        Icon(
          Icons.wifi_off,
          size: 64,
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
        ),
        const SizedBox(height: 12),
        const Center(child: Text('Không có kết nối mạng')),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Đang chuyển đến truyện đã tải...',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: OutlinedButton(
            onPressed: onRetry,
            child: const Text('Thử lại'),
          ),
        ),
      ],
    );
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    final placeholder = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView(
      children: [
        const SizedBox(height: 12),
        // Hero skeleton
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            height: 110,
            decoration: BoxDecoration(
              color: placeholder,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 80,
                  decoration: BoxDecoration(
                    color: placeholder,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 16,
                        width: double.infinity,
                        color: placeholder,
                      ),
                      const SizedBox(height: 8),
                      Container(height: 12, width: 120, color: placeholder),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ─── State ───────────────────────────────────────────────────────

/// Aggregated home feed — one section per "sort" the backend supports.
class HomeFeed {
  const HomeFeed({
    required this.hot,
    required this.fresh,
    required this.completed,
    required this.picks,
    required this.continueReading,
  });
  final List<StorySummary> hot;
  final List<StorySummary> fresh;
  final List<StorySummary> completed;
  final List<StorySummary> picks;
  final List<ContinueReadingItem> continueReading;
}

final homeProvider =
    StateNotifierProvider<HomeNotifier, AsyncValue<HomeFeed>>((ref) {
  return HomeNotifier(ref);
});

class HomeNotifier extends StateNotifier<AsyncValue<HomeFeed>> {
  HomeNotifier(this._ref) : super(const AsyncValue.loading());
  final Ref _ref;

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    _ref.invalidate(homeMarketProvider);
    try {
      final repo = _ref.read(storyRepositoryProvider);
      // Fan out the section fetches in parallel. `fetchContinueReading`
      // is wrapped in a try-catch because it returns 401 when the user
      // is not authenticated — we don't want that to crash the whole
      // home screen.
      final results = await Future.wait([
        repo.listStories(sort: 'hot', perPage: 15),
        repo.listStories(sort: 'fresh', perPage: 15),
        repo.listStories(sort: 'completed', perPage: 15),
        repo.listStories(sort: 'picks', perPage: 15),
        repo.fetchContinueReading().catchError((_) => <ContinueReadingItem>[]),
      ]);
      state = AsyncValue.data(HomeFeed(
        hot: (results[0] as PaginatedStories).stories,
        fresh: (results[1] as PaginatedStories).stories,
        completed: (results[2] as PaginatedStories).stories,
        picks: (results[3] as PaginatedStories).stories,
        continueReading: results[4] as List<ContinueReadingItem>,
      ));
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }
}