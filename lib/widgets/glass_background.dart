import 'package:flutter/material.dart';

import '../core/theme.dart';

/// The scene behind every screen: a flat field of the brand color.
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: AppColors.primary, child: SizedBox.expand());
  }
}
