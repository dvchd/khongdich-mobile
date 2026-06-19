import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/story.dart';
import '../../repositories/story_repository.dart';
import '../home/widgets/story_card.dart';

/// Search screen — plan §6.3 lists full-text + autocomplete as Phase 2.
/// MVP: simple `q` query that hits `GET /api/v1/search?q=`.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  List<StorySummary> _results = const [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(storyRepositoryProvider);
      final results = await repo.search(query);
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _ErrorBox(message: _error!)
                      : _results.isEmpty
                          ? const _EmptyState()
                          : GridView.builder(
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 0.62,
                              ),
                              itemCount: _results.length,
                              itemBuilder: (_, i) => StoryCard(
                                story: _results[i],
                                onTap: () => context.push(
                                  '/story/${_results[i].id}',
                                ),
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 64,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
          const SizedBox(height: 8),
          Text(
            'Nhập từ khoá rồi nhấn tìm.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 8),
            const Text('Tìm kiếm thất bại'),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
