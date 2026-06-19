import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Encrypted on-device storage for auth tokens and other secrets.
///
/// Plan §3 (Auth & Storage → flutter_secure_storage). On Android it backs
/// onto EncryptedSharedPreferences; on iOS the Keychain.
class SecureStorage {
  SecureStorage(this._storage);

  final FlutterSecureStorage _storage;

  static const _kJwt = 'jwt';

  Future<String?> readJwt() => _storage.read(key: _kJwt);
  Future<void> writeJwt(String jwt) => _storage.write(key: _kJwt, value: jwt);
  Future<void> deleteJwt() => _storage.delete(key: _kJwt);
}

final secureStorageProvider = Provider<SecureStorage>((ref) {
  return SecureStorage(const FlutterSecureStorage());
});
