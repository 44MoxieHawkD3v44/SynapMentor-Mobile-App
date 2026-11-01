import 'api_client.dart';

/// The signed-in user's own account for both roles: profile, photo, pseudo
/// name, pricing, password, account status and settings (Postman: Seeker App >
/// Profile, Settings; Solver App > Profile, Setting). [role] is `seeker` or
/// `solver`.
abstract final class AccountApi {
  static ApiClient get _api => ApiClient.instance;

  static bool _solver(String role) => role == 'solver';

  /// POST /seeker/profile or /solver/profile. Only fields that changed are
  /// written. The seeker endpoint returns the updated profile; the solver one
  /// returns nothing, so it's read back.
  static Future<Map<String, dynamic>> updateProfile(String role, Map<String, dynamic> fields) async {
    final data = _map(await _api.post('/$role/profile', data: fields));
    return _solver(role) ? _map(await _api.get('/solver/profile')) : _map(data['updated_profile']);
  }

  /// POST /…/profile/image (up to 5 MB). Returns the new avatar link.
  static Future<String?> uploadImage(String role, String path) async {
    final data = _map(
      await _api.upload(
        '/$role/profile/image',
        files: [UploadFile(field: _solver(role) ? 'image' : 'file', path: path)],
      ),
    );
    return (data[_solver(role) ? 'image_url' : 'profile_image_url']) as String?;
  }

  /// DELETE /seeker/profile/image. Solvers have no endpoint for this yet.
  static Future<void> removeImage() => _api.delete('/seeker/profile/image');

  /// GET /…/profile/pseudo-name/generate: an unused suggestion.
  static Future<String> generatePseudoName(String role) async =>
      _map(await _api.get('/$role/profile/pseudo-name/generate'))['pseudo_name'] as String? ?? '';

  /// POST /…/profile/pseudo-name. Sets it once and locks it.
  static Future<void> setPseudoName(String role, String name) =>
      _api.post('/$role/profile/pseudo-name', data: {'pseudo_name': name.trim()});

  /// POST /solver/profile/pricing with one of the solver's unlocked tier
  /// prices.
  static Future<void> setPrice(num pricePerMinute) =>
      _api.post('/solver/profile/pricing', data: {'price_per_minute': pricePerMinute});

  /// GET /solver/expertise/: `{skills, projects, languages, verified_skills}`.
  static Future<Map<String, dynamic>> solverExpertise() async => _map(await _api.get('/solver/expertise/'));

  /// GET /solver/setting/country: the solver's currency `{currency, symbol,
  /// base_rate_inr, rate_per_minute, fx_rate}`.
  static Future<Map<String, dynamic>> solverCountry() async => _map(await _api.get('/solver/setting/country'));

  /// Changes the password. Ends every session.
  /// POST /solver/setting/change-phone: checks the password and emails a
  /// 6-digit code to confirm the move to [newPhone] (E.164). 409 when the
  /// number is verified on another account.
  static Future<void> requestPhoneChange({required String currentPassword, required String newPhone}) =>
      _api.post('/solver/setting/change-phone', data: {'current_password': currentPassword, 'new_phone': newPhone});

  /// POST /solver/setting/verify-phone-change with the emailed [code]: the
  /// verified number moves to the new one and every session ends.
  static Future<void> confirmPhoneChange(String code) =>
      _api.post('/solver/setting/verify-phone-change', data: {'otp': code});

  static Future<void> changePassword(String role, {required String current, required String newPassword}) => _api.post(
    _solver(role) ? '/solver/setting/change-password' : '/seeker/profile/change-password',
    data: {'current_password': current, 'new_password': newPassword, 'confirm_password': newPassword},
  );

  /// POST /seeker/profile/deactivate-account. Signing in within 30 days
  /// reactivates it. Solvers have no endpoint for this yet.
  static Future<void> deactivate(String password) => _api.post(
    '/seeker/profile/deactivate-account',
    data: {'current_password': password, 'confirmation_text': 'deactivate'},
  );

  /// Schedules permanent deletion.
  static Future<void> delete(String role, String password) => _solver(role)
      ? _api.post('/solver/setting/delete', data: {'current_password': password})
      : _api.delete('/seeker/profile', data: {'confirmation_text': 'DELETE MY ACCOUNT', 'current_password': password});

  /// The user's settings: `{notifications: {...}, privacy: {...}, mfa: {...}}`.
  static Future<Map<String, dynamic>> settings(String role) async =>
      _map(await _api.get(_solver(role) ? '/solver/setting/' : '/seeker/settings/'));

  /// Saves one notification switch, e.g. `email_alerts`.
  static Future<void> setNotification(String role, String type, bool value) => _solver(role)
      ? _api.post('/solver/setting/notifications', data: {type: value})
      : _api.post('/seeker/settings/notifications/$type', data: {'value': value});

  /// Whether the account can switch roles now.
  static Future<Map<String, dynamic>> switchRoleStatus(String role) async =>
      _map(await _api.get(_solver(role) ? '/solver/setting/switch-role' : '/seeker/settings/switch-role'));

  /// Switches to the other role. Ends every session.
  static Future<void> switchRole(String role) =>
      _api.post(_solver(role) ? '/solver/setting/switch-role' : '/seeker/settings/switch-role');

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
