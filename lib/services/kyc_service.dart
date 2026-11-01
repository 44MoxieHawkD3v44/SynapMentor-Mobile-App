import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/verification_api.dart';
import 'auth_service.dart';
import 'face_photos.dart';

/// Live-verification challenges. Three are picked at random per attempt.
enum FaceChallenge {
  blink('Blink Your Eyes', 'Close and open your eyes', 'blink'),
  turnLeft('Turn Left', 'Slowly turn your head to the left', 'turn_left'),
  turnRight('Turn Right', 'Slowly turn your head to the right', 'turn_right'),
  nod('Nod Your Head', 'Slowly nod up and down', 'nod'),
  smile('Smile', 'Please smile naturally', 'smile'),
  readNumber('Read the Number Out Loud', 'Please read the number clearly', 'say_number');

  const FaceChallenge(this.title, this.hint, this.apiName);
  final String title;
  final String hint;

  /// The action's name in the API.
  final String apiName;
}

/// A live face check issued by the server: the actions to perform, the number
/// to read out, and the colour the screen flashes on one frame so the server
/// can check the light on the face.
class LiveChallenge {
  const LiveChallenge({
    required this.id,
    required this.actions,
    required this.number,
    required this.probeColor,
    required this.probeAtFrame,
    required this.expiresAt,
  });

  final String id;
  final List<FaceChallenge> actions;
  final String number;

  /// `red`, `blue`, `green` or `white`.
  final String probeColor;

  /// The frame (from 0) taken while the screen shows [probeColor].
  final int probeAtFrame;
  final DateTime expiresAt;
}

enum IdDocumentType {
  citizenship('Citizenship', 'citizen_card'),
  passport('Passport', 'passport'),
  drivingLicense('Driving License', 'driving_license'),
  others('Others', 'other');

  const IdDocumentType(this.label, this.apiName);
  final String label;

  /// The document type in the API, which no longer accepts PAN cards.
  final String apiName;
}

enum IdStatus { notSubmitted, underReview, rejected, approved }

class IdSubmission {
  const IdSubmission({required this.type, required this.fileName, required this.uploadedAt, this.otherType, this.path});

  /// The file on this device, for uploading.
  final String? path;

  final IdDocumentType type;

  /// What the user called their document when [type] is [IdDocumentType.others].
  final String? otherType;
  final String fileName;
  final DateTime uploadedAt;

  String get typeLabel => type == IdDocumentType.others && otherType != null ? otherType! : type.label;
}

enum ContactChannel {
  email('Email'),
  mobile('Mobile');

  const ContactChannel(this.label);
  final String label;
}

/// OTP state for one contact channel: the pending code, failed attempts and
/// the 24-hour lock after the last allowed attempt fails.
class ContactOtp {
  bool verified = false;
  String? sentTo;
  String? _code;

  /// Firebase's handle for the SMS sent to the mobile number, and the token
  /// that sends it again.
  String? _verificationId;
  int? _resendToken;
  Future<void>? _checking;
  int failedAttempts = 0;
  DateTime? lockedUntil;

  bool get codeSent => _code != null;

  int get attemptsLeft => KycService.maxOtpAttempts - failedAttempts;

  bool get locked {
    final until = lockedUntil;
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    // The wait is over: a fresh set of attempts.
    lockedUntil = null;
    failedAttempts = 0;
    return false;
  }
}

/// What the server accepts for a solver's mobile number: its dial code and
/// digit range come from the profile country.
class PhonePolicy {
  const PhonePolicy({required this.configured, this.dialCode, this.minDigits, this.maxDigits, this.message});

  /// False when the profile country isn't set (or has no phone rule).
  final bool configured;
  final String? dialCode;
  final int? minDigits;
  final int? maxDigits;

  /// Why it can't be verified yet, e.g. "Set your country in Profile…".
  final String? message;

  bool fits(int digits) => (minDigits == null || digits >= minDigits!) && (maxDigits == null || digits <= maxDigits!);

  String get lengthLabel => minDigits == null || maxDigits == null
      ? ''
      : (minDigits == maxDigits ? '$minDigits-digit' : '$minDigits–$maxDigits-digit');
}

class KycState {
  bool faceVerified = false;
  IdStatus idStatus = IdStatus.notSubmitted;

