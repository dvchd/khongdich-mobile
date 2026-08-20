import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/core/auth/auth_service.dart';

void main() {
  group('translateSignInError', () {
    test('NETWORK_ERROR (code 7) là lỗi thoáng qua → retry được', () {
      final e = PlatformException(
        code: 'sign_in_failed',
        message: 'com.google.android.gms.common.api.ApiException: 7: '
            'NetworkError, null, null',
      );
      final err = translateSignInError(e);
      expect(err.isTransient, isTrue);
      expect(err.message, contains('Lỗi mạng'));
      expect(err.hint, contains('tự thử lại'));
    });

    test('INTERNAL_ERROR (code 8) là lỗi thoáng qua → retry được', () {
      final e = PlatformException(
        code: 'sign_in_failed',
        message: 'com.google.android.gms.common.api.ApiException: 8: '
            'InternalError, null, null',
      );
      final err = translateSignInError(e);
      expect(err.isTransient, isTrue);
      expect(err.message, contains('Lỗi nội bộ'));
    });

    test('DEVELOPER_ERROR (code 10) là lỗi cấu hình → KHÔNG retry', () {
      // String thực tế từ emulator (debug build, SHA-1 sai):
      // PlatformException(sign_in_failed, com.google.android.gms.common.api
      // .ApiException: 10: , null, null)
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

    test('User huỷ (12500) → không retry, không hiện hint', () {
      final e = PlatformException(
        code: 'sign_in_canceled',
        message: 'com.google.android.gms.common.api.ApiException: 12500: , '
            'null, null',
      );
      final err = translateSignInError(e);
      expect(err.isTransient, isFalse);
      expect(err.hint, isEmpty);
    });

    test('Lỗi không xác định → không retry, kèm chi tiết', () {
      final err = translateSignInError(StateError('lạ'));
      expect(err.isTransient, isFalse);
      expect(err.message, 'Đăng nhập thất bại.');
      expect(err.hint, contains('lạ'));
    });
  });
}