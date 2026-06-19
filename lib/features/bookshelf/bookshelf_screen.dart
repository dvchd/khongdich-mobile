import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/observability/app_logger.dart';
import '../../models/story.dart';
import '../../repositories/story_repository.dart';
import '../home/widgets/story_card.dart';

/// Bookshelf — 4 list types (reading / completed / plan_to_read / favorite).
/// Plan §5.6.
///
/// For MVP: bookmarks live locally in Drift (`local_bookmarks`). When the
/// user is authenticated we additionally cache the server's bookmark
/// snapshot via `POST /api/v1/bookmarks/{story_id}` (toggle) and
/// `GET /hx/studio-bookmarks` (list — HTML fragment).
class BookshelfScreen extends ConsumerStatefulWidget {
  const BookshelfScreen({super.key});

  @override
  ConsumerState<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends ConsumerState<BookshelfScreen> {
  int _tab = 0;

  static const _tabs = [
    ('reading', 'Đang đọc', Icons.menu_book),
    ('completed', 'Đã đọc xong', Icons.check_circle_outline),
    ('plan_to_read', 'Sẽ đọc', Icons.bookmark_outline),
    ('favorite', 'Yêu thích', Icons.favorite_outline),
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(bookshelfProvider.notifier).refresh());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(bookshelfProvider);
    final currentListType = _tabs[_tab].$1;
    final items = state.valueOrNull
            ?.where((b) => b.listType == currentListType)
            .toList() ??
        const [];
    return Scaffold(
      appBar: AppBar(title: const Text('Tủ truyện')),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(_tabs[i].$2),
                      avatar: Icon(_tabs[i].$3, size: 18),
                      selected: _tab == i,
                      onSelected: (_) => setState(() => _tab = i),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(bookshelfProvider.notifier).refresh(),
              child: items.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 120),
                        _EmptyBookshelf(),
                      ],
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.62,
                      ),
                      padding: const EdgeInsets.all(16),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final b = items[i];
                        final story = StorySummary(
                          id: b.storyId,
                          title: b.storyId,
                          slug: b.storyId,
                          coverUrl: null,
                          author: '',
                          categories: const [],
                          tags: const [],
                          contentTypes: const ['text'],
                        );
                        return StoryCard(
                          story: story,
                          onTap: () => context.push('/story/${b.storyId}'),
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

class _EmptyBookshelf extends StatelessWidget {
  const _EmptyBookshelf();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bookmark_border,
              size: 64,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          const Text('Chưa có truyện trong tủ.'),
          const SizedBox(height: 4),
          Text(
            'Đánh dấu truyện từ trang chi tiết để lưu vào đây.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---- Bookshelf state ----

final bookshelfProvider =
    StateNotifierProvider<BookshelfNotifier, AsyncValue<List<LocalBookmark>>>(
  (ref) => BookshelfNotifier(ref),
);

class BookshelfNotifier
    extends StateNotifier<AsyncValue<List<LocalBookmark>>> {
  BookshelfNotifier(this._ref) : super(const AsyncValue.loading());
  final Ref _ref;

  Future<void> refresh() async {
    final db = _ref.read(appDatabaseProvider);
    try {
      final bookmarks = await db.getBookmarks();
      state = AsyncValue.data(bookmarks);
    } catch (e, s) {
      AppLogger.warning('BookshelfNotifier.refresh failed', e, s);
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> toggle(String storyId, String listType) async {
    final db = _ref.read(appDatabaseProvider);
    final existing = (await db.getBookmarks())
        .where((b) => b.storyId == storyId)
        .toList();
    if (existing.any((b) => b.listType == listType)) {
      await db.deleteBookmark(storyId);
      try {
        final repo = _ref.read(storyRepositoryProvider);
        await repo.toggleBookmark(storyId, listType: listType);
      } catch (_) {/* offline — local is source of truth */}
    } else {
      await db.upsertBookmark(LocalBookmarksCompanion.insert(
        storyId: storyId,
        listType: listType,
        updatedAt: DateTime.now().toIso8601String(),
      ));
      try {
        final repo = _ref.read(storyRepositoryProvider);
        await repo.toggleBookmark(storyId, listType: listType);
      } catch (_) {/* offline */}
    }
    await refresh();
  }
}
