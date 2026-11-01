import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'glass.dart';

/// The clap shown for appreciations. Faded until [active].
class ClapIcon extends StatelessWidget {
  const ClapIcon({super.key, this.size = 22, this.active = true});

  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: active ? 1 : 0.6,
          child: Text(
            '👏',
            textScaler: TextScaler.noScaling,
            style: TextStyle(fontSize: size * 0.85, height: 1, decoration: TextDecoration.none),
          ),
        ),
      ),
    );
  }
}

/// The round glass button with a clap, like [GlassIconButton].
class ClapButton extends StatelessWidget {
  const ClapButton({super.key, required this.active, required this.onPressed, this.tooltip});

  final bool active;

  /// Called with the button's context, for [showClapBurst].
  final ValueChanged<BuildContext> onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: SizedBox.square(
        dimension: 44,
        child: GlassPanel(
          radius: 22,
          padding: EdgeInsets.zero,
          floating: false,
          child: Material(
            type: MaterialType.transparency,
            child: Builder(
              builder: (context) => InkWell(
                customBorder: const CircleBorder(),
                onTap: () => onPressed(context),
                child: Center(child: ClapIcon(active: active)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Claps float up from the widget at [context] for two seconds.
void showClapBurst(BuildContext context) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  final box = context.findRenderObject();
  final overlayBox = overlay?.context.findRenderObject();
  if (overlay == null || box is! RenderBox || !box.hasSize || overlayBox is! RenderBox) return;
  final origin = box.localToGlobal(box.size.center(Offset.zero), ancestor: overlayBox);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _ClapBurst(
      origin: origin,
      onDone: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}

class _Particle {
  _Particle(math.Random random)
    : delay = random.nextDouble() * 0.35,
      drift = (random.nextDouble() - 0.5) * 90,
      rise = 130 + random.nextDouble() * 70,
      size = 18 + random.nextDouble() * 14,
      phase = random.nextDouble() * math.pi * 2;

  /// When it starts, as a fraction of the animation.
  final double delay;
  final double drift;
  final double rise;
  final double size;
  final double phase;
}

class _ClapBurst extends StatefulWidget {
  const _ClapBurst({required this.origin, required this.onDone});

  final Offset origin;
  final VoidCallback onDone;

  @override
  State<_ClapBurst> createState() => _ClapBurstState();
}

class _ClapBurstState extends State<_ClapBurst> with SingleTickerProviderStateMixin {
  static const _count = 8;

  late final _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2));
  final _particles = [for (var i = 0; i < _count; i++) _Particle(math.Random())];

  @override
  void initState() {
    super.initState();
    _controller.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Stack(children: [for (final p in _particles) ?_particle(p, _controller.value)]),
      ),
    );
  }

  Widget? _particle(_Particle p, double value) {
    final t = ((value - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
    if (t <= 0) return null;
    final rise = Curves.easeOut.transform(t) * p.rise;
    final x = p.drift * t + math.sin(t * math.pi * 3 + p.phase) * 8;
    final opacity = t < 0.15 ? t / 0.15 : 1 - ((t - 0.55) / 0.45).clamp(0.0, 1.0);
    final scale = 0.5 + 0.7 * Curves.easeOutBack.transform(math.min(t * 3, 1));
    return Positioned(
      left: widget.origin.dx + x - p.size / 2,
      top: widget.origin.dy - rise - p.size / 2,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: scale,
          child: Text(
            '👏',
            textScaler: TextScaler.noScaling,
            style: TextStyle(fontSize: p.size, height: 1, decoration: TextDecoration.none),
          ),
        ),
      ),
    );
  }
}
