import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/story.dart';
import '../../repositories/story_repository.dart';
import '../bookshelf/bookshelf_screen.dart'
    show bookshelfTabIntentProvider, kBookshelfDownloadedTabIndex;
import '../downloads/offline_library_screen.dart' show offlineLibraryStreamProvider;
import '../home/widgets/story_card.dart';

/// Search screen. Plan §6.3.
///
/// On initial load (no query entered), shows ~12 random stories so the
/// user can start browsing immediately. Once a query is entered, the
/// results replace the random stories.
///
/// When the device is offline, the random-stories fetch fails. Rather
/// than showing a dead error state, we auto-redirect to the bookshelf
/// "Đã tải" tab so the user lands on their offline library — same
/// pattern as the home screen's offline fallback.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  bool _searched = false;
  bool _redirected = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(randomStoriesProvider.notifier).load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _maybeRedirectOffline() {
    if (_redirected) return;
    // Only redirect if there's at least one downloaded chapter —
    // otherwise the offline library is empty and redirecting would
    // just show another empty state.
    final downloads =
        ref.read(offlineLibraryStreamProvider).valueOrNull ?? [];
    if (downloads.isEmpty) return;
    _redirected = true;
    ref.read(bookshelfTabIntentProvider.notifier).state =
        kBookshelfDownloadedTabIndex;
    context.go('/bookshelf');
  }

  Future<void> _runSearch(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() => _searched = false);
      ref.read(searchProvider.notifier).clear();
      return;
    }
    setState(() => _searched = true);
    await ref.read(searchProvider.notifier).run(query);
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    final randomState = ref.watch(randomStoriesProvider);
    // When the random-stories fetch fails (offline), auto-redirect
    // to the bookshelf "Đã tải" tab.
    randomState.whenOrNull(
      error: (_, __) => Future.microtask(_maybeRedirectOffline),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Tìm kiếm')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: _runSearch,
              decoration: InputDecoration(
                hintText: 'Tên truyện, tác giả, tag...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                          _runSearch('');
                        },
                      )
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _searched
                  ? _buildSearchResults(searchState)
                  : _buildRandom(randomState),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults(SearchState state) {
    return switch (state) {
      SearchIdle() => const _EmptyState(
          icon: Icons.search_off,
          message: 'Nhập từ khoá rồi nhấn tìm.',
        ),
      SearchLoading() =>
        const Center(child: CircularProgressIndicator()),
      SearchError(:final message) => _EmptyState(
          icon: Icons.cloud_off,
          message: 'Tìm kiếm thất bại: $message',
        ),
      SearchSuccess(:final result) => result.stories.isEmpty
          ? const _EmptyState(
              icon: Icons.inbox_outlined,
              message: 'Không có kết quả phù hợp.',
            )
          : GridView.builder(
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.62,
              ),
              itemCount: result.stories.length,
              itemBuilder: (_, i) => StoryCard(
                story: result.stories[i],
                onTap: () =>
                    context.push('/story/${result.stories[i].slug}'),
              ),
            ),
    };
  }

  Widget _buildRandom(AsyncValue<List<StorySummary>> state) {
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _EmptyState(
        icon: Icons.cloud_off,
        message: 'Không tải được truyện: $e',
      ),
      data: (stories) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Khám phá truyện',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          SliverGrid(
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
                onTap: () => context.push('/story/${stories[i].slug}'),
              ),
              childCount: stories.length,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
          const SizedBox(height: 8),
          Text(message, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

// ─── Search state ───────────────────────────────────────────────

sealed class SearchState {
  const SearchState();
}

class SearchIdle extends SearchState {
  const SearchIdle();
}

class SearchLoading extends SearchState {
  const SearchLoading();
}

class SearchSuccess extends SearchState {
  const SearchSuccess(this.result);
  final SearchResult result;
}

class SearchError extends SearchState {
  const SearchError(this.message);
  final String message;
}

final searchProvider =
    StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  return SearchNotifier(ref);
});

class SearchNotifier extends StateNotifier<SearchState> {
  SearchNotifier(this._ref) : super(const SearchIdle());
  final Ref _ref;

  Future<void> run(String q) async {
    state = const SearchLoading();
    try {
      final repo = _ref.read(storyRepositoryProvider);
      final result = await repo.search(q);
      state = SearchSuccess(result);
    } catch (e) {
      state = SearchError('$e');
    }
  }

  void clear() => state = const SearchIdle();
}

// ─── Random stories (initial browse) ────────────────────────────

final randomStoriesProvider = StateNotifierProvider<
    RandomStoriesNotifier, AsyncValue<List<StorySummary>>>((ref) {
  return RandomStoriesNotifier(ref);
});

class RandomStoriesNotifier
    extends StateNotifier<AsyncValue<List<StorySummary>>> {
  RandomStoriesNotifier(this._ref) : super(const AsyncValue.loading());
  final Ref _ref;

  Future<void> load() async {
    try {
      final repo = _ref.read(storyRepositoryProvider);
      final page = await repo.listStories(sort: 'random', perPage: 12);
      state = AsyncValue.data(page.stories);
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }
}
