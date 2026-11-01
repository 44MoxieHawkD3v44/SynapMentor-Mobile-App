import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/countries.dart';
import '../services/kyc_service.dart';
import '../services/skill_verification_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import '../widgets/liveness_guide.dart';
import '../widgets/true_colors.dart';
import 'skill_verification_screen.dart';

enum _Step { overview, contact, consent, faceIntro, faceLive, faceDone, idUpload, idReview, idRejected, completed }

/// Seeker KYC in one screen: face verification (consent → live challenges),
/// then ID verification (upload → admin review → approved or rejected).
class KycScreen extends StatefulWidget {
  const KycScreen({super.key, required this.user});

  final AppUser user;

  @override
  State<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends State<KycScreen> {
  final _kyc = KycService.instance;
  final _otherType = TextEditingController();

  late _Step _step = _stepFromState();
  bool _consent = false;
  bool _loading = false;
  String? _error;

  /// The seeker's live check, issued by the server.
  LiveChallenge? _challenge;

  IdDocumentType? _idType;
  PlatformFile? _file;
  int? _fileBytes;
  String? _typeError;
  String? _otherError;
  String? _fileError;

  // Email and mobile (solvers)
  late final _email = TextEditingController();
  late final _phone = TextEditingController(text: widget.user.profile.phone);
  // Each channel has its own code, errors and resend countdown, so email and
  // mobile are verified side by side on one screen.
  final _otps = {for (final c in ContactChannel.values) c: TextEditingController()};
  final _contactErrors = <ContactChannel, String?>{};
  final _otpErrors = <ContactChannel, String?>{};
  final _resendLeft = <ContactChannel, int>{};
  ContactChannel? _busy;
  Timer? _resendTimer;

  KycState get _state => _kyc.stateFor(widget.user);

  /// Solvers verify email and mobile first, then ID, then face.
  bool get _solver => widget.user.role == UserRole.solver;

  /// The server's dial code for the profile country, else the app's own.
  String? get _dialCode => _state.phonePolicy?.dialCode ?? Countries.byName(widget.user.profile.countryName)?.dialCode;

  @override
  void initState() {
    super.initState();
    _kyc.addListener(_onKycChanged);
    _refresh();
    // The mobile number's dial code and length, as the server checks them.
    if (_solver) _kyc.loadPhonePolicy(widget.user).catchError((Object _) {});
  }

  /// Loads the seeker's verification state and opens the step it's on.
  Future<void> _refresh() async {
    try {
      await _kyc.refresh(widget.user);
      if (mounted && (_step == _Step.overview || _step == _Step.idReview)) setState(() => _step = _stepFromState());
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  void dispose() {
    _kyc.removeListener(_onKycChanged);
    _resendTimer?.cancel();
    for (final c in [_otherType, _email, _phone, ..._otps.values]) {
      c.dispose();
    }
    super.dispose();
  }

  _Step _stepFromState() {
    final state = _kyc.stateFor(widget.user);
    if (state.completed) return _Step.completed;
    return switch (state.idStatus) {
      IdStatus.underReview => _Step.idReview,
      IdStatus.rejected => _Step.idRejected,
      _ => _Step.overview,
    };
  }

  /// The admin's decision arrives while the user waits on the review step.
  void _onKycChanged() {
    if (!mounted) return;
    setState(() {
      if (_step == _Step.idReview) _step = _stepFromState();
    });
  }

  void _go(_Step step) => setState(() {
    _step = step;
    _error = null;
  });

  // ---- Email and mobile (solvers) --------------------------------------------

  void _startContact() {
    _contactErrors.clear();
    _otpErrors.clear();
    _go(_Step.contact);
  }

  String? _destination(ContactChannel channel) {
    if (channel == ContactChannel.email) return _email.text.trim();
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null;
    return _dialCode == null ? digits : '$_dialCode $digits';
  }

  /// One ticker counts down every channel's resend wait.
  void _startResend(ContactChannel channel) {
    _resendLeft[channel] = 30;
    _resendTimer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() {
        for (final c in _resendLeft.keys.toList()) {
          final left = _resendLeft[c]! - 1;
          if (left <= 0) {
            _resendLeft.remove(c);
          } else {
            _resendLeft[c] = left;
          }
        }
      });
      if (_resendLeft.isEmpty) {
        timer.cancel();
        _resendTimer = null;
      }
    });
  }

