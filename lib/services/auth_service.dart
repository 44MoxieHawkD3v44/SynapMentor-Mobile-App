import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../api/account_api.dart';
import '../api/api_client.dart';
import '../api/auth_api.dart';
import '../api/session_store.dart';
import 'countries.dart';
import 'password_policy.dart';
import 'push_notifications.dart';
import 'solver_service.dart';

/// Whether verification results (KYC, skill verification) gate features:
/// solver bookings, being listed for seekers, KYC-only booking types and
/// publishing content. Off while verification runs as a dummy flow; the
/// verification screens still work, they just never block anything.
const bool kEnforceVerification = false;

enum UserRole {
  seeker('Problem Seeker'),
  solver('Problem Solver');

  const UserRole(this.label);
  final String label;
}

enum ResetMethod { otp, magicLink }

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

class AppUser {
  AppUser({
    required this.email,
    required this.name,
    required this.role,
    required this.backupCodes,
    this.emailVerified = false,
    this.referralCode,
  });

  final String email;
  String name;

  /// Switchable from Settings; the same credentials serve both roles.
  UserRole role;
  final List<String> backupCodes;
  final String? referralCode;
  bool emailVerified;

  /// Deactivated accounts reactivate on their next successful sign-in.
  bool deactivated = false;
  late UserProfile profile = UserProfile.fromName(name);
}

class UserProfile {
  UserProfile({
    this.photoPath,
    this.firstName = '',
    this.lastName = '',
    this.countryName,
    this.city,
    this.phone = '',
    this.gender,
    this.dateOfBirth,
    this.timezone,
    this.bio = '',
    this.pseudoName,
  });

  factory UserProfile.fromName(String fullName) {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    return UserProfile(firstName: parts.first, lastName: parts.skip(1).join(' '));
  }

  String? photoPath;
  String firstName;
  String lastName;

  /// Drives the phone code, currency and timezone. See [Countries].
  String? countryName;
  String? city;

  /// Digits only, without the country code.
  String phone;
  String? gender;
  DateTime? dateOfBirth;

  /// IANA zone id, e.g. `Asia/Kolkata`. Every time in the app is shown in it.
  String? timezone;
  String bio;

  /// Public identity in the Community. Once set it can't be changed.
  String? pseudoName;

  UserProfile copy() => UserProfile(
    photoPath: photoPath,
    firstName: firstName,
    lastName: lastName,
    countryName: countryName,
    city: city,
    phone: phone,
    gender: gender,
    dateOfBirth: dateOfBirth,
    timezone: timezone,
    bio: bio,
    pseudoName: pseudoName,
  );
}

/// Authentication and the signed-in user. Sign-in, registration, password
/// reset and sign-out go to the API (see [AuthApi]); the session lives in
/// [SessionStore]. Both roles' profile and account settings go to the API too
/// (see [AccountApi]).
class AuthService {
  static final AuthService instance = AuthService();

  final _random = Random.secure();
  final _accounts = <String, AppUser>{};

  AppUser? currentUser;

  /// The solver account behind a public solver profile, if one is registered.
  AppUser? solverAccountNamed(String name) =>
      _accounts.values.where((u) => u.role == UserRole.solver && u.name == name).firstOrNull;

  // ---- Sign in -------------------------------------------------------------

  Future<AppUser> signInWithPassword(String email, String password) async {
    return _completeSignIn(await AuthApi.login(email: email, password: password));
  }

  /// Every sign-in method ends here: the tokens are already saved by the API
  /// client, so remember who signed in and load their profile.
  Future<AppUser> _completeSignIn(Map<String, dynamic> result) async {
    if (result['mfa_required'] == true) {
      throw const AuthException('This account uses two-step verification, which the app doesn\'t support yet.');
    }
    final role = result['role'] as String? ?? 'seeker';
    await SessionStore.instance.setUser(role: role, userId: result['user_id'] as String?);
    return _loadUser(role);
  }

  /// Signs back in from the saved session at launch. Null when there's no
  /// session or it can't be renewed.
  Future<AppUser?> restoreSession() async {
    final session = SessionStore.instance;
    final role = session.role;
    if (!session.hasSession || role == null) return null;
    try {
      return await _loadUser(role);
    } on AuthException {
      await session.clear();
      return null;
    }
  }

  /// Reads the signed-in user's profile again, e.g. after a price change, so
  /// what's shown matches the server.
  Future<void> reloadProfile() async {
    final user = _requireSession();
    await _applyProfile(user, await AuthApi.profile(user.role.name));
  }

  /// Loads the profile for [role] and makes it the current user.
  Future<AppUser> _loadUser(String role) async {
    final p = await AuthApi.profile(role);
    final email = (p['email'] as String?)?.trim() ?? '';
    final user = AppUser(
      email: email,
      name: email.split('@').first,
      role: role == 'solver' ? UserRole.solver : UserRole.seeker,
      backupCodes: [],
      emailVerified: true,
      referralCode: p['referral_code'] as String?,
    );
    await _applyProfile(user, p);
    _accounts[_normalize(email)] = user;
    return currentUser = user;
  }

