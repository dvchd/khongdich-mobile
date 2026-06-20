import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/network/api_client.dart';
import '../../core/observability/app_logger.dart';
import '../../core/theme/app_theme.dart';
import '../../repositories/story_repository.dart';

/// Profile tab. Plan §5.7.
///
/// Shows the current user's avatar + display name (from
/// `GET /api/v1/mobile/auth/me`) or a direct "Đăng nhập bằng Google"
/// button when the JWT is missing / invalid. No intermediate /auth
/// screen — the Google Sign-In flow starts directly from here.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _busy = false;

  Future<void> _signInWithGoogle() async {
    setState(() => _busy = true);
    try {
      final googleSignIn =
          GoogleSignIn(scopes: ['email', 'profile', 'openid']);
      final account = await googleSignIn.signIn();
      if (account == null) return;
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null) {
        _toast('Không lấy được idToken từ Google.');
        return;
      }
      final repo = ref.read(storyRepositoryProvider);
      final resp = await repo.exchangeGoogleIdToken(idToken);
      AppLogger.info('Logged in as ${resp.user.username}');
      ref.invalidate(currentUserProvider);
      if (mounted) {
        _toast('Đăng nhập thành công. Xin chào ${resp.user.displayName}!');
      }
    } catch (e, s) {
      AppLogger.error('Google Sign-In failed', e, s);
      if (mounted) _toast('Đăng nhập thất bại: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
    final api = ref.read(apiClientProvider).maybeWhen(
          data: (c) => c,
          orElse: () => null,
        );
    if (api != null) await api.clearJwt();
    ref.invalidate(currentUserProvider);
    if (mounted) _toast('Đã đăng xuất.');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userAsync = ref.watch(currentUserProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Cá nhân')),
      body: ListView(
        children: [
          // ─── Profile header / login button ───
          userAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => _LoginCard(onTap: _signInWithGoogle, busy: _busy),
            data: (user) => user == null
                ? _LoginCard(onTap: _signInWithGoogle, busy: _busy)
                : _UserHeader(
                    user: user,
                    onSignOut: _signOut,
                  ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: const Text('Tủ truyện'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/bookshelf'),
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
            onTap: _signOut,
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                final info = snapshot.data;
                final ver = info != null
                    ? 'v${info.version}+${info.buildNumber}'
                    : '...';
                return Text(
                  'Không Dịch $ver\nFlutter 3.x · Riverpod · Drift · Dio',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the user is not logged in — a single "Đăng nhập bằng Google"
/// button card. No intermediate navigation; the Google Sign-In flow starts
/// directly from here.
class _LoginCard extends StatelessWidget {
  const _LoginCard({required this.onTap, required this.busy});
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const CircleAvatar(
            radius: 36,
            backgroundColor: AppTheme.primary,
            child: Icon(Icons.person, color: Colors.white, size: 36),
          ),
          const SizedBox(height: 12),
          Text('Chưa đăng nhập', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Đăng nhập để đồng bộ tiến trình đọc, bookmark và nhận thông báo.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: busy ? null : onTap,
            icon: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.login),
            label: const Text('Đăng nhập bằng Google'),
          ),
        ],
      ),
    );
  }
}

class _UserHeader extends StatelessWidget {
  const _UserHeader({required this.user, required this.onSignOut});
  final CurrentUser user;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          user.avatarUrl == null
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
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.displayName.isEmpty ? user.username : user.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  user.email,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (user.readingStreak > 0) ...[
                  const SizedBox(height: 2),
                  Text(
                    '🔥 Streak ${user.readingStreak} ngày',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
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
