import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../observability/app_logger.dart';

/// Error returned by the Không Dịch backend.
///
/// The Rust backend (see `src/errors.rs`) always returns JSON in the form
/// `{"error": "<Vietnamese message>"}` for non-2xx responses when the
/// client sends `Accept: application/json`. We surface that message
/// verbatim to the UI so users see the same text they'd see on the web.
class ApiException implements Exception {
  const ApiException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => 'ApiException($status): $message';
}

/// Singleton HTTP client for the Không Dịch backend.
///
/// ## Auth model
/// The backend (as of 2026-06) authenticates via a **`kd_auth` httpOnly
/// cookie** set by the Google OAuth web flow. There is no Bearer-token
/// extractor yet (see `docs/plan-flutter-app.md` §12.1 — `POST
/// /api/v1/auth/token` is not yet implemented). Until it lands, the
/// mobile app uses a **hybrid WebView login** flow:
///
///   1. The user taps "Đăng nhập" → an in-app WebView opens
///      `https://khongdich.com/dang-nhap`.
///   2. After the Google OAuth round-trip, the backend sets `kd_auth`
///      (and `kd_csrf`) cookies on the `khongdich.com` domain.
///   3. The `WebViewCookieManager` writes those cookies into the
///      [CookieJar] used by this [ApiClient].
///   4. Subsequent Dio requests carry the cookies automatically.
///
/// When the backend ships `POST /api/v1/auth/token`, swap step 1–3 for a
/// single `google_sign_in` → exchange call and store the resulting JWT
/// in [SecureStorage] + `Authorization: Bearer` header.
///
/// ## CSRF
/// The backend applies a CSRF guard to every POST/PUT/DELETE on
/// `/api/v1/*` (see `src/middleware/csrf.rs`). The guard passes when:
///   - The `X-CSRF-Token` header matches the `kd_csrf` cookie value, OR
///   - The `Origin` header host matches the `Host` header.
///
/// Mobile cannot do double-submit cookies reliably, so we set
/// `Origin: <baseUrl>` on every mutating call. That satisfies the
/// same-origin fallback in the CSRF middleware without requiring the
/// `kd_csrf` cookie value to be re-read on every request.
class ApiClient {
  ApiClient._(this._dio, this._jar, this.baseUrl);

  final Dio _dio;
  final CookieJar _jar;
  final String baseUrl;

  Dio get dio => _dio;
  CookieJar get cookieJar => _jar;

  /// Build the singleton. The baseUrl is resolved from the
  /// `API_BASE_URL` dart-define (default `https://khongdich.com`).
  static Future<ApiClient> create() async {
    final baseUrl = const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'https://khongdich.com',
    );

    final dir = await getApplicationDocumentsDirectory();
    final jar = PersistCookieJar(
      storage: FileStorage('${dir.path}/.cookies/'),
      ignoreExpires: false,
    );

    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 15),
        headers: {
          'Accept': 'application/json, text/html; q=0.9, */*; q=0.5',
          // Pass `Origin` so the CSRF middleware's same-origin fallback
          // is satisfied for every POST/PUT/DELETE we send.
          'Origin': baseUrl,
          'User-Agent':
              'KhongDichMobile/0.1 (Android; +https://khongdich.com)',
        },
        responseType: ResponseType.json,
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
    dio.interceptors.add(CookieManager(jar));

    // Convert backend JSON errors into [ApiException] so callers can
    // surface the Vietnamese message directly.
    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (e, handler) {
          final resp = e.response;
          if (resp != null) {
            final data = resp.data;
            String? message;
            if (data is Map) {
              message = data['error'] as String?;
            } else if (data is String && data.isNotEmpty) {
              message = data;
            }
            message ??= _defaultMessageFor(resp.statusCode);
            return handler.reject(
              DioException(
                requestOptions: resp.requestOptions,
                response: resp,
                type: e.type,
                error: ApiException(resp.statusCode ?? 0, message),
              ),
            );
          }
          handler.next(e);
        },
      ),
    );

    return ApiClient._(dio, jar, baseUrl);
  }

  static String _defaultMessageFor(int? status) {
    switch (status) {
      case 400:
        return 'Yêu cầu không hợp lệ';
      case 401:
        return 'Chưa đăng nhập';
      case 403:
        return 'Không có quyền';
      case 404:
        return 'Không tìm thấy';
      case 500:
        return 'Lỗi nội bộ';
      case 502:
        return 'Lỗi kết nối';
      default:
        return 'Lỗi không xác định';
    }
  }

  /// Fetch a CSRF token. Required before the first mutating request if
  /// the cookie jar doesn't already have `kd_csrf`. The backend sets the
  /// cookie on this response too, so one call is enough to bootstrap.
  Future<String?> ensureCsrfCookie() async {
    try {
      final r = await _dio.get('/api/v1/csrf-token');
      return (r.data as Map?)?['csrf_token'] as String?;
    } catch (e, s) {
      AppLogger.warning('ensureCsrfCookie failed', e, s);
      return null;
    }
  }

  /// Are we authenticated (i.e. does the cookie jar hold `kd_auth`)?
  Future<bool> isAuthenticated() async {
    final uri = Uri.parse(baseUrl);
    final cookies = await _jar.loadForRequest(uri);
    return cookies.any((c) => c.name == 'kd_auth');
  }

  /// Wipe auth cookies — used by the "logout" action. Until
  /// `/api/v1/auth/token` lands, this is the only way to log out from
  /// the mobile side.
  Future<void> clearAuth() async {
    final uri = Uri.parse(baseUrl);
    // The cookie_jar API only offers `delete(uri)` (deletes all cookies
    // for that URI) and `deleteAll()`. We use `delete(uri)` to wipe
    // auth cookies — the cookie jar will re-fetch CSRF on the next
    // mutating call.
    try {
      await _jar.delete(uri);
    } catch (e, s) {
      AppLogger.warning('clearAuth: delete failed', e, s);
    }
  }
}

final apiClientProvider = FutureProvider<ApiClient>((ref) async {
  final client = await ApiClient.create();
  ref.onDispose(client._dio.close);
  return client;
});