  // The API's gender values and the labels the profile shows.
  static const _genders = {
    'male': 'Male',
    'female': 'Female',
    'other': 'Non-binary',
    'prefer_not_to_say': 'Prefer not to say',
  };

  /// Copies the API profile onto [user], keeping the photo already on the
  /// device when the server's avatar hasn't changed.
  Future<void> _applyProfile(AppUser user, Map<String, dynamic> p) async {
    String text(String key) => (p[key] as String?)?.trim() ?? '';
    final country = Countries.find(text('country'));
    final dial = country?.dialCode.replaceAll('+', '');
    var phone = text('phone').replaceAll(RegExp(r'\D'), '');
    if (dial != null &&
        phone.length > country!.minPhoneDigits &&
        phone.startsWith(dial) &&
        country.phoneFits(phone.length - dial.length)) {
      phone = phone.substring(dial.length);
    }
    final avatar = text('avatar_url');
    final first = text('first_name');
    final last = text('last_name');
    final name = '$first $last'.trim();
    final dob = DateTime.tryParse(text('date_of_birth'));
    user
      ..name = name.isNotEmpty ? name : user.email.split('@').first
      ..profile = UserProfile(
        photoPath: avatar.isEmpty ? null : await _avatarFile(avatar, user.profile.photoPath),
        firstName: first,
        lastName: last,
        countryName: country?.name,
        city: text('city').isEmpty ? null : text('city'),
        phone: phone,
        gender: _genders[text('gender').toLowerCase()],
        dateOfBirth: dob == null ? null : DateTime(dob.year, dob.month, dob.day),
        timezone: text('timezone').isEmpty ? null : text('timezone'),
        bio: text('bio'),
        pseudoName: text('pseudo_name').isEmpty ? null : text('pseudo_name'),
      );
    // A solver's profile also carries their pricing tiers and languages.
    if (user.role == UserRole.solver) SolverService.instance.applyProfile(user, p);
  }

  /// The avatar is behind sign-in, so it's downloaded once per version to a
  /// cached file the profile shows.
  Future<String?> _avatarFile(String url, String? current) async {
    final version = Uri.tryParse(url)?.queryParameters['v'] ?? '0';
    final file = File('${Directory.systemTemp.path}/avatar_$version.img');
    if (current == file.path && file.existsSync()) return file.path;
    try {
      if (!file.existsSync()) await file.writeAsBytes(await ApiClient.instance.download(url), flush: true);
      return file.path;
    } catch (_) {
      return current; // shown again on the next load
    }
  }

  Future<void> sendLoginOtp(String email) => AuthApi.requestLoginOtp(email);

  Future<AppUser> verifyLoginOtp(String email, String code) async {
    if (!RegExp(r'^\d{6}$').hasMatch(code.trim())) throw const AuthException('Enter the 6-digit code from your email.');
    return _completeSignIn(await AuthApi.verifyLoginOtp(email: email, otp: code));
  }

  /// The sign-in waiting for its emailed link, if any.
  ({String marker, Completer<AppUser> done})? _pendingLink;

  /// Emails a sign-in link. Returns a marker; pass it to [waitForLoginLink].
  Future<String> sendLoginMagicLink(String email) async {
    await AuthApi.requestMagicLink(email);
    final marker = _randomToken();
    _pendingLink = (marker: marker, done: Completer<AppUser>());
    return marker;
  }

  /// Completes once the emailed link is opened (see [openMagicLink]),
  /// signing the user in.
  Future<AppUser> waitForLoginLink(String marker) {
    final pending = _pendingLink;
    return pending != null && pending.marker == marker ? pending.done.future : Completer<AppUser>().future;
  }

  /// Hands the token from an opened sign-in link to the waiting sign-in.
  /// False when no sign-in is waiting for a link.
  bool openMagicLink(String token) {
    final pending = _pendingLink;
    if (pending == null || pending.done.isCompleted) return false;
    AuthApi.verifyMagicLink(token)
        .then(_completeSignIn)
        .then(
          (user) {
            _pendingLink = null;
            pending.done.complete(user);
          },
          onError: (Object e) {
            if (!pending.done.isCompleted) {
              pending.done.completeError(
                e is AuthException
                    ? e
                    : const AuthException('This sign-in link didn\'t work. Please request a new one.'),
              );
            }
          },
        );
    return true;
  }

  Future<AppUser> signInWithBackupCode(String email, String code) async =>
      _completeSignIn(await AuthApi.recoverAccount(email: email, backupCode: code));

  // ---- Registration --------------------------------------------------------

