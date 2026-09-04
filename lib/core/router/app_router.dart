import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/auth_screen.dart';
import '../../features/author/author_screen.dart';
import '../../features/author/my_stories_screen.dart';
import '../../features/bookshelf/bookshelf_screen.dart';
import '../../features/comments/comments_screen.dart';
import '../../features/discover/browse_screens.dart';
import '../../features/discover/explore_screen.dart';
import '../../features/discover/ranking_screen.dart';
import '../../features/downloads/downloads_screen.dart';
import '../../features/downloads/offline_library_screen.dart';
import '../../features/downloads/offline_story_detail_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/market/market_screen.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/reader/chapter_reader_screen.dart';
import '../../features/reader/offline_chapter_reader.dart';
import '../../features/search/search_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/story/story_detail_screen.dart';
import '../../features/story/story_reviews_screen.dart';
import '../../features/tts/tts_bar_state.dart';
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
                builder: (context, state) => SearchScreen(
                  initialFilters: state.extra is SearchFilters
                      ? state.extra as SearchFilters
                      : null,
                ),
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
        path: '/danh-index',
        name: 'danh_index',
        builder: (context, state) => const DanhIndexScreen(),
      ),
      GoRoute(
        path: '/danh/:id',
        name: 'danh',
        builder: (context, state) => DanhStoriesScreen(
          id: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
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
      // Truyện của tôi — danh sách truyện CỦA tác giả đang đăng nhập
      // (gồm nháp/chờ duyệt), mirror dashboard web /dang-truyen.
      GoRoute(
        path: '/my-stories',
        name: 'my_stories',
        builder: (context, state) => const MyStoriesScreen(),
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