  /// The server's verification level: `light`, `standard` or `full`.
  String? level;
  IdSubmission? submission;
  String? rejectionReason;

  /// Solvers verify their email and mobile first: contact → ID → face.
  bool requiresContact = false;
  final otp = {for (final c in ContactChannel.values) c: ContactOtp()};

  bool get contactVerified => otp.values.every((o) => o.verified);

  /// The server's rules for the mobile number (from the profile country),
  /// once loaded.
  PhonePolicy? phonePolicy;

  bool get completed => faceVerified && idStatus == IdStatus.approved && (!requiresContact || contactVerified);
}

/// Identity verification, on the API for both roles. Seekers do live face
/// verification (the server issues the challenge and checks the camera frames,
/// rejecting faces already registered to another account), then a government
/// ID the admin reviews. Solvers verify their email and mobile, then the ID,
/// then their face.
class KycService extends ChangeNotifier {
  static final KycService instance = KycService();

  static const maxFileBytes = 5 * 1024 * 1024;
  static const allowedExtensions = ['pdf', 'jpg', 'jpeg', 'png', 'webp'];
  static const maxOtpAttempts = 3;
  static const otpLock = Duration(hours: 24);

  final _states = <String, KycState>{};

  KycState stateFor(AppUser user) =>
      _states.putIfAbsent(user.email, KycState.new)..requiresContact = user.role == UserRole.solver;

  // ---- Verification (API) ------------------------------------------------------

  /// How long to wait for the server to finish checking the face frames.
  static const faceCheckTimeout = Duration(minutes: 2);

  /// Users whose verification state has loaded from the server.
  final _loaded = <String>{};

  /// Whether [user]'s verification state has loaded.
  bool isLoaded(AppUser user) => _loaded.contains('${user.role.name}:${user.email}');

  /// Loads the user's verification state.
  Future<void> refresh(AppUser user) async {
    final solver = user.role == UserRole.solver;
    final s = await VerificationApi.kycStatus(user.role.name);
    _loaded.add('${user.role.name}:${user.email}');
    final state = stateFor(user);
    final level = s['current_level'];
    final rejection = (s['document_reject_reason'] ?? s['reject_reason']) as String?;
    final idApproved = s['document_verified'] == true || (!solver && s['full_status'] == 'verified');
    state
      ..faceVerified =
          s['face_verified'] == true ||
          s['last_face_attempt_status'] == 'passed' ||
          (solver
              ? s['full_status'] == 'verified' || level == 'full'
              : s['standard_status'] == 'verified' || level == 'standard' || level == 'full')
      ..idStatus = idApproved
          ? IdStatus.approved
          : rejection != null && rejection.isNotEmpty && rejection != 'duplicate_blocked'
          ? IdStatus.rejected
          : s['document_uploaded'] == true || (!solver && s['full_status'] == 'pending')
          ? IdStatus.underReview
          : IdStatus.notSubmitted
      ..rejectionReason = rejection
      ..level = level is String && level.isNotEmpty ? level : null;
    if (solver) {
      state.otp[ContactChannel.email]!.verified = s['email_verified'] == true;
      state.otp[ContactChannel.mobile]!.verified = s['phone_verified'] == true;
    }
    if (s['document_uploaded'] == true && state.submission == null) {
      state.submission = IdSubmission(
        type: IdDocumentType.others,
        otherType: 'Government ID',
        fileName: s['document_name'] as String? ?? 'Document',
        uploadedAt: (DateTime.tryParse('${s['updated_at']}') ?? DateTime.now()).toLocal(),
      );
    }
    notifyListeners();
  }

  /// Starts a live face check; the server picks the actions. The user has
  /// agreed to the biometric notice by now.
  Future<LiveChallenge> startFaceCheck(AppUser user) async {
    final c = await VerificationApi.startFace(user.role.name);
    final actions = [
      for (final a in c['challenge_sequence'] as List? ?? const [])
        ?FaceChallenge.values.where((f) => f.apiName == a).firstOrNull,
    ];
    if (c['challenge_id'] is! String || actions.isEmpty) {
      throw const AuthException('Couldn\'t start face verification. Please try again.');
    }
    final expires = c['expires_in_seconds'];
    return LiveChallenge(
      id: c['challenge_id'] as String,
      actions: actions,
      number: '${c['challenge_number'] ?? ''}',
      probeColor: c['lighting_probe_color'] as String? ?? 'white',
      probeAtFrame: c['lighting_probe_at_frame'] is int ? c['lighting_probe_at_frame'] as int : 8,
      expiresAt: DateTime.now().add(Duration(seconds: expires is int ? expires : 300)),
    );
  }

