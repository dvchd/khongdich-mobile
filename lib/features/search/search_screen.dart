import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../core/observability/app_logger.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/app_retry_view.dart';
import '../../models/story.dart';
import '../../repositories/story_repository.dart';
import '../bookshelf/bookshelf_screen.dart'
    show bookshelfTabIntentProvider, kBookshelfDownloadedTabIndex;
import '../discover/browse_screens.dart'
    show categoriesProvider, tagsProvider;
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

  Future<void> _maybeRedirectOffline(Object error) async {
    if (_redirected) return;
    // Chỉ redirect khi lỗi là lỗi MẠNG (offline/timeout) — lỗi server
    // (5xx) phải giữ lại màn hình lỗi + nút "Thử lại". Cùng rule với
    // home screen (DioException KHÔNG có response = không nhận được
    // HTTP response nào → chắc chắn lỗi mạng).
    final isNetworkError =
        error is DioException && error.response == null;
    if (!isNetworkError) return;
    // Only redirect if there's at least one downloaded chapter —
    // otherwise the offline library is empty and redirecting would
    // just show another empty state.
    //
    // PHẢI await .future của stream provider — trước đây dùng
    // ref.read().value: lúc random load fail, stream chưa từng được
    // watch → valueOrNull == null → tưởng "chưa có truyện tải" → không
    // redirect dù DB có chương đã tải (home đã sửa, search còn sót).
    try {
      final downloads =
          await ref.read(offlineLibraryStreamProvider.future);
      if (downloads.isEmpty || !mounted) return;
    } catch (_) {
      return; // DB lỗi — không redirect được, giữ màn hình lỗi.
    }
    _redirected = true;
    ref.read(bookshelfTabIntentProvider.notifier).state =
        kBookshelfDownloadedTabIndex;
    context.go('/bookshelf');
  }

  Future<void> _runSearch(String q) async {
    final query = q.trim();
    final notifier = ref.read(searchProvider.notifier);
    if (query.isEmpty && notifier.filters.isEmpty) {
      setState(() => _searched = false);
      notifier.clear();
      return;
    }
    setState(() => _searched = true);
    await notifier.run(query);
  }

  /// Đổi filter (từ chip/bottom sheet) → chạy lại kết quả ngay.
  Future<void> _updateFilter(SearchFilters next) async {
    setState(() => _searched = true);
    await ref.read(searchProvider.notifier).updateFilter(next);
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    final randomState = ref.watch(randomStoriesProvider);
    // Khi fetch truyện ngẫu nhiên fail (offline) → auto-redirect sang tab
    // "Đã tải" của tủ truyện. ref.listen thay vì side-effect trong build —
    // trước đây khiOrNull + Future.microtask chạy lại mỗi lần rebuild
    // (đổi theme, gõ text...) như home screen từng bị.
    ref.listen(randomStoriesProvider, (prev, next) {
      next.whenOrNull(error: (e, _) => _maybeRedirectOffline(e));
    });
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
            const SizedBox(height: 8),
            // Bộ lọc tương tự web /tim-kiem: sắp xếp / trạng thái /
            // kiểu truyện / thể loại / tag — chip mở bottom sheet chọn.
            // Filters đọc từ notifier; mọi lần chọn filter đều chạy lại
            // search → state đổi → build lại → chip hiển thị đúng lựa chọn.
            _SearchFilterBar(
              filters: ref.read(searchProvider.notifier).filters,
              onChanged: _updateFilter,
            ),
            const SizedBox(height: 8),
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
      SearchError(:final message) => AppRetryView(
          icon: Icons.search_off,
          message: 'Tìm kiếm thất bại.',
          detail: message,
          onRetry: () =>
              ref.read(searchProvider.notifier).run(_controller.text),
        ),
      SearchSuccess(:final result) => result.stories.isEmpty
          ? const _EmptyState(
              icon: Icons.inbox_outlined,
              message: 'Không có kết quả phù hợp.',
            )
          : CustomScrollView(
              slivers: [
                if (result.total > 0)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${formatCount(result.total)} truyện',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                SliverGrid(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    // Cover AspectRatio 2:3 + title 2 dòng + author 1 dòng.
                    childAspectRatio: 0.52,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => StoryCard(
                      story: result.stories[i],
                      onTap: () =>
                          context.push('/story/${result.stories[i].slug}'),
                    ),
                    childCount: result.stories.length,
                  ),
                ),
                if (result.page < result.totalPages)
                  SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
                        child: OutlinedButton(
                          onPressed: () => ref
                              .read(searchProvider.notifier)
                              .loadMore(),
                          child: Text(
                            'Xem thêm (${result.total - result.stories.length} còn lại)',
                          ),
                        ),
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
    };
  }

  Widget _buildRandom(AsyncValue<List<StorySummary>> state) {
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => AppRetryView(
        message: 'Không tải được truyện.',
        detail: '$e',
        onRetry: () => ref.read(randomStoriesProvider.notifier).load(),
      ),
      data: (stories) => RefreshIndicator(
        // Kéo xuống khi chưa tìm kiếm → load lại 12 truyện ngẫu nhiên
        // KHÁC (seed mới mỗi lần, xem RandomStoriesNotifier.load).
        onRefresh: () => ref.read(randomStoriesProvider.notifier).load(),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
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
                // Cover AspectRatio 2:3 + title 2 dòng + author 1 dòng.
                childAspectRatio: 0.52,
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

// ─── Bộ lọc tìm kiếm (mirror web /tim-kiem) ─────────────────────

const _sortOptions = [
  ('', 'Sắp xếp: Mặc định'),
  ('newest', 'Mới nhất'),
  ('views', 'Lượt xem'),
  ('rating', 'Đánh giá'),
  ('chapters', 'Số chương'),
];

const _statusOptions = [
  ('', 'Trạng thái: Tất cả'),
  ('ongoing', 'Đang ra'),
  ('completed', 'Hoàn thành'),
];

const _typeOptions = [
  ('', 'Kiểu truyện: Tất cả'),
  ('text', '📖 Truyện chữ'),
  ('visual', '📚 Bách khoa'),
  ('manga', '🖼️ Truyện tranh'),
  ('video', '🎬 Truyện video'),
  ('chat', '💬 Truyện chat'),
];

/// Hàng chip bộ lọc nằm dưới ô tìm kiếm — mỗi chip mở bottom sheet chọn
/// (tương đương dropdown trên web). Chip Thể loại/Tag hiện tên đã chọn.
class _SearchFilterBar extends ConsumerWidget {
  const _SearchFilterBar({required this.filters, required this.onChanged});

  final SearchFilters filters;
  final Future<void> Function(SearchFilters) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selected = (filters.isEmpty) ? false : true;

    Widget chip({
      required String label,
      required Future<void> Function() onTap,
      required bool active,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ActionChip(
          label: Text(label),
          labelStyle: TextStyle(
            fontSize: 12.5,
            color: active ? scheme.onPrimary : scheme.onSurface,
          ),
          backgroundColor: active ? scheme.primary : null,
          visualDensity: VisualDensity.compact,
          onPressed: () async => onTap(),
        ),
      );
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          chip(
            label: _sortOptions
                .firstWhere((o) => o.$1 == filters.sort,
                    orElse: () => _sortOptions.first)
                .$2,
            active: filters.sort.isNotEmpty,
            onTap: () => _pickOption(
              context,
              title: 'Sắp xếp',
              options: _sortOptions,
              current: filters.sort,
              onSelect: (v) => onChanged(filters.copyWith(sort: v)),
            ),
          ),
          chip(
            label: _statusOptions
                .firstWhere((o) => o.$1 == filters.status,
                    orElse: () => _statusOptions.first)
                .$2,
            active: filters.status.isNotEmpty,
            onTap: () => _pickOption(
              context,
              title: 'Trạng thái',
              options: _statusOptions,
              current: filters.status,
              onSelect: (v) => onChanged(filters.copyWith(status: v)),
            ),
          ),
          chip(
            label: _typeOptions
                .firstWhere((o) => o.$1 == filters.contentType,
                    orElse: () => _typeOptions.first)
                .$2,
            active: filters.contentType.isNotEmpty,
            onTap: () => _pickOption(
              context,
              title: 'Kiểu truyện',
              options: _typeOptions,
              current: filters.contentType,
              onSelect: (v) => onChanged(filters.copyWith(contentType: v)),
            ),
          ),
          chip(
            label: filters.categorySlug.isEmpty
                ? '🏷 Thể loại'
                : '🏷 ${filters.categoryName}',
            active: filters.categorySlug.isNotEmpty,
            onTap: () => _pickCategories(context, ref, filters, onChanged),
          ),
          chip(
            label: filters.tagSlug.isEmpty ? '# Tag' : '# ${filters.tagName}',
            active: filters.tagSlug.isNotEmpty,
            onTap: () => _pickTags(context, ref, filters, onChanged),
          ),
          // Nút xoá toàn bộ filter khi có filter đang chọn.
          if (selected)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                avatar: Icon(Icons.close, size: 16, color: scheme.onSurface),
                label: const Text('Xoá lọc'),
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurface,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () async => onChanged(const SearchFilters()),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bottom sheet chọn 1 trong danh sách option cố định (sort/status/type).
Future<void> _pickOption(
  BuildContext context, {
  required String title,
  required List<(String, String)> options,
  required String current,
  required Future<void> Function(String) onSelect,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final (value, label) in options)
            ListTile(
              title: Text(label),
              trailing: current == value
                  ? const Icon(Icons.check, color: Color(0xFF2563EB))
                  : null,
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await onSelect(value);
              },
            ),
        ],
      ),
    ),
  );
}

