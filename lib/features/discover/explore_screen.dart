import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../repositories/story_repository.dart';
import '../home/widgets/story_card.dart';
import 'browse_screens.dart' show categoriesProvider, tagsProvider;

/// Khám phá — lọc truyện theo sort / trạng thái / thể loại nội dung
/// (đối chiếu trang web `/kham-pha`). Dùng `GET /api/v1/mobile/stories`
/// với các filter có sẵn.
class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  // Sort giống web /kham-pha: fresh (Mới đăng) / hot (Đang hot) / views
  // (Đọc nhiều) / rating (Đánh giá) / chapters (Dài nhất). Trước đây có
  // 'completed' làm sort — trùng nghĩa với filter Trạng thái "Hoàn thành"
  // nên đã bỏ.
  static const _sorts = [
    ('fresh', 'Mới nhất'),
    ('hot', 'Hot'),
    ('views', 'Lượt đọc'),
    ('rating', 'Đánh giá'),
    ('chapters', 'Dài nhất'),
  ];

  static const _statuses = [
    (null, 'Tất cả'),
    ('ongoing', 'Đang ra'),
    ('completed', 'Hoàn thành'),
    ('hiatus', 'Tạm dừng'),
  ];

  static const _contentTypes = [
    (null, 'Tất cả'),
    ('text', 'Truyện chữ'),
    ('visual', 'Bách khoa'),
    ('manga', 'Manga'),
    ('chat', 'Truyện chat'),
    ('video', 'Video'),
  ];

  String _sort = 'fresh';
  String? _status;
  String? _contentType;
  // Multi-filter AND (mirror web /kham-pha): truyện phải thuộc TẤT CẢ
  // thể loại/tag đã chọn. Set giữ slug; thứ tự không quan trọng vì
  // backend AND theo EXISTS.
  final Set<String> _catSlugs = {};
  final Set<String> _tagSlugs = {};
  PaginatedStories? _feed;
  bool _loading = true;
  String? _error;
  bool _loadingMore = false;
  // Epoch — đổi filter khi đang loadMore sẽ hủy kết quả cũ.
  int _epoch = 0;

  StoryRepository get _repo => ref.read(storyRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final feed = await _repo.listStories(
        sort: _sort,
        status: _status,
        contentType: _contentType,
        categories: _catSlugs.toList(),
        tags: _tagSlugs.toList(),
      );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _feed = feed;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _epoch) return;
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
    final epoch = _epoch;
    setState(() => _loadingMore = true);
    try {
      final next = await _repo.listStories(
        sort: _sort,
        status: _status,
        contentType: _contentType,
        categories: _catSlugs.toList(),
        tags: _tagSlugs.toList(),
        page: feed.page + 1,
      );
      if (!mounted || epoch != _epoch) return;
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
      if (mounted && epoch == _epoch) {
        setState(() => _loadingMore = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final catsAsync = ref.watch(categoriesProvider);
    final tagsAsync = ref.watch(tagsProvider);
    final hasMulti = _catSlugs.isNotEmpty || _tagSlugs.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Khám phá'),
        actions: [
          if (hasMulti)
            TextButton(
              onPressed: () {
                setState(() {
                  _catSlugs.clear();
                  _tagSlugs.clear();
                });
                _load();
              },
              child: const Text('Xoá lọc'),
            ),
        ],
      ),
      body: Column(
        children: [
          _FilterRow(
            title: 'Sắp xếp',
            options: _sorts,
            selected: _sort,
            onSelect: (v) {
              setState(() => _sort = v);
              _load();
            },
          ),
          _FilterRow(
            title: 'Trạng thái',
            options: _statuses,
            selected: _status,
            onSelect: (v) {
              setState(() => _status = v);
              _load();
            },
          ),
          _FilterRow(
            title: 'Nội dung',
            options: _contentTypes,
            selected: _contentType,
            onSelect: (v) {
              setState(() => _contentType = v);
              _load();
            },
          ),
          _MultiFilterRow(
            title: 'Thể loại',
            async: catsAsync,
            getSlug: (c) => c.slug,
            getLabel: (c) => c.name,
            selected: _catSlugs,
            onToggle: (slug, sel) {
              setState(() {
                if (sel) {
                  _catSlugs.add(slug);
                } else {
                  _catSlugs.remove(slug);
                }
              });
              _load();
            },
          ),
          _MultiFilterRow(
            title: 'Tag',
            async: tagsAsync,
            getSlug: (t) => t.slug,
            getLabel: (t) => '#${t.name}',
            selected: _tagSlugs,
            onToggle: (slug, sel) {
              setState(() {
                if (sel) {
                  _tagSlugs.add(slug);
                } else {
                  _tagSlugs.remove(slug);
                }
              });
              _load();
            },
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
              FilledButton(
                onPressed: () => _load(),
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }
    final feed = _feed!;
    if (feed.stories.isEmpty) {
      return const Center(child: Text('Không có truyện phù hợp.'));
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

/// Một hàng filter ĐA CHỌN (thể loại / tag, AND): mỗi chip toggle độc lập.
/// Ẩn cả hàng khi danh sách lỗi/rỗng để không chiếm chỗ.
class _MultiFilterRow<T> extends StatelessWidget {
  const _MultiFilterRow({
    required this.title,
    required this.async,
    required this.getSlug,
    required this.getLabel,
    required this.selected,
    required this.onToggle,
  });

  final String title;
  final AsyncValue<List<T>> async;
  final String Function(T) getSlug;
  final String Function(T) getLabel;
  final Set<String> selected;
  final void Function(String slug, bool sel) onToggle;

  @override
  Widget build(BuildContext context) {
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 0, 0),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  // Nhãn phân biệt hàng ĐA CHỌN với hàng chọn 1 (_FilterRow):
                  // user từng nhầm checkmark giống nhau là cùng 1 kiểu chọn.
                  Text(
                    selected.isEmpty
                        ? 'đa chọn'
                        : 'đa chọn (${selected.length})',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final slug = getSlug(items[i]);
                      final sel = selected.contains(slug);
                      return FilterChip(
                        label: Text(getLabel(items[i])),
                        selected: sel,
                        visualDensity: VisualDensity.compact,
                        onSelected: (v) => onToggle(slug, v),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
/// Một hàng filter (tiêu đề + chips cuộn ngang). `T` là kiểu giá trị
/// (String hoặc String? với null = "Tất cả").
class _FilterRow<T> extends StatelessWidget {
  const _FilterRow({
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final String title;
  final List<(T, String)> options;
  final T? selected;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 0, 0),
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: options.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final (value, label) = options[i];
                  return ChoiceChip(
                    label: Text(label),
                    selected: selected == value,
                    visualDensity: VisualDensity.compact,
                    onSelected: (sel) {
                      if (sel) onSelect(value);
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}