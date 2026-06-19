import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../models/story.dart';
import '../../repositories/story_repository.dart';
import 'widgets/story_card.dart';

/// Home / discovery feed. Plan §5.2.
///
/// For the MVP build we wire the live `GET /api/v1/stories` endpoint. If
/// the backend has not shipped that route yet, the screen degrades
/// gracefully to an empty state with a retry CTA — no crashes.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Kick off the first fetch on mount.
    Future.microtask(
      () => ref.read(homeStoriesProvider.notifier).refresh(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeStoriesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Không Dịch')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(homeStoriesProvider.notifier).refresh(),
        child: state.when(
          loading: () => const _LoadingGrid(),
          error: (e, _) => _ErrorState(
            message: '$e',
            onRetry: () => ref.read(homeStoriesProvider.notifier).refresh(),
          ),
          data: (stories) => stories.isEmpty
              ? const _EmptyState()
              : CustomScrollView(
                  slivers: [
                    const SliverToBoxAdapter(child: _HeroBanner()),
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverToBoxAdapter(
                        child: Text(
                          'Đang hot',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.62,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) => StoryCard(
                            story: stories[i],
                            onTap: () => context.push(
                              '/story/${stories[i].id}',
                            ),
                          ),
                          childCount: stories.length,
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
        ),
      ),
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
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tự đọc truyện text, manga, chat & video YouTube. '
            'Offline sẵn sàng, TTS 100% on-device.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.9),
                ),
          ),
        ],
      ),
    );
  }
}

class _LoadingGrid extends StatelessWidget {
  const _LoadingGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.62,
      ),
      itemCount: 6,
      itemBuilder: (_, __) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SizedBox(height: 120),
        Icon(Icons.inbox_outlined, size: 64),
        SizedBox(height: 12),
        Center(
          child: Text('Chưa có truyện nào. Kéo xuống để thử lại.'),
        ),
      ],
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

/// Notifier powering the home feed.
final homeStoriesProvider =
    StateNotifierProvider<HomeStoriesNotifier, AsyncValue<List<StorySummary>>>(
  (ref) => HomeStoriesNotifier(ref),
);

class HomeStoriesNotifier
    extends StateNotifier<AsyncValue<List<StorySummary>>> {
  HomeStoriesNotifier(this._ref) : super(const AsyncValue.loading());

  final Ref _ref;

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final repo = _ref.read(storyRepositoryProvider);
      final stories = await repo.listStories(sort: 'hot', perPage: 20);
      state = AsyncValue.data(stories);
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }
}
