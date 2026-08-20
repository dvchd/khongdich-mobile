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
  ApiClient._(this._dio, this._storage, this.env, this._jwt);

  final Dio _dio;
  final FlutterSecureStorage _storage;
  final AppEnv env;

  /// In-memory mirror of the stored JWT. Reading secure storage costs a
  /// platform-channel round trip on EVERY request; the mirror serves the
  /// token from memory after the first read and is kept in sync by
  /// [writeJwt]/[clearJwt] and the 401 handler.
  final _JwtStore _jwt;

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
    final jwtStore = _JwtStore();

    // Inject / refresh the JWT on every request.
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // Attach the Bearer JWT to every API route EXCEPT the
          // token-exchange endpoint (`POST .../auth/token` authenticates
          // with the Google id_token in the body, not the JWT). Some
          // non-mobile routes are also called (e.g. `/api/v1/notifications/*`,
          // `/api/v1/search`) — they need the token too, otherwise the
          // backend rejects them and, worse, the 401 handler below could
          // clear a perfectly valid JWT (silent logout).
          final path = options.path;
          if (path.startsWith('/api/v1/') && !path.endsWith('/auth/token')) {
            // Serve from memory after the first storage read — secure
            // storage is a platform channel per call, needlessly slow
            // when the token hasn't changed.
            final token = jwtStore.loaded
                ? jwtStore.value
                : await storage.read(key: _kJwt);
            if (!jwtStore.loaded) {
              jwtStore.value = token;
              jwtStore.loaded = true;
            }
            if (token != null) {
              options.headers['Authorization'] = 'Bearer $token';
            }
          }
          handler.next(options);
        },
        onError: (e, handler) async {
          // Retry giới hạn (1 lần) cho lỗi mạng nhất thời — emulator/mạng
          // kém hay "Software caused connection abort" giữa chừng trước
          // đây fail ngay, user phải bấm lại. Chỉ retry khi chắc chắn
          // không có side-effect kép (connection fail trước khi server
          // nhận, hoặc gateway 502/504).
          final options = e.requestOptions;
          if (options.extra['kd_retried'] != true && _isRetryable(e)) {
            options.extra['kd_retried'] = true;
            AppLogger.warning(
              'ApiClient: retrying ${options.path} '
              '(${e.type.name}${e.response != null ? ' ${e.response!.statusCode}' : ''})',
            );
            await Future<void>.delayed(const Duration(milliseconds: 350));
            try {
              final retryResp = await dio.fetch<dynamic>(options);
              return handler.resolve(retryResp);
            } catch (retryErr) {
              return handler.next(
                retryErr is DioException ? retryErr : e,
              );
            }
          }
          final resp = e.response;
          if (resp != null) {
            // 401 Unauthorized: JWT expired or revoked. Clear the stored
            // JWT so the next request is anonymous, and the auth flow
            // can prompt the user to re-sign-in. Without this, the app
            // would keep sending the expired JWT → permanent 401 loop
            // with no recovery path short of manual sign-out.
            //
            // BUT only clear the JWT when this request actually SENT a
            // Bearer token. A 401 on an anonymous request (e.g. a
            // permission error or a route we called without a token)
            // must never nuke a valid JWT — that used to log users out
            // silently (e.g. the `/api/v1/notifications/*` calls before
            // the token was attached). Same for the token-exchange
            // endpoint itself: a failed re-login must keep the old JWT.
            if (resp.statusCode == 401) {
              final sentBearer =
                  resp.requestOptions.headers['Authorization'] is String;
              final isTokenExchange =
                  resp.requestOptions.path.contains('/auth/token');
              if (sentBearer && !isTokenExchange) {
                try {
                  await storage.delete(key: _kJwt);
                  jwtStore
                    ..value = null
                    ..loaded = true;
                  AppLogger.info(
                    'ApiClient: cleared expired/revoked JWT after 401',
                  );
                } catch (err) {
                  AppLogger.warning(
                    'ApiClient: failed to clear JWT after 401',
                    err,
                  );
                }
              } else {
                AppLogger.warning(
                  'ApiClient: 401 on request without Bearer '
                  '(path=${resp.requestOptions.path}) — JWT kept',
                );
              }
            }
            final data = resp.data;
            String? message;
            if (data is Map) {
              message = data['error'] as String?;
            } else if (data is String && data.isNotEmpty) {
              // A reverse proxy (nginx) can answer 502/504 with an HTML
              // error page — don't show raw HTML to the user.
              final trimmed = data.trimLeft();
              message = trimmed.startsWith('<') ? null : data;
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

    return ApiClient._(dio, storage, env, jwtStore);
  }

  /// Có nên retry một lần? Chỉ lỗi connection-level (server chưa chắc đã
  /// xử lý request) và gateway 502/504 (thường chưa tới backend).
  static bool _isRetryable(DioException e) {
    if (e.response == null) {
      return switch (e.type) {
        DioExceptionType.connectionError ||
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout =>
          true,
        _ => false,
      };
    }
    final s = e.response!.statusCode;
    return s == 502 || s == 504;
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

  /// Read the stored JWT (if any). Refreshes the in-memory mirror.
  Future<String?> readJwt() async {
    final v = await _storage.read(key: _kJwt);
    _jwt
      ..value = v
      ..loaded = true;
    return v;
  }

  /// Persist a JWT issued by `POST /api/v1/mobile/auth/token`.
  Future<void> writeJwt(String jwt) async {
    await _storage.write(key: _kJwt, value: jwt);
    _jwt
      ..value = jwt
      ..loaded = true;
  }

  /// Wipe the stored JWT — used by "Đăng xuất" + on 401 from the server.
  Future<void> clearJwt() async {
    await _storage.delete(key: _kJwt);
    _jwt
      ..value = null
      ..loaded = true;
  }

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

/// Mutable holder for the in-memory JWT mirror (see [ApiClient._jwt]).
class _JwtStore {
  String? value;
  bool loaded = false;
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
