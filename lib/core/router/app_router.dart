import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/auth_screen.dart';
import '../../features/author/author_screen.dart';
import '../../features/bookshelf/bookshelf_screen.dart';
import '../../features/comments/comments_screen.dart';
import '../../features/comments/segment_composer_sheet.dart';
import '../../features/downloads/downloads_screen.dart';
import '../../features/downloads/offline_library_screen.dart';
import '../../features/downloads/offline_story_detail_screen.dart';
import '../../features/discover/browse_screens.dart';
import '../../features/discover/explore_screen.dart';
import '../../features/discover/ranking_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/market/market_screen.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/reader/chapter_reader_screen.dart';
import '../../features/reader/reader_settings_provider.dart';
import '../../features/reader/services/reading_progress_service.dart';
import '../../features/reader/widgets/chapter_list_sheet.dart';
import '../../features/reader/widgets/reader_body.dart';
import '../../features/reader/widgets/reader_settings_sheet.dart';
import '../../features/search/search_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/story/story_detail_screen.dart';
import '../../features/story/story_reviews_screen.dart';
import '../../features/tts/tts_audio_handler.dart';
import '../../features/tts/tts_bar_state.dart';
import '../../features/tts/tts_control_panel.dart' show showTtsControlPanel;
import '../../core/database/app_database.dart';
import '../../core/network/api_client.dart';
import '../../models/chapter_content.dart';
import '../../models/comment.dart';
import '../../services/manga_image_downloader.dart';
import '../shell/main_shell.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  // Theo dõi modal sheet/dialog → now-playing bar ẩn khi sheet mở (bar
  // nổi trên Navigator nên sheet không che được bar, bar sẽ đè lên đáy
  // sheet). Xem TtsBarRouteObserver.
  final ttsBarObserver = TtsBarRouteObserver(ref.read(ttsBarStateProvider));
  final router = GoRouter(
    initialLocation: '/home',
    observers: [ttsBarObserver],
    routes: [
      // Bottom-nav shell: 4 tabs giữ STATE khi chuyển tab (trước đây
      // context.go destroy + remount từng tab → Home refetch + spinner
      // flash mỗi lần quay lại). Stack + fade nhẹ khi đổi branch.
      StatefulShellRoute(
        builder: (context, state, navigationShell) =>
            MainShell(navigationShell: navigationShell),
        navigatorContainerBuilder: _fadeIndexedStackContainerBuilder,
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home',
                name: 'home',
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/search',
                name: 'search',
                builder: (context, state) => const SearchScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/bookshelf',
                name: 'bookshelf',
                builder: (context, state) => const BookshelfScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/profile',
                name: 'profile',
                builder: (context, state) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/story/:slug',
        name: 'story_detail',
        builder: (context, state) =>
            StoryDetailScreen(storySlug: state.pathParameters['slug']!),
      ),
      // Trang tác giả — hồ sơ + danh sách truyện. Mở bằng cách chạm
      // tên tác giả ở story detail (đối chiếu web /u/{username}).
      GoRoute(
        path: '/author/:username',
        name: 'author',
        builder: (context, state) =>
            AuthorScreen(username: state.pathParameters['username']!),
      ),
      // Khám phá: BXH, thể loại, tag, explore filter.
      GoRoute(
        path: '/ranking',
        name: 'ranking',
        builder: (context, state) => const RankingScreen(),
      ),
      GoRoute(
        path: '/explore',
        name: 'explore',
        builder: (context, state) => const ExploreScreen(),
      ),
      GoRoute(
        path: '/category-index',
        name: 'category_index',
        builder: (context, state) => const CategoryIndexScreen(),
      ),
      GoRoute(
        path: '/category/:slug',
        name: 'category',
        builder: (context, state) => CategoryStoriesScreen(
          slug: state.pathParameters['slug']!,
          title: state.extra as String? ?? '',
        ),
      ),
      GoRoute(
        path: '/tag-index',
        name: 'tag_index',
        builder: (context, state) => const TagIndexScreen(),
      ),
      GoRoute(
        path: '/tag/:slug',
        name: 'tag',
        builder: (context, state) => TagStoriesScreen(
          slug: state.pathParameters['slug']!,
          title: state.extra as String? ?? '',
        ),
      ),
      GoRoute(
        path: '/chapter/:ref',
        name: 'chapter_reader',
        builder: (context, state) {
          final raw = state.pathParameters['ref']!;
          final parts = raw.split(':');
          if (parts.length != 2) {
            return Scaffold(
              body: Center(child: Text('Route không hợp lệ: $raw')),
            );
          }
          final storyId = parts[0];
          final chapterNumber = int.tryParse(parts[1]) ?? 1;
          return ChapterReaderScreen(
            key: ValueKey('chapter-$storyId-$chapterNumber'),
            storyId: storyId,
            chapterNumber: chapterNumber,
          );
        },
      ),
      // Chapter comments screen — pushed with the chapter title as `extra`.
      GoRoute(
        path: '/chapter-comments/:chapterId',
        name: 'chapter_comments',
        builder: (context, state) => CommentsScreen(
          chapterId: state.pathParameters['chapterId']!,
          chapterTitle: state.extra as String? ?? '',
        ),
      ),
      // Story comments screen (bình luận truyện) — pushed from story
      // detail with the story title as `extra`.
      GoRoute(
        path: '/story-comments/:storyId',
        name: 'story_comments',
        builder: (context, state) => CommentsScreen(
          storyId: state.pathParameters['storyId']!,
          storyTitle: state.extra as String? ?? '',
        ),
      ),
      // Story reviews screen (đánh giá truyện) — pushed from story detail
      // with the story title as `extra`.
      GoRoute(
        path: '/story-reviews/:storyId',
        name: 'story_reviews',
        builder: (context, state) => StoryReviewsScreen(
          storyId: state.pathParameters['storyId']!,
          storyTitle: state.extra as String? ?? '',
        ),
      ),
      // Offline chapter reader — loads from local Drift DB, no network.
      GoRoute(
        path: '/chapter-offline/:chapterId',
        name: 'chapter_offline',
        builder: (context, state) {
          final chapterId = state.pathParameters['chapterId']!;
          return OfflineChapterReader(
            key: ValueKey('offline-chapter-$chapterId'),
            chapterId: chapterId,
          );
        },
      ),
      // Offline story detail — shows cover, author, synopsis, chapter list.
      GoRoute(
        path: '/offline-story/:storyId',
        name: 'offline_story_detail',
        builder: (context, state) {
          return OfflineStoryDetailScreen(
            storyId: state.pathParameters['storyId']!,
          );
        },
      ),
      GoRoute(
        path: '/notifications',
        name: 'notifications',
        builder: (context, state) => const NotificationsScreen(),
      ),
      // Chợ Phiên — Họp Chợ realtime chat (mirrors the web home section).
      GoRoute(
        path: '/market',
        name: 'market',
        builder: (context, state) => const MarketScreen(),
      ),
      GoRoute(
        path: '/downloads',
        name: 'downloads',
        builder: (context, state) => const DownloadsScreen(),
      ),
      GoRoute(
        path: '/offline-library',
        name: 'offline_library',
        builder: (context, state) => const OfflineLibraryScreen(),
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/auth',
        name: 'auth',
        builder: (context, state) => const AuthScreen(),
      ),
    ],
    errorBuilder: (context, state) =>
        Scaffold(body: Center(child: Text('Route not found: ${state.uri}'))),
  );
  // Theo dõi location đang ở trên cùng navigation stack — cho các overlay
  // toàn cục (TtsNowPlayingBar) biết màn hình hiện tại có bottom nav để
  // đặt bar lên trên thay vì đè lên nav.
  void trackTopLocation() {
    // Dùng matches.last.matchedLocation thay vì currentConfiguration.uri:
    // `.uri` chỉ phản ánh RouteMatch KHÔNG phải ImperativeRouteMatch — các
    // route mở bằng context.push() (reader, story detail...) bị bỏ qua →
    // topLocation dính ở location cũ (vd. /story/... khi đang đọc /chapter)
    // → now-playing bar tưởng màn hình có bottom nav mà đặt cao sai chỗ.
    final matches = router.routerDelegate.currentConfiguration.matches;
    final location = matches.isEmpty ? '/' : matches.last.matchedLocation;
    ref.read(topLocationProvider.notifier).state = location;
  }

  router.routerDelegate.addListener(trackTopLocation);
  // Defer lần track đầu — không được modify StateProvider khác NGAY trong
  // lúc appRouterProvider đang build (Riverpod assertion "modified ... while
  // building"). Listener của các lần đổi route sau vẫn chạy bình thường.
  Future.microtask(trackTopLocation);
  ref.onDispose(() => router.routerDelegate.removeListener(trackTopLocation));
  return router;
});

