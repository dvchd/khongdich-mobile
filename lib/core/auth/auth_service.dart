import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../network/api_client.dart';
import '../observability/app_logger.dart';
import '../../repositories/story_repository.dart';

/// Single source of truth cho Google Sign-In + JWT trên mobile.
///
/// **Định hướng**: app dùng `google_sign_in` để lấy Google idToken, đổi
/// lấy server JWT qua `POST /api/v1/mobile/auth/token`. KHÔNG dùng
/// `firebase_auth` — Firebase đã được bỏ khỏi app (xem README mục
/// "Tính năng thông báo").
///
/// **`serverClientId`** = Web Application OAuth Client ID, hardcode trong
/// code (xem `_googleWebClientId` bên dưới). Đây là **public identifier**
/// theo thiết kế OAuth 2.0 — không phải secret:
///   - Nó nằm trong HTML/meta của web app khongdich.com (view-source thấy)
///   - Backend cũng có cùng giá trị trong `GOOGLE_CLIENT_ID` env
///   - Google docs: "Client IDs are public identifiers. They are not secrets."
///   - Bảo mật thực sự nằm ở SHA-1 fingerprint của keystore (chỉ dev có)
///     + GOOGLE_CLIENT_SECRET (chỉ backend có, dùng cho server-side flow)
///
/// Hardcode giúp local dev chỉ cần `flutter run` (không cần --dart-define),
/// CI không phụ thuộc secret, code self-contained.
class AuthService {
  AuthService(this._api, this._repo);

  final ApiClient _api;
  final StoryRepository _repo;

  /// Web Application OAuth Client ID từ Google Cloud Console.
  /// Cùng giá trị với `GOOGLE_CLIENT_ID` trên backend (xem
  /// `docker-compose.demo.yml` / `docker-compose.prod.yml`).
  ///
  /// Đây là public identifier (không phải secret) — hardcode an toàn.
  /// Đổi Client ID = tạo project Google Cloud mới (sự kiện hiếm), lúc đó
  /// sửa 1 dòng này là xong.
  static const String _googleWebClientId =
      '637160959223-vepeilkvd1i8rl9ul800civ3vm5q8rd8.apps.googleusercontent.com';

  /// Singleton `GoogleSignIn` instance — dùng cho cả sign-in và sign-out
  /// để tránh tạo 2 instance riêng (Bug 6 trong audit).
  late final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: const ['email', 'profile', 'openid'],
    // Web Application OAuth Client ID — bắt buộc để mint idToken có aud
    // đúng với backend.
    serverClientId: _googleWebClientId,
  );

  /// Đăng nhập Google → đổi idToken lấy server JWT.
  ///
  /// Returns `AuthResult` chứa user info, hoặc throws `AuthError` với
  /// user-friendly Vietnamese message.
  Future<AuthResult> signInWithGoogle() async {
    final account = await _googleSignIn.signIn();
    if (account == null) {
      // User cancelled the picker.
      throw const AuthError('Đăng nhập đã bị huỷ.', '');
    }
    final auth = await account.authentication;
    final idToken = auth.idToken;
    if (idToken == null) {
      throw AuthError(
        'Không lấy được idToken từ Google.',
        'Thiếu `serverClientId` (GOOGLE_WEB_CLIENT_ID) hoặc google-services.json '
            'chưa cấu hình đúng. Xem README → "Thiết lập đăng nhập Google".',
      );
    }

    final resp = await _repo.exchangeGoogleIdToken(idToken);
    AppLogger.info('Logged in as ${resp.user.username} '
        '(jwt expires ${resp.expiresAt.toIso8601String()})');
    return AuthResult(user: resp.user, expiresAt: resp.expiresAt);
  }

  /// Đăng xuất: clear JWT + GoogleSignIn.signOut() để lần sau hiện picker.
  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (e) {
      AppLogger.warning('GoogleSignIn.signOut() failed (ignored)', e);
    }
    await _api.clearJwt();
  }

  Future<bool> isAuthenticated() => _api.isAuthenticated();
}

/// Kết quả đăng nhập thành công.
class AuthResult {
  const AuthResult({required this.user, required this.expiresAt});
  final CurrentUser user;
  final DateTime expiresAt;
}

/// Lỗi đăng nhập với user-friendly Vietnamese message + hint.
class AuthError implements Exception {
  const AuthError(this.message, this.hint);
  final String message;
  final String hint;

  @override
  String toString() => message;
}

/// Provider cho AuthService. Singleton — dùng chung cho toàn app.
final authServiceProvider = Provider<AuthService>((ref) {
  final api = ref.watch(apiClientProvider).maybeWhen(
        data: (c) => c,
        orElse: () => throw StateError('ApiClient not ready'),
      );
  final repo = ref.watch(storyRepositoryProvider);
  return AuthService(api, repo);
});

/// Translate raw Google Sign-In exceptions (PlatformException) thành
/// user-friendly Vietnamese. Trả về `AuthError` để caller hiển thị.
AuthError translateSignInError(Object e) {
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
  if (msg.contains('10:') || msg.contains('ApiException: 10')) {
    return AuthError(
      'Lỗi cấu hình Google Sign-In (DEVELOPER_ERROR).',
      'SHA-1 của APK chưa được thêm vào OAuth Client ID trên Google '
          'Cloud Console, hoặc package name không khớp. Xem hướng dẫn '
          'trong README → "Thiết lập đăng nhập Google".',
    );
  } else if (msg.contains('12500') || msg.contains('SIGN_IN_CANCELLED')) {
    return const AuthError('Đăng nhập đã bị huỷ.', '');
  } else if (msg.contains('7:') || msg.contains('NETWORK_ERROR')) {
    return const AuthError(
      'Lỗi mạng khi đăng nhập.',
      'Kiểm tra kết nối Internet và thử lại.',
    );
  } else if (msg.contains('8:') || msg.contains('INTERNAL_ERROR')) {
    return const AuthError(
      'Lỗi nội bộ Google Play Services.',
      'Thử cập nhật Google Play Services trên thiết bị rồi đăng nhập lại.',
    );
  }
  return AuthError('Đăng nhập thất bại.', 'Chi tiết: $msg');
}
