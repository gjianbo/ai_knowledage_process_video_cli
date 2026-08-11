import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionStore {
  SessionStore({
    FlutterSecureStorage? secureStorage,
    SharedPreferencesAsync? preferences,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _preferences = preferences ?? SharedPreferencesAsync();

  static const _serverKey = 'hive_cli.server_url';
  static const _tokenKey = 'hive_cli.jwt';
  static const _autoUploadKey = 'hive_cli.auto_upload';
  final FlutterSecureStorage _secureStorage;
  final SharedPreferencesAsync _preferences;

  Future<StoredSession?> readSession() async {
    final server = await _preferences.getString(_serverKey);
    final token = await _secureStorage.read(key: _tokenKey);
    if (server == null || server.isEmpty || token == null || token.isEmpty) {
      await clearSession();
      return null;
    }
    return StoredSession(server: server, token: token);
  }

  Future<void> saveSession({
    required String server,
    required String token,
  }) async {
    await Future.wait([
      _preferences.setString(_serverKey, server),
      _secureStorage.write(key: _tokenKey, value: token),
    ]);
  }

  Future<void> clearSession() async => Future.wait([
    _preferences.remove(_serverKey),
    _secureStorage.delete(key: _tokenKey),
  ]);

  Future<bool> readAutoUpload() async =>
      await _preferences.getBool(_autoUploadKey) ?? true;
  Future<void> saveAutoUpload(bool value) =>
      _preferences.setBool(_autoUploadKey, value);
}

class StoredSession {
  const StoredSession({required this.server, required this.token});
  final String server;
  final String token;
}
