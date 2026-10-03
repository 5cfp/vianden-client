import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Remembers the chosen server and the session token between app starts.
///
/// An interface, so tests can use an in-memory version instead of the real OS storage.
abstract interface class SessionStore {
  Future<String?> readServer();
  Future<void> writeServer(String server);
  Future<String?> readToken();
  Future<void> writeToken(String token);
  Future<void> deleteToken();

  /// Forgets everything (server and token).
  Future<void> clear();
}

/// Stores data with the operating system's protected storage
/// (on Windows: encrypted with the user's Windows login, via DPAPI).
///
/// The session token is as sensitive as a password: anyone who has it is logged in
/// as you. So it never goes into a plain settings file.
class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _serverKey = 'server_address';
  static const _tokenKey = 'session_token';

  @override
  Future<String?> readServer() => _storage.read(key: _serverKey);

  @override
  Future<void> writeServer(String server) =>
      _storage.write(key: _serverKey, value: server);

  @override
  Future<String?> readToken() => _storage.read(key: _tokenKey);

  @override
  Future<void> writeToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  @override
  Future<void> deleteToken() => _storage.delete(key: _tokenKey);

  @override
  Future<void> clear() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _serverKey);
  }
}