/// Location (string) của route đang ở trên cùng navigation stack — dùng
/// cho các overlay toàn cục (vd. TtsNowPlayingBar) quyết định vị trí,
/// ví dụ có cần chừa chỗ cho bottom nav không.
final topLocationProvider = StateProvider<String>((ref) => '/home');

/// Màn hình nào có bottom nav hiển thị: 4 tab của MainShell + story
/// detail online/offline (chúng tự vẽ AppBottomNav trong Scaffold của
/// riêng mình). Các route khác (reader, settings, ...) không có nav.
bool locationHasBottomNav(String location) {
  const navPrefixes = [
    '/home',
    '/search',
    '/bookshelf',
    '/profile',
    '/story/',
    '/offline-story/',
  ];
  return navPrefixes.any(location.startsWith);
}

/// Branch container for [StatefulShellRoute]: giữ nguyên semantics của
/// container mặc định (Offstage + TickerMode — branch không active không
/// paint, không chạy animation) nhưng thêm fade 220ms khi chuyển tab —
/// trước đây chuyển tab "nhấp nháy" tức thì. Branch được giữ trong cây
/// nên state (scroll position, feed đã load) của từng tab không mất.
Widget _fadeIndexedStackContainerBuilder(
  BuildContext context,
  StatefulNavigationShell navigationShell,
  List<Widget> children,
) {
  return _FadeIndexedStack(
    currentIndex: navigationShell.currentIndex,
    children: children,
  );
}

