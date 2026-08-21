import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../repositories/story_repository.dart';
import '../../core/observability/app_logger.dart';

/// Số thông báo chưa đọc — poll mỗi 30s (giống web poll
/// `/hx/notifications/unread-count`). Dùng cho badge trên icon chuông ở
/// Home; chỉ active khi có ai watch (autoDispose).
///
/// Dùng `Stream.periodic` (timer gắn với subscription) thay vì
/// `Future.delayed` đệ quy — khi provider dispose, `sub.cancel()` huỷ
/// luôn periodic timer → widget test không dính "Timer is still pending".
final unreadNotificationsProvider = StreamProvider.autoDispose<int>((ref) {
  const interval = Duration(seconds: 30);
  final controller = StreamController<int>();

  Future<void> poll() async {
    try {
      final repo = ref.read(storyRepositoryProvider);
      final page = await repo.listNotifications(page: 1, perPage: 1);
      if (!controller.isClosed) controller.add(page.unread);
    } catch (e, s) {
      // Best-effort — badge giữ giá trị cũ; poll sau sẽ thử lại.
      AppLogger.warning('unreadNotificationsProvider: poll failed', e, s);
    }
  }

  // Poll ngay lần đầu (không chờ 30s), rồi lặp mỗi 30s.
  Future.microtask(poll);
  final sub = Stream.periodic(interval).listen((_) => poll());

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });
  return controller.stream;
});
