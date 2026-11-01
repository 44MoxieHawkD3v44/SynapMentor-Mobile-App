import 'package:flutter/material.dart';

import '../core/theme.dart';

const _identity = ColorFilter.matrix(<double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Keeps photos and video in their real colors in light mode by undoing the
/// app-wide light-mode filter (which is its own inverse). In dark mode it
/// changes nothing. The filter is always present so switching modes never
/// rebuilds what's inside, such as a playing video.
class TrueColors extends StatelessWidget {
  const TrueColors({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Appearance>(
      valueListenable: appearance,
      child: child,
      builder: (context, mode, child) =>
          ColorFiltered(colorFilter: mode == Appearance.light ? lightModeFilter : _identity, child: child),
    );
  }
}
