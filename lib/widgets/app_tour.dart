import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme.dart';
import 'auth_scaffold.dart';
import 'glass.dart';
import 'glass_controls.dart';

/// One stop on the tour: what to highlight and what to say about it. A step
/// without a target is a card in the middle of the screen.
class TourStep {
  const TourStep({required this.title, required this.body, required this.icon, this.target});

  final String title;
  final String body;
  final IconData icon;

  /// The highlighted area, in global coordinates; null when it isn't on
  /// screen (that step is skipped) or for a centered card.
  final Rect? Function()? target;
}

/// Whether the tour has been seen, per account, and a way to see it again.
abstract final class AppTourMemory {
  static String _key(String account) => 'app_tour_done:$account';

  static Future<bool> seen(String account) async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_key(account)) ?? false;
    } catch (_) {
      return true; // without storage, don't show it on every launch
    }
  }

  static Future<void> markSeen(String account) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_key(account), true);
    } catch (_) {
      // Shown again next time.
    }
  }

  /// Bumped from Settings to replay the tour on the home screen.
  static final replay = ValueNotifier<int>(0);
}

/// The interactive tour: dims the app, spotlights each step's target and
/// explains it in a glass card with Back, Next and an always-visible Skip
/// Tour.
class AppTour extends StatefulWidget {
  const AppTour({super.key, required this.steps, required this.onDone});

  final List<TourStep> steps;
  final VoidCallback onDone;

  @override
  State<AppTour> createState() => _AppTourState();
}

class _AppTourState extends State<AppTour> {
  int _index = 0;

  /// Steps whose target is on screen (or that have none).
  late final List<TourStep> _steps = [
    for (final s in widget.steps)
      if (s.target == null || s.target!() != null) s,
  ];

  TourStep get _step => _steps[_index];
  bool get _last => _index == _steps.length - 1;

  void _next() => _last ? widget.onDone() : setState(() => _index++);
  void _back() => setState(() => _index--);

  @override
  Widget build(BuildContext context) {
    if (_steps.isEmpty) return const SizedBox.shrink();
    final box = context.findRenderObject() as RenderBox?;
    final global = _step.target?.call();
    // From screen coordinates into this overlay's.
    final hole = global == null || box == null || !box.hasSize
        ? null
        : Rect.fromPoints(box.globalToLocal(global.topLeft), box.globalToLocal(global.bottomRight)).inflate(6);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final below = hole != null && hole.center.dy < size.height / 2;
        return Stack(
          children: [
            // The dimmed app with a spotlight; taps on it do nothing.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: TweenAnimationBuilder<Rect?>(
                  tween: RectTween(end: hole ?? Rect.fromCenter(center: size.center(Offset.zero), width: 0, height: 0)),
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  builder: (context, rect, _) => CustomPaint(painter: _SpotlightPainter(rect)),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              left: 16,
              right: 16,
              top: hole == null ? null : (below ? hole.bottom + 16 : null),
              bottom: hole == null ? null : (below ? null : size.height - hole.top + 16),
              child: hole == null
                  ? SizedBox(
                      height: size.height,
                      child: Center(child: _card()),
                    )
                  : Align(alignment: Alignment.topCenter, child: _card()),
            ),
          ],
        );
      },
    );
  }

  Widget _card() {
    final step = _step;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: GlassPanel(
        radius: 26,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                GlassIconBadge(icon: step.icon, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    step.title,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
                Text('${_index + 1}/${_steps.length}', style: AppText.caption),
              ],
            ),
            gap14,
            Text(step.body, style: AppText.body),
            gap14,
            Row(
              children: [
                SmallPillButton(label: 'Skip Tour', onPressed: widget.onDone),
                const Spacer(),
                if (_index > 0) ...[SmallPillButton(label: 'Back', onPressed: _back), const SizedBox(width: 8)],
                SmallPillButton(label: _last ? 'Finish' : 'Next', primary: true, onPressed: _next),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Dims everything except a rounded hole around the target, ringed in white.
class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter(this.hole);

  final Rect? hole;

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Path()..addRect(Offset.zero & size);
    final rect = hole;
    if (rect == null || rect.isEmpty) {
      canvas.drawPath(screen, Paint()..color = AppColors.primary.withValues(alpha: 0.72));
      return;
    }
    final spot = RRect.fromRectAndRadius(
      rect,
      Radius.circular(rect.shortestSide / 2 > 24 ? 24 : rect.shortestSide / 2),
    );
    canvas.drawPath(
      Path.combine(PathOperation.difference, screen, Path()..addRRect(spot)),
      Paint()..color = AppColors.primary.withValues(alpha: 0.72),
    );
    canvas.drawRRect(
      spot,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => old.hole != hole;
}

/// The global rect of the widget a key is on, if it's on screen.
Rect? rectOf(GlobalKey key) {
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize || !box.attached) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
