import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../widgets/brand_logo.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import 'github_sign_in.dart';
import 'login_screen.dart';
import 'register_screen.dart';

/// Splash and welcome are one screen: the logo sits alone in the center for
/// the splash duration, then the welcome panel rises from below the screen and
/// docks to the bottom edge while the logo lifts to make room.
class SplashWelcomeScreen extends StatefulWidget {
  const SplashWelcomeScreen({super.key});

  static const splashDuration = Duration(milliseconds: 3500);

  @override
  State<SplashWelcomeScreen> createState() => _SplashWelcomeScreenState();
}

class _SplashWelcomeScreenState extends State<SplashWelcomeScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  late final Timer _splashTimer;

  /// Checked while the logo shows: a saved session skips the welcome card.
  final _restore = AuthService.instance.restoreSession();

  @override
  void initState() {
    super.initState();
    _splashTimer = Timer(SplashWelcomeScreen.splashDuration, _afterSplash);
  }

  Future<void> _afterSplash() async {
    final user = await _restore;
    if (!mounted) return;
    if (user != null) {
      enterApp(context, user);
    } else {
      _reveal.forward();
    }
  }

  @override
  void dispose() {
    _splashTimer.cancel();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedBuilder(
        animation: _reveal,
        builder: (context, _) {
          final reveal = Curves.easeOutCubic.transform(_reveal.value);
          // Only translation here: fading would strip the frost off the glass.
          return Stack(
            children: [
              Align(
                alignment: Alignment(0, lerpDouble(0, -0.56, reveal)!),
                child: Transform.scale(scale: 1 - 0.1 * reveal, child: const BrandLogo()),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: FractionalTranslation(
                  translation: Offset(0, 1.05 * (1 - reveal)),
                  child: IgnorePointer(ignoring: _reveal.value < 1, child: const _WelcomeCard()),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _WelcomeCard extends StatefulWidget {
  const _WelcomeCard();

  @override
  State<_WelcomeCard> createState() => _WelcomeCardState();
}

class _WelcomeCardState extends State<_WelcomeCard> {
  bool _github = false;
  String? _error;

  Future<void> _signInWithGitHub() async {
    setState(() {
      _github = true;
      _error = null;
    });
    try {
      final user = await continueWithGitHub(context);
      if (user != null && mounted) enterApp(context, user);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _github = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Full width, docked to the bottom edge; the bottom padding also clears
    // the system gesture area.
    return GlassPanel(
      radius: 34,
      squareBottom: true,
      padding: EdgeInsets.fromLTRB(26, 40, 26, 32 + MediaQuery.paddingOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('WELCOME', style: AppText.heading, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
            'Where problem seekers meet the problem solvers who can crack them. '
            'Sign in or create your account to get started.',
            style: AppText.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          InlineNotice(message: _error, tone: NoticeTone.error),
          Row(
            children: [
              Expanded(
                child: PrimaryPillButton(
                  label: 'Sign In',
                  onPressed: () => Navigator.of(context).push(glassRoute(const LoginScreen())),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GlassPillButton(
                  label: 'Sign Up',
                  onPressed: () => Navigator.of(context).push(glassRoute(const RegisterScreen())),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GlassPillButton(
            label: 'Sign in with GitHub',
            icon: Icons.code_rounded,
            loading: _github,
            onPressed: _github ? null : _signInWithGitHub,
          ),
        ],
      ),
    );
  }
}