/// Bottom sheet chọn thể loại (danh sách từ API, có nút xoá chọn).
Future<void> _pickCategories(
  BuildContext context,
  WidgetRef ref,
  SearchFilters filters,
  Future<void> Function(SearchFilters) onChanged,
) async {
  final categories = ref.read(categoriesProvider).value ?? [];
  final chosen = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          if (filters.categorySlug.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.close, color: Colors.red),
              title: const Text('Bỏ chọn thể loại'),
              onTap: () => Navigator.of(sheetContext).pop('__clear__'),
            ),
          for (final c in categories)
            ListTile(
              title: Text(c.name),
              trailing: filters.categorySlug == c.slug
                  ? const Icon(Icons.check, color: Color(0xFF2563EB))
                  : null,
              onTap: () => Navigator.of(sheetContext).pop(c.slug),
            ),
        ],
      ),
    ),
  );
  if (chosen == null) return;
  if (chosen == '__clear__') {
    await onChanged(filters.copyWith(
      categorySlug: '',
      categoryName: '',
    ));
    return;
  }
  final cat = categories.firstWhere((c) => c.slug == chosen);
  await onChanged(filters.copyWith(
    categorySlug: cat.slug,
    categoryName: cat.name,
  ));
}

/// Bottom sheet chọn tag (danh sách từ API, có nút xoá chọn).
Future<void> _pickTags(
  BuildContext context,
  WidgetRef ref,
  SearchFilters filters,
  Future<void> Function(SearchFilters) onChanged,
) async {
  final tags = ref.read(tagsProvider).value ?? [];
  final chosen = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          if (filters.tagSlug.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.close, color: Colors.red),
              title: const Text('Bỏ chọn tag'),
              onTap: () => Navigator.of(sheetContext).pop('__clear__'),
            ),
          for (final t in tags)
            ListTile(
              title: Text(t.name),
              trailing: filters.tagSlug == t.slug
                  ? const Icon(Icons.check, color: Color(0xFF2563EB))
                  : null,
              onTap: () => Navigator.of(sheetContext).pop(t.slug),
            ),
        ],
      ),
    ),
  );
  if (chosen == null) return;
  if (chosen == '__clear__') {
    await onChanged(filters.copyWith(tagSlug: '', tagName: ''));
    return;
  }
  final tag = tags.firstWhere((t) => t.slug == chosen);
  await onChanged(filters.copyWith(tagSlug: tag.slug, tagName: tag.name));
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

