import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../database/app_database.dart';
import '../network/api_client.dart';
import '../observability/app_logger.dart';
import '../../features/tts/tts_audio_handler.dart';
import '../../repositories/story_repository.dart';
import '../../services/manga_image_downloader.dart';

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
  AuthService(this._api, this._repo, this._db, this._ref);

  final ApiClient _api;
  final StoryRepository _repo;
  final AppDatabase _db;
  final Ref _ref;

  /// Web Application OAuth Client ID từ Google Cloud Console.
  /// Cùng giá trị với `GOOGLE_CLIENT_ID` trên backend (xem
  /// `docker-compose.demo.yml` / `docker-compose.prod.yml`).
  ///
  /// Đây là public identifier (không phải secret) — hardcode an toàn.
  /// Đổi Client ID = tạo project Google Cloud mới (sự kiện hiếm), lúc đó
  /// sửa 1 dòng này là xong.
  static const String _googleWebClientId =
      '637160959223-vepeilkvd1i8rl9ul800civ3vm5q8rd8.apps.googleusercontent.com';

  /// google_sign_in v7: `GoogleSignIn` là singleton dùng chung toàn app —
  /// truy cập qua `GoogleSignIn.instance` (không tạo instance riêng).
  /// Phải gọi `initialize(serverClientId:)` đúng 1 lần trước khi dùng.
  ///
  /// Guard idempotent — `initialize()` được chạy tối đa 1 lần, các lần sau
  /// await cùng Future (memoize) nên sign-in/sign-out cạnh tranh vẫn an toàn.
  Future<void>? _initFuture;

  Future<void> _ensureInitialized() {
    return _initFuture ??= GoogleSignIn.instance
        .initialize(serverClientId: _googleWebClientId)
        .catchError((Object e, StackTrace s) {
      _initFuture = null; // cho phép thử lại init nếu lần đầu fail.
      throw e;
    });
  }

  /// Số lần tự thử lại tối đa khi Google bị gián đoạn tạm thời
  /// (lỗi mạng/máy chủ GMS mint token không tới được OAuth endpoint).
  /// Lỗi kiểu này thường tự khỏi sau vài phút; retry giúp user khỏi phải
  /// bấm lại nhiều lần (bấm liên tục dễ bị Google nghi ngờ → chặn lâu hơn).
  static const int _maxTransientRetries = 2;

  /// Delay giữa các lần retry — tăng dần (backoff) để không spam Google.
  static const List<Duration> _retryBackoff = [
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];

  /// Đăng nhập Google → đổi idToken lấy server JWT.
  ///
  /// Tự retry (tối đa [_maxTransientRetries] lần, backoff) khi gặp lỗi
  /// thoáng qua phía Google. [onRetry] được gọi trước mỗi lần thử lại
  /// để UI hiển thị trạng thái (attempt bắt đầu từ 1).
  ///
  /// Returns `AuthResult` chứa user info, hoặc throws `AuthError` với
  /// user-friendly Vietnamese message.
  Future<AuthResult> signInWithGoogle({
    void Function(int attempt, int maxAttempts)? onRetry,
  }) async {
    await _ensureInitialized();
    var attempt = 0;
    while (true) {
      try {
        return await _signInWithGoogleOnce();
      } on AuthError catch (e) {
        if (!e.isTransient || attempt >= _maxTransientRetries) rethrow;
        attempt++;
        final delay = _retryBackoff[attempt - 1];
        AppLogger.warning(
          'Google Sign-In transient error, auto-retry $attempt/'
          '$_maxTransientRetries in ${delay.inSeconds}s: ${e.message}',
        );
        onRetry?.call(attempt, _maxTransientRetries);
        await Future<void>.delayed(delay);
      } catch (e) {
        final err = translateSignInError(e);
        if (!err.isTransient || attempt >= _maxTransientRetries) rethrow;
        attempt++;
        final delay = _retryBackoff[attempt - 1];
        AppLogger.warning(
          'Google Sign-In transient error, auto-retry $attempt/'
          '$_maxTransientRetries in ${delay.inSeconds}s',
          e,
        );
        onRetry?.call(attempt, _maxTransientRetries);
        await Future<void>.delayed(delay);
      }
    }
  }

  /// Một lượt đăng nhập đầy đủ: picker (Credential Manager) → idToken →
  /// đổi lấy server JWT.
  Future<AuthResult> _signInWithGoogleOnce() async {
    // v7: authenticate() trả về account luôn (không null); user huỷ sẽ
    // ném GoogleSignInException(code: canceled) — translateSignInError
    // xử lý thành "Đăng nhập đã bị huỷ" (không retry).
    final account = await GoogleSignIn.instance.authenticate();
    final auth = account.authentication;
    final idToken = auth.idToken;
    if (idToken == null) {
      throw AuthError(
        'Không lấy được idToken từ Google.',
        'Thiếu `serverClientId` (GOOGLE_WEB_CLIENT_ID) hoặc google-services.json '
            'chưa cấu hình đúng. Xem README → "Thiết lập đăng nhập Google".',
      );
    }

    final resp = await _repo.exchangeGoogleIdToken(idToken);
    // Log without username (PII) — only the JWT expiry timestamp.
    AppLogger.info(
      'Login successful (jwt expires ${resp.expiresAt.toIso8601String()})',
    );
    return AuthResult(user: resp.user, expiresAt: resp.expiresAt);
  }

  /// Đăng xuất: clear JWT + GoogleSignIn.signOut() để lần sau hiện picker.
  ///
  /// Also clears ALL local user data to prevent data leakage between
  /// accounts on a shared device:
  ///   - Downloaded chapters + images (Drift)
  ///   - Local bookmarks (Drift)
  ///   - Reading progress (Drift)
  ///   - TTS playback state (Drift) + stop active TTS
  ///   - Download queue (Drift)
  /// Without this, user A's data would be visible to user B after
  /// switching accounts.
  Future<void> signOut() async {
    // Stop TTS first — otherwise it keeps playing user A's chapter
    // under user B's session.
    try {
      final handler = await _ref.read(ttsHandlerProvider.future);
      await handler.stop();
    } catch (e) {
      AppLogger.warning('TTS stop on signOut failed (ignored)', e);
    }

    await _ensureInitialized();
    try {
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      AppLogger.warning('GoogleSignIn.signOut() failed (ignored)', e);
    }
    await _api.clearJwt();

    // Clear local user data. Best-effort — log but don't throw if a
    // delete fails (e.g. DB locked); the JWT is already cleared so the
    // user is effectively logged out.
    try {
      await _db.deleteAllDownloadedChapters();
    } catch (e) {
      AppLogger.warning('deleteAllDownloadedChapters on signOut failed', e);
    }
    // File ảnh manga + bảng downloaded_chapter_images — trước đây không
    // được xoá → hàng trăm MB ảnh + rows bị bỏ lại vĩnh viễn sau logout.
    try {
      await _ref.read(mangaImageDownloaderProvider).deleteAllImages();
    } catch (e) {
      AppLogger.warning('deleteAllImages on signOut failed', e);
    }
    try {
      await _db.clearDownloadQueue();
    } catch (e) {
      AppLogger.warning('clearDownloadQueue on signOut failed', e);
    }
    // Bookmark + reading progress + TTS state cũng là dữ liệu cá nhân —
    // xoá để không lộ cho user kế tiếp trên shared device.
    try {
      await _db.clearAllBookmarks();
    } catch (e) {
      AppLogger.warning('clearAllBookmarks on signOut failed', e);
    }
    try {
      await _db.clearAllReadingProgress();
    } catch (e) {
      AppLogger.warning('clearAllReadingProgress on signOut failed', e);
    }
    try {
      await _db.clearAllTtsState();
    } catch (e) {
      AppLogger.warning('clearAllTtsState on signOut failed', e);
    }
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
  const AuthError(this.message, this.hint, {this.isTransient = false});
  final String message;
  final String hint;

  /// `true` = lỗi thoáng qua phía Google/mạng (retry có thể cứu),
  /// `false` = lỗi cấu hình/cố định (retry vô ích).
  final bool isTransient;

  @override
  String toString() => message;
}

