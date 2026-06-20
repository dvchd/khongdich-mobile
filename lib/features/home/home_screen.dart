import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../models/story.dart';
import '../../repositories/story_repository.dart';
import 'widgets/story_card.dart';
import 'widgets/story_section.dart';

/// Home / discovery feed. Plan §5.2.
///
/// Hits `GET /api/v1/mobile/stories?sort=hot|fresh|picks|completed` for
/// each section. Authenticated users also see a "Đọc tiếp" strip from
/// `GET /api/v1/mobile/reading-progress`.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(homeProvider.notifier).refresh());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Không Dịch'),
        actions: [
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
          error: (e, _) => _ErrorState(
            message: '$e',
            onRetry: () => ref.read(homeProvider.notifier).refresh(),
          ),
          data: (home) => _HomeContent(home: home),
        ),
      ),
    );
  }
}

class _HomeContent extends StatelessWidget {
  const _HomeContent({required this.home});
  final HomeFeed home;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const _HeroBanner(),
        if (home.continueReading.isNotEmpty)
          StorySection(
            title: 'Đọc tiếp',
            height: 180,
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
            items: [
              for (final s in home.hot)
                StoryCard(
                  story: s,
                  onTap: () => context.push('/story/${s.slug}'),
                ),
            ],
          ),
        if (home.fresh.isNotEmpty)
          StorySection(
            title: 'Truyện mới',
            items: [
              for (final s in home.fresh)
                StoryCard(
                  story: s,
                  onTap: () => context.push('/story/${s.slug}'),
                ),
            ],
          ),
        if (home.picks.isNotEmpty)
          StorySection(
            title: 'Tuyển chọn',
            items: [
              for (final s in home.picks)
                StoryCard(
                  story: s,
                  onTap: () => context.push('/story/${s.slug}'),
                ),
            ],
          ),
        if (home.hot.isEmpty &&
            home.fresh.isEmpty &&
            home.picks.isEmpty &&
            home.continueReading.isEmpty)
          const _EmptyState(),
        const SizedBox(height: 24),
      ],
    );
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

class _HeroBanner extends StatelessWidget {
  const _HeroBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.primary, Color(0xFFB91C1C)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Đọc truyện — Không Dịch',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontSize: 22,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Truyện text, manga, chat & video. Offline sẵn sàng, TTS 100% on-device.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.9),
                ),
          ),
        ],
      ),
    );
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: List.filled(6, 0).map((_) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 80,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 12,
                      width: 120,
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
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
          Icon(Icons.inbox_outlined, size: 64, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
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

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 120),
        const Icon(Icons.cloud_off, size: 64),
        const SizedBox(height: 12),
        const Center(child: Text('Không tải được dữ liệu')),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: OutlinedButton(onPressed: onRetry, child: const Text('Thử lại')),
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
    required this.picks,
    required this.continueReading,
  });
  final List<StorySummary> hot;
  final List<StorySummary> fresh;
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
    try {
      final repo = _ref.read(storyRepositoryProvider);
      // Fan out the section fetches in parallel. `fetchContinueReading`
      // is wrapped in a try-catch because it returns 401 when the user
      // is not authenticated — we don't want that to crash the whole
      // home screen.
      final results = await Future.wait([
        repo.listStories(sort: 'hot', perPage: 20),
        repo.listStories(sort: 'fresh', perPage: 20),
        repo.listStories(sort: 'picks', perPage: 20),
        repo.fetchContinueReading().catchError((_) => <ContinueReadingItem>[]),
      ]);
      state = AsyncValue.data(HomeFeed(
        hot: (results[0] as PaginatedStories).stories,
        fresh: (results[1] as PaginatedStories).stories,
        picks: (results[2] as PaginatedStories).stories,
        continueReading: results[3] as List<ContinueReadingItem>,
      ));
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }
}