  /// Creates an unverified account; the server emails a verification link.
  Future<void> register({
    required String name,
    required String email,
    required String password,
    required UserRole role,
    String? referralCode,
  }) async {
    if (!PasswordPolicy.isValid(password)) {
      throw const AuthException('Password doesn\'t meet the password policy.');
    }
    await AuthApi.register(
      fullName: name,
      email: email,
      password: password,
      role: role.name,
      referralCode: _blankToNull(referralCode),
    );
  }

  /// Sends a fresh verification link to an unverified account.
  Future<void> resendVerification(String email) => AuthApi.resendVerification(email);

  // ---- GitHub ----------------------------------------------------------------

  /// Finishes a GitHub sign-in once the API has issued the session (the
  /// client saved it). GitHub gives a verified email, so the account is
  /// active straight away.
  Future<AppUser> finishGitHubSignIn() async =>
      _completeSignIn({'role': _roleInToken(SessionStore.instance.accessToken) ?? await _probeRole()});

  /// A GitHub account seen for the first time: creates the account for [role]
  /// with the EULA accepted.
  Future<AppUser> completeGitHubSignup({required String signupCookie, required UserRole role}) async =>
      _completeSignIn(await AuthApi.completeOAuthSignup(signupCookie: signupCookie, role: role.name));