  /// Sends the captured frames and waits for the server's verdict. Throws
  /// [AuthException] with the reason when the check doesn't pass.
  Future<void> submitFaceFrames(
    AppUser user,
    LiveChallenge challenge, {
    required List<String> framePaths,
    required List<int> timings,
    required List<List<int>> actionRanges,
    String transcript = '',
  }) async {
    final role = user.role.name;
    // At most 20 photos, with their timings and each action's range moved to
    // the photos that are kept.
    final kept = FacePhotos.keep(framePaths.length);
    final ranges = [
      for (final r in actionRanges)
        () {
          final inside = [
            for (final (n, i) in kept.indexed)
              if (i >= r[0] && i <= r[1]) n,
          ];
          if (inside.isNotEmpty) return [inside.first, inside.last];
          // Too short to keep a photo of its own: the nearest one stands in.
          final nearest = kept.indexOf(kept.reduce((a, b) => (a - r[0]).abs() <= (b - r[0]).abs() ? a : b));
          return [nearest, nearest];
        }(),
    ];
    final List<String> photos;
    try {
      photos = await FacePhotos.prepare([for (final i in kept) framePaths[i]]);
    } catch (_) {
      throw const AuthException('Verification submission failed. Please try again.');
    }
    await VerificationApi.submitFace(
      role,
      challengeId: challenge.id,
      framePaths: photos,
      timings: [for (final i in kept) timings[i]],
      actionRanges: ranges,
      transcript: transcript,
    );
    final deadline = DateTime.now().add(faceCheckTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      // Seekers have a face status; for solvers the latest attempt is on the
      // KYC status.
      final String? status;
      if (user.role == UserRole.solver) {
        final s = await VerificationApi.kycStatus(role);
        status = switch (s['last_face_attempt_status']) {
          'passed' => 'verified',
          'failed' => 'failed',
          'duplicate_blocked' => 'duplicate_blocked',
          _ => s['face_verified'] == true ? 'verified' : null,
        };
      } else {
        status = (await VerificationApi.faceStatus())['status'] as String?;
      }
      if (status == 'verified') {
        stateFor(user).faceVerified = true;
        notifyListeners();
        return;
      }
      if (status == 'duplicate_blocked') {
        throw const AuthException('This identity is already registered with another account. Please contact support.');
      }
      if (status == 'failed' || status == 'rejected') {
        final feedback = (await VerificationApi.kycStatus(role))['last_face_attempt_feedback'] as String?;
        throw AuthException(
          feedback?.isNotEmpty == true ? feedback! : 'We couldn\'t verify your face. Make sure your face is well lit and fully in the circle, then try again.',
        );
      }
    }
    throw const AuthException('Your face check is still being processed. Check back in a few minutes.');
  }

  // ---- Email and mobile (solvers) --------------------------------------------

  /// Loads the server's phone rules for the solver's profile country (dial
  /// code and digit range) and whether the number is already verified.
  Future<void> loadPhonePolicy(AppUser user) async {
    if (user.role != UserRole.solver) return;
    final p = await VerificationApi.phonePolicy();
    int? number(Object? v) => v is int ? v : null;
    final dial = '${p['dial_code'] ?? ''}'.trim();
    final state = stateFor(user)
      ..phonePolicy = PhonePolicy(
        configured: p['country_configured'] == true,
        dialCode: dial.isEmpty ? null : dial,
        minDigits: number(p['min_digits']),
        maxDigits: number(p['max_digits']),
        message: (p['message'] as String?)?.trim(),
      );
    if (p['phone_verified'] == true) state.otp[ContactChannel.mobile]!.verified = true;
    notifyListeners();
  }

