import 'api_client.dart';

/// Identity verification for both roles (Postman: Seeker App > Kyc,
/// Verification, Verification Lock; Solver App > Kyc, Verification). Seekers do
/// live face verification, then a government ID; solvers verify their email
/// and mobile, then the ID, then their face. [role] is `seeker` or `solver`.
abstract final class VerificationApi {
  static ApiClient get _api => ApiClient.instance;

  /// The biometric consent notice the server currently expects.
  static const consentVersion = '2026-10-02';

  static bool _solver(String role) => role == 'solver';

  /// GET /…/kyc/status: levels, contact, face and document state.
  static Future<Map<String, dynamic>> kycStatus(String role) async => _map(await _api.get('/$role/kyc/status'));

  /// GET /seeker/verification/full/status: the seeker's latest face attempt.
  static Future<Map<String, dynamic>> faceStatus() async => _map(await _api.get('/seeker/verification/full/status'));

  /// Starts a live face challenge after the user agreed to the biometric
  /// notice. Returns the challenge: id, actions, number, lighting probe and
  /// expiry.
  static Future<Map<String, dynamic>> startFace(String role) async => _map(
    await _api.post(
      _solver(role) ? '/solver/verification/standard/start' : '/seeker/verification/full/start',
      data: {'biometric_consent': true, 'biometric_consent_version': consentVersion},
    ),
  );

  /// Sends 5–20 JPEG frames (each up to 500 KB). Processing continues on the
  /// server; poll the status.
  static Future<void> submitFace(
    String role, {
    required String challengeId,
    required List<String> framePaths,
    required List<int> timings,
    required List<List<int>> actionRanges,
    String transcript = '',
  }) => _api.upload(
    _solver(role) ? '/solver/verification/standard/submit' : '/seeker/verification/full/submit',
    files: [
      for (final (i, path) in framePaths.indexed)
        UploadFile(field: 'frames[]', path: path, fileName: 'frame_$i.jpg', contentType: 'image/jpeg'),
    ],
    fields: {
      'challenge_id': challengeId,
      'timings': timings.join(','),
      'transcript': transcript,
      'speech_confidence': '0',
      'virtual_camera': 'false',
      'challenge_action_ranges': '[${actionRanges.map((r) => '[${r[0]},${r[1]}]').join(',')}]',
    },
  );

  /// Uploads the government ID (5 MB). [documentType] is `citizen_card`,
  /// `passport`, `driving_license` or `other` (with [label]); [fileType] is
  /// `pdf`, `jpg`, `png` or `webp`.
  static Future<void> uploadId(
    String role, {
    required String path,
    required String fileName,
    required String documentType,
    required String fileType,
    String? label,
  }) => _api.upload(
    _solver(role) ? '/solver/kyc/standard/upload' : '/seeker/verification/standard/upload',
    files: [UploadFile(field: 'document', path: path, fileName: fileName)],
    fields: {'document_type': documentType, 'file_type': fileType, 'document_label': ?label},
  );

  /// GET /seeker/verification-lock: whether a custom-link booking is waiting
  /// on verification.
  static Future<Map<String, dynamic>> lock() async => _map(await _api.get('/seeker/verification-lock'));

  // ---- Solver email and mobile (light KYC) --------------------------------------

  /// POST /solver/kyc/light/start: emails the first code to the registered
  /// email.
  static Future<void> startEmail(String email) => _api.post('/solver/kyc/light/start', data: {'email': email.trim()});

  /// POST /solver/kyc/light/resend-email: a fresh code (3 per 24 hours).
  static Future<void> resendEmail(String email) =>
      _api.post('/solver/kyc/light/resend-email', data: {'email': email.trim()});

  /// POST /solver/kyc/light/verify-email.
  static Future<void> verifyEmail(String email, String otp) =>
      _api.post('/solver/kyc/light/verify-email', data: {'email': email.trim(), 'otp': otp.trim()});

  /// GET /solver/kyc/light/phone-policy: the dial code and digit limits for
  /// the profile country.
  static Future<Map<String, dynamic>> phonePolicy() async => _map(await _api.get('/solver/kyc/light/phone-policy'));

  /// POST /solver/kyc/light/phone-start: checks the number before each SMS
  /// (first or resend) and remembers it; the Firebase code must go to exactly
  /// the returned E.164 number. Also returns the phone channel's state
  /// (`failed_attempts`, `locked`, `locked_until`, …). 409 when the number is
  /// verified on another account.
  static Future<({String? phone, Map<String, dynamic> otpState})> startPhone(String phone) async {
    final data = _map(await _api.post('/solver/kyc/light/phone-start', data: {'phone': phone}));
    return (phone: data['phone'] as String?, otpState: _map(data['otp_state']));
  }

  /// POST /solver/kyc/light/verify-phone: the older check of a 6-digit code
  /// the server texted to [phone] (E.164), instead of Firebase. The server
  /// doesn't send those codes in the current flow, so the app verifies through
  /// Firebase ([verifyPhone]); this stays for a server-sent code.
  static Future<void> verifyPhoneCode(String phone, String code) =>
      _api.post('/solver/kyc/light/verify-phone', data: {'phone': phone, 'otp': code});

  /// POST /solver/kyc/light/verify-phone-firebase with the Firebase phone
  /// sign-in token. Completes light KYC.
  static Future<void> verifyPhone(String firebaseToken) =>
      _api.post('/solver/kyc/light/verify-phone-firebase', data: {'firebase_token': firebaseToken});

  /// POST /solver/kyc/light/resend-phone: counts one more SMS against the
  /// resend limit (Firebase sends it). Returns the phone channel's state.
  static Future<Map<String, dynamic>> resendPhone() async => _map(await _api.post('/solver/kyc/light/resend-phone'));

  /// POST /solver/kyc/light/phone-failure: records a code Firebase rejected as
  /// a failed attempt, which may lock the channel. Returns the channel's state:
  /// `failed_attempts`, `attempts_remaining`, `locked`, `locked_until`.
  static Future<Map<String, dynamic>> phoneFailure(String? phone) async =>
      _map(await _api.post('/solver/kyc/light/phone-failure', data: {'phone': ?phone}));

  /// GET /solver/kyc/light/resend-state: resends, failed attempts and locks
  /// for both channels.
  static Future<Map<String, dynamic>> otpState() async => _map(await _api.get('/solver/kyc/light/resend-state'));

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