class _FadeIndexedStack extends StatefulWidget {
  const _FadeIndexedStack({required this.currentIndex, required this.children});

  final int currentIndex;
  final List<Widget> children;

  @override
  State<_FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<_FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  static const _fade = Duration(milliseconds: 220);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _fade,
    value: 1,
  );
  late int _lastIndex = widget.currentIndex;

  @override
  void didUpdateWidget(_FadeIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex != _lastIndex) {
      _lastIndex = widget.currentIndex;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.currentIndex;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          Offstage(
            offstage: i != current,
            child: TickerMode(
              enabled: i == current,
              // FadeTransition dùng controller của container (không nằm
              // trong TickerMode của branch) — fade chạy được trên MỌI
              // lần đổi tab, kể cả khi quay lại tab từng xem.
              child: FadeTransition(
                opacity: _controller,
                child: widget.children[i],
              ),
            ),
          ),
      ],
    );
  }
}

/// Reads a downloaded chapter from the local Drift DB and displays it
/// using the **shared** [ReaderBody] widget — same UI as the online
/// reader, only the data source differs.
///
/// Plan §5.4 — the only offline-specific behaviour is:
///   - Loading the chapter from `downloaded_chapters` (Drift).
///   - Resolving prev/next chapter from the local `siblings` list
///     (chapters of the same story that are also downloaded).
///   - Marking the chapter as read in the local Drift DB when the
///     user scrolls near the end (no API call).
///   - Building the chapter-list sheet from the local siblings.
///
/// Everything else (reader chrome, theme resolution, content
/// rendering, page-flip / swipe wrappers, tap zones, TTS) is handled
/// by [ReaderBody] and its helpers in `reader_helpers.dart`.
class OfflineChapterReader extends ConsumerStatefulWidget {
  const OfflineChapterReader({super.key, required this.chapterId});
  final String chapterId;

  @override
  ConsumerState<OfflineChapterReader> createState() =>
      _OfflineChapterReaderState();
}

class _OfflineChapterReaderState extends ConsumerState<OfflineChapterReader> {
  ChapterContent? _chapter;
  List<DownloadedChapter> _siblings = [];
  Map<String, String> _mangaLocalImagePaths = {};
  bool _loading = true;
  String? _loadError;
  StreamSubscription<TtsChapterCompleteEvent>? _chapterCompleteSub;
  TtsAudioHandler? _handler;

  @override
  void initState() {
    super.initState();
    _load();
    // Subscribe chapter-complete để auto-advance (xem ChapterReaderScreen —
    // cùng design: màn hình tự xử lý completion của chương của NÓ).
    Future.microtask(() async {
      try {
        final handler = await ref.read(ttsHandlerProvider.future);
        if (!mounted) return;
        _handler = handler;
        _chapterCompleteSub =
            handler.onChapterCompleted.listen(_handleChapterCompleted);
      } catch (_) {
        // TTS init fail — reader vẫn hoạt động bình thường.
      }
    });
  }

  @override
  void dispose() {
    _chapterCompleteSub?.cancel();
    super.dispose();
  }

