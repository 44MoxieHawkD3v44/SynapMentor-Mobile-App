import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// A coupon as a glass ticket: scalloped edges, the code in a dashed box,
/// the bonus minutes beside it, and a torn-off "COUPON" stub.
class CouponTicket extends StatelessWidget {
  const CouponTicket({
    super.key,
    required this.code,
    required this.bonusMinutes,
    required this.appliesTo,
    required this.footer,
    this.onTap,
  });

  final String code;
  final int bonusMinutes;

  /// E.g. "Minute Packs" or "Subscriptions".
  final String appliesTo;

  /// The line under it, e.g. how and until when to use it.
  final String footer;
  final VoidCallback? onTap;

  static const _stub = 54.0;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: 'Coupon $code, $bonusMinutes bonus minutes on $appliesTo. $footer',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, 176);
            final shape = _TicketShape(stubWidth: _stub);
            return SizedBox.fromSize(
              size: size,
              child: Stack(
                children: [
                  // Frosted glass cut to the ticket's outline.
                  Positioned.fill(
                    child: ClipPath(
                      clipper: shape,
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                AppColors.glowIndigo.withValues(alpha: 0.16),
                                AppColors.primary.withValues(alpha: 0.55),
                                AppColors.glowBlue.withValues(alpha: 0.14),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // The stub, a shade lighter.
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: _stub,
                    child: ClipPath(
                      clipper: _StubClip(shape, size),
                      child: ColoredBox(color: AppColors.white(0.08)),
                    ),
                  ),
                  Positioned.fill(
                    child: CustomPaint(painter: _TicketOutline(shape, stubWidth: _stub)),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: _stub,
                    child: Center(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Text(
                          'COUPON',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2,
                            color: AppColors.white(0.45),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 14, _stub + 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.glowBlue.withValues(alpha: 0.28),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.card_giftcard_rounded, size: 14, color: Colors.white),
                              SizedBox(width: 5),
                              Text('Bonus', style: TextStyle(fontSize: 12, color: Colors.white)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: CustomPaint(
                                painter: _DashedBox(AppColors.white(0.4)),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: _Gradient(
                                      Text(
                                        code,
                                        style: const TextStyle(
                                          fontSize: 30,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 1,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Container(
                              width: 1,
                              height: 40,
                              margin: const EdgeInsets.symmetric(horizontal: 10),
                              color: AppColors.white(0.2),
                            ),
                            Expanded(
                              flex: 2,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _Gradient(
                                      Text(
                                        '+$bonusMinutes',
                                        style: const TextStyle(
                                          fontSize: 30,
                                          fontWeight: FontWeight.w900,
                                          height: 1,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    const Text(
                                      'bonus minutes',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.layers_outlined, size: 15, color: AppColors.white(0.7)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  text: 'Applies to: ',
                                  children: [
                                    TextSpan(
                                      text: appliesTo,
                                      style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
                                    ),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption.copyWith(fontSize: 12.5),
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Text.rich(
                          TextSpan(
                            text: code,
                            style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
                            children: [TextSpan(text: '  ·  $footer', style: AppText.caption.copyWith(fontSize: 11))],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// White fading to a soft blue, like light on glass.
class _Gradient extends StatelessWidget {
  const _Gradient(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: (rect) => const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.white, Color(0xFFB9C6FF)],
    ).createShader(rect),
    child: child,
  );
}

/// The ticket outline: rounded corners, small bites down both short edges and
/// a notch top and bottom where the stub tears off.
class _TicketShape extends CustomClipper<Path> {
  _TicketShape({required this.stubWidth});

  final double stubWidth;

  Path outline(Size size) {
    const radius = 20.0;
    const bite = 6.0;
    const notch = 11.0;
    var path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(radius)));
    final cuts = Path();
    for (var y = 32.0; y < size.height - 28; y += 22) {
      cuts
        ..addOval(Rect.fromCircle(center: Offset(0, y), radius: bite))
        ..addOval(Rect.fromCircle(center: Offset(size.width, y), radius: bite));
    }
    final tear = size.width - stubWidth;
    cuts
      ..addOval(Rect.fromCircle(center: Offset(tear, 0), radius: notch))
      ..addOval(Rect.fromCircle(center: Offset(tear, size.height), radius: notch));
    path = Path.combine(PathOperation.difference, path, cuts);
    return path;
  }

  @override
  Path getClip(Size size) => outline(size);

  @override
  bool shouldReclip(_TicketShape old) => old.stubWidth != stubWidth;
}

/// The stub's part of the ticket outline, in the stub's own coordinates.
class _StubClip extends CustomClipper<Path> {
  _StubClip(this.shape, this.ticket);

  final _TicketShape shape;
  final Size ticket;

  @override
  Path getClip(Size size) => shape.outline(ticket).shift(Offset(size.width - ticket.width, 0));

  @override
  bool shouldReclip(_StubClip old) => old.ticket != ticket;
}

class _TicketOutline extends CustomPainter {
  _TicketOutline(this.shape, {required this.stubWidth});

  final _TicketShape shape;
  final double stubWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final path = shape.outline(size);
    // A soft glow, then the rim.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = AppColors.glowBlue.withValues(alpha: 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(colors: [AppColors.white(0.3), AppColors.glowBlue.withValues(alpha: 0.6)])
            .createShader(Offset.zero & size),
    );
    // The perforation where the stub tears off.
    final x = size.width - stubWidth;
    final dash = Paint()
      ..color = AppColors.white(0.35)
      ..strokeWidth = 1;
    for (var y = 14.0; y < size.height - 14; y += 8) {
      canvas.drawLine(Offset(x, y), Offset(x, y + 4), dash);
    }
  }

  @override
  bool shouldRepaint(_TicketOutline old) => old.stubWidth != stubWidth;
}

/// A rounded rectangle drawn in dashes.
class _DashedBox extends CustomPainter {
  const _DashedBox(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 9) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox old) => old.color != color;
}
