import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'unread_badge_provider.dart';

/// Icon chuông thông báo kèm badge số chưa đọc — dùng chung ở AppBar các
/// tab chính (Home / Tìm kiếm / Tủ truyện / Cá nhân). Trước đây icon chỉ
/// có ở Home nên độc giả khó theo dõi thông báo khi đang ở tab khác.
class NotificationBellButton extends ConsumerWidget {
  const NotificationBellButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNotificationsProvider).value;
    return IconButton(
      icon: Badge(
        isLabelVisible: (unread ?? 0) > 0,
        label: Text('${unread ?? 0}'),
        child: const Icon(Icons.notifications_outlined),
      ),
      tooltip: 'Thông báo',
      onPressed: () => context.push('/notifications'),
    );
  }
}