  /// TTS đọc xong chương của màn hình này → chỉ ĐIỀU HƯỚNG sang chương
  /// đích. Load + play chương đích do HANDLER tự làm (hoạt động cả khi
  /// app bị ẩn). Màn hình chính là guard: nó chỉ còn mounted khi reader
  /// này vẫn nằm trên navigation stack.
  void _handleChapterCompleted(TtsChapterCompleteEvent event) {
    if (!mounted) return;
    final handler = _handler;
    final chapter = _chapter;
    if (handler == null || chapter == null) return;
    final matchesCurrent = event.storyId == chapter.storyId &&
        event.chapterId == chapter.id;
    if (!shouldAutoAdvanceTts(
      matchesCurrentChapter: matchesCurrent,
      autoAdvanceEnabled: handler.autoAdvanceEnabled,
      manualSkip: event.manualSkip,
      nextChapterNumber: event.nextChapterNumber,
    )) {
      return;
    }
    final target = _siblings
        .where((s) => s.chapterNumber == event.nextChapterNumber)
        .firstOrNull;
    if (target == null) return;
    context.replace('/chapter-offline/${target.chapterId}');
  }

  Future<void> _load() async {
    try {
      final db = ref.read(appDatabaseProvider);
      final row = await (db.select(
        db.downloadedChapters,
      )..where((t) => t.chapterId.equals(widget.chapterId))).getSingleOrNull();
      if (row == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _loadError = 'Chương không có trong bộ nhớ.';
          });
        }
        return;
      }
      // Find siblings (same story, also downloaded), sorted by chapterNumber.
      final all =
          await (db.select(db.downloadedChapters)
                ..where((t) => t.storyId.equals(row.storyId))
                ..orderBy([(t) => OrderingTerm.asc(t.chapterNumber)]))
              .get();
      final json = jsonDecode(row.contentRaw) as Map<String, dynamic>;
      final fullJson = <String, dynamic>{
        ...json,
        'content_markdown': json['content_markdown'] ?? '',
        'content_type': row.contentType,
        'story_title': row.storyTitle,
        'story_slug': row.storySlug,
        'chapter_number': row.chapterNumber,
        'title': row.chapterTitle,
      };
      // For manga chapters, load the local image path mappings so the
      // reader can render images 100% offline.
      Map<String, String> localPaths = {};
      if (row.contentType == 'manga') {
        final downloader = ref.read(mangaImageDownloaderProvider);
        final images = await db.getDownloadedImagesForChapter(widget.chapterId);
        for (final img in images) {
          localPaths[img.imageUrl] = img.localPath;
        }
        // Best-effort: if the chapter is manga but image rows are
        // missing (e.g. user downloaded before the manga-image
        // feature shipped), don't crash — the view will fall back
        // to CachedNetworkImage which may still hit OS cache.
        if (localPaths.isEmpty) {
          // Try to extract image URLs from the chapter JSON and
          // download them on-demand. This is a migration path for
          // chapters downloaded before image caching existed.
          try {
            final chapterObj = ChapterContent.fromJson(fullJson);
            if (chapterObj is MangaChapterContent) {
              await downloader.downloadImages(
                chapterId: widget.chapterId,
                imageUrls: [for (final p in chapterObj.images) p.url],
              );
              final freshImages = await db.getDownloadedImagesForChapter(
                widget.chapterId,
              );
              for (final img in freshImages) {
                localPaths[img.imageUrl] = img.localPath;
              }
            }
          } catch (_) {
            /* best-effort */
          }
        }
      }
      if (mounted) {
        setState(() {
          _chapter = ChapterContent.fromJson(fullJson);
          _siblings = all;
          _mangaLocalImagePaths = localPaths;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Lỗi khi tải chương: $e';
        });
      }
    }
  }

  int get _currentIndex =>
      _siblings.indexWhere((s) => s.chapterId == widget.chapterId);

  void _goPrev() {
    final i = _currentIndex;
    if (i > 0) {
      context.replace('/chapter-offline/${_siblings[i - 1].chapterId}');
    }
  }

  void _goNext() {
    final i = _currentIndex;
    if (i >= 0 && i < _siblings.length - 1) {
      context.replace('/chapter-offline/${_siblings[i + 1].chapterId}');
    }
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ReaderSettingsSheet(),
    );
  }

  void _openChapterList() {
    final ch = _chapter;
    if (ch == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ChapterListSheet(
        entries: [
          for (final s in _siblings)
            ChapterListEntry(
              number: s.chapterNumber,
              title: s.chapterTitle,
            ),
        ],
        currentChapter: ch.chapterNumber,
        storyId: ch.storyId,
        onSelect: (number) {
          // Find the sibling with this chapter number and navigate
          // to its offline chapter route. Use `replace` (not `go`)
          // so the parent offline-story-detail screen stays in the
          // back stack — pressing Back from the chapter reader
          // returns to the story detail, not exits the app.
          final target = _siblings
              .where((s) => s.chapterNumber == number)
              .firstOrNull;
          if (target != null) {
            context.replace('/chapter-offline/${target.chapterId}');
          }
        },
      ),
    );
  }

  /// Long-press paragraph → bình luận đoạn / góp ý composer (login-gated,
  /// like the online reader — posting fails with a clear message while
  /// offline).
  Future<void> _openSegmentComposer(
    ChapterContent chapter,
    String plainText,
  ) async {
    // Capture UI handles before any await (lint + safety).
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final api = ref.read(apiClientProvider).value;
    if (api == null || !await api.isAuthenticated()) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Đăng nhập để bình luận đoạn và góp ý.'),
        ),
      );
      router.push('/auth');
      return;
    }
    if (!mounted) return;
    final result = await showSegmentComposer(
      context,
      chapterId: chapter.id,
      quoteText: plainText,
    );
    if (result == null || !mounted) return;
    final message = switch (result) {
      CommentPostResult(:final wasHidden) => wasHidden
          ? 'Đã gửi — bình luận đang chờ kiểm duyệt.'
          : 'Đã gửi bình luận đoạn.',
      SuggestionPostResult() => 'Đã gửi góp ý cho tác giả.',
      _ => null,
    };
    if (message == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
    if (result is CommentPostResult) {
      router.push('/chapter-comments/${chapter.id}', extra: chapter.title);
    }
  }

  void _toggleTts(ChapterContent chapter) async {
    final markdown = chapterMarkdownOrNull(chapter);
    if (markdown == null) return;
    try {
      final handler = await ref.read(ttsHandlerProvider.future);
      _handler = handler;
      // Bật chuỗi auto-advance — listener trong initState lo phần còn lại.
      handler.autoAdvanceEnabled = true;

      if (handler.currentChapterId != chapter.id) {
        await handler.stop();
        await handler.loadChapter(
          chapterId: chapter.id,
          storyId: chapter.storyId,
          storyTitle: chapter.storyTitle,
          chapterTitle: chapter.title,
          chapterNumber: chapter.chapterNumber,
          contentMarkdown: markdown,
          storySlug: chapter.storySlug,
          prevChapterNumber: _currentIndex > 0
              ? _siblings[_currentIndex - 1].chapterNumber
              : null,
          nextChapterNumber:
              (_currentIndex >= 0 && _currentIndex < _siblings.length - 1)
              ? _siblings[_currentIndex + 1].chapterNumber
              : null,
          offline: true,
        );
        await handler.play();
      } else {
        final state = handler.playbackState.value;
        if (!state.playing &&
            state.processingState != AudioProcessingState.error) {
          await handler.play();
        }
      }
      if (mounted) {
        unawaited(showTtsControlPanel(context, ref));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('TTS lỗi: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_chapter == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Text(_loadError ?? 'Chương không có trong bộ nhớ.'),
        ),
      );
    }
    final chapter = _chapter!;
    final settings = ref.watch(readerSettingsProvider);
    final i = _currentIndex;
    final hasPrev = i > 0;
    final hasNext = i >= 0 && i < _siblings.length - 1;

    return Scaffold(
      body: ReaderBody(
        chapter: chapter,
        settings: settings,
        onPrev: hasPrev ? _goPrev : null,
        onNext: hasNext ? _goNext : null,
        onOpenSettings: _openSettings,
        onOpenChapterList: _openChapterList,
        onOpenComments: () {
          if (!mounted) return;
          context.push('/chapter-comments/${chapter.id}', extra: chapter.title);
        },
        onParagraphLongPress: (plain) => _openSegmentComposer(chapter, plain),
        onToggleTts: chapterSupportsTts(chapter) ? () => _toggleTts(chapter) : null,
        mangaLocalImagePaths: _mangaLocalImagePaths,
        onChapterNearEnd: () async {
          // Mark chapter as read in local Drift DB (cho LRU evict +
          // is_read flag).
          try {
            final db = ref.read(appDatabaseProvider);
            await db.markChapterRead(widget.chapterId);
          } catch (_) {
            /* best-effort */
          }

          // Sync reading progress lên server (best-effort). Nếu offline,
          // _saveToServer fail silently và để lại row synced=0 —
          // flushPending() sẽ retry khi online lại (app resume / login).
          // Trước đây offline reader không ghi reading_progress → tiến
          // trình đọc offline bị "quên" khi online lại.
          try {
            final progress = ref.read(readingProgressServiceProvider);
            await progress.markChapterRead(
              chapter.storyId,
              chapter.chapterNumber,
            );
          } catch (_) {
            /* best-effort */
          }
        },
      ),
    );
  }
}
