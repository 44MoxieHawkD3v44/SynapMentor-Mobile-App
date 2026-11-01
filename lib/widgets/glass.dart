import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/theme.dart';

// A single light source sits at the upper left. Every glass surface takes its
// fill gradient, rim brightness and shadow direction from it.
const _lightFrom = Alignment.topLeft;
const _lightTo = Alignment.bottomRight;

Color _dark(double alpha) => AppColors.primary.withValues(alpha: alpha);

/// Dark clear glass: a light blur and a slight dimming push whatever is behind
/// the pane one layer back, while its colors and shapes stay recognizable.
/// [dim] scales brightness (1 = unchanged); saturation is barely lifted so the
/// original colors survive the dimming. [contrast] below 1 compresses tones
/// toward a dark pivot, so bright text behind the glass recedes without the
/// darks lifting into a milky grey.
ui.ImageFilter clearGlassFilter({double blur = 4, double dim = 0.86, double contrast = 1, double saturation = 1.05}) {
  const r = 0.2126, g = 0.7152, b = 0.0722;
  const pivot = 24.0; // on the 0–255 scale
  final s = saturation;
  final ir = (1 - s) * r, ig = (1 - s) * g, ib = (1 - s) * b;
  final k = dim * contrast;
  final offset = dim * (1 - contrast) * pivot;
  return ui.ImageFilter.compose(
    outer: ui.ColorFilter.matrix(<double>[
      (ir + s) * k, ig * k, ib * k, 0, offset, //
      ir * k, (ig + s) * k, ib * k, 0, offset, //
      ir * k, ig * k, (ib + s) * k, 0, offset, //
      0, 0, 0, 1, 0,
    ]),
    inner: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.mirror),
  );
}

/// A floating sheet of dark, clear glass.
///
/// Don't wrap this in an [Opacity] or fade transition: the backdrop filter
/// would only see the (empty) opacity layer and the glass would pop in at the
/// end. Animate glass with translation instead.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 32,
    this.padding = const EdgeInsets.all(24),
    this.blur = 4,
    this.dim = 0.86,
    this.contrast = 1,
    this.tintTop = 0.12,
    this.tintBottom = 0.18,
    this.rimTop = 0.38,
    this.rimBottom = 0.07,
    this.floating = true,
    this.squareBottom = false,
    this.squareLeft = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double blur;

  /// Brightness and contrast of what shows through (1 = unchanged). Lower them
  /// to push the background further behind the glass.
  final double dim;
  final double contrast;

  /// Dark tint (black opacity) at the lit upper-left and the far lower-right.
  final double tintTop;
  final double tintBottom;
  final double rimTop;
  final double rimBottom;
  final bool floating;

  /// Square bottom corners, for a panel docked to the bottom screen edge.
  final bool squareBottom;

  /// Square left corners, for a panel docked to the left screen edge.
  final bool squareLeft;

  @override
  Widget build(BuildContext context) {
    Widget panel = ClipRRect(
      borderRadius: squareLeft
          ? BorderRadius.horizontal(right: Radius.circular(radius))
          : squareBottom
          ? BorderRadius.vertical(top: Radius.circular(radius))
          : BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: clearGlassFilter(blur: blur, dim: dim, contrast: contrast),
        child: CustomPaint(
          foregroundPainter: GlassRimPainter(
            radius: radius,
            top: rimTop,
            bottom: rimBottom,
            squareBottom: squareBottom,
            squareLeft: squareLeft,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: _lightFrom, end: _lightTo, colors: [_dark(tintTop), _dark(tintBottom)]),
            ),
            child: DecoratedBox(
              // Restrained surface reflection: a sheen at the lit corner and
              // one faint diagonal band.
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: _lightFrom,
                  end: _lightTo,
                  colors: [
                    AppColors.white(0.05),
                    AppColors.white(0),
                    AppColors.white(0.03),
                    AppColors.white(0),
                    AppColors.white(0),
                  ],
                  stops: const [0, 0.3, 0.38, 0.48, 1],
                ),
              ),
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
    if (floating) {
      panel = CustomPaint(
        painter: _FloatShadowPainter(radius: radius, squareBottom: squareBottom, squareLeft: squareLeft),
        child: panel,
      );
    }
    return panel;
  }
}

/// The 1px light-catching rim plus the faint inner highlight along the top
/// edge that gives the glass its thickness. [radius] null means a full pill.
class GlassRimPainter extends CustomPainter {
  const GlassRimPainter({
    this.radius,
    this.top = 0.38,
    this.bottom = 0.07,
    this.highlight = 0.28,
    this.color = Colors.white,
    this.squareBottom = false,
    this.squareLeft = false,
  });

