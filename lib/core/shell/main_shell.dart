import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/app_bottom_nav.dart';

/// Bottom navigation shell hosting the four primary tabs:
/// Home / Search / Bookshelf / Profile (plan §14.3).
///
/// Uses a [StatefulNavigationShell] so each tab keeps its state (scroll
/// position, loaded feeds) when switching — tab switch chỉ đổi branch
/// của IndexedStack, không destroy + remount màn hình.
class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final i = navigationShell.currentIndex;
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: AppBottomNav(
        currentIndex: i,
        // Dùng goBranch để giữ state các branch — context.go sẽ thay
        // location global, làm mất state của shell hiện tại.
        onDestinationSelected: (target) => navigationShell.goBranch(
          target,
          initialLocation: target == navigationShell.currentIndex,
        ),
      ),
    );
  }
}