  /// Sends a 6-digit code to the registered email, or by SMS to the mobile
  /// number. The server checks the number (and its resend limit) first; the
  /// SMS itself comes from Firebase phone sign-in.
  Future<void> sendContactOtp(AppUser user, ContactChannel channel, String destination) async {
    final otp = stateFor(user).otp[channel]!;
    if (otp.verified) return;
    if (otp.locked) throw const AuthException(_lockMessage);
    if (channel == ContactChannel.email && destination.trim().toLowerCase() != user.email.toLowerCase()) {
      throw const AuthException('Use the email address you registered with.');
    }
    if (channel == ContactChannel.email) {
      // The first code starts verification; later ones are resends.
      otp.codeSent ? await VerificationApi.resendEmail(destination) : await VerificationApi.startEmail(destination);
      otp
        .._code = ''
        ..sentTo = destination.trim();
      notifyListeners();
      return;
    }
    // Before every SMS: the server checks and remembers the number, and only
    // accepts the Firebase proof for exactly the number it returns.
    final ({String? phone, Map<String, dynamic> otpState}) started;
    try {
      started = await VerificationApi.startPhone(destination.replaceAll(' ', ''));
    } on ApiException catch (e) {
      if (e.statusCode == 429) _lockOtp(otp, const {});
      rethrow;
    }
    final state = started.otpState;
    final failed = state['failed_attempts'];
    if (failed is int) otp.failedAttempts = failed;
    if (state['locked'] == true) _lockOtp(otp, state);
    final phone = started.phone ?? destination.replaceAll(' ', '');
    otp.sentTo = phone;
    notifyListeners();
    if (Firebase.apps.isEmpty) {
      throw const AuthException('Mobile verification isn\'t available right now. Please try again later.');
    }
    // Later codes count against the server's resend limit.
    if (otp.codeSent) await VerificationApi.resendPhone();
    await _sendSms(otp, phone);
    if (otp.verified) return;
    otp._code = '';
    notifyListeners();
  }

  /// Asks Firebase to text a code to [phone]. Completes once it's sent, or
  /// once Android has verified the number without one.
  Future<void> _sendSms(ContactOtp otp, String phone) {
    final sent = Completer<void>();
    FirebaseAuth.instance
        .verifyPhoneNumber(
          phoneNumber: phone,
          forceResendingToken: otp._resendToken,
          timeout: const Duration(seconds: 60),
          codeSent: (id, resendToken) {
            otp
              .._verificationId = id
              .._resendToken = resendToken;
            if (!sent.isCompleted) sent.complete();
          },
          codeAutoRetrievalTimeout: (id) => otp._verificationId = id,
          // Android read the SMS itself, or trusts this number already.
          verificationCompleted: (credential) async {
            try {
              await _finishPhone(otp, credential);
            } catch (_) {
              // The user can still type the code.
            }
            if (!sent.isCompleted) sent.complete();
          },
          verificationFailed: (e) {
            if (!sent.isCompleted) sent.completeError(AuthException(_firebaseMessage(e)));
          },
        )
        .catchError((Object _) {
          if (!sent.isCompleted) sent.completeError(const AuthException(_smsFailed));
        });
    return sent.future;
  }

  /// Signs in to Firebase with the code just long enough to get its proof of
  /// the number, which the server checks and saves. An SMS Android reads
  /// while the user taps Verify is checked once.
  Future<void> _finishPhone(ContactOtp otp, PhoneAuthCredential credential) =>
      otp._checking ??= _checkPhone(otp, credential).whenComplete(() => otp._checking = null);

  Future<void> _checkPhone(ContactOtp otp, PhoneAuthCredential credential) async {
    if (otp.verified) return;
    final auth = FirebaseAuth.instance;
    try {
      final String? token;
      try {
        token = await (await auth.signInWithCredential(credential)).user?.getIdToken();
      } on FirebaseAuthException catch (e) {
        if (e.code == 'invalid-verification-code') await _phoneCodeRejected(otp);
        throw AuthException(_firebaseMessage(e));
      }
      if (token == null) throw const AuthException(_smsFailed);
      await VerificationApi.verifyPhone(token);
    } on AuthException catch (e) {
      if (e is ApiException && e.statusCode == 429) {
        otp
          ..lockedUntil = DateTime.now().add(otpLock)
          .._code = null;
        notifyListeners();
        throw const AuthException(_lockMessage);
      }
      rethrow;
    } finally {
      // The Firebase session was only for this check.
      await auth.signOut().catchError((Object _) {});
    }
    otp
      ..verified = true
      .._code = null
      .._verificationId = null
      .._resendToken = null;
    notifyListeners();
    // The server saved the verified number as the solver's profile number.
    unawaited(AuthService.instance.reloadProfile().catchError((Object _) {}));
  }

