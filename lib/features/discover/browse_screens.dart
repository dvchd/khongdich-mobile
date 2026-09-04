import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../repositories/story_repository.dart';
import '../home/widgets/story_card.dart';
import '../search/search_screen.dart' show SearchFilters;

/// Màn thể loại + tag chung: index + danh sách truyện theo thể loại/tag.
/// Đối chiếu các trang web `/the-loai` + `/tag`.

// ── Thể loại index ────────────────────────────────────────────────

class CategoryIndexScreen extends ConsumerStatefulWidget {
  const CategoryIndexScreen({super.key});

  @override
  ConsumerState<CategoryIndexScreen> createState() =>
      _CategoryIndexScreenState();
}

class _CategoryIndexScreenState extends ConsumerState<CategoryIndexScreen> {
  bool _selecting = false;
  final Set<String> _sel = {};
  final Map<String, String> _names = {};

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(categoriesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Thể loại'),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              _selecting = !_selecting;
              _sel.clear();
            }),
            child: Text(_selecting ? 'Huỷ' : 'Chọn nhiều'),
          ),
        ],
      ),
      bottomNavigationBar: _selecting && _sel.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: () {
                    final slugs = _sel.toList();
                    context.push(
                      '/search',
                      extra: SearchFilters(
                        categorySlugs: slugs,
                        categoryNames:
                            slugs.map((s) => _names[s] ?? s).toList(),
                      ),
                    );
                  },
                  child: Text('Xem truyện kết hợp (${_sel.length})'),
                ),
              ),
            )
          : null,
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
        data: (cats) {
          for (final c in cats) {
            _names[c.slug] = c.name;
          }
          return Column(
            children: [
              if (_selecting)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    'Tick nhiều thể loại — chỉ hiện truyện thuộc TẤT CẢ.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: cats.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c = cats[i];
                    if (_selecting) {
                      return CheckboxListTile(
                        secondary:
                            const Icon(Icons.category_outlined),
                        title: Text(c.name),
                        subtitle: c.description.isNotEmpty
                            ? Text(
                                c.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        value: _sel.contains(c.slug),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _sel.add(c.slug);
                          } else {
                            _sel.remove(c.slug);
                          }
                        }),
                      );
                    }
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
                      onTap: () => context.push(
                        '/category/${c.slug}',
                        extra: c.name,
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
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
      return const Center(child: Text('Chưa có truyện nào.'));
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

// ── Danh hiệu index ──────────────────────────────────────────────

class DanhIndexScreen extends ConsumerWidget {
  const DanhIndexScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(danhsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Danh')),
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
                const Text('Không tải được danh sách danh hiệu'),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => ref.invalidate(danhsProvider),
                  child: const Text('Thử lại'),
                ),
              ],
            ),
          ),
        ),
        data: (danhs) => danhs.isEmpty
            ? const Center(child: Text('Chưa có danh hiệu nào.'))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: danhs.length,
                itemBuilder: (context, i) {
                  final d = danhs[i];
                  // Ảnh danh hiệu là ảnh NGANG dài — hiển thị full width
                  // như web, tên + số truyện nằm ở dòng dưới ảnh.
                  return InkWell(
                    onTap: () => context.push('/danh/${d.id}'),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (d.imageUrl.isEmpty)
                            SizedBox(
                              height: 64,
                              child: Center(
                                child: Icon(
                                  d.revealed
                                      ? Icons.workspace_premium_outlined
                                      : Icons.lock_outline,
                                  size: 28,
                                  color: d.revealed
                                      ? null
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                ),
                              ),
                            )
                          else
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: CachedNetworkImage(
                                imageUrl: d.imageUrl,
                                width: double.infinity,
                                height: 64,
                                fit: BoxFit.contain,
                                placeholder: (_, __) => const SizedBox(
                                  height: 64,
                                  child: Center(
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                ),
                                errorWidget: (_, __, ___) => const SizedBox(
                                  height: 64,
                                  child: Center(
                                    child: Icon(
                                      Icons.workspace_premium_outlined,
                                      size: 28,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    d.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                ),
                                Text(
                                  '${d.storyCount} truyện',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

final danhsProvider = FutureProvider.autoDispose<List<DanhSummary>>(
  (ref) => ref.watch(storyRepositoryProvider).fetchDanhs(),
);

// ── Truyện theo danh hiệu ────────────────────────────────────────

class DanhStoriesScreen extends ConsumerStatefulWidget {
  const DanhStoriesScreen({super.key, required this.id});

  final int id;

  @override
  ConsumerState<DanhStoriesScreen> createState() => _DanhStoriesScreenState();
}

class _DanhStoriesScreenState extends ConsumerState<DanhStoriesScreen> {
  DanhStoriesPayload? _payload;
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
      final p = await _repo.fetchStoriesByDanh(widget.id);
      if (!mounted) return;
      setState(() {
        _payload = p;
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
    final p = _payload;
    if (p == null || _loadingMore) return;
    if (p.page >= p.totalPages) return;
    setState(() => _loadingMore = true);
    try {
      final next = await _repo.fetchStoriesByDanh(widget.id, page: p.page + 1);
      if (!mounted) return;
      setState(() {
        final cur = _payload;
        if (cur == null) return;
        _payload = DanhStoriesPayload(
          danh: cur.danh,
          stories: [...cur.stories, ...next.stories],
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
    final danh = _payload?.danh;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          danh?.name.isNotEmpty == true ? danh!.name : 'Danh hiệu',
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
    final p = _payload!;
    final hasMore = p.page < p.totalPages;
    return Column(
      children: [
        if (p.danh.imageUrl.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: CachedNetworkImage(
              imageUrl: p.danh.imageUrl,
              width: double.infinity,
              height: 64,
              fit: BoxFit.contain,
              placeholder: (_, __) => const SizedBox(
                height: 64,
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              errorWidget: (_, __, ___) => const SizedBox.shrink(),
            ),
          )
        else if (!p.danh.revealed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              height: 64,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Center(
                child: Icon(
                  Icons.lock_outline,
                  size: 28,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${p.total} truyện mang danh hiệu này',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        Expanded(
          child: p.stories.isEmpty
              ? const Center(child: Text('Chưa có truyện mang danh hiệu này.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.46,
                  ),
                  itemCount: p.stories.length + (hasMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= p.stories.length) {
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
                    final s = p.stories[i];
                    return StoryCard(
                      story: s,
                      onTap: () => context.push('/story/${s.slug}'),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ── Tag index ────────────────────────────────────────────────────

class TagIndexScreen extends ConsumerStatefulWidget {
  const TagIndexScreen({super.key});

  @override
  ConsumerState<TagIndexScreen> createState() => _TagIndexScreenState();
}

class _TagIndexScreenState extends ConsumerState<TagIndexScreen> {
  bool _selecting = false;
  final Set<String> _sel = {};
  final Map<String, String> _names = {};

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(tagsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tag'),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              _selecting = !_selecting;
              _sel.clear();
            }),
            child: Text(_selecting ? 'Huỷ' : 'Chọn nhiều'),
          ),
        ],
      ),
      bottomNavigationBar: _selecting && _sel.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: () {
                    final slugs = _sel.toList();
                    context.push(
                      '/search',
                      extra: SearchFilters(
                        tagSlugs: slugs,
                        tagNames: slugs.map((s) => _names[s] ?? s).toList(),
                      ),
                    );
                  },
                  child: Text('Xem truyện kết hợp (${_sel.length})'),
                ),
              ),
            )
          : null,
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
        data: (tags) {
          if (tags.isEmpty) {
            return const Center(child: Text('Chưa có tag nào.'));
          }
          for (final t in tags) {
            _names[t.slug] = t.name;
          }
          return Column(
            children: [
              if (_selecting)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    'Tick nhiều tag — chỉ hiện truyện có TẤT CẢ.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: tags.length,
                  itemBuilder: (context, i) {
                    final t = tags[i];
                    if (_selecting) {
                      return CheckboxListTile(
                        secondary: const Icon(Icons.tag, size: 20),
                        title: Text('#${t.name}'),
                        subtitle: t.storyCount > 0
                            ? Text('${t.storyCount} truyện')
                            : null,
                        value: _sel.contains(t.slug),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _sel.add(t.slug);
                          } else {
                            _sel.remove(t.slug);
                          }
                        }),
                      );
                    }
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
            ],
          );
        },
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
      return const Center(child: Text('Chưa có truyện nào.'));
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