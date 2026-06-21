import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../widgets/app_bottom_nav.dart';

/// Bottom navigation shell hosting the four primary tabs:
/// Home / Search / Bookshelf / Profile (plan §14.3).
class MainShell extends ConsumerWidget {
  const MainShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.toString();
    final idx = AppBottomNav.resolveIndexFromLocation(location);
    return Scaffold(
      body: child,
      bottomNavigationBar: AppBottomNav(currentIndex: idx < 0 ? 0 : idx),
    );
  }
}
