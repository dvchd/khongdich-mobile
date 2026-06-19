import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../observability/app_logger.dart';
import '../storage/secure_storage.dart';

/// Dio-based API client for the Không Dịch backend.
///
/// Per `docs/plan-flutter-app.md` §10.2:
///   - Base URL: <https://khongdich.com> (overridable for dev).
///   - Auth: JWT Bearer, read from [SecureStorage].
///   - 401 → wipe JWT + emit `AuthEvents.loggedOut` so the router can bounce
///     the user back to the login screen.
class ApiClient {
  ApiClient(this._storage, {String? baseUrl}) {
    _dio = Dio(
      BaseOptions(
        baseUrl: baseUrl ??
            const String.fromEnvironment(
              'API_BASE_URL',
              defaultValue: 'https://khongdich.com',
            ),
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'Accept': 'application/json'},
      ),
    );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _storage.readJwt();
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          if (error.response?.statusCode == 401) {
            AppLogger.warning('API 401 — clearing stored JWT');
            await _storage.deleteJwt();
            AuthEvents.instance.emitLoggedOut();
          }
          handler.next(error);
        },
      ),
    );
  }

  final SecureStorage _storage;
  late final Dio _dio;

  Dio get dio => _dio;
}

/// Broadcasts auth-state changes so the router (and any listening widgets)
/// can react without us plumbing a stream through every provider.
class AuthEvents {
  AuthEvents._();
  static final AuthEvents instance = AuthEvents._();

  final _logoutController = StreamController<void>.broadcast();
  Stream<void> get onLoggedOut => _logoutController.stream;

  void emitLoggedOut() => _logoutController.add(null);
}

/// Provider for the singleton [ApiClient].
final apiClientProvider = Provider<ApiClient>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return ApiClient(storage);
});
