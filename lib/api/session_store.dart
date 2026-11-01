import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The signed-in session, kept in the platform's secure storage (Keychain on
/// iOS, Keystore-backed storage on Android) and mirrored in memory so requests
/// don't wait on storage.
///
/// The API sets its tokens as cookies; they're captured from `Set-Cookie` and
/// sent back by [ApiClient], so the session works over HTTP and HTTPS alike.
class SessionStore {
  SessionStore._();

  static final SessionStore instance = SessionStore._();

  static const _storage = FlutterSecureStorage();

  static const _accessKey = 'session.access_token';
  static const _refreshKey = 'session.refresh_token';
  static const _csrfKey = 'session.csrf_token';
  static const _roleKey = 'session.role';
  static const _userIdKey = 'session.user_id';

  String? accessToken;
  String? refreshToken;
  String? csrfToken;
  String? role;
  String? userId;

  bool get hasSession => accessToken != null || refreshToken != null;

  /// Loads the saved session once at startup.
  Future<void> load() async {
    try {
      final values = await _storage.readAll();
      accessToken = values[_accessKey];
      refreshToken = values[_refreshKey];
      csrfToken = values[_csrfKey];
      role = values[_roleKey];
      userId = values[_userIdKey];
    } catch (e) {
      // No secure storage available (e.g. tests): start signed out.
      debugPrint('SessionStore: secure storage unavailable');
    }
  }

  Future<void> setAccessToken(String? value) => _set(_accessKey, accessToken = value);
  Future<void> setRefreshToken(String? value) => _set(_refreshKey, refreshToken = value);
  Future<void> setCsrfToken(String? value) => _set(_csrfKey, csrfToken = value);

  Future<void> setUser({required String role, String? userId}) async {
    this.role = role;
    this.userId = userId;
    await _set(_roleKey, role);
    await _set(_userIdKey, userId);
  }

  /// Signs out locally: forgets every token and the user. The CSRF token is
  /// kept, as the server ties it to the device, not the account.
  Future<void> clear() async {
    accessToken = refreshToken = role = userId = null;
    for (final key in [_accessKey, _refreshKey, _roleKey, _userIdKey]) {
      await _set(key, null);
    }
  }

  Future<void> _set(String key, String? value) async {
    try {
      if (value == null || value.isEmpty) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: value);
      }
    } catch (_) {
      // Keep working in memory if storage is unavailable.
    }
  }
}
