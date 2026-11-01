import 'package:flutter/material.dart';

import 'animated_logo.dart';

/// Animated logo + wordmark: "SYNAP MENTOR" in bold capitals on one line.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.markSize});

  /// Defaults to 150, smaller on short screens so the welcome card fits.
  final double? markSize;

  static double _defaultMarkSize(double screenHeight) => (screenHeight * 0.18).clamp(110, 150);

  /// Starts loading the logo at launch, so it's ready when the splash opens.
  static void preload() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return;
    AnimatedLogo.preload(_defaultMarkSize(view.physicalSize.height / view.devicePixelRatio));
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Synap Mentor',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedLogo(size: markSize ?? _defaultMarkSize(MediaQuery.sizeOf(context).height)),
          const SizedBox(height: 16),
          const ExcludeSemantics(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              // Always one line: shrinks on narrow screens or large text.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  // Offsets the trailing letter-spacing so the name stays centered.
                  padding: EdgeInsets.only(left: 3),
                  child: Text(
                    'SYNAP MENTOR',
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3,
                      height: 1,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