/// Bộ lọc tìm kiếm — mirror web /tim-kiem (sort/status/content_type/
/// category/tag). Đổi filter là chạy lại ngay nếu đang trong chế độ
/// kết quả (hoặc có filter nào active → duyệt theo filter).
class SearchFilters {
  const SearchFilters({
    this.sort = '',
    this.status = '',
    this.contentType = '',
    this.categorySlug = '',
    this.categoryName = '',
    this.tagSlug = '',
    this.tagName = '',
  });

  final String sort; // '' | views | rating | newest | chapters
  final String status; // '' | ongoing | completed
  final String contentType; // '' | text | visual | manga | video | chat
  final String categorySlug;
  final String categoryName;
  final String tagSlug;
  final String tagName;

  bool get isEmpty =>
      sort.isEmpty &&
      status.isEmpty &&
      contentType.isEmpty &&
      categorySlug.isEmpty &&
      tagSlug.isEmpty;

  SearchFilters copyWith({
    String? sort,
    String? status,
    String? contentType,
    String? categorySlug,
    String? categoryName,
    String? tagSlug,
    String? tagName,
  }) =>
      SearchFilters(
        sort: sort ?? this.sort,
        status: status ?? this.status,
        contentType: contentType ?? this.contentType,
        categorySlug: categorySlug ?? this.categorySlug,
        categoryName: categoryName ?? this.categoryName,
        tagSlug: tagSlug ?? this.tagSlug,
        tagName: tagName ?? this.tagName,
      );
}