/// Provider cho AuthService. Singleton — dùng chung cho toàn app.
final authServiceProvider = Provider<AuthService>((ref) {
  final api = ref
      .watch(apiClientProvider)
      .maybeWhen(
        data: (c) => c,
        orElse: () => throw StateError('ApiClient not ready'),
      );
  final repo = ref.watch(storyRepositoryProvider);
  final db = ref.watch(appDatabaseProvider);
  return AuthService(api, repo, db, ref);
});

/// Translate raw Google Sign-In exceptions thành user-friendly Vietnamese.
///
/// google_sign_in v7 ném `GoogleSignInException` với mã enum
/// `GoogleSignInExceptionCode`:
///   - canceled / interrupted   → user huỷ / gián đoạn → không retry
///   - clientConfigurationError → SHA-1/package chưa đăng ký trên OAuth
///                                client (tương đương ApiException 10)
///   - providerConfigurationError → GMS auth SDK lỗi cấu hình
///   - uiUnavailable / userMismatch → cố định → không retry
///   - unknownError             → catch-all (thường là lỗi mạng/nội bộ
///                                GMS) → retry được
///
/// Ngoài ra vẫn giữ fallback string-based cho `PlatformException`/lỗi
/// backend (Dio) lọt xuống đây.
AuthError translateSignInError(Object e) {
  if (e is GoogleSignInException) {
    switch (e.code) {
      case GoogleSignInExceptionCode.canceled:
      case GoogleSignInExceptionCode.interrupted:
        // Trên thực tế plugin map nhiều lỗi thoáng qua phía Google thành
        // `canceled` — điển hình là "[16] Account reauth failed" (tài khoản
        // cần xác thực lại, thường tự khỏi sau vài phút). Nếu description
        // cho thấy đây là lỗi reauth chứ KHÔNG phải user chủ động hủy →
        // coi là transient để auto-retry (user hủy thật không có description
        // dạng "[<code>] ...").
        final desc = e.description ?? '';
        final isReauth = desc.contains('reauth') ||
            desc.startsWith('[16]') ||
            desc.contains('Account reauth failed');
        if (isReauth) {
          return AuthError(
            'Google yêu cầu xác thực lại tài khoản.',
            'Lỗi thoáng qua từ phía Google — hệ thống đã tự thử lại. '
                'Nếu vẫn lỗi, hãy chờ vài phút rồi thử lại.',
            isTransient: true,
          );
        }
        return const AuthError('Đăng nhập đã bị huỷ.', '');
      case GoogleSignInExceptionCode.clientConfigurationError:
        return AuthError(
          'Lỗi cấu hình Google Sign-In (clientConfigurationError).',
          'SHA-1 của APK chưa được thêm vào OAuth Client ID trên Google '
              'Cloud Console, hoặc package name không khớp. Xem hướng dẫn '
              'trong README → "Thiết lập đăng nhập Google".',
        );
      case GoogleSignInExceptionCode.providerConfigurationError:
        return AuthError(
          'Lỗi cấu hình Google Sign-In (providerConfigurationError).',
          'Google Play Services trên thiết bị đang lỗi cấu hình hoặc phiên '
              'bản cũ. Hãy cập nhật Google Play Services rồi thử lại.',
        );
      case GoogleSignInExceptionCode.uiUnavailable:
      case GoogleSignInExceptionCode.userMismatch:
        return AuthError(
          'Đăng nhập Google không khả dụng ngay lúc này.',
          'Giao diện đăng nhập (Credential Manager) không hiển thị được '
              'hoặc tài khoản không khớp. Vui lòng thử lại.',
        );
      case GoogleSignInExceptionCode.unknownError:
        return AuthError(
          'Lỗi tạm thời khi đăng nhập Google.',
          'Mạng hoặc máy chủ Google tạm bị gián đoạn — không phải do app. '
              'Hệ thống đã tự thử lại; nếu vẫn lỗi hãy chờ 5-10 phút rồi '
              'thử lại. Bấm đăng nhập liên tục có thể bị Google tạm chặn '
              'lâu hơn.',
          isTransient: true,
        );
    }
  }

  // Fallback cho PlatformException / lỗi backend — giữ logic cũ (ApiException
  // codes) phòng khi plugin platform trả lỗi dạng cũ.
  final msg = e.toString();
  // Google Play Services ApiException codes:
  //   10  = DEVELOPER_ERROR → SHA-1 / package name not registered
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
    return AuthError(
      'Lỗi mạng khi đăng nhập.',
      'Mạng hoặc máy chủ Google tạm bị gián đoạn — không phải do app. '
          'Hệ thống đã tự thử lại; nếu vẫn lỗi hãy chờ 5-10 phút rồi thử lại. '
          'Bấm đăng nhập liên tục có thể bị Google tạm chặn lâu hơn.',
      isTransient: true,
    );
  } else if (msg.contains('8:') || msg.contains('INTERNAL_ERROR')) {
    return AuthError(
      'Lỗi nội bộ Google Play Services.',
      'Lỗi tạm thời từ phía Google, không phải do app. Hệ thống đã tự thử '
          'lại; nếu vẫn lỗi, hãy chờ vài phút rồi thử lại.',
      isTransient: true,
    );
  }
  return AuthError('Đăng nhập thất bại.', 'Chi tiết: $msg');
}
