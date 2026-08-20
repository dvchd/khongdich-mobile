import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:khongdich_mobile/core/auth/auth_service.dart';

void main() {
  group('translateSignInError (google_sign_in v7)', () {
    test('unknownError là lỗi thoáng qua → retry được', () {
      final e = GoogleSignInException(
        code: GoogleSignInExceptionCode.unknownError,
        description: 'Network error',
      );
      final err = translateSignInError(e);
      expect(err.isTransient, isTrue);
      expect(err.message, contains('Lỗi tạm thời'));
      expect(err.hint, contains('tự thử lại'));
    });

    test('clientConfigurationError là lỗi cấu hình → KHÔNG retry', () {
      // Tương đương ApiException 10 (DEVELOPER_ERROR) — SHA-1 sai.
      final e = GoogleSignInException(
        code: GoogleSignInExceptionCode.clientConfigurationError,
        description: 'misconfigured client',
      );
      final err = translateSignInError(e);
      expect(err.isTransient, isFalse);
      expect(err.message, contains('clientConfigurationError'));
      expect(err.hint, contains('SHA-1'));
    });

    test('providerConfigurationError là lỗi cấu hình → KHÔNG retry', () {
      final e = GoogleSignInException(
        code: GoogleSignInExceptionCode.providerConfigurationError,
        description: 'auth sdk unavailable',
      );
      final err = translateSignInError(e);
      expect(err.isTransient, isFalse);
      expect(err.message, contains('providerConfigurationError'));
    });

    test('canceled → không retry, không hiện hint', () {
      final e = GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
        description: 'user canceled',
      );
      final err = translateSignInError(e);
      expect(err.isTransient, isFalse);
      expect(err.message, 'Đăng nhập đã bị huỷ.');
      expect(err.hint, isEmpty);
    });

    test('uiUnavailable / userMismatch → không retry', () {
      for (final code in [
        GoogleSignInExceptionCode.uiUnavailable,
        GoogleSignInExceptionCode.userMismatch,
      ]) {
        final err = translateSignInError(
          GoogleSignInException(code: code),
        );
        expect(err.isTransient, isFalse);
      }
    });
  });

  group('translateSignInError (fallback cũ, PlatformException)', () {
    test('ApiException 7 (NETWORK_ERROR) → retry được', () {
      final e = PlatformException(
        code: 'sign_in_failed',
        message: 'com.google.android.gms.common.api.ApiException: 7: '
            'NetworkError, null, null',
      );
      final err = translateSignInError(e);
      expect(err.isTransient, isTrue);
      expect(err.message, contains('Lỗi mạng'));
    });

    test('ApiException 10 (DEVELOPER_ERROR) → không retry', () {
      final e = PlatformException(
        code: 'sign_in_failed',
        message: 'com.google.android.gms.common.api.ApiException: 10: , '
            'null, null',
      );
      final err = translateSignInError(e);
      expect(err.isTransient, isFalse);
      expect(err.message, contains('DEVELOPER_ERROR'));
      expect(err.hint, contains('SHA-1'));
    });

    test('Lỗi không xác định → không retry, kèm chi tiết', () {
      final err = translateSignInError(StateError('lạ'));
      expect(err.isTransient, isFalse);
      expect(err.message, 'Đăng nhập thất bại.');
      expect(err.hint, contains('lạ'));
    });
  });
}