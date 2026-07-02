import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/network/api_client.dart';
import '../../core/observability/app_logger.dart';
import '../../models/story.dart';
import '../../repositories/story_repository.dart';
import '../downloads/offline_library_screen.dart' show offlineLibraryStreamProvider;
import '../home/widgets/story_card.dart';

/// Index of the "Downloaded" tab. The home screen sets this as the
/// bookshelf intent when the device is offline so the user lands on
/// their offline library directly.
const kBookshelfDownloadedTabIndex = 5;

/// Which tab to show by default (used for offline auto-redirect).
/// Defaults to 0 (the "All" tab) when online.
final bookshelfTabIntentProvider = StateProvider<int>((ref) => 0);

/// Bookshelf — 6 tabs:
///   0. Tất cả      (merged bookshelf + downloaded, deduped by story id)
///   1. Đang đọc
///   2. Đã đọc xong
///   3. Sẽ đọc
///   4. Yêu thích
///   5. Đã tải      (offline library)
///
/// Default tab is 0 (All) when online. When the home screen detects
/// no network, it sets [bookshelfTabIntentProvider] to
/// [kBookshelfDownloadedTabIndex] so the bookshelf opens directly on
/// the offline library.
class BookshelfScreen extends ConsumerStatefulWidget {
  const BookshelfScreen({super.key});

