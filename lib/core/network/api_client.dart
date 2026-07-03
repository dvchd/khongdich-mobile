import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../observability/app_logger.dart';

/// Which backend the app should talk to.
///
/// The CI/CD pipeline builds two flavors:
///   - **demo**  → talks to `https://demo.khongdich.com` (internal test)
///   - **prod** → talks to `https://khongdich.com`         (public)
///
/// The flavor is baked into the binary at build time via the
/// `--dart-define=APP_ENV=demo|prod` flag (see `.github/workflows/ci.yml`).
/// End-users can also override at runtime via the env switcher in
/// Settings → Môi trường (useful for QA to swap between demo/prod
/// without reinstalling).
enum AppEnv { demo, prod }

extension AppEnvX on AppEnv {
  String get label => switch (this) {
    AppEnv.demo => 'Demo (demo.khongdich.com)',
    AppEnv.prod => 'Production (khongdich.com)',
  };

  String get baseUrl => switch (this) {
    AppEnv.demo => 'https://demo.khongdich.com',
    AppEnv.prod => 'https://khongdich.com',
  };
}

/// Error returned by the Không Dịch backend.
///
/// `src/errors.rs::AppError::IntoResponse` always returns JSON in the form
/// `{"error": "<Vietnamese message>"}` for non-2xx responses when the
/// client sends `Accept: application/json` (which we always do).
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
/// The backend (as of 2026-06-19) ships `POST /api/v1/mobile/auth/token`
/// which exchanges a Google `id_token` for a server-issued JWT. The JWT
/// is stored in [FlutterSecureStorage] and sent on every request via
/// `Authorization: Bearer <jwt>`. The backend's `AuthUser` / `MaybeUser`
/// extractors check this header first, falling back to the `kd_auth`
/// cookie for web clients.
///
/// ## CSRF
/// All mobile routes are mounted at `/api/v1/mobile/*` and bypass the
/// CSRF guard (see `src/main.rs`). The mobile client does not need to
/// send any CSRF token.
class ApiClient {
  ApiClient._(this._dio, this._storage, this.env);

  final Dio _dio;
  final FlutterSecureStorage _storage;
  final AppEnv env;

  Dio get dio => _dio;
  String get baseUrl => env.baseUrl;

  static const _kJwt = 'jwt';
  static const _kEnv = 'app_env';

  /// Build the singleton. The base URL is resolved from:
  ///   1. `--dart-define=APP_ENV` (set at build time by CI/CD), then
  ///   2. `flutter_secure_storage` (runtime override from Settings), then
  ///   3. `AppEnv.prod` as the default.
  static Future<ApiClient> create() async {
    const storage = FlutterSecureStorage();
    final savedEnvName = await storage.read(key: _kEnv);
    final compileTimeEnv = const String.fromEnvironment(
      'APP_ENV',
      defaultValue: 'prod',
    );
    final env = AppEnv.values.firstWhere(
      (e) => e.name == (savedEnvName ?? compileTimeEnv),
      orElse: () => AppEnv.prod,
    );

    final dio = Dio(
      BaseOptions(
        baseUrl: env.baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 15),
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'KhongDichMobile/0.3 (+https://khongdich.com)',
        },
        responseType: ResponseType.json,
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );

    // Inject / refresh the JWT on every request.
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // All mobile API routes live under /api/v1/mobile/* — no need
          // to attach the token to other paths.
          if (options.path.startsWith('/api/v1/mobile/') ||
              options.path.contains('/api/v1/mobile/')) {
            final token = await storage.read(key: _kJwt);
            if (token != null) {
              options.headers['Authorization'] = 'Bearer $token';
            }
          }
          handler.next(options);
        },
        onError: (e, handler) async {
          final resp = e.response;
          if (resp != null) {
            // 401 Unauthorized: JWT expired or revoked. Clear the stored
            // JWT so the next request is anonymous, and the auth flow
            // can prompt the user to re-sign-in. Without this, the app
            // would keep sending the expired JWT → permanent 401 loop
            // with no recovery path short of manual sign-out.
            if (resp.statusCode == 401) {
              try {
                await storage.delete(key: _kJwt);
                AppLogger.info(
                  'ApiClient: cleared expired/revoked JWT after 401',
                );
              } catch (err) {
                AppLogger.warning(
                  'ApiClient: failed to clear JWT after 401',
                  err,
                );
              }
            }
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

    return ApiClient._(dio, storage, env);
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

  /// Read the stored JWT (if any).
  Future<String?> readJwt() => _storage.read(key: _kJwt);

  /// Persist a JWT issued by `POST /api/v1/mobile/auth/token`.
  Future<void> writeJwt(String jwt) => _storage.write(key: _kJwt, value: jwt);

  /// Wipe the stored JWT — used by "Đăng xuất" + on 401 from the server.
  Future<void> clearJwt() => _storage.delete(key: _kJwt);

  /// Are we authenticated (i.e. is there a JWT in secure storage)?
  Future<bool> isAuthenticated() async => (await readJwt()) != null;

  /// Switch the active environment at runtime. Persists to secure storage
  /// so the choice survives across app launches. The caller is expected
  /// to trigger an app restart (or a full Riverpod container reset)
  /// after this returns so the new baseUrl takes effect.
  Future<void> setEnv(AppEnv newEnv) async {
    await _storage.write(key: _kEnv, value: newEnv.name);
    AppLogger.info('AppEnv switched to ${newEnv.name}');
  }
}

/// Provider for the singleton [ApiClient].
final apiClientProvider = FutureProvider<ApiClient>((ref) async {
  final client = await ApiClient.create();
  ref.onDispose(client._dio.close);
  return client;
});

/// Currently active environment — exposed as a separate provider so the
/// Settings screen can `ref.watch` it without re-creating the ApiClient.
final appEnvProvider = StateProvider<AppEnv>((ref) {
  // The FutureProvider below will overwrite this on boot, but we need a
  // sensible default for the first frame.
  return AppEnv.prod;
});
