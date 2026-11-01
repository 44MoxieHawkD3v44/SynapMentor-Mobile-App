import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'glass.dart';

/// The Synap Wallet as a glass bank card: chip, balance, and the holder's
/// name, shared by the seeker and solver Payments screens.
class WalletCard extends StatelessWidget {
  const WalletCard({
    super.key,
    required this.holder,
    required this.balanceLabel,
    required this.balance,
    this.caption,
    this.trailing,
  });

  final String holder;

  /// What the balance is, e.g. "Minutes Balance".
  final String balanceLabel;
  final String balance;

  /// A line under the balance, e.g. its value in rupees.
  final String? caption;

  /// Shown at the lower right, e.g. the rate per minute.
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 26,
      padding: EdgeInsets.zero,
      child: AspectRatio(
        aspectRatio: 1.62,
        child: Stack(
          children: [
            const Positioned.fill(child: CustomPaint(painter: _RingsPainter())),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'SYNAP WALLET',
                        style: AppText.caption.copyWith(
                          letterSpacing: 2.2,
                          fontWeight: FontWeight.w700,
                          color: AppColors.white(0.85),
                        ),
                      ),
                      const Spacer(),
                      Icon(Icons.contactless_outlined, size: 22, color: AppColors.white(0.75)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const _Chip(),
                  const Spacer(),
                  Text(balanceLabel, style: AppText.caption),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      balance,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.15,
                      ),
                    ),
                  ),
                  if (caption != null) Text(caption!, style: AppText.caption.copyWith(fontSize: 11.5)),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text(
                          holder.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.8,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (trailing != null)
                        Text(trailing!, style: AppText.caption.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The card's contact chip, drawn in white lines on glass.
class _Chip extends StatelessWidget {
  const _Chip();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      child: GlassWell(
        radius: 7,
        height: 30,
        padding: EdgeInsets.zero,
        fillTop: 0.1,
        fillBottom: 0.04,
        child: CustomPaint(painter: _ChipLinesPainter(AppColors.white(0.45)), child: const SizedBox.expand()),
      ),
    );
  }
}

class _ChipLinesPainter extends CustomPainter {
  const _ChipLinesPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final w = size.width, h = size.height;
    canvas
      ..drawLine(Offset(0, h / 3), Offset(w, h / 3), paint)
      ..drawLine(Offset(0, h * 2 / 3), Offset(w, h * 2 / 3), paint)
      ..drawLine(Offset(w / 3, 0), Offset(w / 3, h), paint)
      ..drawLine(Offset(w * 2 / 3, 0), Offset(w * 2 / 3, h), paint);
  }

  @override
  bool shouldRepaint(_ChipLinesPainter old) => old.color != color;
}

/// Faint concentric rings in the upper-right corner.
class _RingsPainter extends CustomPainter {
  const _RingsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.92, size.height * 0.1);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(26)));
    for (var i = 1; i <= 4; i++) {
      paint.color = AppColors.white(0.09 - i * 0.015);
      canvas.drawCircle(center, size.height * 0.22 * i, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RingsPainter old) => false;
}