  /// A wrong code: the server counts it and may lock the channel.
  Future<void> _phoneCodeRejected(ContactOtp otp) async {
    Map<String, dynamic> s;
    try {
      s = await VerificationApi.phoneFailure(otp.sentTo);
    } on AuthException {
      s = const {};
    }
    final failed = s['failed_attempts'];
    otp.failedAttempts = failed is int ? failed : otp.failedAttempts + 1;
    if (s['locked'] == true || otp.attemptsLeft <= 0) _lockOtp(otp, s);
    notifyListeners();
  }

  /// The server locked the channel (too many codes, wrong codes or starts):
  /// until its `locked_until`, or 24 hours.
  Never _lockOtp(ContactOtp otp, Map<String, dynamic> state) {
    otp
      ..lockedUntil = DateTime.tryParse('${state['locked_until']}')?.toLocal() ?? DateTime.now().add(otpLock)
      .._code = null;
    notifyListeners();
    throw const AuthException(_lockMessage);
  }

  /// What to tell the user about a Firebase phone sign-in error; Firebase's
  /// own messages are for developers.
  static String _firebaseMessage(FirebaseAuthException e) => switch (e.code) {
    'invalid-verification-code' => 'Invalid verification code. Please check the code and try again.',
    'session-expired' || 'code-expired' => 'This code has expired. Request a new one.',
    'invalid-phone-number' => 'Enter a valid mobile number.',
    'too-many-requests' => 'Too many attempts from this device. Please try again later.',
    'quota-exceeded' => 'We can\'t send codes right now. Please try again later.',
    'network-request-failed' => 'No internet connection. Check your connection and try again.',
    _ => _smsFailed,
  };

  static const _smsFailed = 'Couldn\'t verify your mobile number. Please try again.';

  /// Checks the code. The server counts wrong codes; after the last one the
  /// channel is locked for 24 hours.
  Future<void> verifyContactOtp(AppUser user, ContactChannel channel, String code) async {
    final otp = stateFor(user).otp[channel]!;
    if (otp.locked) throw const AuthException(_lockMessage);
    if (otp.verified) return;
    if (channel == ContactChannel.mobile) {
      final id = otp._verificationId;
      if (!otp.codeSent || id == null) throw const AuthException('Request a new code first.');
      return _finishPhone(otp, PhoneAuthProvider.credential(verificationId: id, smsCode: code.trim()));
    }
    if (!otp.codeSent) throw const AuthException('Request a new code first.');
    try {
      await VerificationApi.verifyEmail(otp.sentTo ?? user.email, code);
    } on AuthException catch (e) {
      if (e is ApiException && e.statusCode == 429) {
        otp
          ..lockedUntil = DateTime.now().add(otpLock)
          .._code = null;
        notifyListeners();
        throw const AuthException(_lockMessage);
      }
      if (e.message.contains('Invalid verification code')) {
        otp.failedAttempts++;
        notifyListeners();
      }
      rethrow;
    }
    otp
      ..verified = true
      .._code = null;
    notifyListeners();
  }

  static const _lockMessage = 'You\'ve used all 3 attempts. For security, try again after 24 hours.';

  /// Uploads the government ID for admin review.
  Future<void> submitId(AppUser user, IdSubmission submission) async {
    final state = stateFor(user);
    final path = submission.path;
    if (path == null) {
      throw const AuthException('Couldn\'t read that file from this device. Choose it again and retry.');
    }
    if (state.requiresContact && !state.contactVerified) {
      throw const AuthException('Verify your email and mobile number before uploading your ID.');
    }
    final extension = submission.fileName.split('.').last.toLowerCase();
    await VerificationApi.uploadId(
      user.role.name,
      path: path,
      fileName: submission.fileName,
      documentType: submission.type.apiName,
      fileType: extension == 'jpeg' ? 'jpg' : extension,
      label: submission.type == IdDocumentType.others ? submission.otherType : null,
    );
    state
      ..submission = submission
      ..idStatus = IdStatus.underReview
      ..rejectionReason = null;
    notifyListeners();
  }
}