  Future<void> _sendOtp(ContactChannel channel) async {
    final destination = _destination(channel);
    String? problem;
    if (channel == ContactChannel.email) {
      if (destination == null || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(destination)) {
        problem = 'Enter a valid email address.';
      } else if (destination.toLowerCase() != widget.user.email.toLowerCase()) {
        problem = 'This email doesn\'t match your registered email. Use the email you signed up with.';
      }
    } else {
      final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
      final expected = Countries.byName(widget.user.profile.countryName);
      final policy = _state.phonePolicy;
      if (policy != null && !policy.configured) {
        problem = policy.message?.isNotEmpty == true
            ? policy.message
            : 'Set your country in Profile before verifying your mobile number.';
      } else if (digits.isEmpty) {
        problem = 'Enter your mobile number.';
      } else if (policy != null && policy.lengthLabel.isNotEmpty) {
        // The server's digit range for the profile country.
        if (!policy.fits(digits.length)) problem = 'Enter your ${policy.lengthLabel} mobile number.';
      } else if (expected != null ? !expected.phoneFits(digits.length) : digits.length < 7 || digits.length > 15) {
        problem = expected != null
            ? 'Enter your ${expected.phoneLengthLabel} mobile number.'
            : 'Enter a valid mobile number.';
      }
    }
    setState(() {
      _contactErrors[channel] = problem;
      _error = null;
    });
    if (problem != null) return;
    setState(() => _busy = channel);
    try {
      await _kyc.sendContactOtp(widget.user, channel, destination!);
      if (!mounted) return;
      _otps[channel]!.clear();
      _otpErrors[channel] = null;
      _startResend(channel);
    } on AuthException catch (e) {
      if (mounted) setState(() => _contactErrors[channel] = e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _verifyOtp(ContactChannel channel) async {
    final code = _otps[channel]!.text;
    if (code.length < 6) {
      setState(() => _otpErrors[channel] = 'Enter the 6-digit code.');
      return;
    }
    setState(() {
      _busy = channel;
      _otpErrors[channel] = null;
      _error = null;
    });
    try {
      await _kyc.verifyContactOtp(widget.user, channel, code);
      if (mounted) setState(() => _resendLeft.remove(channel));
    } on AuthException catch (e) {
      if (mounted) setState(() => _otpErrors[channel] = e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  // ---- Face verification -----------------------------------------------------

  /// The server issues the challenge; the camera check runs it.
  Future<void> _startLiveCheck() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _challenge = await _kyc.startFaceCheck(widget.user);
      if (mounted) _go(_Step.faceLive);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _finishFace(_FaceCapture capture) async {
    final challenge = _challenge;
    if (challenge == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _kyc.submitFaceFrames(
        widget.user,
        challenge,
        framePaths: capture.framePaths,
        timings: capture.timings,
        actionRanges: capture.actionRanges,
        transcript: capture.transcript,
      );
      if (_solver) {
        // Face is the solver's last step: KYC is done.
        if (mounted) _go(_Step.completed);
      } else if (mounted) {
        _go(_Step.faceDone);
      }
    } on AuthException catch (e) {
      _faceFailed(e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _faceFailed(String message) {
    if (!mounted) return;
    setState(() {
      _challenge = null;
      _error = message;
      _step = _Step.faceIntro;
    });
  }

  // ---- ID verification -------------------------------------------------------

  Future<void> _selectIdType() async {
    final picked = await showGlassPicker(
      context,
      title: 'ID Type',
      options: IdDocumentType.values,
      label: (t) => t.label,
      selected: _idType,
    );
    if (picked != null) {
      setState(() {
        _idType = picked;
        _typeError = null;
      });
    }
  }

  Future<void> _chooseFile() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: KycService.allowedExtensions);
    if (file == null || !mounted) return;
    final extension = file.extension?.toLowerCase();
    final bytes = await file.length();
    if (!mounted) return;
    setState(() {
      if (extension == null || !KycService.allowedExtensions.contains(extension)) {
        _fileError = 'Use a PDF, JPG, PNG or WebP file.';
      } else if (bytes == null) {
        _fileError = 'Couldn\'t read that file. Try another one.';
      } else if (bytes > KycService.maxFileBytes) {
        _fileError = 'That file is over 5 MB. Choose a smaller one.';
      } else {
        _file = file;
        _fileBytes = bytes;
        _fileError = null;
      }
    });
  }

  Future<void> _submitId() async {
    final other = _idType == IdDocumentType.others;
    setState(() {
      _typeError = _idType == null ? 'Select your ID type.' : null;
      _otherError = other && _otherType.text.trim().isEmpty ? 'Name the document you\'re uploading.' : null;
      _fileError = _file == null ? 'Choose a file to upload.' : _fileError;
      _error = null;
    });
    if (_typeError != null || _otherError != null || _file == null) return;
    setState(() => _loading = true);
    try {
      await _kyc.submitId(
        widget.user,
        IdSubmission(
          type: _idType!,
          otherType: other ? _otherType.text.trim() : null,
          fileName: _file!.name,
          uploadedAt: DateTime.now(),
          path: _file!.path,
        ),
      );
      if (mounted) _go(_Step.idReview);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _uploadAgain() {
    setState(() {
      _file = null;
      _fileBytes = null;
      _fileError = null;
    });
    _go(_Step.idUpload);
  }

  // ---- Layout ----------------------------------------------------------------

  String get _title => switch (_step) {
    _Step.overview || _Step.completed => 'KYC Verification',
    _Step.contact => 'Email & Mobile',
    _Step.consent || _Step.faceIntro || _Step.faceLive || _Step.faceDone => 'Face Verification',
    _ => 'ID Verification',
  };

  String? get _subtitle => _step != _Step.overview
      ? null
      : _solver
      ? 'Complete your verification to accept bookings and publish content.'
      : 'Complete your verification to unlock all Seeker features.';

  VoidCallback? get _onBack => switch (_step) {
    _Step.overview || _Step.completed => null, // leave the screen
    _Step.faceLive => () => _go(_Step.faceIntro),
    _ => () => _go(_Step.overview),
  };

  String? get _stepBadge => _solver
      ? switch (_step) {
          _Step.contact => '1/3',
          _Step.idUpload || _Step.idReview || _Step.idRejected => '2/3',
          _Step.consent || _Step.faceIntro || _Step.faceLive => '3/3',
          _ => null,
        }
      : switch (_step) {
          _Step.consent || _Step.faceIntro || _Step.faceLive || _Step.faceDone => '1/2',
          _Step.idUpload || _Step.idReview || _Step.idRejected => '2/2',
          _ => null,
        };

  @override
  Widget build(BuildContext context) {
    final badge = _stepBadge;
    return AuthScaffold(
      title: _title,
      subtitle: _subtitle,
      onBack: _onBack,
      trailing: badge == null
          ? null
          : GlassWell(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                badge,
                semanticsLabel: 'Step $badge',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white),
              ),
            ),
      child: GlassFormColumn(
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          StepSwitcher(
            child: KeyedSubtree(key: ValueKey(_step), child: _buildStep()),
          ),
        ],
      ),
    );
  }

  Widget _buildStep() {
    return switch (_step) {
      _Step.overview => _solver ? _buildSolverOverview() : _buildOverview(),
      _Step.contact => _buildContact(),
      _Step.consent => _buildConsent(),
      _Step.faceIntro => _buildFaceIntro(),
      _Step.faceLive =>
        _loading
            ? const _Busy(message: 'Verifying your face…')
            : _CameraFaceCheck(challenge: _challenge!, onCaptured: _finishFace, onFailed: _faceFailed),
      _Step.faceDone => _Result(
        icon: Icons.check_rounded,
        title: 'Face verification completed',
        message: 'Your face has been successfully verified. You can now proceed to ID verification.',
        action: PrimaryPillButton(label: 'Continue to ID Verification', onPressed: () => _go(_Step.idUpload)),
      ),
      _Step.idUpload => _buildIdUpload(),
      _Step.idReview => _buildIdReview(),
      _Step.idRejected => _buildIdRejected(),
      _Step.completed when _solver => _buildSolverCompleted(),
      _Step.completed => _Result(
        icon: Icons.check_rounded,
        title: 'KYC Verification Completed!',
        message: 'You now have full access to all Seeker features.',
        details: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Levels(state: _state),
            gap14,
            const _UnlockedList(),
          ],
        ),
        action: PrimaryPillButton(label: 'Go to Home', onPressed: () => Navigator.of(context).maybePop()),
      ),
    };
  }

  // ---- Solver views ------------------------------------------------------------

  Widget _buildSolverOverview() {
    final state = _state;
    final contact = state.contactVerified;
    final idApproved = state.idStatus == IdStatus.approved;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepCard(
          icon: Icons.mark_email_read_outlined,
          title: 'Email & Mobile Verification',
          badge: 'Step 1',
          subtitle: 'Verify your registered email and mobile number with an OTP.',
          done: contact,
          onTap: contact ? null : _startContact,
        ),
        const SizedBox(height: 12),
        _StepCard(
          icon: Icons.badge_outlined,
          title: 'ID Verification',
          badge: 'Step 2',
          subtitle: contact
              ? 'Upload a government-issued ID for identity verification.'
              : 'Unlocks after email and mobile verification.',
          done: idApproved,
          onTap: !contact
              ? null
              : switch (state.idStatus) {
                  IdStatus.notSubmitted => () => _go(_Step.idUpload),
                  IdStatus.underReview => () => _go(_Step.idReview),
                  IdStatus.rejected => () => _go(_Step.idRejected),
                  IdStatus.approved => null,
                },
        ),
        const SizedBox(height: 12),
        _StepCard(
          icon: Icons.photo_camera_outlined,
          title: 'Face Verification',
          badge: 'Step 3',
          subtitle: idApproved
              ? 'Live face verification to prove you are a real person.'
              : 'Unlocks after your ID is approved.',
          done: state.faceVerified,
          onTap: idApproved && !state.faceVerified ? () => _go(_Step.consent) : null,
        ),
      ],
    );
  }

  /// Email and mobile on one screen, each verified with its own OTP.
  Widget _buildContact() {
    final both = _state.contactVerified;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Verify your registered email address and mobile number. We\'ll send a separate 6-digit OTP to each.',
          style: AppText.body,
          textAlign: TextAlign.center,
        ),
        gap24,
        _contactSection(ContactChannel.email),
        gap14,
        _contactSection(ContactChannel.mobile),
        gap14,
        const InlineNotice(
          message:
              'Maximum 3 attempts each for email and mobile. After 3 failed attempts, you must wait 24 hours '
              'before trying again.',
        ),
        PrimaryPillButton(label: 'Continue to ID Verification', onPressed: both ? () => _go(_Step.idUpload) : null),
      ],
    );
  }

  Widget _contactSection(ContactChannel channel) {
    final email = channel == ContactChannel.email;
    final otp = _state.otp[channel]!;
    final busy = _busy == channel;
    final title = email ? 'Email Verification' : 'Mobile Verification';
    final status = otp.verified
        ? 'Verified'
        : otp.locked
        ? 'Locked'
        : otp.codeSent
        ? 'Code sent'
        : 'Pending';
    final List<Widget> body;
    if (otp.verified) {
      body = [
        _InfoCard(
          icon: Icons.check_circle_rounded,
          label: email ? 'Verified Email Address' : 'Verified Mobile Number',
          value: otp.sentTo ?? '',
        ),
      ];
    } else if (otp.locked) {
      body = [
        Text(
          'Maximum attempts reached. For security reasons, you must wait 24 hours before trying again.',
          style: AppText.caption,
        ),
        gap8,
        _LockCountdown(until: otp.lockedUntil!, onDone: () => setState(() {})),
      ];
    } else if (otp.codeSent) {
      final resend = _resendLeft[channel];
      body = [
        Text('Enter the 6-digit OTP sent to ${otp.sentTo}', style: AppText.caption),
        gap8,
        OtpInput(controller: _otps[channel]!, onCompleted: (_) => _verifyOtp(channel)),
        FieldError(_otpErrors[channel]),
        gap8,
        Center(
          child: resend != null
              ? Text('Resend OTP in ${resend}s', style: AppText.caption)
              : UnderlineLink(label: 'Resend OTP', onTap: busy ? null : () => _sendOtp(channel)),
        ),
        if (otp.failedAttempts > 0) ...[gap8, _AttemptsLeft(left: otp.attemptsLeft)],
        gap14,
        PrimaryPillButton(label: 'Verify OTP', loading: busy, onPressed: () => _verifyOtp(channel)),
      ];
    } else {
      body = [
        if (email) ...[
          GlassTextField(
            controller: _email,
            hint: 'Registered email address',
            icon: Icons.mail_outline_rounded,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            errorText: _contactErrors[channel],
            onChanged: (_) {
              if (_contactErrors[channel] != null) setState(() => _contactErrors[channel] = null);
            },
          ),
          const SizedBox(height: 6),
          Text(
            'Use the same email you registered with. Other emails aren\'t accepted.',
            style: AppText.caption.copyWith(fontSize: 11.5),
          ),
        ] else ...[
          // The number is entered here; once verified it becomes the profile
          // number. The dial code comes from the profile country.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_dialCode != null) ...[
                SizedBox(
                  width: 92,
                  child: GlassSelectField(value: _dialCode, hint: '+', locked: true),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: GlassTextField(
                  controller: _phone,
                  hint: 'Mobile number',
                  icon: _dialCode == null ? Icons.phone_iphone_rounded : null,
                  keyboardType: TextInputType.phone,
                  autofillHints: const [AutofillHints.telephoneNumberNational],
                  errorText: _contactErrors[channel],
                  onChanged: (_) {
                    if (_contactErrors[channel] != null) setState(() => _contactErrors[channel] = null);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _dialCode == null
                ? 'Set your country in Profile first; it sets your country code.'
                : '$_dialCode is from your profile country. Enter your number without it; once verified, it\'s '
                      'saved to your profile.',
            style: AppText.caption.copyWith(fontSize: 11.5),
          ),
        ],
        gap14,
        GlassPillButton(label: 'Send OTP', loading: busy, onPressed: () => _sendOtp(channel)),
      ];
    }

    return GlassWell(
      radius: 22,
      active: otp.verified,
      error: otp.locked,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GlassIconBadge(icon: email ? Icons.alternate_email_rounded : Icons.phone_iphone_rounded, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppColors.white(0.35)),
                ),
                child: Text(
                  status,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ),
            ],
          ),
          gap14,
          ...body,
        ],
      ),
    );
  }

  Widget _buildSolverCompleted() {
    final skills = SkillVerificationService.instance.verifiedSkills(widget.user);
    return _Result(
      icon: Icons.check_rounded,
      title: 'KYC Verification Completed!',
      message: skills.isEmpty
          ? 'Your identity is verified. Complete Skill Verification to accept bookings, publish content and '
                'appear to Seekers.'
          : 'You\'re fully verified and can now accept bookings and publish content.',
      details: skills.isEmpty
          ? null
          : const _UnlockedList(items: ['Accept bookings', 'Publish your content', 'Appear to Seekers in Explore']),
      action: skills.isEmpty
          ? PrimaryPillButton(
              label: 'Go to Skill Verification',
              onPressed: () =>
                  Navigator.of(context).pushReplacement(glassRoute(SkillVerificationScreen(user: widget.user))),
            )
          : PrimaryPillButton(label: 'Go to Home', onPressed: () => Navigator.of(context).maybePop()),
    );
  }

  Widget _buildOverview() {
    final state = _state;
    final idLabel = switch (state.idStatus) {
      IdStatus.notSubmitted => 'Pending',
      IdStatus.underReview => 'Under review',
      IdStatus.rejected => 'Rejected — upload again',
      IdStatus.approved => 'Completed',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepCard(
          icon: Icons.photo_camera_outlined,
          title: 'Face Verification',
          badge: 'Step 1',
          subtitle: 'Live face verification to prove you are a real person.',
          done: state.faceVerified,
          onTap: state.faceVerified ? null : () => _go(_Step.consent),
        ),
        const SizedBox(height: 12),
        _StepCard(
          icon: Icons.badge_outlined,
          title: 'ID Verification',
          badge: 'Step 2',
          subtitle: state.faceVerified
              ? 'Upload a government-issued ID for identity verification.'
              : 'Unlocks after face verification.',
          done: state.idStatus == IdStatus.approved,
          onTap: !state.faceVerified
              ? null
              : switch (state.idStatus) {
                  IdStatus.notSubmitted => () => _go(_Step.idUpload),
                  IdStatus.underReview => () => _go(_Step.idReview),
                  IdStatus.rejected => () => _go(_Step.idRejected),
                  IdStatus.approved => null,
                },
        ),
        gap24,
        _Timeline(
          entries: [
            ('Face Verification', state.faceVerified ? 'Completed' : 'Pending', state.faceVerified),
            ('ID Verification', idLabel, state.idStatus == IdStatus.approved),
            ('KYC Completed', state.completed ? 'Completed' : 'Pending', state.completed),
          ],
        ),
      ],
    );
  }

  Widget _buildConsent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: GlassIconBadge(icon: Icons.face_retouching_natural_outlined, size: 72)),
        gap24,
        const Text('WE NEED YOUR CONSENT', style: AppText.title, textAlign: TextAlign.center),
        gap14,
        Text(
          'We will use your face data to verify your identity. Your biometric data is encrypted and stored '
          'securely. It will also be compared against existing accounts to prevent duplicate registrations. '
          'You can request deletion of your biometric data at any time through Settings.',
          style: AppText.body,
          textAlign: TextAlign.center,
        ),
        gap24,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassCheckbox(value: _consent, onChanged: (v) => setState(() => _consent = v)),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _consent = !_consent),
                  child: const Text(
                    'I consent to the processing of my biometric data for identity verification as described above.',
                    style: TextStyle(fontSize: 13.5, height: 1.4, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
        gap24,
        PrimaryPillButton(label: 'Continue', onPressed: _consent ? () => _go(_Step.faceIntro) : null),
      ],
    );
  }

  Widget _buildFaceIntro() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: GlassIconBadge(icon: Icons.center_focus_weak_rounded, size: 72)),
        gap24,
        const Text('GET READY FOR LIVE VERIFICATION', style: AppText.title, textAlign: TextAlign.center),
        gap14,
        Text(
          'Your front camera opens and you\'ll complete a few random challenges to verify that you are a real person.',
          style: AppText.body,
          textAlign: TextAlign.center,
        ),
        gap24,
        for (final challenge in FaceChallenge.values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Row(
              children: [
                Icon(_challengeIcon(challenge), size: 20, color: Colors.white),
                const SizedBox(width: 14),
                Text(challenge.title, style: AppText.label.copyWith(fontSize: 14)),
              ],
            ),
          ),
        gap24,
        PrimaryPillButton(label: 'Start Verification', loading: _loading, onPressed: _startLiveCheck),
      ],
    );
  }

  Widget _buildIdUpload() {
    final file = _file;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: GlassIconBadge(icon: Icons.badge_outlined, size: 72)),
        gap24,
        const Text('UPLOAD GOVERNMENT ID', style: AppText.title, textAlign: TextAlign.center),
        gap14,
        Text(
          'Upload any government-issued ID for identity verification. Your document is encrypted with Kyber '
          'and Dilithium before storage and sent for admin review.',
          style: AppText.body,
          textAlign: TextAlign.center,
        ),
        gap24,
        const Padding(
          padding: EdgeInsets.only(left: 6, bottom: 8),
          child: Text('Select ID Type *', style: AppText.label),
        ),
        GlassSelectField(value: _idType?.label, hint: 'Choose ID type', errorText: _typeError, onTap: _selectIdType),
        if (_idType == IdDocumentType.others) ...[
          gap14,
          GlassTextField(
            controller: _otherType,
            hint: 'Document name, e.g. Voter ID',
            textCapitalization: TextCapitalization.words,
            errorText: _otherError,
            onChanged: (_) {
              if (_otherError != null) setState(() => _otherError = null);
            },
          ),
        ],
        gap24,
        GlassWell(
          radius: 22,
          error: _fileError != null,
          padding: const EdgeInsets.fromLTRB(18, 24, 18, 22),
          child: file == null
              ? Column(
                  children: [
                    const Icon(Icons.upload_file_outlined, size: 36, color: Colors.white),
                    gap14,
                    const Text(
                      'Upload Document',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                    const SizedBox(height: 4),
                    Text('Tap to browse your files', style: AppText.caption),
                    gap14,
                    SmallPillButton(label: 'Choose File', onPressed: _chooseFile),
                    gap14,
                    Text(
                      'Accepted formats: PDF, JPG, PNG\nMax file size: 5 MB',
                      style: AppText.caption.copyWith(fontSize: 11.5),
                      textAlign: TextAlign.center,
                    ),
                  ],
                )
              : Row(
                  children: [
                    const Icon(Icons.description_outlined, size: 28, color: Colors.white),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                          Text(_formatBytes(_fileBytes ?? 0), style: AppText.caption),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove file',
                      onPressed: () => setState(() {
                        _file = null;
                        _fileBytes = null;
                      }),
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                  ],
                ),
        ),
        FieldError(_fileError),
        gap24,
        PrimaryPillButton(label: 'Submit for Review', loading: _loading, onPressed: _submitId),
      ],
    );
  }

  Widget _buildIdReview() {
    final submission = _state.submission;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Result(
          icon: Icons.upload_file_outlined,
          title: 'Document submitted',
          message:
              'Your ID document has been securely uploaded and sent for admin review. You will receive an '
              'email once it is approved or if any changes are required.',
          details: submission == null
              ? null
              : GlassWell(
                  radius: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(
                    children: [
                      _DetailRow('Selected ID Type', submission.typeLabel),
                      _DetailRow('File Name', submission.fileName),
                      _DetailRow('Uploaded On', _formatDate(submission.uploadedAt)),
                      const _DetailRow('Status', 'Under Review', icon: Icons.hourglass_top_rounded),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildIdRejected() {
    return _Result(
      icon: Icons.error_outline_rounded,
      title: 'Document Rejected',
      message:
          'Your submitted document could not be verified. Check the reason below and upload a corrected '
          'document. We\'ve also emailed you the details.',
      details: InlineNotice(
        message: 'Reason for rejection: ${_state.rejectionReason ?? 'Not specified.'}',
        tone: NoticeTone.error,
        persistent: true,
      ),
      action: PrimaryPillButton(label: 'Upload Again', onPressed: _uploadAgain),
    );
  }

  static IconData _challengeIcon(FaceChallenge c) => switch (c) {
    FaceChallenge.blink => Icons.visibility_outlined,
    FaceChallenge.turnLeft => Icons.turn_left_rounded,
    FaceChallenge.turnRight => Icons.turn_right_rounded,
    FaceChallenge.nod => Icons.swap_vert_rounded,
    FaceChallenge.smile => Icons.sentiment_satisfied_outlined,
    FaceChallenge.readNumber => Icons.pin_outlined,
  };

  static String _formatBytes(int bytes) =>
      bytes >= 1024 * 1024 ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB' : '${(bytes / 1024).ceil()} KB';

  static String _formatDate(DateTime t) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    String two(int v) => v.toString().padLeft(2, '0');
    final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '${t.day} ${months[t.month - 1]} ${t.year}, ${two(hour)}:${two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// What the live camera check captured, ready to send.
class _FaceCapture {
  const _FaceCapture({
    required this.framePaths,
    required this.timings,
    required this.actionRanges,
    this.transcript = '',
  });

  final List<String> framePaths;

  /// Milliseconds from the start of the check, one per frame.
  final List<int> timings;

  /// The first and last frame of each action, in order.
  final List<List<int>> actionRanges;

  /// The number the user typed for the read-out challenge, if they did.
  final String transcript;
}

/// The seeker's live face check: the front camera shows inside the ring while
/// the user performs the server's actions, and frames are captured during
/// each one. On one frame the screen flashes the server's colour so it can
/// check the light falling on a real face.
class _CameraFaceCheck extends StatefulWidget {
  const _CameraFaceCheck({required this.challenge, required this.onCaptured, required this.onFailed});

  final LiveChallenge challenge;
  final ValueChanged<_FaceCapture> onCaptured;
  final ValueChanged<String> onFailed;

  @override
  State<_CameraFaceCheck> createState() => _CameraFaceCheckState();
}

/// The live face check. First the face has to be in the circle; then each
/// action the server asked for is shown, and the check moves on only once the
/// camera actually sees it done (head turned, nod, blink, smile, or the number
/// heard). Photos are taken while each action is being done; the last few of
/// each are sent with the action's range.
class _CameraFaceCheckState extends State<_CameraFaceCheck> {
  /// The server takes 5–20 frames (each is made small enough when sent).
  static const _maxFrames = 20;
  static const _minFrames = 5;

  /// How long one step may take before the check gives up.
  static const _stepTimeout = Duration(seconds: 30);

  final _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      performanceMode: FaceDetectorMode.accurate,
      minFaceSize: 0.2,
    ),
  );
  final _speech = SpeechToText();
  bool _speechReady = false;

  CameraController? _camera;

  /// Camera frames received, frames face detection ran on, and why it last
  /// failed: to tell a phone where detection can't run from a missed action.
  int _frames = 0;
  int _analyzed = 0;
  String? _detectorError;

  /// -1 while waiting for the face to be in the circle, then the action.
  int _index = -1;
  bool _done = false;
  bool _busy = false;
  OverlayEntry? _flash;

  /// The current step has been seen, and is showing its tick.
  bool _met = false;
  bool _tick = false;
  String? _note;

  // What has been seen during the current step.
  DateTime? _centeredSince;
  double _baseYaw = 0;
  double _basePitch = 0;
  bool _eyesClosed = false;
  bool _wentUp = false;
  bool _wentDown = false;

  final _typed = TextEditingController();
  bool _typing = false;
  String? _typedError;
  String _transcript = '';

  List<FaceChallenge> get _actions => widget.challenge.actions;
  FaceChallenge? get _action => _index < 0 ? null : _actions[_index];

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _done = true;
    _flash?.remove();
    _speech.cancel();
    final camera = _camera;
    if (camera != null && camera.value.isStreamingImages) camera.stopImageStream().catchError((Object _) {});
    camera?.dispose();
    _detector.close();
    _typed.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return _fail('No camera was found on this device.');
      final front = cameras.where((c) => c.lensDirection == CameraLensDirection.front).firstOrNull ?? cameras.first;
      final camera = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        // Frames for face detection; photos are still saved as JPEG.
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      _camera = camera;
      await camera.initialize();
      if (!mounted) return;
      setState(() {});
      // Face detection starts straight away; speech only for the number.
      await camera.startImageStream(_onImage);
      await _run(camera);
    } on CameraException catch (e) {
      _fail(
        e.code.contains('AccessDenied') || e.code.contains('Restricted')
            ? 'Camera access is needed for face verification. Allow camera access for Synap Mentor in your phone\'s settings, then try again.'
            : 'Couldn\'t open the camera. Close other apps using it and try again.',
      );
    }
  }

  // ---- The steps ---------------------------------------------------------------

  /// How many photos each action keeps, and where the coloured-flash photo
  /// goes so it lands on the frame the server asked for with every photo in
  /// time order: [pre] before the first action, the flash before action
  /// [flashAt] (or after the last), [post] before a final flash, and [tail]
  /// to reach the minimum.
  static ({int pre, List<int> counts, int flashAt, int post, int tail}) _plan(int n, int probe) {
    for (var base = 3; ; base--) {
      final counts = List.filled(n, base);
      var pre = 0;
      var post = 0;
      int flashAt;
      if (probe >= n * base) {
        post = probe - n * base;
        flashAt = n;
      } else {
        final k = probe ~/ base;
        final rest = probe % base;
        if (rest == 0) {
          flashAt = k;
        } else if (rest >= 2) {
          counts[k] = rest;
          flashAt = k + 1;
        } else if (k >= 1) {
          counts[k - 1] += 1;
          flashAt = k;
        } else {
          pre = 1;
          flashAt = 0;
        }
      }
      final frames = pre + counts.fold<int>(0, (a, b) => a + b) + post + 1;
      if (frames <= _maxFrames || base == 2) {
        return (pre: pre, counts: counts, flashAt: flashAt, post: post, tail: max(0, _minFrames - frames));
      }
    }
  }

  Future<void> _run(CameraController camera) async {
    final plan = _plan(_actions.length, widget.challenge.probeAtFrame);
    final clock = Stopwatch()..start();
    final paths = <String>[];
    final timings = <int>[];
    final ranges = <List<int>>[];

    Future<XFile> photo() => camera.takePicture();
    // Photos are made small enough for the server when they're sent.
    Future<bool> keep(XFile f, int at) async {
      paths.add(f.path);
      timings.add(at);
      return true;
    }

    Future<bool> shoot({bool flash = false}) async {
      if (flash) await _showFlash();
      try {
        return await keep(await photo(), clock.elapsedMilliseconds);
      } finally {
        if (flash) _hideFlash();
      }
    }

    // Look at the camera.
    _setStep(-1);
    if (!await _until(const Duration(seconds: 8), orWhile: () => _analyzed > 0) || !await _until(_stepTimeout)) {
      if (_done) return;
      if (_analyzed == 0) {
        return _fail(
          _frames == 0
              ? 'The camera isn\'t sending images for face detection on this phone. Close other camera apps and try again.'
              : 'Face detection couldn\'t start on this phone. Please try again.'
                    '${kDebugMode && _detectorError != null ? ' ($_detectorError)' : ''}',
        );
      }
      return _fail('We couldn\'t see your face clearly. Sit in good light, hold the phone at eye level and try again.');
    }
    await _showTick();
    for (var i = 0; i < plan.pre; i++) {
      if (_done || !await shoot()) return;
    }

    for (var i = 0; i < _actions.length; i++) {
      if (_done) return;
      if (plan.flashAt == i && !await shoot(flash: true)) return;
      _setStep(i);
      final want = plan.counts[i];
      // Photos are taken while the user does the action; the last ones are
      // kept once it has been seen.
      final taken = <(XFile, int)>[];
      final deadline = DateTime.now().add(_stepTimeout);
      while (!_met && !_done && DateTime.now().isBefore(deadline)) {
        taken.add((await photo(), clock.elapsedMilliseconds));
        if (taken.length > want * 3) taken.removeAt(0);
        // A pause between photos leaves the camera free to feed detection.
        await Future<void>.delayed(const Duration(milliseconds: 450));
      }
      if (_done) return;
      if (!_met) {
        return _fail(
          'We couldn\'t see you complete "${_actions[i].title}". Follow the guide on the circle in good light, then try again.',
        );
      }
      // At least one photo after it was seen, and enough for its share.
      do {
        taken.add((await photo(), clock.elapsedMilliseconds));
      } while (taken.length < want && !_done);
      final first = paths.length;
      for (final (file, at) in taken.sublist(taken.length - want)) {
        if (!await keep(file, at)) return;
      }
      ranges.add([first, paths.length - 1]);
      await _showTick();
    }

    for (var i = 0; i < plan.post; i++) {
      if (_done || !await shoot()) return;
    }
    if (plan.flashAt == _actions.length && !await shoot(flash: true)) return;
    for (var i = 0; i < plan.tail; i++) {
      if (_done || !await shoot()) return;
    }
    if (_done || !mounted) return;
    _done = true;
    await _speech.cancel();
    if (camera.value.isStreamingImages) await camera.stopImageStream().catchError((Object _) {});
    widget.onCaptured(_FaceCapture(framePaths: paths, timings: timings, actionRanges: ranges, transcript: _transcript));
  }

  void _setStep(int index) {
    setState(() {
      _index = index;
      _met = false;
      _note = null;
      _centeredSince = null;
      _eyesClosed = false;
      _wentUp = false;
      _wentDown = false;
      _typing = false;
      _typedError = null;
    });
    if (_action == FaceChallenge.readNumber) _listenForNumber(index);
  }

  /// Waits until the current step has been seen (or [orWhile] holds), or
  /// [timeout].
  Future<bool> _until(Duration timeout, {bool Function()? orWhile}) async {
    bool ready() => _met || (orWhile?.call() ?? false);
    final deadline = DateTime.now().add(timeout);
    while (!ready() && !_done && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return ready() && !_done;
  }

  Future<void> _showTick() async {
    if (!mounted) return;
    setState(() => _tick = true);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (mounted) setState(() => _tick = false);
  }

  void _seen() {
    if (_met || !mounted) return;
    setState(() => _met = true);
  }

  // ---- Seeing the actions ------------------------------------------------------

  void _onImage(CameraImage image) {
    _frames++;
    if (_busy || _done || _met) return;
    final camera = _camera;
    final input = camera == null ? null : _inputOf(image);
    if (input == null) {
      _detectorError ??= 'unsupported image format ${image.format.raw}';
      return;
    }
    _busy = true;
    _detector
        .processImage(input)
        .then((faces) {
          if (!mounted || _done) return;
          final size = input.metadata!.size;
          final rotated =
              input.metadata!.rotation == InputImageRotation.rotation90deg ||
              input.metadata!.rotation == InputImageRotation.rotation270deg;
          final upright = rotated ? Size(size.height, size.width) : size;
          faces.sort(
            (a, b) =>
                (b.boundingBox.width * b.boundingBox.height).compareTo(a.boundingBox.width * a.boundingBox.height),
          );
          _analyzed++;
          _evaluate(faces.firstOrNull, upright);
        })
        .catchError((Object e) {
          _detectorError = '$e'.split('\n').first;
          if (kDebugMode) debugPrint('Face check: detection failed ($e)');
        })
        .whenComplete(() => _busy = false);
  }

  /// The rotation that turns camera frames upright for detection. Phones
  /// report their front camera's rotation differently, so if no face turns up
  /// the others are tried, and the one that finds a face is kept.
  late final List<int> _rotations = [
    if (Platform.isAndroid) _camera?.description.sensorOrientation ?? 270 else 0,
    for (final r in const [270, 90, 0, 180])
      if (r != (Platform.isAndroid ? _camera?.description.sensorOrientation ?? 270 : 0)) r,
  ];
  int _rotationIndex = 0;
  bool _rotationFound = false;
  int _noFace = 0;

  /// After a run of frames with no face, tries the next rotation.
  void _missedFace() {
    if (_rotationFound || ++_noFace < 6) return;
    _noFace = 0;
    _rotationIndex = (_rotationIndex + 1) % _rotations.length;
  }

  InputImage? _inputOf(CameraImage image) {
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    final supported = Platform.isAndroid ? InputImageFormat.nv21 : InputImageFormat.bgra8888;
    if (format != supported || image.planes.length != 1) return null;
    final rotation = InputImageRotationValue.fromRawValue(_rotations[_rotationIndex]);
    if (rotation == null) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format!,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  void _evaluate(Face? face, Size image) {
    if (face == null) _missedFace();
    if (face != null && !_rotationFound) {
      _rotationFound = true;
      if (kDebugMode) debugPrint('Face check: frames are upright at ${_rotations[_rotationIndex]}°');
    }
    if (face == null) {
      if (_note == null) setState(() => _note = 'Move your face into the circle');
      _centeredSince = null;
      return;
    }
    final box = face.boundingBox;
    final offset = (box.center - image.center(Offset.zero));
    final centered =
        offset.dx.abs() < image.width * 0.35 && offset.dy.abs() < image.height * 0.35 && box.width > image.width * 0.15;
    final note = centered ? null : 'Center your face in the circle';
    if (note != _note) setState(() => _note = note);

    final yaw = face.headEulerAngleY ?? 0;
    final pitch = face.headEulerAngleX ?? 0;
    switch (_action) {
      case null:
        if (!centered) {
          _centeredSince = null;
          return;
        }
        final since = _centeredSince ??= DateTime.now();
        if (DateTime.now().difference(since) >= const Duration(milliseconds: 500)) {
          _baseYaw = yaw;
          _basePitch = pitch;
          _seen();
        }
      case FaceChallenge.turnLeft || FaceChallenge.turnRight:
        // The server checks the direction on the photos; here the head must
        // clearly turn.
        if ((yaw - _baseYaw).abs() > 14) _seen();
      case FaceChallenge.nod:
        if (pitch - _basePitch > 6) _wentUp = true;
        if (pitch - _basePitch < -6) _wentDown = true;
        if (_wentUp && _wentDown) _seen();
      case FaceChallenge.blink:
        final left = face.leftEyeOpenProbability;
        final right = face.rightEyeOpenProbability;
        if (left == null || right == null) return;
        if (left < 0.4 && right < 0.4) _eyesClosed = true;
        if (_eyesClosed && left > 0.5 && right > 0.5) _seen();
      case FaceChallenge.smile:
        if ((face.smilingProbability ?? 0) > 0.6) _seen();
      case FaceChallenge.readNumber:
        break; // heard, not seen
    }
  }

  /// Listens until the number is heard, starting again whenever the phone's
  /// recogniser stops on its own.
  Future<void> _listenForNumber(int index) async {
    _speechReady = _speechReady || await _speech.initialize(onError: (_) {}).catchError((Object _) => false);
    if (!_speechReady) return;
    while (mounted && !_done && !_met && _index == index) {
      final ended = Completer<void>();
      try {
        await _speech.listen(
          onResult: (result) {
            if (_index != index || _met) return;
            final heard = [result.recognizedWords, ...result.alternates.map((a) => a.recognizedWords)];
            if (heard.any((h) => _digits(h).contains(widget.challenge.number))) {
              _transcript = widget.challenge.number;
              _speech.cancel();
              _seen();
            }
            if (result.finalResult && !ended.isCompleted) ended.complete();
          },
          listenOptions: SpeechListenOptions(
            listenFor: const Duration(seconds: 20),
            pauseFor: const Duration(seconds: 6),
            listenMode: ListenMode.dictation,
            cancelOnError: true,
          ),
        );
      } catch (_) {
        return; // the typed number still works
      }
      // Wait for this session to end before starting another.
      final stop = DateTime.now().add(const Duration(seconds: 22));
      while (!ended.isCompleted && _speech.isListening && DateTime.now().isBefore(stop) && !_met) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// "seven two six nine", "72 69" or "7269" → "7269".
  static String _digits(String text) {
    const words = {
      'zero': '0',
      'oh': '0',
      'o': '0',
      'one': '1',
      'two': '2',
      'to': '2',
      'too': '2',
      'three': '3',
      'four': '4',
      'for': '4',
      'five': '5',
      'six': '6',
      'seven': '7',
      'eight': '8',
      'ate': '8',
      'nine': '9',
    };
    final out = StringBuffer();
    for (final token in text.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
      if (token.isEmpty) continue;
      if (RegExp(r'^\d+$').hasMatch(token)) {
        out.write(token);
      } else if (words[token] case final d?) {
        out.write(d);
      }
    }
    return out.toString();
  }

  // ---- Flash and failure ---------------------------------------------------------

  Future<void> _showFlash() async {
    final color = switch (widget.challenge.probeColor) {
      'red' => const Color(0xFFFF0000),
      'blue' => const Color(0xFF0000FF),
      'green' => const Color(0xFF00FF00),
      _ => Colors.white,
    };
    final entry = OverlayEntry(
      builder: (_) => TrueColors(child: ColoredBox(color: color)),
    );
    Overlay.of(context).insert(entry);
    _flash = entry;
    // Let the screen light the face before the frame is taken.
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  void _hideFlash() {
    _flash?.remove();
    _flash = null;
  }

  void _fail(String message) {
    if (_done || !mounted) return;
    _done = true;
    _speech.cancel();
    widget.onFailed(message);
  }

  void _startTyping() => setState(() => _typing = true);

  void _checkTyped() {
    if (_typed.text.trim() != widget.challenge.number) {
      setState(() => _typedError = 'That number doesn\'t match. Try again.');
      return;
    }
    _transcript = _typed.text.trim();
    _speech.cancel();
    setState(() => _typing = false);
    _seen();
  }

  // ---- Screen --------------------------------------------------------------------

  static GuideAction _guideFor(FaceChallenge? c) => switch (c) {
    null => GuideAction.center,
    FaceChallenge.turnLeft => GuideAction.turnLeft,
    FaceChallenge.turnRight => GuideAction.turnRight,
    FaceChallenge.blink => GuideAction.blink,
    FaceChallenge.nod => GuideAction.nod,
    FaceChallenge.smile => GuideAction.smile,
    FaceChallenge.readNumber => GuideAction.readNumber,
  };

  @override
  Widget build(BuildContext context) {
    final action = _action;
    final camera = _camera;
    final size = min(MediaQuery.sizeOf(context).width - 56, 300.0);
    final title = action?.title ?? 'Look at the camera';
    final hint = action?.hint ?? 'Keep your face inside the circle';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: GlassWell(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Text(
              action == null ? 'Get ready' : 'Challenge ${_index + 1} of ${_actions.length}',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ),
        ),
        gap14,
        Center(
          child: LivenessGuide(
            size: size,
            action: _guideFor(action),
            completed: _index < 0 ? 0 : _index + (_met ? 1 : 0),
            total: _actions.length,
            done: _tick,
            number: widget.challenge.number,
            message: _note,
            child: camera == null || !camera.value.isInitialized
                ? ColoredBox(
                    color: AppColors.primary,
                    child: Center(child: Icon(Icons.face_outlined, size: 96, color: AppColors.white(0.55))),
                  )
                : FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: camera.value.previewSize?.height ?? 1,
                      height: camera.value.previewSize?.width ?? 1,
                      child: TrueColors(child: CameraPreview(camera)),
                    ),
                  ),
          ),
        ),
        gap14,
        Text(title, style: AppText.title, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(hint, style: AppText.caption, textAlign: TextAlign.center),
        if (action == FaceChallenge.readNumber && !_met) ...[
          gap14,
          if (_typing)
            Row(
              children: [
                Expanded(
                  child: GlassTextField(
                    controller: _typed,
                    hint: 'Type the number',
                    icon: Icons.pin_outlined,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    errorText: _typedError,
                    onChanged: (_) {
                      if (_typedError != null) setState(() => _typedError = null);
                    },
                    onSubmitted: (_) => _checkTyped(),
                  ),
                ),
                const SizedBox(width: 10),
                SmallPillButton(label: 'Submit', primary: true, onPressed: _checkTyped),
              ],
            )
          else
            Center(
              child: UnderlineLink(label: 'Microphone not working? Type the number', onTap: _startTyping),
            ),
        ],
        gap14,
        Text(
          'Each step moves on once it\'s done. Keep your face inside the circle in good light; the screen may flash once.',
          style: AppText.caption.copyWith(fontSize: 11.5),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.icon,
    required this.title,
    required this.badge,
    required this.subtitle,
    required this.done,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String badge;
  final String subtitle;
  final bool done;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final locked = onTap == null && !done;
    return Opacity(
      opacity: locked ? 0.55 : 1,
      child: GlassWell(
        radius: 22,
        active: onTap != null,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  GlassIconBadge(icon: icon, size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: AppColors.white(0.35)),
                              ),
                              child: Text(
                                done ? 'Done' : badge,
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(subtitle, style: AppText.caption),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    done
                        ? Icons.check_circle_rounded
                        : (locked ? Icons.lock_outline_rounded : Icons.chevron_right_rounded),
                    size: 20,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.entries});

  /// (label, status, done)
  final List<(String, String, bool)> entries;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < entries.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 28,
                  child: Column(
                    children: [
                      Icon(
                        entries[i].$3 ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                        size: 20,
                        color: AppColors.white(entries[i].$3 ? 1 : 0.6),
                      ),
                      if (i < entries.length - 1) Expanded(child: Container(width: 1, color: AppColors.white(0.25))),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: i < entries.length - 1 ? 16 : 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entries[i].$1, style: AppText.label.copyWith(fontSize: 14)),
                        Text(entries[i].$2, style: AppText.caption.copyWith(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Icon badge, title, message, optional details and action.
class _Result extends StatelessWidget {
  const _Result({required this.icon, required this.title, required this.message, this.details, this.action});

  final IconData icon;
  final String title;
  final String message;
  final Widget? details;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: GlassIconBadge(icon: icon, size: 80)),
        gap24,
        Text(title.toUpperCase(), style: AppText.title, textAlign: TextAlign.center),
        gap14,
        Text(message, style: AppText.body, textAlign: TextAlign.center),
        if (details != null) ...[gap24, details!],
        if (action != null) ...[gap24, action!],
      ],
    );
  }
}

/// The seeker's verification levels: Standard after the face check, Full
/// after the ID is approved, with the level reached.
class _Levels extends StatelessWidget {
  const _Levels({required this.state});

  final KycState state;

  @override
  Widget build(BuildContext context) {
    final full = state.level == 'full' || state.idStatus == IdStatus.approved;
    final standard = full || state.level == 'standard' || state.faceVerified;
    final current = full ? 'Full' : (standard ? 'Standard' : 'Not verified');
    return GlassWell(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Verification Levels',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ),
              GlassWell(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                fillTop: 0.1,
                fillBottom: 0.05,
                child: Text(
                  'Level: $current',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final (done, name, detail, icon) in [
            (standard, 'Level 1 · Standard', 'Live face verification', Icons.photo_camera_outlined),
            (full, 'Level 2 · Full', 'Government ID verified', Icons.badge_outlined),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: AppText.label.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
                        Text(detail, style: AppText.caption.copyWith(fontSize: 12)),
                      ],
                    ),
                  ),
                  Icon(
                    done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: AppColors.white(done ? 1 : 0.5),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _UnlockedList extends StatelessWidget {
  const _UnlockedList({
    this.items = const ['Join communities', 'Watch content after 5 minutes of free time', 'Book sessions'],
  });

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_rounded, size: 20, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(child: Text(item, style: AppText.label.copyWith(fontSize: 14))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value, {this.icon});

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.caption),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (icon != null) ...[Icon(icon, size: 14, color: Colors.white), const SizedBox(width: 4)],
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(
        children: [
          const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)),
          gap14,
          Text(message, style: AppText.body),
        ],
      ),
    );
  }
}

/// Icon, label and value in a glass card, e.g. the registered mobile number.
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 20,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GlassIconBadge(icon: icon, size: 44),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.caption),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Attempts remaining" with one dot per attempt left.
class _AttemptsLeft extends StatelessWidget {
  const _AttemptsLeft({required this.left});

  final int left;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(child: Text('Attempts remaining', style: AppText.label.copyWith(fontSize: 13.5))),
          for (var i = 0; i < KycService.maxOtpAttempts; i++)
            Container(
              width: 14,
              height: 14,
              margin: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < left ? Colors.white : Colors.transparent,
                border: Border.all(color: AppColors.white(i < left ? 1 : 0.35)),
              ),
            ),
        ],
      ),
    );
  }
}

