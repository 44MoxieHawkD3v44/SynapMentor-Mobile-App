import 'package:flutter/material.dart';

enum Appearance { dark, light }

/// The chosen look. The UI is designed dark; light mode is an exact
/// monochrome remap of it done once at the app root by [lightModeFilter].
final appearance = ValueNotifier<Appearance>(Appearance.dark);

bool get isLightMode => appearance.value == Appearance.light;

/// Light mode: #00001A ground → white, white text and icons → #00001A, the
/// white primary buttons → #00001A with white text, and the dark glass →
/// light glass. It maps each channel linearly (R, G: 255 − x; B: 281 − x), so
/// it is its own inverse; applying it twice gives back the original colors.
const lightModeFilter = ColorFilter.matrix(<double>[
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 281, //
  0, 0, 0, 1, 0, //
]);

/// The color to paint so it shows as [shown] once the light-mode filter runs.
Color _underLightFilter(Color shown) {
  int channel(double v) => (v * 255).round();
  return Color.fromARGB(
    channel(shown.a),
    255 - channel(shown.r),
    255 - channel(shown.g),
    (281 - channel(shown.b)).clamp(0, 255),
  );
}

abstract final class AppColors {
  /// Brand primary. Used for the app ground and for text on opaque white.
  static const primary = Color(0xFF00001A);

  // Ambient color fields that sit behind the glass. They only ever appear
  // through (or around) frosted surfaces, never as UI fills.
  static const glowIndigo = Color(0xFF3A46FF);
  static const glowViolet = Color(0xFF7A3CF2);
  static const glowCyan = Color(0xFF19C6FF);
  static const glowBlue = Color(0xFF1F63FF);

  // Status colors stay red and green in light mode too.
  static Color get error => isLightMode ? _underLightFilter(const Color(0xFFC62828)) : const Color(0xFFFFB4BC);
  static Color get success => isLightMode ? _underLightFilter(const Color(0xFF2E7D32)) : const Color(0xFFB4F5D8);

  /// Tints of inline error and success notices.
  static Color get noticeError => isLightMode ? _underLightFilter(const Color(0xFFD32F2F)) : const Color(0xFFFF6B7D);
  static Color get noticeSuccess => isLightMode ? _underLightFilter(const Color(0xFF2E7D32)) : const Color(0xFF5CE0A8);

  /// Soft shadows under floating glass: #00001A in both modes.
  static Color shadow(double alpha) => (isLightMode ? Colors.white : primary).withValues(alpha: alpha);

  static Color white(double alpha) => Colors.white.withValues(alpha: alpha);
}

abstract final class AppText {
  static const heading = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w800,
    letterSpacing: 2.6,
    height: 1.15,
    color: Colors.white,
  );
  static const title = TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 1.4, color: Colors.white);
  static const label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w400, color: Colors.white);
  static final body = TextStyle(fontSize: 14, height: 1.5, color: AppColors.white(0.84));
  static final caption = TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.white(0.72));
  static const button = TextStyle(
    fontSize: 15.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.3,
    color: AppColors.primary,
  );
}

ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.dark,
      primary: Colors.white,
      onPrimary: AppColors.primary,
      surface: AppColors.primary,
    ),
    scaffoldBackgroundColor: Colors.transparent,
    splashFactory: InkRipple.splashFactory,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: Colors.white,
      selectionColor: AppColors.white(0.3),
      selectionHandleColor: Colors.white,
    ),
  );
}
