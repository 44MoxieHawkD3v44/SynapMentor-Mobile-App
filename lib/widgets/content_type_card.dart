import 'dart:math';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/content_service.dart';
import 'glass.dart';

/// A tall glass card for one kind of content: artwork for the kind on top,
/// fading into the glass, then its icon and name. The card in the middle of
/// the carousel is lit.
class ContentTypeCard extends StatelessWidget {
  const ContentTypeCard({super.key, required this.type, required this.icon, required this.focused, this.onTap});

  final ContentType type;
  final IconData icon;
  final bool focused;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: type.plural,
      excludeSemantics: true,
      child: GlassWell(
        radius: 22,
        active: focused,
        floating: true,
        fillTop: focused ? 0.06 : 0,
        fillBottom: focused ? 0.03 : 0,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Column(
                children: [
                  Expanded(
                    flex: 3,
                    child: ShaderMask(
                      // The artwork melts into the glass below it.
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (r) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.white, Colors.white, Colors.transparent],
                        stops: [0, 0.7, 1],
                      ).createShader(r),
                      child: CustomPaint(painter: _ContentArt(type), child: const SizedBox.expand()),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: focused ? 28 : 24, color: Colors.white),
                        const SizedBox(height: 6),
                        Text(
                          type.plural,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: focused ? 16 : 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: 22,
                          height: 3,
                          decoration: BoxDecoration(
                            color: AppColors.white(focused ? 0.85 : 0.5),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Simple artwork for each kind of content, drawn in the app's glow colours.
class _ContentArt extends CustomPainter {
  const _ContentArt(this.type);

  final ContentType type;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final w = size.width;
    final h = size.height;
    // A deep backdrop with a soft light behind the subject.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.glowIndigo.withValues(alpha: 0.35), AppColors.primary.withValues(alpha: 0.2)],
        ).createShader(rect),
    );
    canvas.drawCircle(
      Offset(w / 2, h * 0.5),
      w * 0.55,
      Paint()
        ..shader = RadialGradient(
          colors: [AppColors.glowBlue.withValues(alpha: 0.35), AppColors.glowBlue.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: Offset(w / 2, h * 0.5), radius: w * 0.55)),
    );
    final line = Paint()
      ..color = AppColors.white(0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = AppColors.white(0.85);
    final soft = Paint()..color = AppColors.white(0.25);

    switch (type) {
      case ContentType.reel:
        // A film strip with a play button.
        final strip = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(w / 2, h * 0.52), width: w * 0.5, height: h * 0.7),
          const Radius.circular(8),
        );
        canvas.drawRRect(strip, Paint()..color = AppColors.white(0.12));
        canvas.drawRRect(strip, line..strokeWidth = 1.5);
        for (var i = 0; i < 6; i++) {
          final y = strip.top + 8 + i * (strip.height - 16) / 5;
          canvas
            ..drawRect(Rect.fromLTWH(strip.left + 4, y - 2, 4, 4), soft)
            ..drawRect(Rect.fromLTWH(strip.right - 8, y - 2, 4, 4), soft);
        }
        _play(canvas, Offset(w / 2, h * 0.52), w * 0.11, fill);
      case ContentType.blog:
        // A page with a picture and lines of text.
        final page = RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.14, h * 0.16, w * 0.72, h * 0.78),
          const Radius.circular(8),
        );
        canvas.drawRRect(page, Paint()..color = AppColors.white(0.18));
        for (var i = 0; i < 3; i++) {
          canvas.drawCircle(Offset(page.left + 9 + i * 7, page.top + 8), 2, soft);
        }
        final pic = Rect.fromLTWH(page.left + 10, page.top + 18, page.width - 20, page.height * 0.32);
        canvas.drawRRect(RRect.fromRectAndRadius(pic, const Radius.circular(4)), Paint()..color = AppColors.white(0.3));
        canvas.drawPath(
          Path()
            ..moveTo(pic.left + pic.width * 0.2, pic.bottom - 4)
            ..lineTo(pic.left + pic.width * 0.45, pic.top + pic.height * 0.3)
            ..lineTo(pic.left + pic.width * 0.7, pic.bottom - 4)
            ..close(),
          fill,
        );
        for (var i = 0; i < 4; i++) {
          final y = pic.bottom + 10 + i * 9.0;
          if (y > page.bottom - 6) break;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(page.left + 10, y, (page.width - 20) * (i.isEven ? 1 : 0.7), 3),
              const Radius.circular(2),
            ),
            soft,
          );
        }
      case ContentType.video:
        // A glowing ring around a play button.
        final c = Offset(w / 2, h * 0.52);
        canvas.drawCircle(
          c,
          w * 0.3,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 6
            ..color = AppColors.glowCyan.withValues(alpha: 0.35)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );
        canvas.drawCircle(c, w * 0.3, line..strokeWidth = 2);
        _play(canvas, c, w * 0.12, fill);
      case ContentType.image:
        // Mountains under a night sky, reflected below.
        for (var i = 0; i < 14; i++) {
          final r = Random(i);
          canvas.drawCircle(Offset(r.nextDouble() * w, r.nextDouble() * h * 0.35), 0.9, soft);
        }
        final peak = Path()
          ..moveTo(0, h * 0.72)
          ..lineTo(w * 0.32, h * 0.36)
          ..lineTo(w * 0.48, h * 0.52)
          ..lineTo(w * 0.66, h * 0.28)
          ..lineTo(w, h * 0.72)
          ..close();
        canvas.drawPath(peak, Paint()..color = AppColors.white(0.3));
        final snow = Path()
          ..moveTo(w * 0.57, h * 0.38)
          ..lineTo(w * 0.66, h * 0.28)
          ..lineTo(w * 0.75, h * 0.4)
          ..lineTo(w * 0.68, h * 0.37)
          ..close();
        canvas.drawPath(snow, fill);
        canvas.drawRect(
          Rect.fromLTWH(0, h * 0.72, w, h * 0.28),
          Paint()..color = AppColors.glowViolet.withValues(alpha: 0.2),
        );
      case ContentType.repo:
        // Lines of code.
        final rand = Random(7);
        for (var i = 0; i < 11; i++) {
          final y = h * 0.14 + i * h * 0.07;
          var x = w * 0.14 + (i % 3 == 1 ? 10 : 0);
          for (var k = 0; k < 3; k++) {
            final len = w * (0.08 + rand.nextDouble() * 0.2);
            if (x + len > w * 0.88) break;
            final color = [AppColors.glowCyan, AppColors.white(0.8), AppColors.glowViolet][(i + k) % 3];
            canvas.drawRRect(
              RRect.fromRectAndRadius(Rect.fromLTWH(x, y, len, 3), const Radius.circular(2)),
              Paint()..color = color.withValues(alpha: 0.75),
            );
            x += len + 6;
          }
        }
      case ContentType.podcast:
        // A microphone with sound waves.
        final c = Offset(w / 2, h * 0.46);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: c, width: w * 0.2, height: h * 0.3),
            Radius.circular(w * 0.1),
          ),
          fill,
        );
        canvas.drawArc(
          Rect.fromCenter(center: c.translate(0, h * 0.04), width: w * 0.34, height: h * 0.34),
          0.2,
          pi - 0.4,
          false,
          line,
        );
        canvas.drawLine(c.translate(0, h * 0.21), c.translate(0, h * 0.3), line);
        for (var i = 1; i <= 2; i++) {
          final r = w * (0.24 + i * 0.1);
          canvas
            ..drawArc(
              Rect.fromCircle(center: c, radius: r),
              -0.5,
              1.0,
              false,
              soft
                ..strokeWidth = 2
                ..style = PaintingStyle.stroke,
            )
            ..drawArc(Rect.fromCircle(center: c, radius: r), pi - 0.5, 1.0, false, soft);
        }
    }
  }

  void _play(Canvas canvas, Offset c, double r, Paint paint) => canvas.drawPath(
    Path()
      ..moveTo(c.dx - r * 0.6, c.dy - r)
      ..lineTo(c.dx + r, c.dy)
      ..lineTo(c.dx - r * 0.6, c.dy + r)
      ..close(),
    paint,
  );

  @override
  bool shouldRepaint(_ContentArt old) => old.type != type;
}
