import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../repositories/story_repository.dart';
import '../home/widgets/story_card.dart';

/// Search screen. Plan §6.3 lists full-text + autocomplete as Phase 2.
/// MVP: simple `q` query that hits `GET /api/v1/search?q=&limit=` —
/// the only JSON search endpoint currently exposed by the backend.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      ref.read(searchProvider.notifier).clear();
      return;
    }
    _focus.unfocus();
    await ref.read(searchProvider.notifier).run(query);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Tìm kiếm')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              focusNode: _focus,
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
                          ref.read(searchProvider.notifier).clear();
                        },
                      )
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: switch (state) {
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
              },
            ),
          ],
        ),
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

// ---- Search state ----

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
