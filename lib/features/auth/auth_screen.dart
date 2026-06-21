import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../core/observability/app_logger.dart';
import '../../core/theme/app_theme.dart';
import '../../repositories/story_repository.dart';

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
      final googleSignIn = GoogleSignIn(scopes: ['email', 'profile', 'openid']);
      final account = await googleSignIn.signIn();
      if (account == null) {
        // User cancelled the picker.
        return;
      }
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null) {
        _showError(
            'Không lấy được idToken từ Google.',
            'Thiếu `openid` scope hoặc google-services.json chưa cấu hình '
                'đúng. Kiểm tra lại Firebase + OAuth Client ID.');
        return;
      }

      final repo = ref.read(storyRepositoryProvider);
      final resp = await repo.exchangeGoogleIdToken(idToken);
      AppLogger.info('Logged in as ${resp.user.username} '
          '(jwt expires ${resp.expiresAt.toIso8601String()})');
      if (mounted) {
        _toast('Đăng nhập thành công. Xin chào ${resp.user.displayName}!');
        context.go('/home');
      }
    } catch (e, s) {
      AppLogger.error('Google Sign-In failed', e, s);
      if (!mounted) return;
      _showSignInError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Translate raw Google Sign-In exceptions into user-friendly
  /// Vietnamese messages. The raw exception text is rarely actionable
  /// for end-users (e.g. `PlatformException(sign_in_failed, ..., 10: , null, null)`)
  /// — we extract the GMS status code and map to a hint.
  void _showSignInError(Object e) {
    final msg = e.toString();
    // Google Play Services ApiException codes:
    //   10  = DEVELOPER_ERROR  → SHA-1 / package name not registered in
    //                            Google Cloud Console OAuth Client ID
    //   12500 = SIGN_IN_CANCELLED
    //   7   = NETWORK_ERROR
    //   8   = INTERNAL_ERROR
    //   13  = ERROR
    //   4   = SIGN_IN_REQUIRED
    //   5   = INVALID_ACCOUNT
    //   6   = RESOLUTION_REQUIRED
    String userMessage;
    String hint;
    if (msg.contains('10:') || msg.contains('ApiException: 10')) {
      userMessage = 'Lỗi cấu hình Google Sign-In (DEVELOPER_ERROR).';
      hint = 'SHA-1 của APK chưa được thêm vào OAuth Client ID trên Google '
          'Cloud Console, hoặc package name không khớp. Xem hướng dẫn '
          'trong README → "Thiết lập đăng nhập Google".';
    } else if (msg.contains('12500') || msg.contains('SIGN_IN_CANCELLED')) {
      userMessage = 'Đăng nhập đã bị huỷ.';
      hint = '';
    } else if (msg.contains('7:') || msg.contains('NETWORK_ERROR')) {
      userMessage = 'Lỗi mạng khi đăng nhập.';
      hint = 'Kiểm tra kết nối Internet và thử lại.';
    } else if (msg.contains('8:') || msg.contains('INTERNAL_ERROR')) {
      userMessage = 'Lỗi nội bộ Google Play Services.';
      hint = 'Thử cập nhật Google Play Services trên thiết bị rồi đăng nhập lại.';
    } else {
      userMessage = 'Đăng nhập thất bại.';
      hint = 'Chi tiết: $msg';
    }
    _showError(userMessage, hint);
  }

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
