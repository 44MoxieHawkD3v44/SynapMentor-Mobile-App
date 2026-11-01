import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'true_colors.dart';

/// The animated Synap Mentor logo, played from its rendered frames: the
/// hourglass flips (54 frames at 24 fps) at the start of every 4-second cycle
/// while the ring spins (50 frames at 48 fps), over a soft pulsing glow. It
/// fades and scales in once its frames are ready, and holds still when the
/// system asks for reduced motion. Its first frame shows as soon as it's
/// decoded; the animation starts once the rest are ready.
class AnimatedLogo extends StatefulWidget {
  const AnimatedLogo({super.key, this.size = 150});

  /// Width and height of the square the frames are drawn in.
  final double size;

  /// Starts decoding the frames for a logo [size] wide before it's built
  /// (at launch, for the splash), so it appears without a wait. They're kept
  /// a few seconds for the logo to take over.
  static void preload(double size) {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return;
    final frames = _LogoFrames.acquire(size * view.devicePixelRatio);
    Future<void>.delayed(const Duration(seconds: 10), frames.release);
  }

  @override
  State<AnimatedLogo> createState() => _AnimatedLogoState();
}

class _AnimatedLogoState extends State<AnimatedLogo> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((elapsed) => _clock.value = elapsed);
  final _clock = ValueNotifier(Duration.zero);
  _LogoFrames? _frames;
  bool _ready = false;
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    _frames ??= _LogoFrames.acquire(widget.size * MediaQuery.devicePixelRatioOf(context))
      ..ready.then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _syncTicker();
      });
    if (_ready) _syncTicker();
  }

  void _syncTicker() {
    if (_still) {
      _ticker.stop();
      _clock.value = Duration.zero;
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    _frames?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frames = _frames;
    return SizedBox.square(
      dimension: widget.size,
      child: !_ready || frames == null
          ? null
          : TrueColors(
              child: RepaintBoundary(
                child: CustomPaint(painter: _LogoPainter(frames, _clock, still: _still)),
              ),
            ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.frames, this.clock, {required this.still}) : super(repaint: clock);

  final _LogoFrames frames;
  final ValueNotifier<Duration> clock;
  final bool still;

  static const _intro = Duration(milliseconds: 1200);
  static const _cycle = Duration(seconds: 4);
  static const _flipFps = 24;
  static const _ringFps = 48;

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.value;
    final rect = Offset.zero & size;
    final center = rect.center;

    // Fade and scale in (0.9 → 1) once, like the original.
    final intro = still ? 1.0 : Curves.easeOutCubic.transform((t.inMicroseconds / _intro.inMicroseconds).clamp(0, 1));

    // Ambient glow, pulsing every 4 s (there and back).
    final pulse = still ? 1.0 : Curves.easeInOut.transform(_triangle(t.inMicroseconds / 4e6));
    final glowRadius = size.width * 0.43 * (1 + 0.15 * pulse);
    final glowAlpha = (0.4 + 0.6 * pulse) * intro;
    canvas.drawCircle(
      center,
      glowRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.fromRGBO(0, 180, 200, 0.08 * glowAlpha),
            Color.fromRGBO(0, 120, 160, 0.04 * glowAlpha),
            const Color.fromRGBO(0, 120, 160, 0),
          ],
          stops: const [0, 0.4, 0.7],
        ).createShader(Rect.fromCircle(center: center, radius: glowRadius))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.14),
    );

    // The hourglass flips at the start of every cycle, after the intro, and
    // rests on its first frame in between.
    final animate = !still && frames.complete;
    var flip = 0;
    final sinceIntro = t - _intro;
    if (animate && sinceIntro > Duration.zero) {
      final inCycle = sinceIntro.inMicroseconds % _cycle.inMicroseconds;
      final flipLength = frames.flip.length / _flipFps * 1e6;
      if (inCycle < flipLength) flip = (inCycle / flipLength * (frames.flip.length - 1)).round();
    }
    // The ring loops continuously.
    final ringLength = frames.ring.length / _ringFps * 1e6;
    final ring = !animate ? 0 : ((t.inMicroseconds % ringLength) / ringLength * frames.ring.length).floor();

    canvas.save();
    canvas
      ..translate(center.dx, center.dy)
      ..scale(0.9 + 0.1 * intro)
      ..translate(-center.dx, -center.dy);
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Color.fromRGBO(0, 0, 0, intro);
    _draw(canvas, frames.flip[flip], rect, paint);
    _draw(canvas, frames.ring[ring], rect, paint);
    canvas.restore();
  }

  /// 0 → 1 → 0 over each unit of [x].
  static double _triangle(double x) {
    final f = x % 2;
    return f < 1 ? f : 2 - f;
  }

  static void _draw(Canvas canvas, ui.Image image, Rect dst, Paint paint) =>
      canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), dst, paint);

  @override
  bool shouldRepaint(_LogoPainter old) => old.frames != frames || old.still != still;
}

/// The decoded frames, shared by every logo on screen at the same size and
/// freed when the last one goes away. Frames are decoded at the size they're
/// shown at, not their full 2048 px.
class _LogoFrames {
  _LogoFrames._(this.width);

  static const _flipCount = 54;
  static const _ringCount = 50;
  static final _cache = <int, _LogoFrames>{};

  final int width;
  final flip = <ui.Image>[];
  final ring = <ui.Image>[];
  int _users = 0;

  /// The first frame of each layer is decoded: the logo can show.
  late final Future<void> ready = _loadFirst();

  /// Every frame is decoded: the logo can animate.
  bool complete = false;
  Future<void>? _rest;

  /// [pixels] is the drawn width in physical pixels.
  static _LogoFrames acquire(double pixels) {
    // Sizes are bucketed so logos of similar size share one set of frames.
    final width = ((pixels / 128).ceil() * 128).clamp(256, 768);
    final frames = _cache[width] ??= _LogoFrames._(width);
    frames._users++;
    return frames;
  }

  void release() {
    if (--_users > 0) return;
    _cache.remove(width);
    ready.whenComplete(() => _rest).whenComplete(() {
      for (final image in [...flip, ...ring]) {
        image.dispose();
      }
    });
  }

  Future<ui.Image> _decode(String path) async {
    final data = await rootBundle.load(path);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(), targetWidth: width);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  static String _flipPath(int i) => 'assets/logo/flip/${_name(i)}.webp';
  static String _ringPath(int i) => 'assets/logo/ring/${_name(i)}.webp';
  static String _name(int i) => '${i + 1}'.padLeft(2, '0');

  /// Just the resting frames first, so the logo doesn't wait for all of them.
  Future<void> _loadFirst() async {
    final first = await Future.wait([_decode(_flipPath(0)), _decode(_ringPath(0))]);
    flip.add(first[0]);
    ring.add(first[1]);
    _rest = _loadRest().catchError((Object _) {}); // the logo stays still
  }

  /// The rest a few at a time, so they don't hold up the app's start.
  Future<void> _loadRest() async {
    Future<void> load(List<ui.Image> into, int count, String Function(int) path) async {
      for (var i = 1; i < count; i += 6) {
        into.addAll(await Future.wait([for (var j = i; j < count && j < i + 6; j++) _decode(path(j))]));
      }
    }

    await Future.wait([load(ring, _ringCount, _ringPath), load(flip, _flipCount, _flipPath)]);
    complete = true;
  }
}
