import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../repositories/story_repository.dart';

/// Notifications screen. Plan §6.2.
///
/// Uses the backend's existing `/hx/notifications` HTML fragment
/// (there is no JSON list endpoint yet — plan §12 lists it as MISSING).
/// Read/mark-all actions use the JSON endpoints.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(notificationsProvider.notifier).refresh());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(notificationsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Thông báo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.done_all),
            tooltip: 'Đánh dấu đã đọc tất cả',
            onPressed: () async {
              await ref
                  .read(notificationsProvider.notifier)
                  .markAllRead();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(notificationsProvider.notifier).refresh(),
        child: state.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _ErrorState(
            message: '$e',
            onRetry: () =>
                ref.read(notificationsProvider.notifier).refresh(),
          ),
          data: (page) => page.notifications.isEmpty
              ? const _EmptyState()
              : ListView.separated(
                  itemCount: page.notifications.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final item = page.notifications[i];
                    return _NotificationTile(
                      item: item,
                      onTap: () {
                        if (!item.isRead) {
                          ref
                              .read(notificationsProvider.notifier)
                              .markRead(item.id);
                        }
                        if (item.link != null) {
                          // Crude deep-link: try to parse
                          // `/truyen/{slug}/chuong/{num}` style URLs.
                          final m = RegExp(
                                  r'/truyen/([^/?#]+)/chuong/(\d+)')
                              .firstMatch(item.link!);
                          if (m != null) {
                            context.push(
                                '/chapter/${m.group(1)}/${m.group(2)}');
                          } else {
                            final m2 = RegExp(r'/truyen/([^/?#]+)')
                                .firstMatch(item.link!);
                            if (m2 != null) {
                              context.push('/story/${m2.group(1)}');
                            }
                          }
                        }
                      },
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.item, this.onTap});
  final NotificationItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = _typeColor(item.type);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(_typeIcon(item.type), color: color, size: 20),
      ),
      title: Text(
        item.title,
        style: TextStyle(
          fontWeight: item.isRead ? FontWeight.normal : FontWeight.w700,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: item.body.isEmpty
          ? null
          : Text(
              item.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
      trailing: item.isRead
          ? null
          : Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: AppTheme.primary,
                shape: BoxShape.circle,
              ),
            ),
      onTap: onTap,
    );
  }

  IconData _typeIcon(String type) {
    return switch (type) {
      'new_chapter' || 'bookmark_new_chapter' => Icons.menu_book,
      'new_comment' || 'new_reply' => Icons.comment,
      'new_review' => Icons.star,
      'new_follower' => Icons.person_add,
      'story_approved' || 'chapter_approved' => Icons.check_circle,
      'story_rejected' || 'chapter_rejected' => Icons.cancel,
      'chapter_pending' || 'review_pending' => Icons.hourglass_top,
      'content_flag' => Icons.flag,
      'collab_invite' => Icons.group_add,
      'beta_comment_new' => Icons.feedback,
      _ => Icons.notifications,
    };
  }

  Color _typeColor(String type) {
    return switch (type) {
      'new_chapter' || 'bookmark_new_chapter' => const Color(0xFF2563EB),
      'new_comment' || 'new_reply' || 'beta_comment_new' =>
        const Color(0xFF0891B2),
      'new_review' => const Color(0xFFCA8A04),
      'new_follower' || 'collab_invite' => const Color(0xFF7C3AED),
      'story_approved' || 'chapter_approved' => const Color(0xFF16A34A),
      'story_rejected' || 'chapter_rejected' || 'content_flag' =>
        const Color(0xFFDC2626),
      'chapter_pending' || 'review_pending' => const Color(0xFFD97706),
      _ => AppTheme.primary,
    };
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(Icons.notifications_none,
            size: 64,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
        const SizedBox(height: 12),
        const Center(child: Text('Không có thông báo.')),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 120),
        const Icon(Icons.cloud_off, size: 64),
        const SizedBox(height: 12),
        const Center(child: Text('Không tải được thông báo')),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 16),
        Center(child: OutlinedButton(onPressed: onRetry, child: const Text('Thử lại'))),
      ],
    );
  }
}

// ---- Notifications state ----

final notificationsProvider = StateNotifierProvider<NotificationsNotifier,
    AsyncValue<PaginatedNotifications>>((ref) {
  return NotificationsNotifier(ref);
});

class NotificationsNotifier
    extends StateNotifier<AsyncValue<PaginatedNotifications>> {
  NotificationsNotifier(this._ref) : super(const AsyncValue.loading());
  final Ref _ref;

  Future<void> refresh() async {
    final api = _ref.read(apiClientProvider).maybeWhen(
          data: (c) => c,
          orElse: () => null,
        );
    if (api == null || !await api.isAuthenticated()) {
      state = const AsyncValue.data(PaginatedNotifications(
        notifications: [],
        total: 0,
        unread: 0,
        page: 1,
        perPage: 20,
        totalPages: 0,
      ));
      return;
    }
    state = const AsyncValue.loading();
    try {
      final repo = _ref.read(storyRepositoryProvider);
      state = AsyncValue.data(await repo.listNotifications());
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> markRead(String id) async {
    try {
      final repo = _ref.read(storyRepositoryProvider);
      await repo.markNotificationRead(id);
      await refresh();
    } catch (_) {}
  }

  Future<void> markAllRead() async {
    try {
      final repo = _ref.read(storyRepositoryProvider);
      await repo.markAllNotificationsRead();
      await refresh();
    } catch (_) {}
  }
}
