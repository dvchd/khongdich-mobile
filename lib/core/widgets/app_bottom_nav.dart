import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/downloads/downloads_screen.dart'
    show downloadQueueStreamProvider;

/// Reusable bottom navigation bar matching [MainShell]'s nav bar.
///
/// Used both by [MainShell] (where it's the scaffold's bottom nav) and
/// by standalone screens that live outside the shell — e.g. the story
/// detail screen — so the user can jump between Home / Search /
/// Bookshelf / Profile without first backing out of the detail page.
///
/// Pass [currentIndex] when the host screen maps to one of the four
/// main tabs (so the right destination is highlighted). When the host
/// is a detail screen (not one of the four), pass `currentIndex: -1`
/// so no destination is highlighted.
class AppBottomNav extends ConsumerWidget {
  const AppBottomNav({super.key, this.currentIndex = -1});

  /// Index of the currently-selected tab, or -1 if none.
  final int currentIndex;

  static const _tabs = [
    _TabSpec('/home', Icons.home_outlined, Icons.home, 'Trang chủ'),
    _TabSpec('/search', Icons.search_outlined, Icons.search, 'Tìm kiếm'),
    _TabSpec('/bookshelf', Icons.menu_book_outlined, Icons.menu_book, 'Tủ truyện'),
    _TabSpec('/profile', Icons.person_outline, Icons.person, 'Cá nhân'),
  ];

  /// Resolve the active tab index from the current router location.
  /// Returns -1 when the location doesn't match any of the four tabs
  /// (e.g. on a detail page like /story/:slug).
  static int resolveIndexFromLocation(String location) {
    for (var i = _tabs.length - 1; i >= 0; i--) {
      if (location.startsWith(_tabs[i].path)) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueAsync = ref.watch(downloadQueueStreamProvider);
    final activeCount = queueAsync.valueOrNull
            ?.where((q) =>
                q.status == 'pending' ||
                q.status == 'downloading' ||
                q.status == 'retry')
            .length ??
        0;

    final idx = currentIndex < 0 ? null : currentIndex;

    return NavigationBar(
      selectedIndex: idx ?? 0,
      onDestinationSelected: (i) {
        // Use `go` so the destination tab replaces the current route
        // in the shell — no detail screen left dangling on the back
        // stack.
        context.go(_tabs[i].path);
      },
      destinations: [
        for (var i = 0; i < _tabs.length; i++)
          NavigationDestination(
            icon: _tabs[i].path == '/bookshelf' && activeCount > 0
                ? Badge(
                    label: Text('$activeCount'),
                    child: Icon(_tabs[i].iconOutlined),
                  )
                : Icon(_tabs[i].iconOutlined),
            selectedIcon: _tabs[i].path == '/bookshelf' && activeCount > 0
                ? Badge(
                    label: Text('$activeCount'),
                    child: Icon(_tabs[i].iconFilled),
                  )
                : Icon(_tabs[i].iconFilled),
            label: _tabs[i].label,
          ),
      ],
    );
  }
}

class _TabSpec {
  const _TabSpec(this.path, this.iconOutlined, this.iconFilled, this.label);
  final String path;
  final IconData iconOutlined;
  final IconData iconFilled;
  final String label;
}