/// Counts down the 24-hour OTP lock and calls [onDone] when it ends.
class _LockCountdown extends StatefulWidget {
  const _LockCountdown({required this.until, required this.onDone});

  final DateTime until;
  final VoidCallback onDone;

  @override
  State<_LockCountdown> createState() => _LockCountdownState();
}

class _LockCountdownState extends State<_LockCountdown> {
  late final Timer _timer = Timer.periodic(const Duration(seconds: 1), (_) {
    if (!widget.until.isAfter(DateTime.now())) {
      _timer.cancel();
      widget.onDone();
    } else {
      setState(() {});
    }
  });

  @override
  void initState() {
    super.initState();
    _timer; // start ticking
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var left = widget.until.difference(DateTime.now());
    if (left.isNegative) left = Duration.zero;
    String two(int v) => v.toString().padLeft(2, '0');
    final text = '${two(left.inHours)}:${two(left.inMinutes % 60)}:${two(left.inSeconds % 60)}';
    return GlassWell(
      radius: 20,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const GlassIconBadge(icon: Icons.schedule_rounded, size: 44),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Try again after', style: AppText.caption),
              const SizedBox(height: 2),
              Text(
                text,
                semanticsLabel: '${left.inHours} hours ${left.inMinutes % 60} minutes',
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