  @override
  ConsumerState<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends ConsumerState<BookshelfScreen> {
  int _tab = 0;

  static const _tabs = [
    ('all', 'Tất cả', Icons.apps),
    ('reading', 'Đang đọc', Icons.menu_book),
    ('completed', 'Đã đọc xong', Icons.check_circle_outline),
    ('plan_to_read', 'Sẽ đọc', Icons.bookmark_outline),
    ('favorite', 'Yêu thích', Icons.favorite_outline),
    ('downloaded', 'Đã tải', Icons.download_done),
  ];

  @override
  void initState() {
    super.initState();
    // Pick up the intent provider once (e.g. offline redirect sets it
    // to kBookshelfDownloadedTabIndex so the user lands on offline lib).
    final intent = ref.read(bookshelfTabIntentProvider);
    if (intent != 0) {
      _tab = intent;
      Future.microtask(() => ref.read(bookshelfTabIntentProvider.notifier).state = 0);
    }
    Future.microtask(() => ref.read(bookshelfProvider.notifier).refresh());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(bookshelfProvider);
    final downloadsAsync = ref.watch(offlineLibraryStreamProvider);

    final chapters = downloadsAsync.valueOrNull ?? [];
    // Set of story IDs that have at least one chapter downloaded —
    // used for two things:
    //   1. Auto-routing bookshelf cards to the offline story detail
    //      when tapped (so the user can keep browsing offline).
    //   2. StoryCard already auto-renders the green downloaded badge
    //      via its own `downloadedStoryIdsProvider` watch — that
    //      part doesn't need this local set.
    final downloadedStoryIds = chapters.map((d) => d.storyId).toSet();

    // Build StorySummary list for downloaded stories (one entry per story).
    final downloadedStories = <StorySummary>[];
    final seen = <String>{};
    for (final d in chapters) {
      if (seen.add(d.storyId)) {
        downloadedStories.add(StorySummary(
          id: d.storyId,
          title: d.storyTitle,
          slug: d.storySlug,
          coverUrl: d.coverUrl,
          author: d.storyAuthor ?? '',
          categories: const [],
          tags: const [],
          contentTypes: [d.contentType],
          chapterCount: chapters.where((x) => x.storyId == d.storyId).length,
        ));
      }
    }

    // Snapshot of bookmarks for the "All" tab merge — kept lazy so the
    // list-type tabs below can re-filter directly from `state.valueOrNull`.
    final bookmarks = state.valueOrNull ?? [];

    final isAllTab = _tab == 0;
    final isDownloadedTab = _tab == _tabs.length - 1;

    final List<StorySummary> items;
    if (isAllTab) {
      // Merge bookshelf stories + downloaded stories, dedupe by story ID.
      // Bookshelf metadata takes precedence (it has author / categories
      // from the server), but we fall back to downloaded-chapter metadata
      // for stories that exist only locally.
      final merged = <String, StorySummary>{};
      for (final b in bookmarks) {
        merged[b.storyId] = StorySummary(
          id: b.storyId,
          title: b.title,
          slug: b.slug,
          coverUrl: b.coverUrl,
          author: b.author,
          categories: const [],
          tags: const [],
          contentTypes: [b.contentType],
          chapterCount: b.chapterCount,
        );
      }
      for (final s in downloadedStories) {
        merged.putIfAbsent(s.id, () => s);
      }
      items = merged.values.toList();
    } else if (isDownloadedTab) {
      items = downloadedStories;
    } else {
      // Filter bookshelf by list_type (reading / completed /
      // plan_to_read / favorite).
      final listType = _tabs[_tab].$1;
      items = bookmarks
          .where((b) => b.listType == listType)
          .map((b) => StorySummary(
                id: b.storyId,
                title: b.title,
                slug: b.slug,
                coverUrl: b.coverUrl,
                author: b.author,
                categories: const [],
                tags: const [],
                contentTypes: [b.contentType],
                chapterCount: b.chapterCount,
              ))
          .toList();
    }

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
              onRefresh: () =>
                  ref.read(bookshelfProvider.notifier).refresh(),
              child: items.isEmpty
                  ? ListView(
                      children: [
                        SizedBox(height: 120),
                        isDownloadedTab
                            ? const _EmptyDownloads()
                            : (isAllTab
                                ? const _EmptyAll()
                                : const _EmptyBookshelf()),
                      ],
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        // Cover AspectRatio 2:3 + title 2 dòng + author 1 dòng.
                        // Trước đây 0.62 gây cover bị co khi text dài.
                        childAspectRatio: 0.52,
                      ),
                      padding: const EdgeInsets.all(16),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final s = items[i];
                        // Always show the green downloaded badge on every
                        // tab — it provides consistent visual feedback
                        // that the story is available offline, matching
                        // the user's mental model across home/search/
                        // bookshelf screens.
                        final isDownloaded =
                            downloadedStoryIds.contains(s.id);
                        return StoryCard(
                          story: s,
                          onTap: () {
                            if (isDownloadedTab) {
                              // Navigate to offline story detail instead of
                              // jumping directly into the first chapter.
                              context.push('/offline-story/${s.id}');
                              return;
                            }
                            // For "All" tab and bookshelf tabs, prefer
                            // the offline story detail when the story
                            // has been downloaded — this way the user
                            // can keep browsing even when the device is
                            // offline. Falls back to the online detail
                            // for stories that haven't been downloaded.
                            if (isDownloaded) {
                              context.push('/offline-story/${s.id}');
                              return;
                            }
                            context.push('/story/${s.slug}');
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

class _EmptyDownloads extends StatelessWidget {
  const _EmptyDownloads();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_download_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          const Text('Chưa có truyện đã tải xuống.'),
          const SizedBox(height: 4),
          Text(
            'Tải chương từ trang chi tiết truyện để đọc offline.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _EmptyAll extends StatelessWidget {
  const _EmptyAll();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          const Text('Tủ truyện đang trống.'),
          const SizedBox(height: 4),
          Text(
            'Đánh dấu truyện từ trang chi tiết hoặc tải chương để đọc offline.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
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

// ─── State ───────────────────────────────────────────────────────

final bookshelfProvider = StateNotifierProvider<BookshelfNotifier,
    AsyncValue<List<BookmarkItem>>>((ref) {
  return BookshelfNotifier(ref);
});

class BookshelfNotifier
    extends StateNotifier<AsyncValue<List<BookmarkItem>>> {
  BookshelfNotifier(this._ref) : super(const AsyncValue.loading());
  final Ref _ref;

  /// Cache of story metadata for local bookmark rendering.
  /// Key = storyId, Value = (title, slug, coverUrl, author, contentType).
  final Map<String, ({String title, String slug, String? coverUrl, String author, String contentType})> _storyCache = {};

  /// Register story metadata so the bookshelf can render local bookmarks
  /// with proper title/cover instead of raw IDs. Called from
  /// StoryDetailScreen when the user visits a story.
  void registerStory(StorySummary story) {
    _storyCache[story.id] = (
      title: story.title,
      slug: story.slug,
      coverUrl: story.coverUrl,
      author: story.author,
      contentType: story.contentTypes.isNotEmpty
          ? story.contentTypes.first
          : 'text',
    );
  }

  Future<void> refresh() async {
    try {
      final api = _ref.read(apiClientProvider).maybeWhen(
            data: (c) => c,
            orElse: () => null,
          );
      final isAuthenticated = api != null && await api.isAuthenticated();

      if (isAuthenticated) {
        final repo = _ref.read(storyRepositoryProvider);
        final page = await repo.listBookmarks(perPage: 100);
        // Cache locally for offline access.
        final db = _ref.read(appDatabaseProvider);
        for (final b in page.bookmarks) {
          await db.upsertBookmark(LocalBookmarksCompanion.insert(
            storyId: b.storyId,
            listType: b.listType,
            storyTitle: Value(b.title),
            storySlug: Value(b.slug),
            coverUrl: Value(b.coverUrl),
            author: Value(b.author),
            contentType: Value(b.contentType),
            updatedAt: b.bookmarkedAt.toIso8601String(),
          ));
        }
        state = AsyncValue.data(page.bookmarks);
      } else {
        // Local bookmarks — use the new metadata columns.
        final db = _ref.read(appDatabaseProvider);
        final locals = await db.getBookmarks();
        final items = locals.map((b) {
          final cached = _storyCache[b.storyId];
          return BookmarkItem(
            storyId: b.storyId,
            title: b.storyTitle.isNotEmpty ? b.storyTitle : (cached?.title ?? b.storyId),
            slug: b.storySlug.isNotEmpty ? b.storySlug : (cached?.slug ?? b.storyId),
            coverUrl: b.coverUrl ?? cached?.coverUrl,
            author: b.author.isNotEmpty ? b.author : (cached?.author ?? ''),
            listType: b.listType,
            contentType: b.contentType.isNotEmpty ? b.contentType : (cached?.contentType ?? 'text'),
            chapterCount: null,
            bookmarkedAt: DateTime.tryParse(b.updatedAt) ?? DateTime.now(),
          );
        }).toList();
        state = AsyncValue.data(items);
      }
    } catch (e, s) {
      AppLogger.warning('BookshelfNotifier.refresh failed, falling back to local', e, s);
      // Fall back to local bookmarks when offline / API error
      try {
        final db = _ref.read(appDatabaseProvider);
        final locals = await db.getBookmarks();
        final items = locals.map((b) {
          final cached = _storyCache[b.storyId];
          return BookmarkItem(
            storyId: b.storyId,
            title: b.storyTitle.isNotEmpty ? b.storyTitle : (cached?.title ?? b.storyId),
            slug: b.storySlug.isNotEmpty ? b.storySlug : (cached?.slug ?? b.storyId),
            coverUrl: b.coverUrl ?? cached?.coverUrl,
            author: b.author.isNotEmpty ? b.author : (cached?.author ?? ''),
            listType: b.listType,
            contentType: b.contentType.isNotEmpty ? b.contentType : (cached?.contentType ?? 'text'),
            chapterCount: null,
            bookmarkedAt: DateTime.tryParse(b.updatedAt) ?? DateTime.now(),
          );
        }).toList();
        state = AsyncValue.data(items);
      } catch (dbError) {
        state = AsyncValue.error(dbError, StackTrace.current);
      }
    }
  }

  /// Toggle a bookmark. Stores story metadata locally so the bookshelf
  /// renders proper cards even for anonymous users. If authenticated,
  /// also pushes to server.
  ///
  /// Returns `true` if the bookmark was added, `false` if removed.
  Future<bool> toggle(
    String storyId, {
    String listType = 'reading',
    String title = '',
    String slug = '',
    String? coverUrl,
    String author = '',
    String contentType = 'text',
  }) async {
    final db = _ref.read(appDatabaseProvider);
    final existing = (await db.getBookmarks())
        .where((b) => b.storyId == storyId)
        .toList();

    final wasBookmarked = existing.any((b) => b.listType == listType);

    if (wasBookmarked) {
      // Remove
      await db.deleteBookmark(storyId);
      try {
        final repo = _ref.read(storyRepositoryProvider);
        await repo.toggleBookmark(storyId, listType: listType);
      } catch (_) {/* offline */}
    } else {
      // Add — store full metadata so bookshelf renders proper cards
      await db.upsertBookmark(LocalBookmarksCompanion.insert(
        storyId: storyId,
        listType: listType,
        storyTitle: Value(title),
        storySlug: Value(slug),
        coverUrl: Value(coverUrl),
        author: Value(author),
        contentType: Value(contentType),
        updatedAt: DateTime.now().toIso8601String(),
      ));
      try {
        final repo = _ref.read(storyRepositoryProvider);
        await repo.toggleBookmark(storyId, listType: listType);
      } catch (_) {/* offline */}
    }
    await refresh();
    return !wasBookmarked;
  }
}
