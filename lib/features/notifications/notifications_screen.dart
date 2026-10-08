import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../core/observability/app_logger.dart';
import '../../core/theme/app_theme.dart';
import '../../repositories/story_repository.dart';
import 'notification_link.dart';

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
  /// Chặn bấm liên tiếp nhiều thông báo khi một link đang resolve.
  bool _openingLink = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(notificationsProvider.notifier).refresh());
  }

  /// Mở deep link của thông báo. Link chỉ có slug + số chương, còn API
  /// mobile cần UUID (story/chapter) → phải resolve qua API trước khi
  /// điều hướng. Nhờ vậy mở được đúng màn bình luận và cuộn tới bình
  /// luận (trước đây luôn thả về chi tiết truyện).
  Future<void> _openLink(String link) async {
    final target = NotificationLink.parse(link);
    if (target == null) return;
    // Link truyện thuần — điều hướng ngay, không cần gọi API.
    if (target.chapterNumber == null &&
        target.commentId == null &&
        !target.isReviews) {
      context.push('/story/${target.slug}');
      return;
    }
    if (_openingLink) return;
    _openingLink = true;
    final router = GoRouter.of(context);
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    _showResolvingDialog();
    var dialogOpen = true;
    void closeDialog() {
      if (dialogOpen) {
        dialogOpen = false;
        rootNavigator.pop();
      }
    }

    try {
      final repo = ref.read(storyRepositoryProvider);
      final detail = await repo.fetchStoryDetail(target.slug);
      final storyId = detail.story.id;
      final title = detail.story.title;
      if (target.commentId != null) {
        final commentQuery =
            'comment=${Uri.encodeQueryComponent(target.commentId!)}';
        if (target.chapterNumber != null) {
          final chapterId =
              await _resolveChapterId(repo, storyId, target.chapterNumber!);
          closeDialog();
          if (chapterId != null) {
            router.push(
              '/chapter-comments/$chapterId?$commentQuery',
              extra: title,
            );
          } else {
            // Không tra được UUID chương (chương ẩn/xoá?) — mở reader
            // tại chương đó để độc giả xem thay.
            router.push('/chapter/$storyId:${target.chapterNumber}');
          }
        } else {
          closeDialog();
          router.push('/story-comments/$storyId?$commentQuery', extra: title);
        }
      } else if (target.isReviews) {
        closeDialog();
        router.push('/story-reviews/$storyId', extra: title);
      } else {
        closeDialog();
        router.push('/chapter/$storyId:${target.chapterNumber}');
      }
    } catch (e) {
      closeDialog();
      AppLogger.warning('NotificationsScreen._openLink failed', e);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Không mở được liên kết thông báo — thử lại sau.'),
          ),
        );
    } finally {
      _openingLink = false;
    }
  }

  /// Tra UUID chương từ số chương — danh sách trả mới nhất trước nên
  /// thường chỉ cần 1 request. Trả null khi không tìm thấy.
  Future<String?> _resolveChapterId(
    StoryRepository repo,
    String storyId,
    int chapterNumber,
  ) async {
    var page = 1;
    while (page <= 10) {
      final list = await repo.fetchChapterList(
        storyId,
        page: page,
        perPage: 200,
        desc: true,
      );
      for (final c in list.chapters) {
        if (c.chapterNumber == chapterNumber) return c.id;
      }
      if (page >= list.totalPages || list.chapters.isEmpty) return null;
      page++;
    }
    return null;
  }

  void _showResolvingDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Đang mở…'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: page.notifications.length +
                      (page.page < page.totalPages ? 1 : 0),
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    if (i >= page.notifications.length) {
                      // "Xem thêm" — nạp trang cũ hơn.
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Center(
                          child: TextButton(
                            onPressed: () => ref
                                .read(notificationsProvider.notifier)
                                .loadMore(),
                            child: const Text('Xem thêm'),
                          ),
                        ),
                      );
                    }
                    final item = page.notifications[i];
                    // Swipe để xoá — backend giờ có DELETE /mobile/notifications/{id}.
                    return Dismissible(
                      key: ValueKey(item.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red.shade400,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete_outline,
                            color: Colors.white),
                      ),
                      confirmDismiss: (_) => showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Xoá thông báo?'),
                          content: const Text(
                              'Thông báo này sẽ bị xoá vĩnh viễn.'),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(context).pop(false),
                              child: const Text('Huỷ'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.of(context).pop(true),
                              style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red),
                              child: const Text('Xoá'),
                            ),
                          ],
                        ),
                      ),
                      onDismissed: (_) => ref
                          .read(notificationsProvider.notifier)
                          .delete(item.id),
                      child: _NotificationTile(
                        item: item,
                        onTap: () {
                          if (!item.isRead) {
                            ref
                                .read(notificationsProvider.notifier)
                                .markRead(item.id);
                          }
                          if (item.link != null) {
                            _openLink(item.link!);
                          }
                        },
                      ),
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
      'new_chapter' || 'bookmark_new_chapter' ||
      'collab_chapter_published' =>
        Icons.menu_book,
      'new_comment' || 'new_reply' => Icons.comment,
      'new_review' => Icons.star,
      'new_follower' => Icons.person_add,
      'story_approved' || 'chapter_approved' || 'emoji_approved' ||
      'suggestion_reviewed' =>
        Icons.check_circle,
      'story_rejected' || 'chapter_rejected' || 'emoji_rejected' =>
        Icons.cancel,
      'chapter_pending' || 'review_pending' || 'story_pending' ||
      'emoji_pending' =>
        Icons.hourglass_top,
      'content_flag' || 'new_report' => Icons.flag,
      'collab_invite' || 'collab_accepted' || 'collab_declined' =>
        Icons.group_add,
      'collab_revoked' => Icons.link_off,
      'beta_comment_new' || 'segment_suggestion' => Icons.feedback,
      'old_draft' => Icons.edit_note,
      'vip_registered' || 'vip_approved' || 'vip_granted' =>
        Icons.workspace_premium,
      'vip_rejected' || 'vip_revoked' => Icons.workspace_premium_outlined,
      _ => Icons.notifications,
    };
  }

  Color _typeColor(String type) {
    return switch (type) {
      'new_chapter' || 'bookmark_new_chapter' ||
      'collab_chapter_published' =>
        const Color(0xFF2563EB),
      'new_comment' || 'new_reply' || 'beta_comment_new' ||
      'segment_suggestion' =>
        const Color(0xFF0891B2),
      'new_review' => const Color(0xFFCA8A04),
      'new_follower' || 'collab_invite' || 'collab_accepted' ||
      'collab_declined' =>
        const Color(0xFF7C3AED),
      'collab_revoked' => const Color(0xFFDC2626),
      'story_approved' || 'chapter_approved' || 'emoji_approved' ||
      'suggestion_reviewed' =>
        const Color(0xFF16A34A),
      'story_rejected' || 'chapter_rejected' || 'emoji_rejected' ||
      'content_flag' || 'new_report' =>
        const Color(0xFFDC2626),
      'chapter_pending' || 'review_pending' || 'story_pending' ||
      'emoji_pending' =>
        const Color(0xFFD97706),
      'old_draft' => const Color(0xFF64748B),
      'vip_registered' || 'vip_approved' || 'vip_granted' =>
        const Color(0xFFB45309),
      'vip_rejected' || 'vip_revoked' => const Color(0xFF9A3412),
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
  bool _loadingMore = false;

  /// `silent = true` giữ data cũ trong lúc reload (không full-screen
  /// spinner) — dùng sau mark-read/delete để UI không giật cục.
  Future<void> refresh({bool silent = false}) async {
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
    if (!silent) state = const AsyncValue.loading();
    try {
      final repo = _ref.read(storyRepositoryProvider);
      state = AsyncValue.data(await repo.listNotifications());
    } catch (e, s) {
      if (!silent) state = AsyncValue.error(e, s);
      // silent: giữ nguyên data cũ, lần refresh tiếp theo sẽ cập nhật.
    }
  }

  /// Nạp thêm trang cũ hơn — append vào list hiện tại (dedupe theo id).
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || _loadingMore) return;
    if (current.page >= current.totalPages) return;
    _loadingMore = true;
    try {
      final repo = _ref.read(storyRepositoryProvider);
      final next = await repo.listNotifications(page: current.page + 1);
      final known = {for (final n in current.notifications) n.id};
      state = AsyncValue.data(PaginatedNotifications(
        notifications: [
          ...current.notifications,
          ...next.notifications.where((n) => !known.contains(n.id)),
        ],
        total: next.total,
        unread: next.unread,
        page: next.page,
        perPage: next.perPage,
        totalPages: next.totalPages,
      ));
    } catch (e) {
      AppLogger.warning('NotificationsNotifier.loadMore failed', e);
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> markRead(String id) async {
    try {
      final repo = _ref.read(storyRepositoryProvider);
      await repo.markNotificationRead(id);
      await refresh(silent: true);
    } catch (e) {
      AppLogger.warning('NotificationsNotifier.markRead failed', e);
    }
  }

  Future<void> markAllRead() async {
    try {
      final repo = _ref.read(storyRepositoryProvider);
      await repo.markAllNotificationsRead();
      await refresh(silent: true);
    } catch (e) {
      AppLogger.warning('NotificationsNotifier.markAllRead failed', e);
    }
  }

  /// Xoá 1 thông báo + cập nhật list local ngay (không chờ refresh).
  Future<void> delete(String id) async {
    final current = state.value;
    if (current != null) {
      final deleted =
          current.notifications.where((n) => n.id == id).firstOrNull;
      state = AsyncValue.data(PaginatedNotifications(
        notifications: [
          for (final n in current.notifications)
            if (n.id != id) n,
        ],
        total: current.total - 1,
        unread: deleted != null && !deleted.isRead
            ? (current.unread - 1).clamp(0, 1 << 31)
            : current.unread,
        page: current.page,
        perPage: current.perPage,
        totalPages: current.totalPages,
      ));
    }
    try {
      final repo = _ref.read(storyRepositoryProvider);
      await repo.deleteNotification(id);
    } catch (e) {
      AppLogger.warning('NotificationsNotifier.delete failed', e);
      // Server xoá thất bại → khôi phục list từ server.
      await refresh(silent: true);
    }
  }
}
