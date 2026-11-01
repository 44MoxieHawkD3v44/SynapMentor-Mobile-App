import 'dart:io';

import '../services/auth_service.dart' show AuthException;
import 'api_client.dart';
import 'session_store.dart';

/// Auth endpoints (Postman: Shared > Auth, Seeker App > Auth).
abstract final class AuthApi {
  static ApiClient get _api => ApiClient.instance;

  /// POST /auth/login. Sets the session cookies; returns `{user_id, role, …}`.
  static Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    bool rememberMe = true,
  }) async {
    final data = await _api.post(
      '/auth/login',
      data: {
        'email': email.trim(),
        'password': password,
        'remember_me': rememberMe,
        'recaptcha_token': ApiConfig.recaptchaToken,
      },
    );
    return _map(data);
  }

  /// POST /auth/request-otp. Emails a 6-digit sign-in code; the reply is the
  /// same whether or not the email is registered.
  static Future<void> requestLoginOtp(String email) => _api.post('/auth/request-otp', data: {'email': email.trim()});

  /// POST /auth/verify-otp. Signs in like [login].
  static Future<Map<String, dynamic>> verifyLoginOtp({
    required String email,
    required String otp,
    bool rememberMe = true,
  }) async => _map(
    await _api.post('/auth/verify-otp', data: {'email': email.trim(), 'otp': otp.trim(), 'remember_me': rememberMe}),
  );

  /// POST /auth/request-magic-link. Emails a sign-in link (valid 24 hours).
  static Future<void> requestMagicLink(String email) =>
      _api.post('/auth/request-magic-link', data: {'email': email.trim()});

  /// POST /auth/verify-magic-link with the token from the emailed link.
  static Future<Map<String, dynamic>> verifyMagicLink(String token, {bool rememberMe = true}) async =>
      _map(await _api.post('/auth/verify-magic-link', data: {'token': token, 'remember_me': rememberMe}));

  /// POST /auth/recover-account. Signs in with a single-use backup code and
  /// ends the account's other sessions.
  static Future<Map<String, dynamic>> recoverAccount({required String email, required String backupCode}) async =>
      _map(await _api.post('/auth/recover-account', data: {'email': email.trim(), 'backup_code': backupCode.trim()}));

  /// POST /auth/register. Always answers the same way (the server doesn't
  /// reveal whether the email exists); a verification link is emailed.
  static Future<String?> register({
    required String fullName,
    required String email,
    required String password,
    required String role,
    String? referralCode,
  }) async {
    final data = await _api.post(
      '/auth/register',
      data: {
        'full_name': fullName.trim(),
        'email': email.trim(),
        'password': password,
        'confirm_password': password,
        'role': role,
        if (referralCode != null && referralCode.trim().isNotEmpty) 'referral_code': referralCode.trim(),
        'eula_accepted': true,
        'recaptcha_token': ApiConfig.recaptchaToken,
      },
    );
    return _map(data)['message'] as String?;
  }

  /// POST /auth/verify-email with the token from the emailed link.
  static Future<String?> verifyEmail(String token) async =>
      _map(await _api.post('/auth/verify-email', data: {'token': token}))['message'] as String?;

  /// POST /auth/resend-verification.
  static Future<String?> resendVerification(String email) async =>
      _map(await _api.post('/auth/resend-verification', data: {'email': email.trim()}))['message'] as String?;

  /// POST /auth/forgot-password. [method] is `otp` or `magic_link`.
  static Future<String?> forgotPassword(String email, String method) async =>
      _map(await _api.post('/auth/forgot-password', data: {'email': email.trim(), 'method': method}))['message']
          as String?;

  /// POST /auth/reset-password-otp.
  static Future<String?> resetPasswordWithOtp({
    required String email,
    required String otp,
    required String newPassword,
  }) async =>
      _map(
            await _api.post(
              '/auth/reset-password-otp',
              data: {'email': email.trim(), 'otp': otp, 'new_password': newPassword, 'confirm_password': newPassword},
            ),
          )['message']
          as String?;

  /// POST /auth/reset-password with the token from the emailed link.
  static Future<String?> resetPasswordWithLink({required String token, required String newPassword}) async =>
      _map(
            await _api.post(
              '/auth/reset-password',
              data: {'token': token, 'new_password': newPassword, 'confirm_password': newPassword},
            ),
          )['message']
          as String?;

  /// POST /auth/logout. Revokes the session on the server; the app sends its
  /// refresh token in the body.
  static Future<void> logout() => _api.post(
    '/auth/logout',
    data: {if (SessionStore.instance.refreshToken != null) 'refresh_token': SessionStore.instance.refreshToken},
  );

  /// GET /auth/ws-token: the access token to pass on the WebSocket upgrade.
  static Future<String?> wsToken() async => _map(await _api.get('/auth/ws-token'))['token'] as String?;

  /// GET /auth/oauth/providers, e.g. `["github"]`.
  static Future<List<String>> oauthProviders() async {
    final providers = _map(await _api.get('/auth/oauth/providers'))['providers'];
    return providers is List ? providers.map((p) => '$p').toList() : const [];
  }

  /// GET /auth/oauth/github/start without following it: GitHub's sign-in page
  /// to open, and the nonce the callback must bring back. [signup] creates the
  /// account straight away for [role] (with the EULA accepted); otherwise an
  /// unknown GitHub account ends with a pending signup.
  static Future<({Uri authorizeUrl, String nonce})> githubStart({
    bool signup = false,
    String? role,
    String? referralCode,
  }) async {
    final response = await _api.getRedirect(
      '/auth/oauth/github/start',
      query: {
        if (signup) ...{'signup': '1', 'eula': '1', 'role': ?role},
        if (referralCode != null && referralCode.trim().isNotEmpty) 'ref': referralCode.trim(),
      },
    );
    final location = Uri.tryParse(response.headers.value(HttpHeaders.locationHeader) ?? '');
    final nonce = ApiClient.cookieIn(response, 'oauth_nonce');
    if (location == null || nonce == null || location.host != 'github.com') {
      throw AuthException(
        location?.queryParameters['oauth_error'] ??
            'GitHub sign-in isn\'t available right now. Please try again later.',
      );
    }
    return (authorizeUrl: location, nonce: nonce);
  }

  /// GET /auth/oauth/github/callback with GitHub's answer ([query]: code and
  /// state) and the nonce from [githubStart]. A known account is signed in
  /// (the session cookies are saved); an unknown one returns the pending
  /// signup cookie for [completeOAuthSignup].
  static Future<({String? pendingSignup})> githubCallback(Map<String, String> query, String nonce) async {
    final response = await _api.getRedirect('/auth/oauth/github/callback', query: query, cookie: 'oauth_nonce=$nonce');
    final location = Uri.tryParse(response.headers.value(HttpHeaders.locationHeader) ?? '');
    final error = location?.queryParameters['oauth_error'];
    if (error != null) throw AuthException(error);
    final pending = ApiClient.cookieIn(response, 'oauth_signup');
    if (pending == null && SessionStore.instance.accessToken == null && SessionStore.instance.refreshToken == null) {
      throw const AuthException('GitHub sign-in didn\'t finish. Please try again.');
    }
    return (pendingSignup: pending);
  }

  /// POST /auth/oauth/complete-signup with the pending-signup cookie from the
  /// GitHub sign-in. The session comes back as cookies. Returns `{user_id,
  /// role}`.
  static Future<Map<String, dynamic>> completeOAuthSignup({required String signupCookie, required String role}) async =>
      _map(
        await _api.post(
          '/auth/oauth/complete-signup',
          data: {'role': role, 'eula_accepted': true},
          extra: {'cookie': 'oauth_signup=$signupCookie'},
        ),
      );

  /// The signed-in user's profile: GET /seeker/profile or /solver/profile.
  /// The seeker endpoint nests it under `profile`.
  static Future<Map<String, dynamic>> profile(String role) async {
    final data = _map(await _api.get(role == 'solver' ? '/solver/profile' : '/seeker/profile'));
    final nested = data['profile'];
    return nested is Map ? Map<String, dynamic>.from(nested) : data;
  }

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
