import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/observability/app_logger.dart';
import '../../core/theme/app_theme.dart';

/// Auth screen. Plan §5.1 + §10.1.
///
/// Flow:
///   1. User taps "Đăng nhập với Google" → `google_sign_in` opens the
///      native Android account picker.
///   2. We grab the `idToken` from the result.
///   3. POST it to `/api/v1/mobile/auth/token` — backend verifies the
///      id_token via Google's tokeninfo endpoint, finds-or-creates the
///      user, and returns a server-issued JWT.
///   4. ApiClient writes the JWT to `flutter_secure_storage`. Every
///      subsequent Dio call auto-attaches `Authorization: Bearer <jwt>`.
///
/// When the user signs out, we clear the JWT from secure storage and
/// also call `google_sign_in.signOut()` so the next login attempt
/// shows the account picker again (instead of silently re-using the
/// last account).
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  bool _busy = false;

  Future<void> _signInWithGoogle() async {
    setState(() => _busy = true);
    try {
      final auth = ref.read(authServiceProvider);
      final result = await auth.signInWithGoogle();
      if (mounted) {
        _toast('Đăng nhập thành công. Xin chào ${result.user.displayName}!');
        context.go('/home');
      }
    } on AuthError catch (e) {
      if (!mounted) return;
      if (e.hint.isEmpty) {
        // Cancelled — không hiện error, chỉ tắt busy.
        return;
      }
      _showError(e.message, e.hint);
    } catch (e, s) {
      AppLogger.error('Google Sign-In failed', e, s);
      if (!mounted) return;
      final err = translateSignInError(e);
      if (err.hint.isEmpty) return;
      _showError(err.message, err.hint);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Translate raw Google Sign-In exceptions into user-friendly
  /// Vietnamese messages. (Logic đã chuyển sang `translateSignInError`
  /// trong auth_service.dart — giữ lại ở đây để backward compat.)

  void _showError(String title, String hint) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (hint.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(hint, style: const TextStyle(fontSize: 12)),
            ],
          ],
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Đăng nhập')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            Image.asset(
              'assets/icons/ic_launcher_splash.png',
              width: 96,
              height: 96,
              errorBuilder: (_, _, _) => Icon(
                Icons.menu_book,
                size: 96,
                color: AppTheme.primary.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Không Dịch',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Đăng nhập để đồng bộ tiến trình đọc, bookmark và nhận thông báo chương mới.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _busy ? null : _signInWithGoogle,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.login),
              label: const Text('Đăng nhập với Google'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => context.go('/home'),
              child: const Text('Đọc không đăng nhập'),
            ),
            const Spacer(),
            Text(
              'Đăng nhập qua google_sign_in → POST /api/v1/mobile/auth/token.\n'
              'Server xác minh id_token với Google, cấp JWT riêng cho app.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
