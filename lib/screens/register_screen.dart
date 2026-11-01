import 'package:flutter/material.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/password_policy.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import 'github_sign_in.dart';
import 'login_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  static const redirectDelay = Duration(seconds: 6);

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> with SingleTickerProviderStateMixin {
  final _auth = AuthService.instance;
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _referral = TextEditingController();
  final _passwordFocus = FocusNode();

  UserRole? _role;
  bool _eulaAccepted = false;
  bool _loading = false;
  bool _githubLoading = false;

  String? _error;
  final _errors = <String, String?>{};

  /// Set once registration succeeds; switches the panel to the "check your
  /// email" state and starts the redirect to Sign In.
  String? _registeredEmail;
  late final AnimationController _redirect = AnimationController(vsync: this, duration: RegisterScreen.redirectDelay)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _goToLogin();
    });

  @override
  void initState() {
    super.initState();
    _passwordFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in [_name, _email, _password, _confirm, _referral]) {
      c.dispose();
    }
    _passwordFocus.dispose();
    _redirect.dispose();
    super.dispose();
  }

  bool get _busy => _loading || _githubLoading;

  void _clearError(String field) {
    if (_errors[field] != null) setState(() => _errors[field] = null);
  }

  bool _validate() {
    setState(() {
      _error = null;
      _errors
        ..['name'] = _name.text.trim().length < 2 ? 'Enter your full name.' : null
        ..['email'] = Validators.email(_email.text)
        ..['password'] = Validators.newPassword(_password.text)
        ..['confirm'] = Validators.confirmPassword(_password.text, _confirm.text)
        ..['role'] = _role == null ? 'Choose how you\'ll use Synap Mentor.' : null
        ..['eula'] = _eulaAccepted ? null : 'You need to accept the EULA to continue.';
    });
    return _errors.values.every((e) => e == null);
  }

  Future<void> _register() async {
    FocusScope.of(context).unfocus();
    if (!_validate()) return;
    setState(() => _loading = true);
    try {
      await _auth.register(
        name: _name.text,
        email: _email.text,
        password: _password.text,
        role: _role!,
        referralCode: _referral.text,
      );
      if (!mounted) return;
      setState(() => _registeredEmail = _email.text.trim().toLowerCase());
      _redirect.forward();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _registerWithGitHub() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _errors
        ..['role'] = _role == null ? 'Choose a role to continue with GitHub.' : null
        ..['eula'] = _eulaAccepted ? null : 'You need to accept the EULA to continue.';
    });
    if (_errors['role'] != null || _errors['eula'] != null) return;
    setState(() => _githubLoading = true);
    try {
      final user = await continueWithGitHub(context, signup: true, role: _role, referralCode: _referral.text);
      if (user != null && mounted) enterApp(context, user);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _githubLoading = false);
    }
  }

  void _goToLogin() {
    if (!mounted) return;
    _redirect.stop();
    Navigator.of(context).pushReplacement(
      glassRoute(
        LoginScreen(
          initialEmail: _registeredEmail,
          notice: _registeredEmail == null ? null : 'Verify your email using the link we sent, then sign in.',
        ),
      ),
    );
  }

  Future<void> _showEula() async {
    final accepted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: AppColors.primary.withValues(alpha: 0.45),
      builder: (_) => const EulaSheet(),
    );
    if (accepted == true && mounted) {
      setState(() {
        _eulaAccepted = true;
        _errors['eula'] = null;
      });
    }
  }

  // Compact sizes so the whole form fits one screen without scrolling;
  // still comfortable touch targets.
  static const _fieldHeight = 48.0;
  static const _buttonHeight = 50.0;
  static SizedBox _gap(double height) => SizedBox(height: height);

  @override
  Widget build(BuildContext context) {
    final done = _registeredEmail != null;
    return AuthScaffold(
      fitToScreen: true,
      title: done ? 'Check Your Email' : 'Register',
      subtitle: done ? null : 'Create your account to join Synap Mentor.',
      showBack: !done,
      trailing: done
          ? null
          : UnderlineLink(
              label: 'Sign In',
              bold: true,
              onTap: () => Navigator.of(context).pushReplacement(glassRoute(const LoginScreen())),
            ),
      child: StepSwitcher(
        child: done
            ? KeyedSubtree(key: const ValueKey('done'), child: _buildSuccess())
            : KeyedSubtree(key: const ValueKey('form'), child: _buildForm()),
      ),
    );
  }

  Widget _buildForm() {
    return AutofillGroup(
      child: GlassFormColumn(
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          GlassTextField(
            height: _fieldHeight,
            controller: _name,
            hint: 'Full name',
            icon: Icons.person_outline_rounded,
            textCapitalization: TextCapitalization.words,
            autofillHints: const [AutofillHints.name],
            textInputAction: TextInputAction.next,
            errorText: _errors['name'],
            onChanged: (_) => _clearError('name'),
          ),
          _gap(8),
          GlassTextField(
            height: _fieldHeight,
            controller: _email,
            hint: 'Email address',
            icon: Icons.alternate_email_rounded,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.next,
            errorText: _errors['email'],
            onChanged: (_) => _clearError('email'),
          ),
          _gap(8),
          GlassTextField(
            height: _fieldHeight,
            controller: _password,
            focusNode: _passwordFocus,
            hint: 'Password',
            icon: Icons.lock_outline_rounded,
            obscure: true,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.next,
            errorText: _errors['password'],
            onChanged: (_) {
              _clearError('password');
              setState(() {});
            },
          ),
          PasswordChecklist(password: _password.text, visible: _passwordFocus.hasFocus || _password.text.isNotEmpty),
          _gap(8),
          GlassTextField(
            height: _fieldHeight,
            controller: _confirm,
            hint: 'Confirm password',
            icon: Icons.lock_reset_rounded,
            obscure: true,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.next,
            errorText: _errors['confirm'],
            onChanged: (_) => _clearError('confirm'),
          ),
          _gap(12),
          Text('I am joining as a', style: AppText.label, textAlign: TextAlign.center),
          _gap(8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final role in UserRole.values) ...[
                if (role != UserRole.values.first) const SizedBox(width: 10),
                Expanded(
                  child: GlassChoiceTile(
                    icon: role == UserRole.seeker ? Icons.travel_explore_rounded : Icons.lightbulb_outline_rounded,
                    title: role.label,
                    subtitle: role == UserRole.seeker ? 'I have problems to solve' : 'I solve problems',
                    selected: _role == role,
                    error: _errors['role'] != null,
                    compact: true,
                    onTap: () => setState(() {
                      _role = role;
                      _errors['role'] = null;
                    }),
                  ),
                ),
              ],
            ],
          ),
          FieldError(_errors['role']),
          _gap(10),
          GlassTextField(
            height: _fieldHeight,
            controller: _referral,
            hint: 'Referral code (optional)',
            icon: Icons.card_giftcard_rounded,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
          ),
          _gap(8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GlassCheckbox(
                value: _eulaAccepted,
                error: _errors['eula'] != null,
                onChanged: (v) => setState(() {
                  _eulaAccepted = v;
                  if (v) _errors['eula'] = null;
                }),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('I have read and accept the ', style: AppText.label.copyWith(fontSize: 13)),
                    UnderlineLink(label: 'EULA', bold: true, onTap: _showEula),
                  ],
                ),
              ),
            ],
          ),
          FieldError(_errors['eula']),
          _gap(10),
          PrimaryPillButton(
            label: 'Register',
            height: _buttonHeight,
            loading: _loading,
            onPressed: _busy ? null : _register,
          ),
          _gap(8),
          const OrDivider(),
          _gap(8),
          GlassPillButton(
            height: _buttonHeight,
            label: 'Continue with GitHub',
            icon: Icons.code_rounded,
            loading: _githubLoading,
            onPressed: _busy ? null : _registerWithGitHub,
          ),
        ],
      ),
    );
  }

  Widget _buildSuccess() {
    return GlassFormColumn(
      children: [
        const Center(child: GlassIconBadge(icon: Icons.mark_email_read_outlined, size: 72)),
        gap24,
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'We\'ve sent a verification email to '),
              TextSpan(
                text: _registeredEmail,
                style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
              ),
              const TextSpan(text: '. Open the magic link inside to verify your address, then sign in.'),
            ],
          ),
          style: AppText.body,
          textAlign: TextAlign.center,
        ),
        gap24,
        for (final line in const ['Verification magic link sent', 'Backup codes sent — keep them somewhere safe'])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.check_circle_rounded, size: 17, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(line, style: AppText.caption.copyWith(color: Colors.white)),
                ),
              ],
            ),
          ),
        gap24,
        AnimatedBuilder(
          animation: _redirect,
          builder: (context, _) {
            final secondsLeft = (RegisterScreen.redirectDelay.inSeconds * (1 - _redirect.value)).ceil();
            return Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: _redirect.value,
                    minHeight: 3,
                    backgroundColor: AppColors.white(0.18),
                    valueColor: const AlwaysStoppedAnimation(Colors.white),
                  ),
                ),
                gap8,
                Text('Taking you to Sign In in ${secondsLeft}s', style: AppText.caption),
              ],
            );
          },
        ),
        gap24,
        PrimaryPillButton(label: 'Go to Sign In', onPressed: _goToLogin),
      ],
    );
  }
}

