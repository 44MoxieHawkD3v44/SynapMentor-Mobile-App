import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/password_policy.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass_controls.dart';

enum _Step { request, enterOtp, awaitLink, newPassword }

/// Email → reset method (OTP or magic link) → proof → new password.
/// Pops with `true` once the password has been changed.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail});

  final String? initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> with ResendCooldown {
  final _auth = AuthService.instance;
  late final _email = TextEditingController(text: widget.initialEmail);
  final _otp = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  _Step _step = _Step.request;
  ResetMethod _method = ResetMethod.otp;
  bool _loading = false;
  String? _error;
  String? _emailError;
  String? _passwordError;
  String? _confirmError;

  @override
  void dispose() {
    _email.dispose();
    _otp.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() task) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await task();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _send() {
    setState(() => _emailError = Validators.email(_email.text));
    if (_emailError != null) return;
    _run(() async {
      await _auth.requestPasswordReset(_email.text, _method);
      if (!mounted) return;
      setState(() {
        _otp.clear();
        _step = _method == ResetMethod.otp ? _Step.enterOtp : _Step.awaitLink;
      });
      startResendCooldown();
    });
  }

  /// The API checks the code together with the new password, so this only
  /// moves on to choosing it.
  void _verifyOtp() {
    FocusScope.of(context).unfocus();
    setState(() {
      if (_otp.text.length != 6) {
        _error = 'Enter the 6-digit code from your email.';
        return;
      }
      _error = null;
      _step = _Step.newPassword;
    });
  }

  void _savePassword() {
    setState(() {
      _passwordError = Validators.newPassword(_password.text);
      _confirmError = Validators.confirmPassword(_password.text, _confirm.text);
    });
    if (_passwordError != null || _confirmError != null) return;
    _run(() async {
      await _auth.resetPassword(email: _email.text, code: _otp.text, newPassword: _password.text);
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  void _restart() {
    setState(() {
      _step = _Step.request;
      _error = null;
      stopResendCooldown();
    });
  }

  String get _subtitle => switch (_step) {
    _Step.request => 'Enter your account email and choose how you\'d like to reset your password.',
    _Step.enterOtp => 'Enter the 6-digit code we emailed you.',
    _Step.awaitLink => 'Open the reset link we emailed you to continue.',
    _Step.newPassword => 'Choose a new password for your account.',
  };

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: _step == _Step.newPassword ? 'New Password' : 'Forgot Password',
      subtitle: _subtitle,
      // From the new password, back returns to the code in case it was mistyped.
      onBack: switch (_step) {
        _Step.request => null,
        _Step.newPassword => () => setState(() {
          _step = _Step.enterOtp;
          _error = null;
        }),
        _ => _restart,
      },
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
    switch (_step) {
      case _Step.request:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassTextField(
              controller: _email,
              hint: 'Email address',
              icon: Icons.alternate_email_rounded,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              errorText: _emailError,
              onChanged: (_) {
                if (_emailError != null) setState(() => _emailError = null);
              },
            ),
            gap24,
            Text('Reset using', style: AppText.label, textAlign: TextAlign.center),
            gap14,
            Row(
              children: [
                Expanded(
                  child: GlassChoiceTile(
                    icon: Icons.pin_outlined,
                    title: 'OTP',
                    subtitle: '6-digit code by email',
                    selected: _method == ResetMethod.otp,
                    onTap: () => setState(() => _method = ResetMethod.otp),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GlassChoiceTile(
                    icon: Icons.link_rounded,
                    title: 'Magic Link',
                    subtitle: 'Secure link by email',
                    selected: _method == ResetMethod.magicLink,
                    onTap: () => setState(() => _method = ResetMethod.magicLink),
                  ),
                ),
              ],
            ),
            gap24,
            PrimaryPillButton(
              label: _method == ResetMethod.otp ? 'Send OTP' : 'Send Magic Link',
              loading: _loading,
              onPressed: _send,
            ),
          ],
        );

      case _Step.enterOtp:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OtpInput(controller: _otp, onCompleted: (_) => _verifyOtp()),
            gap8,
            ResendRow(secondsLeft: resendSecondsLeft, onResend: _send, onChangeEmail: _restart),
            gap14,
            PrimaryPillButton(label: 'Verify', loading: _loading, onPressed: _verifyOtp),
          ],
        );

      case _Step.awaitLink:
        return MagicLinkWaiting(
          email: _email.text.trim(),
          message: 'Open it to choose a new password.',
          resend: ResendRow(
            secondsLeft: resendSecondsLeft,
            resendLabel: 'Resend link',
            onResend: _send,
            onChangeEmail: _restart,
          ),
        );

      case _Step.newPassword:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassTextField(
              controller: _password,
              hint: 'New password',
              icon: Icons.lock_outline_rounded,
              obscure: true,
              autofillHints: const [AutofillHints.newPassword],
              errorText: _passwordError,
              onChanged: (_) => setState(() => _passwordError = null),
            ),
            PasswordChecklist(password: _password.text, visible: true),
            gap14,
            GlassTextField(
              controller: _confirm,
              hint: 'Confirm new password',
              icon: Icons.lock_reset_rounded,
              obscure: true,
              autofillHints: const [AutofillHints.newPassword],
              errorText: _confirmError,
              onChanged: (_) {
                if (_confirmError != null) setState(() => _confirmError = null);
              },
              onSubmitted: (_) => _savePassword(),
            ),
            gap24,
            PrimaryPillButton(label: 'Reset Password', loading: _loading, onPressed: _savePassword),
          ],
        );
    }
  }
}
