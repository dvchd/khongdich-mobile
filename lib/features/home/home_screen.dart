import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../models/story.dart';
import '../../core/observability/app_logger.dart';
import '../../repositories/story_repository.dart';
import '../bookshelf/bookshelf_screen.dart'
    show bookshelfTabIntentProvider, kBookshelfDownloadedTabIndex;
import '../notifications/unread_badge_provider.dart';
import '../downloads/offline_library_screen.dart' show offlineLibraryStreamProvider;
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

  Future<void> _maybeRedirectOffline(Object error) async {
    if (_redirected) return;
    // Chỉ redirect khi lỗi là lỗi MẠNG (offline/timeout) — lỗi server
    // (5xx, 401...) phải giữ lại màn hình lỗi + nút "Thử lại" để user
    // có thể retry. Trước đây redirect trên MỌI lỗi → nút retry không
    // bao giờ chạm được.
    //
    // DioException KHÔNG có response = không nhận được HTTP response
    // nào (connectionError/timeout/socket) → chắc chắn lỗi mạng. Trước
    // đây chỉ check 4 DioExceptionType cụ thể — Android airplane mode
    // có thể trả về type khác → redirect không bao giờ chạy.
    final isNetworkError =
        error is DioException && error.response == null;
    if (!isNetworkError) return;
    // Chỉ redirect khi có ít nhất 1 chương đã tải — như search screen.
    //
    // PHẢI await .future của stream provider — trước đây dùng
    // ref.read().value: lúc home vừa lỗi, stream chưa từng được
    // watch → valueOrNull == null → tưởng "chưa có truyện tải" → không
    // redirect dù DB có hàng trăm chương đã tải.
    try {
      final downloads =
          await ref.read(offlineLibraryStreamProvider.future);
      if (downloads.isEmpty || !mounted) return;
    } catch (_) {
      return; // DB lỗi — không redirect được, giữ màn hình lỗi.
    }
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
    // First error (offline) → auto-redirect to bookshelf downloaded tab.
    // ref.listen thay vì side-effect trong build — trước đây
    // Future.microtask chạy lại mỗi lần rebuild (đổi theme...).
    ref.listen(homeProvider, (prev, next) {
      next.whenOrNull(error: (e, _) => _maybeRedirectOffline(e));
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Không Dịch'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_note),
            tooltip: 'Đăng truyện (web)',
            onPressed: () => showPublishWebSheet(context),
          ),
          Consumer(
            builder: (context, ref, _) {
              final unread = ref.watch(unreadNotificationsProvider)
                  .value;
              return IconButton(
                icon: Badge(
                  isLabelVisible: (unread ?? 0) > 0,
                  label: Text('${unread ?? 0}'),
                  child: const Icon(Icons.notifications_outlined),
                ),
                tooltip: 'Thông báo',
                onPressed: () => context.push('/notifications'),
              );
            },
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
        home.picks.isNotEmpty ||
        home.random.isNotEmpty;
    return ListView(
      children: [
        const HomeHero(),
        // Khám phá nhanh: BXH / Thể loại / Tag / Khám phá (lọc).
        const _DiscoverShortcuts(),
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
            onReload: () =>
                ref.read(homeProvider.notifier).refreshSection('completed'),
            items: [
              for (final s in home.completed)
                StoryCard(story: s, onTap: () => _openStory(context, s.slug)),
            ],
          ),
        if (home.random.isNotEmpty)
          StorySection(
            title: 'Truyện ngẫu nhiên',
            icon: Icons.casino,
            trailing: '${home.random.length} truyện',
            onReload: () =>
                ref.read(homeProvider.notifier).refreshSection('random'),
            // Giống nút "Gieo xúc xắc" trên web — mỗi lần bấm là seed mới.
            reloadIcon: Icons.casino,
            reloadTooltip: 'Gieo xúc xắc — đổi truyện ngẫu nhiên',
            items: [
              for (final s in home.random)
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
class _OfflineOrErrorState extends ConsumerWidget {
  const _OfflineOrErrorState({
    required this.message,
    required this.onRetry,
  });
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Fallback button trong trường hợp auto-redirect không chạy được
    // (vd. stream chưa kịp emit) — nút hiện NGAY khi có truyện đã tải.
    final hasDownloads =
        (ref.watch(offlineLibraryStreamProvider).value ?? [])
            .isNotEmpty;
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
            hasDownloads
                ? 'Đang chuyển đến truyện đã tải...'
                : 'Bạn đang ngoại tuyến và chưa có truyện nào được tải. '
                    'Kết nối mạng rồi thử lại, hoặc tải truyện trước để '
                    'đọc offline.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Wrap(
            spacing: 12,
            children: [
              if (hasDownloads)
                FilledButton.icon(
                  icon: const Icon(Icons.download_done),
                  label: const Text('Xem truyện đã tải'),
                  onPressed: () => context.push('/offline-library'),
                ),
              OutlinedButton(
                onPressed: onRetry,
                child: const Text('Thử lại'),
              ),
            ],
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
    required this.random,
    required this.continueReading,
  });
  final List<StorySummary> hot;
  final List<StorySummary> fresh;
  final List<StorySummary> completed;
  final List<StorySummary> picks;

  /// Truyện ngẫu nhiên — khám phá tình cờ, giống web (`sort=random`
  /// với seed mới mỗi lần refresh).
  final List<StorySummary> random;
  final List<ContinueReadingItem> continueReading;

  /// Trả bản copy với riêng section [sort] được thay bằng [stories] —
  /// dùng cho nút "làm mới / gieo xúc xắc" ở từng section (không refetch
  /// lại toàn bộ home, giữ nguyên các section khác + scroll position).
  HomeFeed copyWithSection(String sort, List<StorySummary> stories) {
    return switch (sort) {
      'hot' => HomeFeed(
          hot: stories,
          fresh: fresh,
          completed: completed,
          picks: picks,
          random: random,
          continueReading: continueReading,
        ),
      'fresh' => HomeFeed(
          hot: hot,
          fresh: stories,
          completed: completed,
          picks: picks,
          random: random,
          continueReading: continueReading,
        ),
      'completed' => HomeFeed(
          hot: hot,
          fresh: fresh,
          completed: stories,
          picks: picks,
          random: random,
          continueReading: continueReading,
        ),
      'picks' => HomeFeed(
          hot: hot,
          fresh: fresh,
          completed: completed,
          picks: stories,
          random: random,
          continueReading: continueReading,
        ),
      'random' => HomeFeed(
          hot: hot,
          fresh: fresh,
          completed: completed,
          picks: picks,
          random: stories,
          continueReading: continueReading,
        ),
      _ => this,
    };
  }
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
        repo.listStories(
          sort: 'random',
          perPage: 15,
          seed: DateTime.now().millisecondsSinceEpoch.toString(),
        ),
        repo.fetchContinueReading().catchError((_) => <ContinueReadingItem>[]),
      ]);
      state = AsyncValue.data(HomeFeed(
        hot: (results[0] as PaginatedStories).stories,
        fresh: (results[1] as PaginatedStories).stories,
        completed: (results[2] as PaginatedStories).stories,
        picks: (results[3] as PaginatedStories).stories,
        random: (results[4] as PaginatedStories).stories,
        continueReading: results[5] as List<ContinueReadingItem>,
      ));
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  /// Refetch RIÊNG một section (nút reload/gieo xúc xắc cạnh tiêu đề) —
  /// chỉ thay đổi dữ liệu của section đó, giữ nguyên các section khác.
  /// Với `random` dùng seed mới mỗi lần → mỗi lần bấm là một danh sách
  /// truyện khác (giống nút "Gieo xúc xắc" trên web).
  Future<void> refreshSection(String sort) async {
    final current = state.value;
    if (current == null) return;
    try {
      final repo = _ref.read(storyRepositoryProvider);
      final seed = sort == 'random'
          ? DateTime.now().millisecondsSinceEpoch.toString()
          : null;
      final page = await repo.listStories(
        sort: sort,
        perPage: 15,
        seed: seed,
      );
      state = AsyncValue.data(current.copyWithSection(sort, page.stories));
    } catch (e, s) {
      // Giữ dữ liệu cũ của section — không làm chết màn hình khi lỗi
      // mạng; user vẫn còn danh sách cũ để duyệt.
      AppLogger.warning('Home: refresh section $sort failed', e, s);
    }
  }
}

/// Hàng phím tắt khám phá trên Home: BXH / Thể loại / Tag / Khám phá.
class _DiscoverShortcuts extends StatelessWidget {
  const _DiscoverShortcuts();

  static const _items = [
    (Icons.emoji_events_outlined, 'BXH', '/ranking'),
    (Icons.category_outlined, 'Thể loại', '/category-index'),
    (Icons.tag, 'Tag', '/tag-index'),
    (Icons.explore_outlined, 'Khám phá', '/explore'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          for (final (icon, label, path) in _items)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => context.push(path),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      Icon(
                        icon,
                        color: theme.colorScheme.primary,
                        size: 26,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        label,
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}