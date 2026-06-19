import 'dart:io' show Cookie;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/network/api_client.dart';
import '../../core/observability/app_logger.dart';
import '../../core/theme/app_theme.dart';

/// Auth screen. Plan §5.1 + §10.1.
///
/// The backend (as of 2026-06) authenticates via Google OAuth and stores
/// the JWT in a `kd_auth` httpOnly cookie — there is **no `POST
/// /api/v1/auth/token` endpoint yet** (plan §12.1, MISSING). To unblock
/// the mobile app we use a hybrid WebView flow:
///
///   1. User taps "Đăng nhập" → opens an in-app WebView on
///      `https://khongdich.com/dang-nhap`.
///   2. User completes the Google OAuth round-trip inside the WebView.
///   3. On each page navigation, we copy the `kd_auth` / `kd_csrf`
///      cookies from the WebView's CookieManager into the [ApiClient]'s
///      shared PersistCookieJar.
///   4. When the user lands back on `/` (home), we close the WebView and
///      navigate the app to `/home`.
///
/// When the backend ships the Bearer-JWT endpoint, swap this for
/// `google_sign_in` → `POST /api/v1/auth/token` → store JWT in
/// `flutter_secure_storage` → set `Authorization: Bearer` header.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  bool _busy = false;

  Future<void> _openWebViewLogin() async {
    final api = ref.read(apiClientProvider).maybeWhen(
          data: (c) => c,
          orElse: () => null,
        );
    if (api == null) {
      _toast('ApiClient chưa sẵn sàng — thử lại.');
      return;
    }

    setState(() => _busy = true);
    final baseUri = Uri.parse(api.baseUrl);
    final cookieManager = WebViewCookieManager();

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) async {
            AppLogger.info('WebView page finished: $url');
            // Pull every cookie the WebView holds for the backend host
            // and mirror kd_auth / kd_csrf into our shared cookie jar.
            try {
              final cookies = await cookieManager.getCookies(domain: baseUri);
              for (final c in cookies) {
                if (c.name == 'kd_auth' || c.name == 'kd_csrf') {
                  await api.cookieJar.saveFromResponse(
                    baseUri,
                    [
                      Cookie(c.name, c.value)
                        ..domain = baseUri.host
                        ..path = '/',
                    ],
                  );
                }
              }
            } catch (e, s) {
              AppLogger.warning('cookie sync failed', e, s);
            }
            // If we're back on the home page (or any non-login page) AND
            // we now have kd_auth, the OAuth round-trip is done.
            if (url == api.baseUrl ||
                url == '${api.baseUrl}/' ||
                (url.startsWith(api.baseUrl) &&
                    !url.contains('/dang-nhap') &&
                    !url.contains('/auth/google'))) {
              if (await api.isAuthenticated()) {
                if (mounted) {
                  Navigator.of(context).maybePop();
                  _toast('Đăng nhập thành công.');
                  context.go('/home');
                }
              }
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('${api.baseUrl}/dang-nhap'));

    if (!mounted) return;
    await Navigator.of(context).push<Widget>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('Đăng nhập'),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: WebViewWidget(controller: controller),
        ),
      ),
    );
    if (mounted) setState(() => _busy = false);
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
              onPressed: _busy ? null : _openWebViewLogin,
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
              'Luồng đăng nhập dùng WebView để nhận cookie từ web.\n'
              'Khi backend có `POST /api/v1/auth/token`, sẽ chuyển sang google_sign_in.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
