import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';

/// Auth screen. Plan §5.1 + §10.1 — Google Sign-In → exchange idToken
/// for JWT via `POST /api/v1/auth/token`.
///
/// `google_sign_in` is intentionally commented out of `pubspec.yaml`
/// until a Firebase project + OAuth client ID is provisioned. The MVP
/// build therefore shows the "browse as guest" path; login will be wired
/// in Phase 2.
class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key});

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
            Icon(Icons.menu_book,
                size: 72, color: AppTheme.primary.withValues(alpha: 0.8)),
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
              onPressed: () => _showComingSoon(context),
              icon: const Icon(Icons.login),
              label: const Text('Đăng nhập với Google'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => context.go('/home'),
              child: const Text('Đọc không đăng nhập'),
            ),
            const Spacer(),
            Text(
              'Phase 2 sẽ wire google_sign_in + /api/v1/auth/token.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  void _showComingSoon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Google Sign-In sẽ được bật khi Firebase setup xong.'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}