  final double? radius;
  final bool squareBottom;
  final bool squareLeft;
  final double top;
  final double bottom;
  final double highlight;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final r = math.min(radius ?? size.height / 2, size.shortestSide / 2);

    canvas.drawRRect(
      _rrect(bounds.deflate(0.5), math.max(0, r - 0.5), squareBottom, squareLeft: squareLeft),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: _lightFrom,
          end: _lightTo,
          colors: [
            color.withValues(alpha: top),
            color.withValues(alpha: (top + bottom) / 2.4),
            color.withValues(alpha: bottom),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(bounds),
    );

    if (highlight > 0 && size.width > r * 2) {
      const y = 1.5;
      final inset = r * 0.7;
      final line = Rect.fromLTWH(inset, y, size.width - inset * 2, 1);
      canvas.drawLine(
        Offset(line.left, y),
        Offset(line.right, y),
        Paint()
          ..strokeWidth = 1
          ..shader = LinearGradient(
            colors: [
              AppColors.white(0),
              AppColors.white(highlight),
              AppColors.white(highlight * 0.35),
              AppColors.white(0),
            ],
            stops: const [0, 0.18, 0.8, 1],
          ).createShader(line),
      );
    }

    // The left interior edge catches a little light too, fading downward.
    final leftEdge = Rect.fromLTWH(1.5, r * 0.7, 1, size.height * 0.55 - r * 0.7);
    if (highlight > 0 && leftEdge.height > 0) {
      canvas.drawLine(
        leftEdge.topLeft,
        leftEdge.bottomLeft,
        Paint()
          ..strokeWidth = 1
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.white(highlight * 0.6), AppColors.white(0)],
          ).createShader(leftEdge),
      );
    }
  }

  @override
  bool shouldRepaint(GlassRimPainter old) =>
      old.radius != radius ||
      old.top != top ||
      old.bottom != bottom ||
      old.highlight != highlight ||
      old.color != color ||
      old.squareBottom != squareBottom ||
      old.squareLeft != squareLeft;
}

RRect _rrect(Rect rect, double radius, bool squareBottom, {bool squareLeft = false}) {
  final r = Radius.circular(radius);
  if (squareLeft) return RRect.fromRectAndCorners(rect, topRight: r, bottomRight: r);
  return squareBottom ? RRect.fromRectAndCorners(rect, topLeft: r, topRight: r) : RRect.fromRectAndRadius(rect, r);
}

/// Wide, soft, low-contrast shadow falling down and slightly right. It's clipped to outside
/// the panel so it never darkens the glass itself.
class _FloatShadowPainter extends CustomPainter {
  const _FloatShadowPainter({required this.radius, this.squareBottom = false, this.squareLeft = false});

  final double radius;
  final bool squareBottom;
  final bool squareLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final body = _rrect(Offset.zero & size, radius, squareBottom, squareLeft: squareLeft);
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect((Offset.zero & size).inflate(160))
        ..addRRect(body),
    );
    canvas.drawRRect(
      body.shift(const Offset(6, 18)),
      Paint()
        ..color = AppColors.shadow(0.16)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, Shadow.convertRadiusToSigma(38)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FloatShadowPainter old) =>
      old.radius != radius || old.squareBottom != squareBottom || old.squareLeft != squareLeft;
}

/// A dark clear-glass capsule sitting on a panel, one layer above it. Used for
/// inputs, OTP cells, cards and selectable tiles.
class GlassWell extends StatelessWidget {
  const GlassWell({
    super.key,
    required this.child,
    this.radius,
    this.height,
    this.padding,
    this.active = false,
    this.error = false,
    this.fillTop = 0,
    this.fillBottom = 0,
    this.floating = false,
  });

  final Widget child;

  /// Null makes a full pill.
  final double? radius;

  /// Adds the soft outside-only shadow of floating panels, for a little depth.
  final bool floating;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final bool active;
  final bool error;

  /// Optional white lift over the dark tint, for selected/emphasised states.
  final double fillTop;
  final double fillBottom;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius ?? 999);
    final well = CustomPaint(
      foregroundPainter: GlassRimPainter(
        radius: radius,
        top: active ? 0.55 : 0.30,
        bottom: active ? 0.28 : 0.14,
        highlight: 0.26,
        color: error ? AppColors.error : Colors.white,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: clearGlassFilter(blur: 3, dim: 0.92),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: _lightFrom, end: _lightTo, colors: [_dark(0.15), _dark(0.22)]),
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: height,
              padding: padding,
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                gradient: LinearGradient(
                  begin: _lightFrom,
                  end: _lightTo,
                  colors: [AppColors.white(fillTop), AppColors.white(fillBottom)],
                ),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
    return floating
        ? CustomPaint(
            painter: _FloatShadowPainter(radius: radius ?? 999),
            child: well,
          )
        : well;
  }
}
