import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'glass.dart';
import 'glass_controls.dart';

/// Shared frame for every auth screen: a top bar (back + optional link) and a
/// single large glass panel carrying the heading and the form.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.onBack,
    this.showBack = true,
    this.fitToScreen = false,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final VoidCallback? onBack;
  final bool showBack;

  /// Lays the whole panel out in one viewport with no scrolling. The panel
  /// only scales down on very short screens, and the keyboard slides the page
  /// up just enough to keep the focused field visible.
  final bool fitToScreen;

  @override
  Widget build(BuildContext context) {
    final canGoBack = showBack && (onBack != null || Navigator.of(context).canPop());
    final topBar = Padding(
      padding: EdgeInsets.fromLTRB(20, fitToScreen ? 4 : 8, 16, 0),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            if (canGoBack)
              GlassIconButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back',
                onPressed: onBack ?? () => Navigator.of(context).maybePop(),
              ),
            const Spacer(),
            ?trailing,
          ],
        ),
      ),
    );
    if (fitToScreen) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: _KeyboardLift(
            child: Column(
              children: [
                topBar,
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth.clamp(0.0, 440.0);
                        return Align(
                          alignment: const Alignment(0, -0.3),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                              width: width,
                              child: GlassPanel(
                                padding: const EdgeInsets.fromLTRB(14, 22, 14, 20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Text(title.toUpperCase(), style: AppText.heading, textAlign: TextAlign.center),
                                    if (subtitle != null)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                                        child: Text(subtitle!, style: AppText.body, textAlign: TextAlign.center),
                                      ),
                                    const SizedBox(height: 16),
                                    child,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 16, 0),
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    if (canGoBack)
                      GlassIconButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: 'Back',
                        onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                      ),
                    const Spacer(),
                    ?trailing,
                  ],
                ),
              ),
            ),
            // The glass stays fixed inside the screen and the form scrolls
            // within it: a backdrop filter that extends past a scroll viewport
            // loses its blur.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Align(
                  alignment: const Alignment(0, -0.4),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: GlassPanel(
                      padding: EdgeInsets.zero,
                      child: SingleChildScrollView(
                        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(14, 40, 14, 40),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(title.toUpperCase(), style: AppText.heading, textAlign: TextAlign.center),
                            if (subtitle != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                                child: Text(subtitle!, style: AppText.body, textAlign: TextAlign.center),
                              ),
                            const SizedBox(height: 32),
                            child,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slides a fixed (non-scrolling) page up while the keyboard is open, by just
/// enough to keep the focused field above it.
class _KeyboardLift extends StatefulWidget {
  const _KeyboardLift({required this.child});

  final Widget child;

  @override
  State<_KeyboardLift> createState() => _KeyboardLiftState();
}

class _KeyboardLiftState extends State<_KeyboardLift> {
  double _lift = 0;

  @override
  void initState() {
    super.initState();
    // Moving to another field re-measures without a keyboard change.
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  void _measure(double keyboard) {
    if (!mounted) return;
    var target = 0.0;
    final box = FocusManager.instance.primaryFocus?.context?.findRenderObject();
    if (keyboard > 0 && box is RenderBox && box.attached) {
      final screen = MediaQuery.sizeOf(context).height;
      // Where the field sits without the current lift, plus room for its
      // glass padding and any error text.
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy + _lift + 24;
      target = (bottom - (screen - keyboard)).clamp(0.0, keyboard);
    }
    if ((target - _lift).abs() > 0.5) setState(() => _lift = target);
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure(keyboard));
    return Transform.translate(offset: Offset(0, -_lift), child: widget.child);
  }
}

/// Swaps panel content (steps, methods) with a short fade and slide. Safe to
/// fade: panel content holds wells, not backdrop-filtered glass.
class StepSwitcher extends StatelessWidget {
  const StepSwitcher({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(animation),
            child: child,
          ),
        ),
        child: child,
      ),
    );
  }
}

class OrDivider extends StatelessWidget {
  const OrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final line = Expanded(child: Container(height: 1, color: AppColors.white(0.18)));
    return Row(
      children: [
        line,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('or', style: AppText.caption),
        ),
        line,
      ],
    );
  }
}

/// 30-second lockout between code/link resends.
mixin ResendCooldown<T extends StatefulWidget> on State<T> {
  Timer? _cooldown;
  int resendSecondsLeft = 0;

  void startResendCooldown() {
    _cooldown?.cancel();
    setState(() => resendSecondsLeft = 30);
    _cooldown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => resendSecondsLeft--);
      if (resendSecondsLeft <= 0) timer.cancel();
    });
  }

  void stopResendCooldown() {
    _cooldown?.cancel();
    resendSecondsLeft = 0;
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    super.dispose();
  }
}

/// "Resend in 0:24" countdown that turns into a link.
class ResendRow extends StatelessWidget {
  const ResendRow({
    super.key,
    required this.secondsLeft,
    required this.onResend,
    required this.onChangeEmail,
    this.resendLabel = 'Resend code',
  });

  final int secondsLeft;
  final VoidCallback onResend;
  final VoidCallback onChangeEmail;
  final String resendLabel;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      children: [
        if (secondsLeft > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('Resend in 0:${secondsLeft.toString().padLeft(2, '0')}', style: AppText.caption),
          )
        else
          UnderlineLink(label: resendLabel, onTap: onResend),
        Text('·', style: AppText.caption),
        UnderlineLink(label: 'Change email', onTap: onChangeEmail),
      ],
    );
  }
}

const gap8 = SizedBox(height: 8);
const gap14 = SizedBox(height: 14);
const gap24 = SizedBox(height: 24);