/// The EULA; pops `true` when accepted.
class EulaSheet extends StatelessWidget {
  const EulaSheet({super.key});

  static const _sections = [
    (
      '1. Your account',
      'You are responsible for keeping your credentials and backup codes secure, and for all activity under your account.',
    ),
    (
      '2. Acceptable use',
      'Do not post unlawful, misleading or harmful content, impersonate others, or attempt to disrupt or reverse-engineer the service.',
    ),
    (
      '3. Problems and solutions',
      'You keep ownership of what you submit. You grant Synap Mentor a licence to host and display it so the service can work.',
    ),
    (
      '4. Privacy',
      'We process your personal data as described in our Privacy Policy, including the email address used for sign-in and verification.',
    ),
    ('5. Termination', 'We may suspend accounts that breach these terms. You can close your account at any time.'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8, maxWidth: 480),
        child: GlassPanel(
          radius: 32,
          blur: 5,
          padding: const EdgeInsets.fromLTRB(22, 28, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('END USER LICENSE AGREEMENT', style: AppText.title, textAlign: TextAlign.center),
              gap14,
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (title, body) in _sections) ...[
                        Text(title, style: AppText.label.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(body, style: AppText.body),
                        gap14,
                      ],
                    ],
                  ),
                ),
              ),
              gap8,
              GlassFormColumn(
                children: [PrimaryPillButton(label: 'I Accept', onPressed: () => Navigator.of(context).pop(true))],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
