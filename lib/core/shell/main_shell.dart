import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Bottom navigation shell hosting the four primary tabs:
/// Home / Search / Bookshelf / Profile (plan §14.3).
class MainShell extends ConsumerWidget {
  const MainShell({super.key, required this.child});

  final Widget child;

  static const _tabs = [
    _TabSpec('/home', Icons.home_outlined, Icons.home, 'Trang chủ'),
    _TabSpec('/search', Icons.search_outlined, Icons.search, 'Tìm kiếm'),
    _TabSpec('/bookshelf', Icons.menu_book_outlined, Icons.menu_book, 'Tủ truyện'),
    _TabSpec('/profile', Icons.person_outline, Icons.person, 'Cá nhân'),
  ];

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    for (var i = _tabs.length - 1; i >= 0; i--) {
      if (location.startsWith(_tabs[i].path)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idx = _currentIndex(context);
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: idx,
        onDestinationSelected: (i) => context.go(_tabs[i].path),
        destinations: [
          for (final t in _tabs)
            NavigationDestination(
              icon: Icon(t.iconOutlined),
              selectedIcon: Icon(t.iconFilled),
              label: t.label,
            ),
        ],
      ),
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
