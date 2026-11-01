import 'dart:math';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'glass.dart';

/// What the face check is asking for right now.
enum GuideAction { center, turnLeft, turnRight, blink, nod, smile, readNumber }

/// The round camera view of the live face check with guides drawn on it: a
/// segmented glowing rim that fills as actions are done, dotted arcs on the
/// side the user should move toward, arrows, and the number to read out.
class LivenessGuide extends StatefulWidget {
  const LivenessGuide({
    super.key,
    required this.size,
    required this.action,
    required this.child,
    required this.completed,
    required this.total,
    this.done = false,
    this.number,
    this.message,
  });

  final double size;
  final GuideAction action;

  /// The camera preview, clipped to the circle.
  final Widget child;

  /// Actions finished so far, of [total].
  final int completed;
  final int total;

  /// The current action was just seen: shows a tick.
  final bool done;

  /// The number to read out, for [GuideAction.readNumber].
  final String? number;

  /// A short note over the view, e.g. "Move your face into the circle".
  final String? message;

  @override
  State<LivenessGuide> createState() => _LivenessGuideState();
}

class _LivenessGuideState extends State<LivenessGuide> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final action = widget.action;
    return SizedBox.square(
      dimension: s,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final t = MediaQuery.disableAnimationsOf(context) ? 0.5 : _pulse.value;
          // Arrows drift a little toward where the user should move.
          final drift = 6 * sin(t * 2 * pi);
          return Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: EdgeInsets.all(s * 0.05),
                child: ClipOval(child: widget.child),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _GuidePainter(
                    action: action,
                    t: t,
                    done: widget.done,
                    progress: widget.total == 0 ? 0 : widget.completed / widget.total,
                  ),
                ),
              ),
              if (!widget.done)
                ...switch (action) {
                  GuideAction.turnLeft => [
                    Positioned(left: s * 0.13 - drift.abs(), child: _glyph(Icons.arrow_back_rounded, s)),
                  ],
                  GuideAction.turnRight => [
                    Positioned(right: s * 0.13 - drift.abs(), child: _glyph(Icons.arrow_forward_rounded, s)),
                  ],
                  GuideAction.nod => [
                    Positioned(top: s * 0.11 - drift.abs(), child: _glyph(Icons.arrow_upward_rounded, s)),
                    Positioned(bottom: s * 0.11 - drift.abs(), child: _glyph(Icons.arrow_downward_rounded, s)),
                  ],
                  GuideAction.blink => [Positioned(top: s * 0.12, child: _glyph(Icons.visibility_off_outlined, s))],
                  GuideAction.smile => [
                    Positioned(bottom: s * 0.12, child: _glyph(Icons.sentiment_satisfied_alt_rounded, s)),
                  ],
                  GuideAction.readNumber => [
                    Positioned(
                      top: s * 0.11,
                      child: _NumberBubble(number: widget.number ?? '', size: s),
                    ),
                    Positioned(
                      bottom: s * 0.12,
                      child: _VoiceWave(t: t, size: s),
                    ),
                  ],
                  GuideAction.center => const <Widget>[],
                },
              if (widget.message != null && !widget.done)
                Positioned(
                  bottom: s * 0.27,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(widget.message!, style: const TextStyle(fontSize: 12, color: Colors.white)),
                  ),
                ),
              AnimatedScale(
                scale: widget.done ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutBack,
                child: SizedBox.square(
                  dimension: s * 0.26,
                  child: const GlassWell(
                    fillTop: 0.18,
                    fillBottom: 0.1,
                    child: Center(child: Icon(Icons.check_rounded, size: 40, color: Colors.white)),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _glyph(IconData icon, double s) => Icon(
    icon,
    size: s * 0.12,
    color: Colors.white,
    shadows: [Shadow(color: AppColors.glowBlue.withValues(alpha: 0.9), blurRadius: 12)],
  );
}

class _NumberBubble extends StatelessWidget {
  const _NumberBubble({required this.number, required this.size});

  final String number;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: size * 0.05, vertical: size * 0.015),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white, width: 1.6),
        boxShadow: [BoxShadow(color: AppColors.glowBlue.withValues(alpha: 0.5), blurRadius: 14)],
      ),
      child: Text(
        number,
        style: TextStyle(
          fontSize: size * 0.1,
          fontWeight: FontWeight.w800,
          letterSpacing: size * 0.02,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Bars that rise and fall, as a cue to speak.
class _VoiceWave extends StatelessWidget {
  const _VoiceWave({required this.t, required this.size});

  final double t;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 7; i++)
          Container(
            width: 4,
            height: size * (0.025 + 0.06 * (0.5 + 0.5 * sin(t * 2 * pi * 2 + i * 0.9)).abs()),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(2),
              boxShadow: [BoxShadow(color: AppColors.glowBlue.withValues(alpha: 0.7), blurRadius: 6)],
            ),
          ),
      ],
    );
  }
}

