import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// A 3D carousel: the focused card faces the viewer and its neighbours turn
/// away in perspective. Advances every [interval], loops forever, and pauses
/// while the user is touching it. With reduced motion it doesn't auto-advance.
class GlassCoverflow extends StatefulWidget {
  const GlassCoverflow({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.height,
    this.viewportFraction = 0.64,
    this.interval = const Duration(seconds: 2),
    this.flat = false,
  });

  final int itemCount;

  /// [focused] is true for the card currently in the middle.
  final Widget Function(BuildContext context, int index, bool focused) itemBuilder;
  final double height;
  final double viewportFraction;
  final Duration interval;

  /// Slides flat instead of turning the neighbours away in 3D.
  final bool flat;

  @override
  State<GlassCoverflow> createState() => _GlassCoverflowState();
}

class _GlassCoverflowState extends State<GlassCoverflow> {
  // Start far from zero so the carousel can loop in both directions.
  late final int _origin = widget.itemCount * 1000;
  late final PageController _controller = PageController(
    viewportFraction: widget.viewportFraction,
    initialPage: _origin,
  );
  Timer? _timer;
  bool _touching = false;
  int _page = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    if (widget.itemCount < 2 || MediaQuery.disableAnimationsOf(context)) return;
    _timer = Timer.periodic(widget.interval, (_) {
      if (_touching || !_controller.hasClients) return;
      _controller.nextPage(duration: const Duration(milliseconds: 650), curve: Curves.easeInOutCubic);
    });
  }

  double get _currentPage => _controller.hasClients && _controller.position.haveDimensions
      ? _controller.page ?? _origin.toDouble()
      : _origin.toDouble();

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) return const SizedBox.shrink();
    return Column(
      children: [
        SizedBox(
          height: widget.height,
          child: Listener(
            onPointerDown: (_) => _touching = true,
            onPointerUp: (_) => _touching = false,
            onPointerCancel: (_) => _touching = false,
            child: PageView.builder(
              controller: _controller,
              clipBehavior: Clip.none,
              onPageChanged: (p) => setState(() => _page = (p - _origin) % widget.itemCount),
              itemBuilder: (context, i) {
                final index = (i - _origin) % widget.itemCount;
                final card = Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: widget.itemBuilder(context, index, index == _page),
                );
                if (widget.flat) return card;
                return AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    final offset = (_currentPage - i).clamp(-1.0, 1.0);
                    final distance = offset.abs();
                    final transform = Matrix4.identity()
                      ..setEntry(3, 2, 0.0014)
                      ..rotateY(offset * 0.62)
                      ..scaleByDouble(1 - 0.16 * distance, 1 - 0.16 * distance, 1, 1);
                    return Transform(
                      alignment: offset > 0 ? Alignment.centerRight : Alignment.centerLeft,
                      transform: transform,
                      child: child,
                    );
                  },
                  child: card,
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 14),
        Semantics(
          label: 'Card ${_page + 1} of ${widget.itemCount}',
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < widget.itemCount; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 20 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: AppColors.white(i == _page ? 1 : 0.35),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A layered-glass carousel: the active card sits in front, and its
/// neighbours sit behind it, offset left and right, smaller, blurred and
/// dimmed. The front card's own backdrop blur frosts whatever of them shows
/// through it, giving real depth. Swipe or tap a neighbour to bring it
/// forward; advances every [interval] unless touched or reduced motion is on.
class GlassStackCarousel extends StatefulWidget {
  const GlassStackCarousel({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.height,
    this.cardWidthFraction = 0.66,
    this.interval = const Duration(seconds: 2),
  });

  final int itemCount;

  /// [focused] is true for the front card.
  final Widget Function(BuildContext context, int index, bool focused) itemBuilder;
  final double height;

  /// Front card width as a share of the available width.
  final double cardWidthFraction;
  final Duration interval;

  @override
  State<GlassStackCarousel> createState() => _GlassStackCarouselState();
}

class _GlassStackCarouselState extends State<GlassStackCarousel> with SingleTickerProviderStateMixin {
  late final AnimationController _position = AnimationController.unbounded(vsync: this);
  Timer? _timer;
  bool _touching = false;

  int get _page => _position.value.round() % widget.itemCount;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    if (widget.itemCount < 2 || MediaQuery.disableAnimationsOf(context)) return;
    _timer = Timer.periodic(widget.interval, (_) {
      if (!_touching && !_position.isAnimating) _goTo(_position.value.roundToDouble() + 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _position.dispose();
    super.dispose();
  }

  void _goTo(double target) =>
      _position.animateTo(target, duration: const Duration(milliseconds: 600), curve: Curves.easeInOutCubic);

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) return const SizedBox.shrink();
    return Column(
      children: [
        SizedBox(
          height: widget.height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final cardWidth = width * widget.cardWidthFraction;
              final dragScale = width * 0.5;
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) {
                  _touching = true;
                  _position.stop();
                },
                onHorizontalDragUpdate: (d) => _position.value -= d.primaryDelta! / dragScale,
                onHorizontalDragEnd: (d) {
                  _touching = false;
                  final fling = -(d.primaryVelocity ?? 0) / dragScale * 0.2;
                  _goTo((_position.value + fling).roundToDouble());
                },
                child: AnimatedBuilder(
                  animation: _position,
                  builder: (context, _) {
                    final p = _position.value;
                    // Farthest first, so the front card paints last (on top).
                    final slots = [for (var k = p.floor() - 2; k <= p.ceil() + 2; k++) k]
                      ..removeWhere((k) => (k - p).abs() > 2.2)
                      ..sort((a, b) => (b - p).abs().compareTo((a - p).abs()));
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [for (final k in slots) _slot(context, k, k - p, width, cardWidth)],
                    );
                  },
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        // Rebuilt as the carousel moves, so the dot follows the front card.
        AnimatedBuilder(
          animation: _position,
          builder: (context, _) => Semantics(
            label: 'Card ${_page + 1} of ${widget.itemCount}',
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.itemCount; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 20 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: AppColors.white(i == _page ? 1 : 0.35),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _slot(BuildContext context, int k, double d, double width, double cardWidth) {
    final distance = d.abs();
    final index = k % widget.itemCount;
    Widget card = widget.itemBuilder(context, index, distance < 0.5);
    if (distance > 0.02) {
      // Behind the front card: blurred, dimmed and lower in contrast, but
      // still recognizable. Not interactive; a tap brings it forward.
      final sigma = (4.5 * distance).clamp(0.0, 8.0);
      card = GestureDetector(
        onTap: () => _goTo(k.toDouble()),
        child: IgnorePointer(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal),
            child: Opacity(opacity: (1 - 0.6 * distance).clamp(0.12, 1.0), child: card),
          ),
        ),
      );
    }
    final scale = 1 - 0.1 * distance.clamp(0.0, 2.0);
    return Positioned(
      left: (width - cardWidth) / 2 + d * width * 0.27,
      top: 0,
      width: cardWidth,
      height: widget.height,
      child: Transform.scale(scale: scale, child: card),
    );
  }
}
