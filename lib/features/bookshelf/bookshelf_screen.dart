import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/network/api_client.dart';
import '../../core/observability/app_logger.dart';
import '../../models/story.dart';
import '../../repositories/story_repository.dart';
import '../downloads/offline_library_screen.dart'
    show
        offlineLibraryStreamProvider,
        offlineStoriesMapProvider,
        offlineStoryBackfillProvider;
import '../home/widgets/story_card.dart';

/// Index of the "Downloaded" tab. The home screen sets this as the
/// bookshelf intent when the device is offline so the user lands on
/// their offline library directly.
const kBookshelfDownloadedTabIndex = 3;

/// Which tab to show by default (used for offline auto-redirect).
/// Defaults to 0 (the "All" tab) when online.
final bookshelfTabIntentProvider = StateProvider<int>((ref) => 0);

/// Bookshelf — 4 tabs:
///   0. Tất cả      (merged bookshelf + downloaded, deduped by story id)
///   1. Đang đọc    (bookmarks với list_type = reading)
///   2. Đã lưu      (toàn bộ bookmarks, mọi list_type)
///   3. Đã tải      (offline library)
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

  /// Scroll chip row tới tab đang chọn — tab "Đã tải" là tab CUỐI cùng,
  /// nằm ngoài tầm nhìn bên phải. Trước đây khi offline redirect set
  /// _tab = 5, chip row vẫn cuộn ở đầu → user không thấy tab nào đang
  /// chọn, chỉ thấy danh sách truyện đã tải.
  final ScrollController _chipsController = ScrollController();
  final List<GlobalKey> _chipKeys = List.generate(
      _tabs.length, (_) => GlobalKey());

  static const _tabs = [
    ('all', 'Tất cả'),
    ('reading', 'Đang đọc'),
    ('saved', 'Đã lưu'),
    ('downloaded', 'Đã tải'),
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
      // Scroll chip row tới tab intent (vd. "Đã tải" nằm cuối) sau
      // frame đầu — chip chưa build xong nên phải chờ postFrame.
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _ensureChipVisible(_tab));
    }
    Future.microtask(() => ref.read(bookshelfProvider.notifier).refresh());
  }

  @override
  void dispose() {
    _chipsController.dispose();
    super.dispose();
  }

  void _ensureChipVisible(int index) {
    final ctx = _chipKeys[index].currentContext;
    if (ctx == null || !mounted) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(bookshelfProvider);
    final downloadsAsync = ref.watch(offlineLibraryStreamProvider);
    // Bìa lưu local (tải kèm khi download chương) — tab Đã tải hiển thị
    // bìa y hệt online khi không có mạng.
    final offlineStories = ref.watch(offlineStoriesMapProvider).value ?? {};
    // Backfill snapshot + bìa cho download cũ (trước khi có offline_stories).
    ref.watch(offlineStoryBackfillProvider);

    final chapters = downloadsAsync.value ?? [];
    // Set of story IDs that have at least one chapter downloaded —
    // used for two things:
    //   1. Auto-routing bookshelf cards to the offline story detail
    //      when tapped (so the user can keep browsing offline).
    //   2. StoryCard already auto-renders the green downloaded badge
    //      via its own `downloadedStoryIdsProvider` watch — that
    //      part doesn't need this local set.
    final downloadedStoryIds = chapters.map((d) => d.storyId).toSet();

    // Build StorySummary list for downloaded stories (one entry per story).
    // Metadata ưu tiên snapshot offline_stories (mới + đủ cover) nếu có —
    // download cũ có thể thiếu coverUrl trong bảng chương.
    final downloadedStories = <StorySummary>[];
    final seen = <String>{};
    for (final d in chapters) {
      if (seen.add(d.storyId)) {
        final snap = offlineStories[d.storyId];
        downloadedStories.add(StorySummary(
          id: d.storyId,
          title: snap?.title ?? d.storyTitle,
          slug: snap?.slug ?? d.storySlug,
          coverUrl: snap?.coverUrl ?? d.coverUrl,
          author: snap?.author ?? d.storyAuthor ?? '',
          categories: const [],
          tags: const [],
          contentTypes: [snap?.contentType ?? d.contentType],
          chapterCount: chapters.where((x) => x.storyId == d.storyId).length,
        ));
      }
    }

    // Snapshot of bookmarks for the "All" tab merge — kept lazy so the
    // list-type tabs below can re-filter directly from `state.value`.
    final bookmarks = state.value ?? [];

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
      // Tab "Đang đọc" (1) chỉ hiện bookmark list_type = reading;
      // tab "Đã lưu" (2) hiện TOÀN BỘ bookmark (mọi list_type) —
      // user chỉ cần 2 mức: đang đọc / đã lưu lại.
      final tab = _tabs[_tab].$1;
      items = bookmarks
          .where((b) => tab == 'saved' || b.listType == 'reading')
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
            // SingleChildScrollView + Row thay vì ListView: ListView build
            // LAZY → chip "Đã tải" (cuối, ngoài tầm nhìn) chưa được build
            // → GlobalKey.currentContext == null → _ensureChipVisible
            // không scroll được trên màn hình hẹp. Row build EAGER cả 4
            // chip nên ensureVisible luôn hoạt động.
            child: SingleChildScrollView(
              controller: _chipsController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  for (var i = 0; i < _tabs.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        key: _chipKeys[i],
                        label: Text(_tabs[i].$2),
                        // Không dùng avatar icon — chip row đã dày đặc
                        // chữ; icon lặp lại ý nghĩa nhãn, gây rối thị
                        // giác (web dùng text tabs thuần).
                        selected: _tab == i,
                        onSelected: (_) {
                          setState(() => _tab = i);
                          // Bấm chip cuối/ngoài tầm nhìn → kéo chip row
                          // cho chip đang chọn hiện giữa thanh.
                          _ensureChipVisible(i);
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () =>
                  ref.read(bookshelfProvider.notifier).refresh(),
              child: items.isEmpty
                  ? ListView(
                      // AlwaysScrollable: kéo để refresh vẫn hoạt động
                      // khi list ngắn hơn viewport (ClampingScrollPhysics
                      // mặc định trên Android không cho kéo).
                      physics: const AlwaysScrollableScrollPhysics(),
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
                      physics: const AlwaysScrollableScrollPhysics(),
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
                          // Bìa local nếu đã snapshot khi download —
                          // offline vẫn hiện bìa như online.
                          coverLocalPath: offlineStories[s.id]?.coverLocalPath,
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
        // Fetch TẤT CẢ các trang bookmark — trước đây chỉ lấy page 1
        // (tối đa 100) → user >100 bookmark bị cắt âm thầm.
        final all = <BookmarkItem>[];
        var pageNum = 1;
        while (true) {
          final page = await repo.listBookmarks(page: pageNum, perPage: 100);
          all.addAll(page.bookmarks);
          if (pageNum >= page.totalPages) break;
          pageNum++;
        }
        // Cache locally for offline access.
        final db = _ref.read(appDatabaseProvider);
        final seenIds = {for (final b in all) b.storyId};
        for (final b in all) {
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
        // Prune local rows bị xoá ở thiết bị khác — nếu không, fallback
        // offline sẽ hiện bookmark ma không còn tồn tại trên server.
        final locals = await db.getBookmarks();
        for (final l in locals) {
          if (!seenIds.contains(l.storyId)) {
            await db.deleteBookmark(l.storyId);
          }
        }
        state = AsyncValue.data(all);
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