class SearchNotifier extends StateNotifier<SearchState> {
  SearchNotifier(this._ref) : super(const SearchIdle());
  final Ref _ref;
  // Request token chống race: submit "abc" rồi "xyz" nhanh — response
  // của "abc" về sau "xyz" sẽ bị bỏ qua (last-completion-wins sai).
  int _latestRequestId = 0;

  SearchFilters _filters = const SearchFilters();
  SearchFilters get filters => _filters;

  /// Từ khoá của lần chạy gần nhất — dùng cho retry + loadMore.
  String _query = '';

  /// Kết quả đã tích luỹ (cho loadMore phân trang).
  List<SearchResult> _pages = [];

  Future<void> run(String q) async {
    _query = q.trim();
    _pages = [];
    final requestId = ++_latestRequestId;
    state = const SearchLoading();
    try {
      final repo = _ref.read(storyRepositoryProvider);
      final result = await repo.search(
        _query,
        limit: 20,
        page: 1,
        sort: _filters.sort,
        status: _filters.status,
        contentType: _filters.contentType,
        category: _filters.categorySlug,
        tag: _filters.tagSlug,
      );
      if (requestId != _latestRequestId) return;
      _pages = [result];
      state = SearchSuccess(_mergedPages());
    } catch (e) {
      if (requestId != _latestRequestId) return;
      state = SearchError('$e');
    }
  }

  /// Đổi bộ lọc → chạy lại ngay (user đang xem kết quả). Gọi từ UI khi
  /// chọn filter trong bottom sheet.
  Future<void> updateFilter(SearchFilters next) async {
    _filters = next;
    // Có filter hoặc đã từng tìm → chạy; chưa tìm + filter rỗng → idle.
    if (_filters.isEmpty && _query.isEmpty) {
      _latestRequestId++;
      state = const SearchIdle();
      return;
    }
    await run(_query);
  }

  /// Tải trang tiếp theo (nút "Xem thêm" dưới lưới kết quả).
  Future<void> loadMore() async {
    final current = state;
    if (current is! SearchSuccess) return;
    if (current.result.page >= current.result.totalPages) return;
    final requestId = ++_latestRequestId;
    try {
      final repo = _ref.read(storyRepositoryProvider);
      final next = await repo.search(
        _query,
        limit: 20,
        page: current.result.page + 1,
        sort: _filters.sort,
        status: _filters.status,
        contentType: _filters.contentType,
        category: _filters.categorySlug,
        tag: _filters.tagSlug,
      );
      if (requestId != _latestRequestId) return;
      _pages.add(next);
      state = SearchSuccess(_mergedPages());
    } catch (e) {
      // Giữ kết quả cũ — nút Xem thêm bấm lại được.
      AppLogger.debug('Search: loadMore failed ($e)');
    }
  }

  SearchResult _mergedPages() {
    final all = [for (final p in _pages) ...p.stories];
    final last = _pages.last;
    return SearchResult(
      stories: all,
      posts: const [],
      total: last.total,
      page: last.page,
      perPage: last.perPage,
      totalPages: last.totalPages,
    );
  }

  void clear() {
    _latestRequestId++;
    _query = '';
    _pages = [];
    state = const SearchIdle();
  }
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
      // Seed NGẪU NHIÊN mỗi lần load: backend sort=random dùng
      // ORDER BY md5(id || seed) — deterministic theo seed. Seed cố
      // định → kéo refresh trả y hệt bộ truyện cũ.
      final seed = DateTime.now().microsecondsSinceEpoch.toString();
      final page =
          await repo.listStories(sort: 'random', perPage: 12, seed: seed);
      state = AsyncValue.data(page.stories);
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }
}
