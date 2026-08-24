import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/auth/auth_service.dart';
import '../../core/network/api_client.dart';
import '../../core/observability/app_logger.dart';
import '../../core/theme/app_theme.dart';
import '../../repositories/story_repository.dart';
import '../downloads/offline_library_screen.dart'
    show downloadedChaptersCountProvider;
import '../home/widgets/home_hero.dart' show homeHeroHiddenProvider;

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
      final auth = ref.read(authServiceProvider);
      final result = await auth.signInWithGoogle();
      AppLogger.info('Logged in as ${result.user.username}');
      ref.invalidate(currentUserProvider);
      if (mounted) {
        _toast('Đăng nhập thành công. Xin chào ${result.user.displayName}!');
      }
    } on AuthError catch (e) {
      if (mounted && e.hint.isNotEmpty) {
        _toast('${e.message} ${e.hint}');
      }
    } catch (e, s) {
      AppLogger.error('Google Sign-In failed', e, s);
      if (mounted) {
        final err = translateSignInError(e);
        _toast(err.hint.isEmpty ? err.message : '${err.message} ${err.hint}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final auth = ref.read(authServiceProvider);
      await auth.signOut();
      ref.invalidate(currentUserProvider);
      if (mounted) _toast('Đã đăng xuất.');
    } catch (e, s) {
      AppLogger.error('Sign out failed', e, s);
      if (mounted) _toast('Đăng xuất thất bại — thử lại sau.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userAsync = ref.watch(currentUserProvider);
    // Thẻ hero "Đọc & nghe offline" trên Home bị ẩn bằng nút X → thông
    // tin chuyển về đây (nguồn duy nhất: homeHeroHiddenProvider). Khi
    // hero còn hiện, quick action "Đã tải" trên Home đã đủ → ẩn tile
    // này để không lặp đường vào.
    final heroHidden = ref.watch(homeHeroHiddenProvider).value ?? false;
    final downloadedChapters =
        heroHidden ? ref.watch(downloadedChaptersCountProvider).value : null;
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
          // Đọc & nghe offline — chỉ khi thẻ hero trên Home đã bị ẩn.
          if (heroHidden)
            ListTile(
              leading: const Icon(Icons.headphones_outlined),
              title: const Text('Đọc & nghe offline'),
              subtitle: Text(
                downloadedChapters != null && downloadedChapters > 0
                    ? 'Đã lưu $downloadedChapters chương về máy'
                    : 'Tải truyện để đọc/nghe không cần mạng',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/offline-library'),
            ),
          // "Tủ truyện" đã có tab riêng trên bottom nav → không lặp lại
          // ở đây (trước đây 2 đường vào cùng /bookshelf gây thừa).
          // "Thông báo" là dữ liệu theo tài khoản → chỉ hiện khi đã đăng
          // nhập; chưa đăng nhập bấm vào cũng chỉ ra màn rỗng/vô nghĩa.
          if (userAsync.value != null) ...[
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('Truyện của tôi'),
              subtitle: const Text('Quản lý truyện đã đăng — kể cả bản nháp'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/my-stories'),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Thông báo'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/notifications'),
            ),
          ],
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Cài đặt'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings'),
          ),
          const Divider(),
          // Nút Đăng xuất chỉ có nghĩa khi đã đăng nhập — chưa đăng nhập
          // thì ẩn (trước đây luôn hiện, gây nhầm lẫn).
          if (userAsync.value != null) ...[
            ListTile(
              leading: const Icon(Icons.logout, color: AppTheme.primary),
              title: const Text('Đăng xuất',
                  style: TextStyle(color: AppTheme.primary)),
              onTap: _signOut,
            ),
          ],
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
                  'Không Dịch $ver',
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

/// Badge "🎯 Uy tín" — mirror web profile.html: label + thanh tiến trình
/// + số X/100 + nút ? giải thích (tap mở tooltip). Màu theo ngưỡng web:
/// >=70 xanh (trust-high), >=40 vàng (trust-mid), <40 đỏ (trust-low).
class TrustScoreBadge extends StatelessWidget {
  const TrustScoreBadge({super.key, required this.score});

  final int score;

  Color _color(BuildContext context) {
    if (score >= 70) return const Color(0xFF22C55E); // trust-high
    if (score >= 40) return const Color(0xFFEAB308); // trust-mid
    return const Color(0xFFEF4444); // trust-low
  }

  @override
  Widget build(BuildContext context) {
    final color = _color(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('🎯 Uy tín', style: TextStyle(fontSize: 12)),
        const SizedBox(width: 6),
        // Thanh tiến trình 0-100 — mirror .trust-track/.trust-fill.
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: SizedBox(
            width: 48,
            height: 6,
            child: Stack(
              children: [
                Container(color: Colors.black12),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: (score / 100).clamp(0.0, 1.0),
                  child: Container(color: color),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$score/100',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        const SizedBox(width: 2),
        // Nút ? giải thích — mirror .trust-info-btn (web dùng Alpine
        // toggle; Tooltip của Flutter trên mobile chỉ hiện khi ấn GIỮ,
        // user muốn tap 1 lần là hiện → dùng dialog).
        GestureDetector(
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('🎯 Điểm uy tín'),
              content: const Text(
                'Điểm uy tín phản ánh lịch sử đăng truyện và chấp hành '
                'quy định của bạn trên Không Dịch. Tài khoản mới bắt đầu ở '
                '50/100 — đăng truyện/chương chất lượng giúp điểm tăng dần, '
                'vi phạm quy định sẽ bị trừ.',
                style: TextStyle(fontSize: 14, height: 1.5),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Đóng'),
                ),
              ],
            ),
          ),
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.grey.shade400),
            ),
            child: const Icon(Icons.help_outline, size: 12),
          ),
        ),
      ],
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

class _UserHeader extends ConsumerWidget {
  const _UserHeader({required this.user, required this.onSignOut});
  final CurrentUser user;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                // Điểm uy tín — mirror web profile.html: 🎯 Uy tín + thanh
                // tiến trình + X/100. Màu theo ngưỡng web: >=70 xanh,
                // >=40 vàng, <40 đỏ (style.css .trust-high/mid/low).
                if (user.trustScore > 0) ...[
                  const SizedBox(height: 6),
                  TrustScoreBadge(score: user.trustScore),
                ],
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
                if (user.username.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  // Mirror the web profile's "📋 Sao chép link" — copies
                  // the full profile URL with a 2s text feedback.
                  OutlinedButton.icon(
                    onPressed: () async {
                      final baseUrl = ref
                              .read(apiClientProvider)
                              .value
                              ?.baseUrl ??
                          'https://khongdich.com';
                      await Clipboard.setData(
                        ClipboardData(text: '$baseUrl/u/${user.username}'),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          const SnackBar(
                            content: Text('Đã sao chép link trang cá nhân'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                    },
                    icon: const Icon(Icons.link, size: 16),
                    label: const Text('Sao chép link'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
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
    return await repo.fetchMe();
  } catch (e, s) {
    AppLogger.warning('currentUserProvider: fetchMe failed', e, s);
    return null;
  }
});
