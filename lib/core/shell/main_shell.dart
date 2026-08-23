import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/home/home_screen.dart' show homeProvider;
import '../../features/search/search_screen.dart'
    show searchRefreshIntentProvider;
import '../../features/tts/tts_now_playing_bar.dart';
import '../widgets/app_bottom_nav.dart';

/// Bottom navigation shell hosting the four primary tabs:
/// Home / Search / Bookshelf / Profile (plan §14.3).
///
/// Uses a [StatefulNavigationShell] so each tab keeps its state (scroll
/// position, loaded feeds) when switching — tab switch chỉ đổi branch
/// của IndexedStack, không destroy + remount màn hình.
///
/// Slot bottomNavigationBar = Column [TtsNowPlayingBar, AppBottomNav]:
/// bar nằm giữa nội dung và menu (vị trí thực — Scaffold tự thu hẹp body
/// nên không đè nội dung, SnackBar tự nổi trên cả hai). Khi bar ẩn nó
/// thu về 0px nên layout revert về như cũ.
///
/// Tap lại tab ĐANG active = làm mới nội dung tab đó (pattern chuẩn
/// "re-tap to refresh"): Trang chủ refetch feed kèm seed ngẫu nhiên
/// mới, Tìm kiếm chạy lại query hiện tại hoặc kéo random mới. Tủ truyện
/// / Cá nhân là Drift stream realtime — không cần làm mới tay.
class MainShell extends ConsumerWidget {
  const MainShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i = navigationShell.currentIndex;
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const TtsNowPlayingBar(),
          AppBottomNav(
            currentIndex: i,
            onDestinationSelected: (target) {
              if (target == i) {
                // Tap LẠI tab đang active → reload nội dung tab đó thay
                // vì goBranch (no-op với branch 1 route).
                _refreshTab(ref, target);
                return;
              }
              // Dùng goBranch để giữ state các branch — context.go sẽ
              // thay location global, làm mất state của shell hiện tại.
              navigationShell.goBranch(target);
            },
          ),
        ],
      ),
    );
  }

  void _refreshTab(WidgetRef ref, int index) {
    switch (index) {
      case 0: // Trang chủ — refetch toàn bộ feed (random dùng seed mới).
        unawaited(ref.read(homeProvider.notifier).refresh());
      case 1: // Tìm kiếm — màn hình tự xử lý qua intent provider.
        ref.read(searchRefreshIntentProvider.notifier).state++;
      default:
        break; // Tủ truyện / Cá nhân — Drift streams tự cập nhật.
    }
  }
}
