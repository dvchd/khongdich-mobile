import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
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
import '../../core/observability/app_logger.dart';
import '../../models/chapter_content.dart';
import '../../models/comment.dart';
import '../../models/story.dart' show ChapterSummary;
import '../../services/chapter_cache_service.dart';
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
      // Reader cho TRUYỆN ĐÃ TẢI (hybrid offline/online) — nguồn dữ liệu
      // linh hoạt: chương đã tải đọc từ Drift ngay (offline vẫn chạy),
      // chương chưa tải fetch qua API khi có mạng → đọc LIÊN TỤC.
      GoRoute(
        path: '/chapter-offline/:storyId/:chapterNumber',
        name: 'chapter_offline',
        builder: (context, state) {
          final storyId = state.pathParameters['storyId']!;
          final chapterNumber =
              int.tryParse(state.pathParameters['chapterNumber'] ?? '') ?? 1;
          return OfflineChapterReader(
            key: ValueKey('offline-chapter-$storyId-$chapterNumber'),
            storyId: storyId,
            chapterNumber: chapterNumber,
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
    // KHÔNG set state NGAY trong listener: listener của router delegate có
    // thể fire NGAY TRONG LÚC widget tree đang build (vd. restoreState /
    // setInitialRoutePath của Router khi push route đầu tiên sau boot) —
    // set StateProvider lúc đó làm Riverpod ném "Tried to modify a provider
    // while the widget tree was building" → push reader CHẾT với lỗi
    // "Không tải được chương". Defer sang microtask (chạy sau khi build
    // xong) — luôn an toàn.
    Future.microtask(() {
      ref.read(topLocationProvider.notifier).state = location;
    });
  }

  router.routerDelegate.addListener(trackTopLocation);
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

/// Hybrid reader cho TRUYỆN ĐÃ TẢI — một reader phục vụ cả 2 ngữ cảnh:
///
///   - **Đang có mạng**: danh sách chương ĐẦY ĐỦ từ API (badge "đã tải"),
///     next/prev + chapter-list sheet đi xuyên suốt truyện — chương chưa
///     tải được fetch ngầm qua ChapterCacheService (auto_cache) nên trải
///     nghiệm đọc LIÊN TỤC, không dừng ở chương cuối đã tải.
///   - **Mất mạng**: chương đã tải đọc thẳng từ Drift (100% offline),
///     danh sách chương chỉ còn chương đã tải; chương chưa tải hiện lỗi
///     rõ ràng kèm nút thử lại.
///
/// TTS dùng `offline: true` — handler resolve DB trước rồi fallback API
/// (xem TtsAudioHandler) → nghe liên tục khi có mạng, offline nghe đúng
/// các chương đã tải.
class OfflineChapterReader extends ConsumerStatefulWidget {
  const OfflineChapterReader({
    super.key,
    required this.storyId,
    required this.chapterNumber,
  });

  final String storyId;
  final int chapterNumber;

  @override
  ConsumerState<OfflineChapterReader> createState() =>
      _OfflineChapterReaderState();
}

class _OfflineChapterReaderState extends ConsumerState<OfflineChapterReader> {
  ChapterContent? _chapter;

  /// Danh sách chương ĐẦY ĐỦ từ API (khi có mạng). Rỗng khi offline.
  List<ChapterSummary> _fullSiblings = const [];

  /// Danh sách chương ĐÃ TẢI từ DB (fallback offline).
  List<DownloadedChapter> _dbSiblings = const [];
  bool _hasFullList = false;
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

  /// Số chương dùng cho prev/next — full list khi có mạng, DB list khi
  /// offline.
  List<int> get _siblingNumbers {
    if (_hasFullList) {
      return [for (final s in _fullSiblings) s.chapterNumber];
    }
    return [for (final s in _dbSiblings) s.chapterNumber];
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
        event.chapterNumber == chapter.chapterNumber;
    if (!shouldAutoAdvanceTts(
      matchesCurrentChapter: matchesCurrent,
      autoAdvanceEnabled: handler.autoAdvanceEnabled,
      manualSkip: event.manualSkip,
      nextChapterNumber: event.nextChapterNumber,
    )) {
      return;
    }
    final target = event.nextChapterNumber;
    if (target == null) return;
    // DB-only list (offline) → chỉ điều hướng khi chương đích đã tải.
    // Full list (online) → target luôn nằm trong list vì reader truyền
    // prev/next từ chính list đó.
    if (!_hasFullList && !_siblingNumbers.contains(target)) return;
    context.replace('/chapter-offline/${widget.storyId}/$target');
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final db = ref.read(appDatabaseProvider);
      final cache = ref.read(chapterCacheServiceProvider);

      // 1. Nội dung chương: DB trước (chương đã tải — đọc ngay, không
      // đụng mạng), fallback API qua cache service (memory → DB → API).
      final row = await db.getDownloadedChapterByNumber(
        storyId: widget.storyId,
        chapterNumber: widget.chapterNumber,
      );
      ChapterContent? chapter;
      var fromDb = false;
      if (row != null) {
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
        chapter = ChapterContent.fromJson(fullJson);
        fromDb = true;
        // Update lastReadAt để LRU evict biết chương này được đọc gần đây.
        await db.markChapterRead(row.chapterId);
      }
      chapter ??= await cache.getChapter(
        storyId: widget.storyId,
        chapterNumber: widget.chapterNumber,
      );

      // 2. Sibling list: full từ API (qua cache service, TTL 5 phút) —
      // fallback danh sách chương đã tải trong DB khi offline.
      final fullList = await cache.tryGetChapterList(widget.storyId);
      final dbList = await db.getDownloadedChaptersForStory(widget.storyId);

      // 3. Manga: map ảnh local để render 100% offline.
      Map<String, String> localPaths = {};
      if (chapter is MangaChapterContent) {
        final images = await db.getDownloadedImagesForChapter(chapter.id);
        for (final img in images) {
          localPaths[img.imageUrl] = img.localPath;
        }
        // Best-effort: chương manga tải từ TRƯỚC khi có tính năng lưu ảnh
        // local → tải on-demand (migration). Chỉ khi chương nằm trong DB
        // (đã download) — chương fetch online không cần bước này.
        if (fromDb && localPaths.isEmpty) {
          try {
            final downloader = ref.read(mangaImageDownloaderProvider);
            await downloader.downloadImages(
              chapterId: chapter.id,
              imageUrls: [for (final p in chapter.images) p.url],
            );
            final freshImages =
                await db.getDownloadedImagesForChapter(chapter.id);
            for (final img in freshImages) {
              localPaths[img.imageUrl] = img.localPath;
            }
          } catch (_) {
            /* best-effort */
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _chapter = chapter;
        _fullSiblings = fullList ?? const [];
        _dbSiblings = dbList;
        _hasFullList = fullList != null;
        _mangaLocalImagePaths = localPaths;
        _loading = false;
      });

      // Prefetch chương kế ngầm (có mạng) → next không loading spinner.
      unawaited(cache.prefetchNext(chapter));

      // Best-effort: cập nhật vị trí đang đọc (service tự queue khi offline).
      try {
        await ref
            .read(readingProgressServiceProvider)
            .markChapterOpened(widget.storyId, widget.chapterNumber);
      } catch (e, s) {
        AppLogger.warning(
            'OfflineChapterReader: markChapterOpened failed', e, s);
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = e.status == 403
              ? 'Chương này là chương VIP — bạn chưa được cấp quyền đọc.'
              : 'Không tải được chương (${e.status}): ${e.message}';
        });
      }
    } catch (e, s) {
      AppLogger.warning(
          'OfflineChapterReader: load chapter ${widget.chapterNumber} '
          'failed', e, s);
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Chương chưa được tải về máy và không tải được từ '
              'máy chủ. Kiểm tra kết nối rồi thử lại.';
        });
      }
    }
  }

  void _goPrev() {
    final nums = _siblingNumbers;
    final i = nums.indexOf(widget.chapterNumber);
    if (i > 0) {
      context.replace('/chapter-offline/${widget.storyId}/${nums[i - 1]}');
    }
  }

  void _goNext() {
    final nums = _siblingNumbers;
    final i = nums.indexOf(widget.chapterNumber);
    if (i >= 0 && i < nums.length - 1) {
      context.replace('/chapter-offline/${widget.storyId}/${nums[i + 1]}');
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
    final downloaded = ref
            .read(downloadedChaptersForStoryProvider(widget.storyId))
            .value ??
        const <DownloadedChapter>[];
    final downloadedNumbers =
        downloaded.map((d) => d.chapterNumber).toSet();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ChapterListSheet(
        entries: _hasFullList
            ? [
                for (final s in _fullSiblings)
                  ChapterListEntry(
                    number: s.chapterNumber,
                    title: s.title,
                    viewCount: s.viewCount,
                    isDownloaded:
                        downloadedNumbers.contains(s.chapterNumber),
                  ),
              ]
            : [
                for (final s in _dbSiblings)
                  ChapterListEntry(
                    number: s.chapterNumber,
                    title: s.chapterTitle,
                  ),
              ],
        currentChapter: ch.chapterNumber,
        storyId: ch.storyId,
        onSelect: (number) {
          // Chương đã tải → đọc DB; chưa tải → fetch API (có mạng).
          // Reader hybrid xử lý cả hai — replace để parent story detail
          // nằm lại trong back stack.
          context.replace('/chapter-offline/${widget.storyId}/$number');
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
        // prev/next từ sibling list HIỆN TẠI: full list khi có mạng
        // (nghe liên tục qua chương chưa tải), DB list khi offline.
        final nums = _siblingNumbers;
        final i = nums.indexOf(chapter.chapterNumber);
        await handler.loadChapter(
          chapterId: chapter.id,
          storyId: chapter.storyId,
          storyTitle: chapter.storyTitle,
          chapterTitle: chapter.title,
          chapterNumber: chapter.chapterNumber,
          contentMarkdown: markdown,
          storySlug: chapter.storySlug,
          prevChapterNumber: i > 0 ? nums[i - 1] : null,
          nextChapterNumber:
              i >= 0 && i < nums.length - 1 ? nums[i + 1] : null,
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
    final chapter = _chapter;
    if (chapter == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off,
                  size: 64,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.4),
                ),
                const SizedBox(height: 12),
                Text(
                  _loadError ?? 'Chương không có trong bộ nhớ.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Thử lại'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final settings = ref.watch(readerSettingsProvider);
    final nums = _siblingNumbers;
    final i = nums.indexOf(widget.chapterNumber);
    final hasPrev = i > 0;
    final hasNext = i >= 0 && i < nums.length - 1;

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
          // Mark chapter as read trong DB local (LRU evict + is_read).
          try {
            final db = ref.read(appDatabaseProvider);
            await db.markChapterRead(chapter.id);
          } catch (_) {
            /* best-effort */
          }

          // Retry prefetch khi user scroll gần cuối — prefetch ban đầu
          // fail (lỗi mạng) thì đây là cơ hội retry.
          try {
            final cache = ref.read(chapterCacheServiceProvider);
            unawaited(cache.prefetchNext(chapter));
          } catch (_) {
            /* best-effort */
          }

          // Sync reading progress lên server (best-effort). Nếu offline,
          // _saveToServer fail silently và để lại row synced=0 —
          // flushPending() sẽ retry khi online lại (app resume / login).
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

