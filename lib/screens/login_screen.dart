import 'package:flutter/material.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/password_policy.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import 'forgot_password_screen.dart';
import 'register_screen.dart';

enum LoginMethod {
  password('Password', Icons.lock_outline_rounded),
  otp('OTP', Icons.pin_outlined),
  magicLink('Magic Link', Icons.link_rounded),
  backupCode('Backup Code', Icons.key_outlined);

  const LoginMethod(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// One sign-in screen for every method. The email field is shared, so
/// switching methods keeps what the user already typed.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.initialEmail, this.notice});

  final String? initialEmail;

  /// Success message carried over from registration or password reset.
  final String? notice;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with ResendCooldown {
  final _auth = AuthService.instance;
  late final _email = TextEditingController(text: widget.initialEmail);
  final _password = TextEditingController();
  final _otp = TextEditingController();
  final _backupCode = TextEditingController();

  LoginMethod _method = LoginMethod.password;
  bool _loading = false;
  bool _otpSent = false;
  String? _magicToken;

  String? _error;
  late String? _success = widget.notice;
  String? _emailError;
  String? _secretError;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _otp.dispose();
    _backupCode.dispose();
    super.dispose();
  }

  bool get _awaitingSecondStep => _otpSent || _magicToken != null;

  void _selectMethod(LoginMethod method) {
    if (_loading || method == _method) return;
    setState(() {
      _method = method;
      _resetSteps();
    });
  }

  void _resetSteps() {
    _otpSent = false;
    _magicToken = null;
    _otp.clear();
    _error = null;
    _success = null;
    _secretError = null;
    stopResendCooldown();
  }

  bool _checkEmail() {
    setState(() => _emailError = Validators.email(_email.text));
    return _emailError == null;
  }

  Future<void> _run(Future<void> Function() task) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _success = null;
    });
    try {
      await task();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _signInWithPassword() {
    final emailOk = _checkEmail();
    setState(() => _secretError = _password.text.isEmpty ? 'Enter your password.' : null);
    if (!emailOk || _secretError != null) return;
    _run(() async {
      final user = await _auth.signInWithPassword(_email.text, _password.text);
      if (mounted) enterApp(context, user);
    });
  }

  void _sendOtp() {
    if (!_checkEmail()) return;
    _run(() async {
      await _auth.sendLoginOtp(_email.text);
      if (!mounted) return;
      setState(() {
        _otpSent = true;
        _otp.clear();
      });
      startResendCooldown();
    });
  }

  void _verifyOtp() {
    if (_otp.text.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from your email.');
      return;
    }
    _run(() async {
      final user = await _auth.verifyLoginOtp(_email.text, _otp.text);
      if (mounted) enterApp(context, user);
    });
  }

  void _sendMagicLink() {
    if (!_checkEmail()) return;
    _run(() async {
      final token = await _auth.sendLoginMagicLink(_email.text);
      if (!mounted) return;
      setState(() => _magicToken = token);
      startResendCooldown();
      _waitForMagicLink(token);
    });
  }

  Future<void> _waitForMagicLink(String token) async {
    try {
      final user = await _auth.waitForLoginLink(token);
      // Ignore links for a request the user has since abandoned.
      if (mounted && _magicToken == token) enterApp(context, user);
    } on AuthException catch (e) {
      if (mounted && _magicToken == token) setState(() => _error = e.message);
    }
  }

  void _signInWithBackupCode() {
    final emailOk = _checkEmail();
    setState(() => _secretError = _backupCode.text.trim().isEmpty ? 'Enter one of your backup codes.' : null);
    if (!emailOk || _secretError != null) return;
    _run(() async {
      final user = await _auth.signInWithBackupCode(_email.text, _backupCode.text);
      if (mounted) enterApp(context, user);
    });
  }

  Future<void> _openForgotPassword() async {
    final reset = await Navigator.of(context)
        .push<bool>(glassRoute(ForgotPasswordScreen(initialEmail: _email.text.trim())));
    if (reset == true && mounted) {
      setState(() {
        _method = LoginMethod.password;
        _resetSteps();
        _password.clear();
        _success = 'Password updated. Sign in with your new password.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Sign In',
      subtitle: 'Welcome back. Choose how you\'d like to sign in.',
      trailing: UnderlineLink(
        label: 'Register',
        bold: true,
        onTap: () => Navigator.of(context).pushReplacement(glassRoute(const RegisterScreen())),
      ),
      child: AutofillGroup(
        child: Column(
          children: [
            _MethodSelector(selected: _method, onSelected: _loading ? null : _selectMethod),
            const SizedBox(height: 28),
            GlassFormColumn(
              children: [
                InlineNotice(message: _success, tone: NoticeTone.success),
                InlineNotice(message: _error, tone: NoticeTone.error),
                if (_magicToken == null)
                  GlassTextField(
                    controller: _email,
                    hint: 'Email address',
                    icon: Icons.alternate_email_rounded,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    textInputAction: TextInputAction.next,
                    readOnly: _awaitingSecondStep,
                    errorText: _emailError,
                    onChanged: (_) {
                      if (_emailError != null) setState(() => _emailError = null);
                    },
                  ),
                StepSwitcher(
                  child: KeyedSubtree(
                    key: ValueKey('$_method-$_otpSent-${_magicToken != null}'),
                    child: _buildMethodBody(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMethodBody() {
    switch (_method) {
      case LoginMethod.password:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            gap14,
            GlassTextField(
              controller: _password,
              hint: 'Password',
              icon: Icons.lock_outline_rounded,
              obscure: true,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              errorText: _secretError,
              onSubmitted: (_) => _signInWithPassword(),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: UnderlineLink(label: 'Forgot Password?', onTap: _loading ? null : _openForgotPassword),
              ),
            ),
            gap24,
            PrimaryPillButton(label: 'Sign In', loading: _loading, onPressed: _signInWithPassword),
          ],
        );

      case LoginMethod.otp:
        if (!_otpSent) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              gap24,
              PrimaryPillButton(label: 'Send OTP', loading: _loading, onPressed: _sendOtp),
              gap14,
              Text('We\'ll email you a one-time 6-digit code.', style: AppText.caption, textAlign: TextAlign.center),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            gap24,
            Text('Enter the 6-digit code sent to your email', style: AppText.label, textAlign: TextAlign.center),
            gap14,
            OtpInput(controller: _otp, onCompleted: (_) => _verifyOtp()),
            gap8,
            ResendRow(secondsLeft: resendSecondsLeft, onResend: _sendOtp, onChangeEmail: () => setState(_resetSteps)),
            gap14,
            PrimaryPillButton(label: 'Verify', loading: _loading, onPressed: _verifyOtp),
          ],
        );

      case LoginMethod.magicLink:
        if (_magicToken == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              gap24,
              PrimaryPillButton(label: 'Send Magic Link', loading: _loading, onPressed: _sendMagicLink),
              gap14,
              Text(
                'We\'ll email you a secure link that signs you in instantly.',
                style: AppText.caption,
                textAlign: TextAlign.center,
              ),
            ],
          );
        }
        return MagicLinkWaiting(
          email: _email.text.trim(),
          message: 'Open it to continue — you\'ll be signed in automatically.',
          resend: ResendRow(
            secondsLeft: resendSecondsLeft,
            resendLabel: 'Resend link',
            onResend: _sendMagicLink,
            onChangeEmail: () => setState(_resetSteps),
          ),
        );

      case LoginMethod.backupCode:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            gap14,
            GlassTextField(
              controller: _backupCode,
              hint: 'Backup code',
              icon: Icons.key_outlined,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              errorText: _secretError,
              onSubmitted: (_) => _signInWithBackupCode(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Text(
                'Use one of the backup codes emailed to you when you registered. Each code works once.',
                style: AppText.caption,
                textAlign: TextAlign.center,
              ),
            ),
            gap24,
            PrimaryPillButton(label: 'Sign In', loading: _loading, onPressed: _signInWithBackupCode),
          ],
        );
    }
  }
}

/// Glass segmented control with a sliding frosted indicator.
class _MethodSelector extends StatelessWidget {
  const _MethodSelector({required this.selected, required this.onSelected});

  final LoginMethod selected;
  final ValueChanged<LoginMethod>? onSelected;

  @override
  Widget build(BuildContext context) {
    const methods = LoginMethod.values;
    return GlassWell(
      radius: 22,
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        height: 60,
        child: Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              alignment: Alignment(-1 + 2 * selected.index / (methods.length - 1), 0),
              child: FractionallySizedBox(
                widthFactor: 1 / methods.length,
                heightFactor: 1,
                child: const GlassWell(
                  radius: 18,
                  active: true,
                  fillTop: 0.10,
                  fillBottom: 0.06,
                  child: SizedBox.expand(),
                ),
              ),
            ),
            Row(
              children: [
                for (final method in methods)
                  Expanded(
                    child: Semantics(
                      selected: method == selected,
                      button: true,
                      label: method.label,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: onSelected == null ? null : () => onSelected!(method),
                        child: ExcludeSemantics(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(method.icon, size: 19, color: AppColors.white(method == selected ? 1 : 0.7)),
                                const SizedBox(height: 4),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    method.label,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: method == selected ? FontWeight.w700 : FontWeight.w400,
                                      color: AppColors.white(method == selected ? 1 : 0.75),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
