import 'package:flutter/material.dart';

import '../screens/app_shell.dart';
import '../services/auth_service.dart';

/// Horizontal slide, no fade: fading would put the glass inside an opacity
/// layer and drop its frost for the length of the transition.
Route<T> glassRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 380),
    reverseTransitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curve = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      final out = CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeOutCubic);
      return SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(curve),
        child: SlideTransition(
          position: Tween(begin: Offset.zero, end: const Offset(-0.25, 0)).animate(out),
          child: child,
        ),
      );
    },
  );
}

/// After any successful sign-in: straight to the screens for the role the
/// credentials belong to.
void enterApp(BuildContext context, AppUser user) {
  final Widget page = switch (user.role) {
    UserRole.seeker => SeekerHomeScreen(user: user),
    UserRole.solver => SolverHomeScreen(user: user),
  };
  Navigator.of(context).pushAndRemoveUntil(glassRoute(page), (_) => false);
}