  /// The role in a readable (v4.public) session token, if it carries one.
  static String? _roleInToken(String? token) {
    final parts = token?.split('.') ?? const [];
    if (parts.length < 3 || parts[1] != 'public') return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(parts[2]));
      // The message is followed by a 64-byte signature.
      final claims = jsonDecode(utf8.decode(bytes.sublist(0, bytes.length - 64)));
      final role = claims is Map ? claims['role'] : null;
      return role == 'seeker' || role == 'solver' ? role as String : null;
    } catch (_) {
      return null;
    }
  }

  /// Otherwise the profile that opens tells: only the right role's does.
  Future<String> _probeRole() async {
    try {
      await AuthApi.profile('seeker');
      return 'seeker';
    } on ApiException catch (e) {
      if (e.statusCode == 403) return 'solver';
      rethrow;
    }
  }

  // ---- Password reset ------------------------------------------------------

  /// Emails an OTP or a reset link. Reset links open in the browser, so the
  /// reset itself happens on that page; the user signs in afterwards.
  Future<void> requestPasswordReset(String email, ResetMethod method) =>
      AuthApi.forgotPassword(email, method == ResetMethod.otp ? 'otp' : 'magic_link');

  /// Sets the new password with the emailed [code]; the API checks both
  /// together.
  Future<void> resetPassword({required String email, required String code, required String newPassword}) async {
    if (!RegExp(r'^\d{6}$').hasMatch(code.trim())) throw const AuthException('Enter the 6-digit code from your email.');
    if (!PasswordPolicy.isValid(newPassword)) {
      throw const AuthException('Password doesn\'t meet the password policy.');
    }
    await AuthApi.resetPasswordWithOtp(email: email, otp: code.trim(), newPassword: newPassword);
  }

  // ---- Session -------------------------------------------------------------

  /// Saves everything except the pseudo name, which goes through
  /// [setPseudoName] because it can only be set once.
  Future<void> saveProfile(UserProfile profile) async {
    final user = _requireSession();
    final role = user.role.name;
    // A new photo is a local file; a removed one is null.
    final photo = profile.photoPath;
    final photoChanged = photo != user.profile.photoPath;
    if (photoChanged && photo == null && user.role == UserRole.solver) {
      throw const AuthException('Removing your photo isn\'t available yet. You can replace it with a new one.');
    }
    final country = Countries.byName(profile.countryName);
    final dob = profile.dateOfBirth;
    String? blank(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
    var updated = await AccountApi.updateProfile(
      role,
      {
        'first_name': profile.firstName.trim(),
        'last_name': profile.lastName.trim(),
        'bio': blank(profile.bio),
        'country': country?.name,
        'city': blank(profile.city),
        'gender': _genders.entries.where((e) => e.value == profile.gender).firstOrNull?.key,
        'date_of_birth': dob == null
            ? null
            : '${dob.year.toString().padLeft(4, '0')}-${dob.month.toString().padLeft(2, '0')}-${dob.day.toString().padLeft(2, '0')}',
        // A solver's number comes from KYC, where the server saves it.
        'phone': user.role == UserRole.solver || country == null || profile.phone.isEmpty
            ? null
            : '${country.dialCode}${profile.phone}',
        'timezone': blank(profile.timezone),
      }..removeWhere((_, v) => v == null),
    );
    if (photoChanged) {
      if (photo == null) {
        await AccountApi.removeImage();
        updated = {...updated, 'avatar_url': null};
      } else {
        final url = await AccountApi.uploadImage(role, photo);
        updated = {...updated, 'avatar_url': ?url};
      }
    }
    await _applyProfile(user, updated);
  }

  Future<void> setPseudoName(String name) async {
    final user = _requireSession();
    if (user.profile.pseudoName != null) {
      throw const AuthException('Your pseudo name is already set and can\'t be changed.');
    }
    await AccountApi.setPseudoName(user.role.name, name);
    user.profile.pseudoName = name.trim();
  }

  /// An unused pseudo name suggestion such as `QuietFalcon_42`.
  Future<String> suggestPseudoName() => AccountApi.generatePseudoName(_requireSession().role.name);

  AppUser _requireSession() {
    final user = currentUser;
    if (user == null) throw const AuthException('Your session has ended. Please sign in again.');
    return user;
  }

  /// Signs out: revokes the session on the server, then forgets it here.
  void signOut() {
    currentUser = null;
    unawaited(_endSession());
  }

  Future<void> _endSession() async {
    try {
      // No more pushes for this account on this device; told to the server
      // before the session ends.
      await PushNotifications.instance.unregister(server: SessionStore.instance.hasSession);
      if (SessionStore.instance.hasSession) await AuthApi.logout();
    } catch (_) {
      // Signed out locally either way.
    } finally {
      await SessionStore.instance.clear();
    }
  }

  // ---- Account settings --------------------------------------------------------

  /// Changes the password. The server then ends every session, so the user
  /// signs in again with the new one.
  Future<void> changePassword(String current, String newPassword) async {
    final user = _requireSession();
    if (!PasswordPolicy.isValid(newPassword)) {
      throw const AuthException('Password doesn\'t meet the password policy.');
    }
    if (newPassword == current) throw const AuthException('Choose a password you haven\'t used just now.');
    await AccountApi.changePassword(user.role.name, current: current, newPassword: newPassword);
    _signedOutByServer();
  }

  /// Solvers: step 1 of moving their verified mobile number to
  /// [nationalNumber] (in their profile country). The server checks the
  /// password and emails a code.
  Future<void> requestPhoneChange(String password, String nationalNumber) async {
    final user = _requireSession();
    final country = Countries.byName(user.profile.countryName);
    if (country == null) throw const AuthException('Set your country in Profile first.');
    final digits = nationalNumber.replaceAll(RegExp(r'\D'), '');
    if (!country.phoneFits(digits.length)) throw AuthException('Enter the ${country.phoneLengthLabel} number.');
    if (digits == user.profile.phone) throw const AuthException('That\'s already your mobile number.');
    await AccountApi.requestPhoneChange(currentPassword: password, newPhone: '${country.dialCode}$digits');
  }

  /// Step 2: confirms with the emailed [code]. The number changes and the
  /// server ends every session, so the user signs in again.
  Future<void> confirmPhoneChange(String code) async {
    _requireSession();
    if (!RegExp(r'^\d{6}$').hasMatch(code.trim())) throw const AuthException('Enter the 6-digit code.');
    await AccountApi.confirmPhoneChange(code.trim());
    _signedOutByServer();
  }

  /// Switches between seeker and solver and ends every session, so the user
  /// signs in again (with the same credentials) under the new role.
  Future<UserRole> switchRole() async {
    final user = _requireSession();
    final role = user.role.name;
    final status = await AccountApi.switchRoleStatus(role);
    if (status['can_switch'] == false) {
      throw AuthException(status['block_reason'] as String? ?? 'You can\'t switch roles right now.');
    }
    await AccountApi.switchRole(role);
    _signedOutByServer();
    return user.role == UserRole.seeker ? UserRole.solver : UserRole.seeker;
  }

  /// Hides the account until the user signs in again. [password] confirms it.
  Future<void> deactivateAccount({String? reason, String? details, String password = ''}) async {
    final user = _requireSession();
    if (user.role == UserRole.solver) {
      throw const AuthException('Deactivating a solver account isn\'t available yet. Contact support for help.');
    }
    await AccountApi.deactivate(password);
    _signedOutByServer();
  }

  /// Schedules the account and everything tied to it for deletion. [password]
  /// confirms it.
  Future<void> deleteAccount({required String reason, String? details, String password = ''}) async {
    await AccountApi.delete(_requireSession().role.name, password);
    _signedOutByServer();
  }

  /// The server already ended every session; forget it here.
  void _signedOutByServer() {
    currentUser = null;
    unawaited(PushNotifications.instance.unregister(server: false));
    unawaited(SessionStore.instance.clear());
  }

  // ---- Internals -----------------------------------------------------------

  String _normalize(String email) => email.trim().toLowerCase();

  String? _blankToNull(String? value) => (value == null || value.trim().isEmpty) ? null : value.trim();

  String _randomToken() => List.generate(24, (_) => _random.nextInt(16).toRadixString(16)).join();
}
