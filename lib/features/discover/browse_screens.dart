import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../repositories/story_repository.dart';
import '../home/widgets/story_card.dart';

/// Màn thể loại + tag chung: index + danh sách truyện theo thể loại/tag.
/// Đối chiếu các trang web `/the-loai` + `/tag`.

// ── Thể loại index ────────────────────────────────────────────────

class CategoryIndexScreen extends ConsumerWidget {
  const CategoryIndexScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(categoriesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Thể loại')),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 48),
                const SizedBox(height: 12),
                const Text('Không tải được danh sách thể loại'),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => ref.invalidate(categoriesProvider),
                  child: const Text('Thử lại'),
                ),
              ],
            ),
          ),
        ),
        data: (cats) => ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: cats.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final c = cats[i];
            return ListTile(
              leading: const Icon(Icons.category_outlined),
              title: Text(c.name),
              subtitle: c.description.isNotEmpty
                  ? Text(
                      c.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  context.push('/category/${c.slug}', extra: c.name),
            );
          },
        ),
      ),
    );
  }
}

final categoriesProvider = FutureProvider.autoDispose<List<CategoryInfo>>(
  (ref) => ref.watch(storyRepositoryProvider).fetchCategories(),
);

// ── Truyện theo thể loại ─────────────────────────────────────────

class CategoryStoriesScreen extends ConsumerStatefulWidget {
  const CategoryStoriesScreen({
    super.key,
    required this.slug,
    this.title = '',
  });

  final String slug;
  final String title;

  @override
  ConsumerState<CategoryStoriesScreen> createState() =>
      _CategoryStoriesScreenState();
}

class _CategoryStoriesScreenState extends ConsumerState<CategoryStoriesScreen> {
  static const _sorts = [
    ('newest', 'Mới nhất'),
    ('views', 'Lượt đọc'),
    ('rating', 'Đánh giá'),
    ('chapters', 'Số chương'),
  ];

  String _sort = 'newest';
  PaginatedStories? _feed;
  bool _loading = true;
  String? _error;
  bool _loadingMore = false;

  StoryRepository get _repo => ref.read(storyRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final feed = await _repo.fetchStoriesByCategory(widget.slug, sort: _sort);
      if (!mounted) return;
      setState(() {
        _feed = feed;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final feed = _feed;
    if (feed == null || _loadingMore) return;
    if (feed.page >= feed.totalPages) return;
    setState(() => _loadingMore = true);
    try {
      final next = await _repo.fetchStoriesByCategory(
        widget.slug,
        sort: _sort,
        page: feed.page + 1,
      );
      if (!mounted) return;
      setState(() {
        final current = _feed;
        if (current == null) return;
        _feed = PaginatedStories(
          stories: [...current.stories, ...next.stories],
          total: next.total,
          page: next.page,
          perPage: next.perPage,
          totalPages: next.totalPages,
        );
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title.isEmpty ? 'Thể loại' : widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          // Sort chips
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              itemCount: _sorts.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final (value, label) = _sorts[i];
                return ChoiceChip(
                  label: Text(label),
                  selected: _sort == value,
                  visualDensity: VisualDensity.compact,
                  onSelected: _loading
                      ? null
                      : (sel) {
                          if (!sel) return;
                          setState(() => _sort = value);
                          _load();
                        },
                );
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 12),
              const Text('Không tải được truyện'),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Thử lại')),
            ],
          ),
        ),
      );
    }
    final feed = _feed!;
    if (feed.stories.isEmpty) {
      return const Center(child: Text('Chưa có truyện trong thể loại này.'));
    }
    final hasMore = feed.page < feed.totalPages;
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
        childAspectRatio: 0.46,
      ),
      itemCount: feed.stories.length + (hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= feed.stories.length) {
          return Center(
            child: _loadingMore
                ? const CircularProgressIndicator(strokeWidth: 2)
                : TextButton.icon(
                    onPressed: _loadMore,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Xem thêm'),
                  ),
          );
        }
        final s = feed.stories[i];
        return StoryCard(story: s, onTap: () => context.push('/story/${s.slug}'));
      },
    );
  }
}

// ── Tag index ────────────────────────────────────────────────────

class TagIndexScreen extends ConsumerWidget {
  const TagIndexScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(tagsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Tag')),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 48),
                const SizedBox(height: 12),
                const Text('Không tải được danh sách tag'),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => ref.invalidate(tagsProvider),
                  child: const Text('Thử lại'),
                ),
              ],
            ),
          ),
        ),
        data: (tags) => tags.isEmpty
            ? const Center(child: Text('Chưa có tag nào.'))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: tags.length,
                itemBuilder: (context, i) {
                  final t = tags[i];
                  return ListTile(
                    leading: const Icon(Icons.tag, size: 20),
                    title: Text('#${t.name}'),
                    trailing: Text(
                      '${t.storyCount}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    onTap: () =>
                        context.push('/tag/${t.slug}', extra: t.name),
                  );
                },
              ),
      ),
    );
  }
}

final tagsProvider = FutureProvider.autoDispose<List<TagInfo>>(
  (ref) => ref.watch(storyRepositoryProvider).fetchTags(),
);

// ── Truyện theo tag ──────────────────────────────────────────────

class TagStoriesScreen extends ConsumerStatefulWidget {
  const TagStoriesScreen({super.key, required this.slug, this.title = ''});

  final String slug;
  final String title;

  @override
  ConsumerState<TagStoriesScreen> createState() => _TagStoriesScreenState();
}

class _TagStoriesScreenState extends ConsumerState<TagStoriesScreen> {
  PaginatedStories? _feed;
  bool _loading = true;
  String? _error;
  bool _loadingMore = false;

  StoryRepository get _repo => ref.read(storyRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final feed = await _repo.fetchStoriesByTag(widget.slug);
      if (!mounted) return;
      setState(() {
        _feed = feed;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final feed = _feed;
    if (feed == null || _loadingMore) return;
    if (feed.page >= feed.totalPages) return;
    setState(() => _loadingMore = true);
    try {
      final next = await _repo.fetchStoriesByTag(widget.slug, page: feed.page + 1);
      if (!mounted) return;
      setState(() {
        final current = _feed;
        if (current == null) return;
        _feed = PaginatedStories(
          stories: [...current.stories, ...next.stories],
          total: next.total,
          page: next.page,
          perPage: next.perPage,
          totalPages: next.totalPages,
        );
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title.isEmpty ? 'Tag' : '#${widget.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 12),
              const Text('Không tải được truyện'),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Thử lại')),
            ],
          ),
        ),
      );
    }
    final feed = _feed!;
    if (feed.stories.isEmpty) {
      return const Center(child: Text('Chưa có truyện với tag này.'));
    }
    final hasMore = feed.page < feed.totalPages;
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
        childAspectRatio: 0.46,
      ),
      itemCount: feed.stories.length + (hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= feed.stories.length) {
          return Center(
            child: _loadingMore
                ? const CircularProgressIndicator(strokeWidth: 2)
                : TextButton.icon(
                    onPressed: _loadMore,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Xem thêm'),
                  ),
          );
        }
        final s = feed.stories[i];
        return StoryCard(story: s, onTap: () => context.push('/story/${s.slug}'));
      },
    );
  }
}