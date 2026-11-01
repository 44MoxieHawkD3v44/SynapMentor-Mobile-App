import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'glass.dart';

class LiquidNavItem {
  const LiquidNavItem(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Floating liquid-glass capsule. A single shared glass bubble marks the
/// emphasised item: the hovered/pressed one, else the keyboard-focused one,
/// else the active page. It glides between items without touching layout.
class LiquidNavBar extends StatefulWidget {
  const LiquidNavBar({super.key, required this.items, required this.currentIndex, required this.onSelected});

  final List<LiquidNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onSelected;

  /// Space content should leave below itself so the bar never covers it.
  static const double clearance = 104;

  @override
  State<LiquidNavBar> createState() => _LiquidNavBarState();
}

class _LiquidNavBarState extends State<LiquidNavBar> {
  static const _liquid = Cubic(0.22, 1, 0.36, 1);

  int? _hovered; // pointer hover, or a touch that is still down
  int? _focused; // keyboard focus highlight

  int get _target => _hovered ?? _focused ?? widget.currentIndex;

  void _setHover(int index, bool on) {
    if (on) {
      setState(() => _hovered = index);
    } else if (_hovered == index) {
      setState(() => _hovered = null);
    }
  }

  void _setFocus(int index, bool on) {
    if (on) {
      setState(() => _focused = index);
    } else if (_focused == index) {
      setState(() => _focused = null);
    }
  }

  void _select(int index) {
    setState(() => _hovered = null);
    widget.onSelected(index);
  }

  double _opacityFor(int index) {
    if (index == _target || index == widget.currentIndex) return 1;
    return _hovered != null ? 0.78 : 0.88;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compact = screenWidth < 420;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final barWidth = math.min(screenWidth - (compact ? 24 : 48), 560.0);
    final barHeight = compact ? 66.0 : 74.0;
    const inset = 6.0;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Main navigation',
      child: SizedBox(
        width: barWidth,
        height: barHeight,
        child: _Capsule(
          child: Padding(
            padding: const EdgeInsets.all(inset),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final itemWidth = constraints.maxWidth / widget.items.length;
                final target = _target;
                final bubble = _Bubble(
                  // Resting on the active page alone, the lens is quieter.
                  restrained: _hovered == null && _focused == null,
                  focusRing: _focused != null && _hovered == null && _focused == target,
                );
                final dx = itemWidth * target;

                final Widget slider = reduceMotion
                    ? AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: Transform.translate(key: ValueKey(target), offset: Offset(dx, 0), child: bubble),
                      )
                    : TweenAnimationBuilder<double>(
                        tween: Tween(end: dx),
                        duration: const Duration(milliseconds: 320),
                        curve: _liquid,
                        builder: (context, x, child) => Transform.translate(offset: Offset(x, 0), child: child),
                        child: bubble,
                      );

                return Stack(
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      width: itemWidth,
                      height: constraints.maxHeight,
                      child: IgnorePointer(child: slider),
                    ),
                    Row(
                      children: [
                        for (var i = 0; i < widget.items.length; i++)
                          SizedBox(
                            width: itemWidth,
                            child: _NavButton(
                              item: widget.items[i],
                              selected: i == widget.currentIndex,
                              opacity: _opacityFor(i),
                              compact: compact,
                              onHover: (on) => _setHover(i, on),
                              onFocus: (on) => _setFocus(i, on),
                              onPressStart: () => setState(() => _hovered = i),
                              onPressCancel: () => _setHover(i, false),
                              onTap: () => _select(i),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The main capsule: transparent body, strong blur, fine edge, faint inner
/// reflection on top and a restrained shadow underneath.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _PillShadowPainter(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: clearGlassFilter(),
          child: CustomPaint(
            foregroundPainter: const _LiquidEdgePainter(border: 0.24, topInner: 0.22, bottomInner: 0.08),
            child: ColoredBox(color: AppColors.primary.withValues(alpha: 0.14), child: child),
          ),
        ),
      ),
    );
  }
}

/// The small liquid lens around one item.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.restrained, required this.focusRing});

  final bool restrained;
  final bool focusRing;

  @override
  Widget build(BuildContext context) {
    const duration = Duration(milliseconds: 220);
    final fill = restrained ? 0.06 : 0.09;
    return AnimatedContainer(
      duration: duration,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(color: AppColors.white(restrained ? 0.05 : 0.08), blurRadius: 16, offset: const Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: clearGlassFilter(blur: 3, dim: 1),
          child: CustomPaint(
            foregroundPainter: _LiquidEdgePainter(
              border: focusRing ? 0.7 : (restrained ? 0.2 : 0.24),
              borderWidth: focusRing ? 1.5 : 1,
              topInner: restrained ? 0.22 : 0.28,
              bottomInner: 0,
            ),
            child: AnimatedContainer(
              duration: duration,
              decoration: BoxDecoration(
                // Flat translucent body with a faint glow pooling at the
                // bottom, like light gathering in a lens.
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [AppColors.white(fill), AppColors.white(fill), AppColors.white(fill + 0.05)],
                  stops: const [0, 0.62, 1],
                ),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.opacity,
    required this.compact,
    required this.onHover,
    required this.onFocus,
    required this.onPressStart,
    required this.onPressCancel,
    required this.onTap,
  });

  final LiquidNavItem item;
  final bool selected;
  final double opacity;
  final bool compact;
  final ValueChanged<bool> onHover;
  final ValueChanged<bool> onFocus;
  final VoidCallback onPressStart;
  final VoidCallback onPressCancel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: onHover,
      onShowFocusHighlight: onFocus,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        selected: selected,
        label: item.label,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => onPressStart(),
          onTapCancel: onPressCancel,
          onTap: onTap,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: opacity,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(item.icon, size: compact ? 22 : 24, color: Colors.white),
                SizedBox(height: compact ? 3 : 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    item.label,
                    maxLines: 1,
                    style: TextStyle(fontSize: compact ? 11 : 12.5, fontWeight: FontWeight.w500, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Even 1px rim plus faint inner lines along the top (reflection) and bottom
/// (lower inner shadow) of a pill.
class _LiquidEdgePainter extends CustomPainter {
  const _LiquidEdgePainter({
    required this.border,
    required this.topInner,
    required this.bottomInner,
    this.borderWidth = 1,
  });

  final double border;
  final double borderWidth;
  final double topInner;
  final double bottomInner;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.height / 2;
    final inset = borderWidth / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius((Offset.zero & size).deflate(inset), Radius.circular(r - inset)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderWidth
        ..color = AppColors.white(border),
    );

    void innerLine(double y, double alpha) {
      if (alpha <= 0 || size.width <= r * 1.4) return;
      final line = Rect.fromLTWH(r * 0.7, y, size.width - r * 1.4, 1);
      canvas.drawLine(
        Offset(line.left, y),
        Offset(line.right, y),
        Paint()
          ..strokeWidth = 1
          ..shader = LinearGradient(
            colors: [AppColors.white(0), AppColors.white(alpha), AppColors.white(alpha), AppColors.white(0)],
            stops: const [0, 0.2, 0.8, 1],
          ).createShader(line),
      );
    }

    innerLine(1.5, topInner);
    innerLine(size.height - 1.5, bottomInner);
  }

  @override
  bool shouldRepaint(_LiquidEdgePainter old) =>
      old.border != border ||
      old.borderWidth != borderWidth ||
      old.topInner != topInner ||
      old.bottomInner != bottomInner;
}

/// Soft shadow drawn only outside the capsule so the glass stays clear.
class _PillShadowPainter extends CustomPainter {
  const _PillShadowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.height / 2));
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect((Offset.zero & size).inflate(80))
        ..addRRect(body),
    );
    canvas.drawRRect(
      body.shift(const Offset(0, 12)),
      Paint()
        ..color = AppColors.shadow(0.12)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, Shadow.convertRadiusToSigma(35)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PillShadowPainter old) => false;
}