class _GuidePainter extends CustomPainter {
  const _GuidePainter({required this.action, required this.t, required this.done, required this.progress});

  final GuideAction action;
  final double t;
  final bool done;
  final double progress;

  static const _gap = 0.09; // radians each side of the four rim gaps

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 5;
    final rect = Rect.fromCircle(center: c, radius: r);

    // The rim: four arcs with small gaps at the top, right, bottom and left.
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..color = AppColors.glowBlue.withValues(alpha: done ? 0.7 : 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..color = AppColors.white(done ? 1 : 0.85);
    for (var q = 0; q < 4; q++) {
      final start = q * pi / 2 + _gap;
      const sweep = pi / 2 - 2 * _gap;
      canvas
        ..drawArc(rect, start, sweep, false, glow)
        ..drawArc(rect, start, sweep, false, rim);
    }

    // Progress through the actions, just inside the rim.
    if (progress > 0) {
      canvas.drawArc(
        rect.deflate(7),
        -pi / 2,
        2 * pi * progress.clamp(0, 1),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = Colors.white,
      );
    }
    if (done) return;

    // Dotted arcs toward where the user should move.
    void dots(double from, double to) {
      const rows = 3;
      for (var row = 0; row < rows; row++) {
        final radius = r - 16 - row * 9;
        final step = 0.15 + row * 0.02;
        var i = 0;
        for (var a = from; a <= to; a += step, i++) {
          final wave = 0.5 + 0.5 * sin(2 * pi * t - i * 0.55 - row * 0.8);
          canvas.drawCircle(
            c + Offset(cos(a), sin(a)) * radius,
            1.9 - row * 0.3,
            Paint()..color = AppColors.white(0.2 + 0.8 * wave),
          );
        }
      }
    }

    switch (action) {
      case GuideAction.turnLeft:
        dots(pi * 0.62, pi * 1.38);
      case GuideAction.turnRight:
        dots(-pi * 0.38, pi * 0.38);
      case GuideAction.nod:
        dots(-pi * 0.86, -pi * 0.14);
        dots(pi * 0.14, pi * 0.86);
      case GuideAction.blink || GuideAction.smile || GuideAction.readNumber:
        dots(pi * 0.62, pi * 1.38);
        dots(-pi * 0.38, pi * 0.38);
      case GuideAction.center:
        // Corner brackets around where the face should be.
        final half = r * 0.5;
        final len = r * 0.16;
        final bracket = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round
          ..color = AppColors.white(0.55 + 0.45 * (0.5 + 0.5 * sin(2 * pi * t)));
        for (final (sx, sy) in const [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)]) {
          final corner = c + Offset(sx * half, sy * half);
          canvas
            ..drawLine(corner, corner + Offset(-sx * len, 0), bracket)
            ..drawLine(corner, corner + Offset(0, -sy * len), bracket);
        }
    }
  }

  @override
  bool shouldRepaint(_GuidePainter old) =>
      old.t != t || old.action != action || old.done != done || old.progress != progress;
}
