import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../core/network/api_client.dart';
import '../../core/observability/app_logger.dart';
import '../../core/theme/app_theme.dart';
import '../../repositories/story_repository.dart';

/// Profile tab. Plan §5.7 — Settings entry + account section.
///
/// Shows the current user's avatar + display name (from
/// `GET /api/v1/mobile/auth/me`) or a "Đăng nhập" button when the JWT
/// is missing / invalid.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currentUserProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Cá nhân')),
      body: ListView(
        children: [
          const _ProfileHeader(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: const Text('Tủ truyện'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/bookshelf'),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Tải xuống'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/downloads'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Thông báo'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/notifications'),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Cài đặt'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: AppTheme.primary),
            title: const Text('Đăng xuất',
                style: TextStyle(color: AppTheme.primary)),
            onTap: () async {
              try {
                await GoogleSignIn().signOut();
              } catch (_) {/* best effort */}
              final api = ref.read(apiClientProvider).maybeWhen(
                    data: (c) => c,
                    orElse: () => null,
                  );
              if (api != null) await api.clearJwt();
              ref.invalidate(currentUserProvider);
              if (context.mounted) {
                _toast(context, 'Đã đăng xuất.');
                context.go('/home');
              }
            },
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Không Dịch v0.3.0\n'
              'Flutter 3.x · Riverpod · Drift · Dio · Bearer JWT · Custom markdown',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}

class _ProfileHeader extends ConsumerWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(currentUserProvider);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          userAsync.when(
            loading: () => const CircleAvatar(
              radius: 28,
              backgroundColor: AppTheme.primary,
              child: Icon(Icons.person, color: Colors.white),
            ),
            error: (_, _) => const CircleAvatar(
              radius: 28,
              backgroundColor: AppTheme.primary,
              child: Icon(Icons.person, color: Colors.white),
            ),
            data: (user) => user == null || user.avatarUrl == null
                ? const CircleAvatar(
                    radius: 28,
                    backgroundColor: AppTheme.primary,
                    child: Icon(Icons.person, color: Colors.white),
                  )
                : CircleAvatar(
                    radius: 28,
                    backgroundImage: NetworkImage(user.avatarUrl!),
                    backgroundColor: AppTheme.primary,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  userAsync.maybeWhen(
                    data: (u) => u == null
                        ? 'Khách'
                        : (u.displayName.isEmpty ? u.username : u.displayName),
                    orElse: () => 'Khách',
                  ),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  userAsync.maybeWhen(
                    data: (u) => u?.email ?? 'Chưa đăng nhập',
                    orElse: () => 'Chưa đăng nhập',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          userAsync.maybeWhen(
            data: (u) => u == null
                ? FilledButton(
                    onPressed: () => context.push('/auth'),
                    child: const Text('Đăng nhập'),
                  )
                : const SizedBox.shrink(),
            orElse: () => FilledButton(
              onPressed: () => context.push('/auth'),
              child: const Text('Đăng nhập'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fetches the current user via `GET /api/v1/mobile/auth/me`. Returns
/// `null` when not authenticated so the UI can show the login CTA.
final currentUserProvider =
    FutureProvider.autoDispose<CurrentUser?>((ref) async {
  final api = ref.watch(apiClientProvider).maybeWhen(
        data: (c) => c,
        orElse: () => null,
      );
  if (api == null || !await api.isAuthenticated()) return null;
  try {
    final repo = ref.read(storyRepositoryProvider);
    return repo.fetchMe();
  } catch (e, s) {
    AppLogger.warning('currentUserProvider: fetchMe failed', e, s);
    return null;
  }
});
