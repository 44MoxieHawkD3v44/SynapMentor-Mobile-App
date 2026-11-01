import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'true_colors.dart';

/// The played part of the progress bar and its handle.
const _accent = Color(0xFFFF0033);

/// Playback speeds offered under settings.
const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

String _speedLabel(double s) => s == 1 ? 'Normal' : '${s.toString().replaceAll(RegExp(r'\.0$'), '')}x';

/// "0:20", or "1:02:05" past an hour.
String _time(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Controls over a playing video: play/pause in the middle, playback speed
/// under settings, the time and full screen at the bottom, and a progress bar
/// to seek along the bottom edge. A tap shows or hides them; they hide by
/// themselves a few seconds into playback.
class VideoControls extends StatefulWidget {
  const VideoControls({
    super.key,
    required this.video,
    required this.onPlayPause,
    this.onFullscreen,
    this.fullscreen = false,
    this.reel = false,
  });

  final VideoPlayerController video;

  /// Plays or pauses; the owner decides whether playing is allowed.
  final VoidCallback onPlayPause;

  /// Enters or leaves full screen; no button without it.
  final VoidCallback? onFullscreen;
  final bool fullscreen;

  /// A full-screen reel: the progress bar and times stay along the bottom,
  /// and settings sit below the reel's own top buttons.
  final bool reel;

  @override
  State<VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<VideoControls> {
  bool _visible = true;
  Timer? _hide;

  /// Where the handle is while it's dragged, as a fraction of the video.
  double? _dragging;

  VideoPlayerController get _video => widget.video;

  @override
  void initState() {
    super.initState();
    _video.addListener(_onVideo);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(VideoControls old) {
    super.didUpdateWidget(old);
    if (old.video != widget.video) {
      old.video.removeListener(_onVideo);
      widget.video.addListener(_onVideo);
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    _video.removeListener(_onVideo);
    super.dispose();
  }

  bool _wasPlaying = false;

  void _onVideo() {
    if (!mounted) return;
    final playing = _video.value.isPlaying;
    if (playing != _wasPlaying) {
      _wasPlaying = playing;
      // Paused videos keep their controls; playing ones hide them again.
      playing ? _scheduleHide() : _show(stay: true);
    }
    setState(() {});
  }

  void _scheduleHide() {
    _hide?.cancel();
    if (!_video.value.isPlaying || _dragging != null) return;
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && _video.value.isPlaying && _dragging == null) setState(() => _visible = false);
    });
  }

  void _show({bool stay = false}) {
    setState(() => _visible = true);
    if (!stay) _scheduleHide();
  }

  void _toggleVisible() {
    if (_visible) {
      _hide?.cancel();
      setState(() => _visible = false);
    } else {
      _show();
    }
  }

  void _playPause() {
    widget.onPlayPause();
    _show();
  }

  Future<void> _chooseSpeed() async {
    _hide?.cancel();
    final current = _video.value.playbackSpeed;
    final picked = await showModalBottomSheet<double>(
      context: context,
      useRootNavigator: true,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text(
                  'Playback speed',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ),
              for (final s in _speeds)
                ListTile(
                  dense: true,
                  leading: SizedBox(
                    width: 24,
                    child: s == current ? const Icon(Icons.check_rounded, color: Colors.white) : null,
                  ),
                  title: Text(_speedLabel(s), style: const TextStyle(fontSize: 15, color: Colors.white)),
                  onTap: () => Navigator.of(context).pop(s),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) await _video.setPlaybackSpeed(picked);
    if (mounted) _show();
  }

  double get _fraction {
    final total = _video.value.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_video.value.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  double get _buffered {
    final total = _video.value.duration.inMilliseconds;
    if (total <= 0) return 0;
    final end = _video.value.buffered.fold(0, (max, r) => r.end.inMilliseconds > max ? r.end.inMilliseconds : max);
    return (end / total).clamp(0.0, 1.0);
  }

  void _seekTo(double fraction) {
    final total = _video.value.duration;
    _video.seekTo(total * fraction.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final value = _video.value;
    final ended = value.duration > Duration.zero && value.position >= value.duration && !value.isPlaying;
    final shown = _visible || !value.isPlaying;
    final position = _dragging == null ? value.position : value.duration * _dragging!;
    final padding = widget.fullscreen
        ? const EdgeInsets.fromLTRB(20, 12, 20, 0)
        : widget.reel
        ? const EdgeInsets.fromLTRB(8, 64, 8, 0)
        : const EdgeInsets.fromLTRB(8, 8, 8, 0);
    final bar = _ProgressBar(
      played: _dragging ?? _fraction,
      buffered: _buffered,
      active: shown || widget.reel,
      onSeekStart: (f) {
        _hide?.cancel();
        setState(() {
          _visible = true;
          _dragging = f;
        });
      },
      onSeekUpdate: (f) => setState(() => _dragging = f),
      onSeekEnd: () {
        final f = _dragging;
        setState(() => _dragging = null);
        if (f != null) _seekTo(f);
        _scheduleHide();
      },
      onSeekCancel: () {
        setState(() => _dragging = null);
        _scheduleHide();
      },
    );
    const timeStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: Colors.white,
      fontFeatures: [FontFeature.tabularFigures()],
      shadows: [Shadow(blurRadius: 6)],
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleVisible,
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            ignoring: !shown,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: shown ? 1 : 0,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const IgnorePointer(child: ColoredBox(color: Color(0x59000000))),
                  // Top: leave full screen, and settings.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: padding,
                        child: Row(
                          children: [
                            if (widget.fullscreen && widget.onFullscreen != null)
                              _IconTap(
                                icon: Icons.keyboard_arrow_down_rounded,
                                tooltip: 'Exit full screen',
                                size: 30,
                                onTap: widget.onFullscreen!,
                              ),
                            const Spacer(),
                            _IconTap(icon: Icons.settings_outlined, tooltip: 'Playback speed', onTap: _chooseSpeed),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Middle: play or pause.
                  Center(
                    child: _Round(
                      size: widget.fullscreen ? 76 : 64,
                      tooltip: ended ? 'Replay' : (value.isPlaying ? 'Pause' : 'Play'),
                      onTap: _playPause,
                      child: Icon(
                        ended
                            ? Icons.replay_rounded
                            : (value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                        size: widget.fullscreen ? 48 : 40,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  // Bottom: time, and full screen.
                  if (!widget.reel)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 14,
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: widget.fullscreen ? 20 : 10),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0x80000000),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '${_time(position)} / ${_time(value.duration)}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white,
                                    fontFeatures: [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                              const Spacer(),
                              if (widget.onFullscreen != null)
                                _Round(
                                  size: 40,
                                  tooltip: widget.fullscreen ? 'Exit full screen' : 'Full screen',
                                  onTap: widget.onFullscreen!,
                                  child: Icon(
                                    widget.fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                                    size: 26,
                                    color: Colors.white,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // The progress bar: along the bottom edge (thin while hidden), or
          // for a reel always shown above the played and total times.
          if (widget.reel)
            Positioned(
              left: 16,
              right: 16,
              bottom: 10,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    bar,
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(_time(position), style: timeStyle),
                        const Spacer(),
                        Text(_time(value.duration), style: timeStyle),
                      ],
                    ),
                  ],
                ),
              ),
            )
          else
            Positioned(left: 0, right: 0, bottom: 0, child: SafeArea(top: false, child: bar)),
        ],
      ),
    );
  }
}

/// The seek bar: buffered and played parts, with a handle while controls show.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.played,
    required this.buffered,
    required this.active,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    required this.onSeekCancel,
  });

  final double played;
  final double buffered;
  final bool active;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<double> onSeekUpdate;
  final VoidCallback onSeekEnd;
  final VoidCallback onSeekCancel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        double at(Offset local) => width <= 0 ? 0 : (local.dx / width).clamp(0.0, 1.0);
        final track = active ? 3.0 : 2.0;
        return Semantics(
          slider: true,
          label: 'Seek',
          value: '${(played * 100).round()}%',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => onSeekStart(at(d.localPosition)),
            onTapUp: (_) => onSeekEnd(),
            onTapCancel: onSeekCancel,
            onHorizontalDragStart: (d) => onSeekStart(at(d.localPosition)),
            onHorizontalDragUpdate: (d) => onSeekUpdate(at(d.localPosition)),
            onHorizontalDragEnd: (_) => onSeekEnd(),
            child: SizedBox(
              height: 20,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.bottomLeft,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(height: track, color: const Color(0x3DFFFFFF)),
                  ),
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: Container(height: track, width: width * buffered, color: const Color(0x66FFFFFF)),
                  ),
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: Container(height: track, width: width * played, color: _accent),
                  ),
                  if (active)
                    Positioned(
                      left: (width * played - 7).clamp(0.0, width > 14 ? width - 14 : 0.0),
                      bottom: track / 2 - 7,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: const BoxDecoration(color: _accent, shape: BoxShape.circle),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A round, see-through button, as in the middle and bottom right.
class _Round extends StatelessWidget {
  const _Round({required this.size, required this.child, required this.onTap, required this.tooltip});

  final double size;
  final Widget child;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0x66000000),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(
            dimension: size,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _IconTap extends StatelessWidget {
  const _IconTap({required this.icon, required this.tooltip, required this.onTap, this.size = 26});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: size, color: Colors.white, shadows: const [Shadow(blurRadius: 6)]),
    );
  }
}

/// A video on its own, filling the screen. Wide videos turn the screen
/// sideways; the system bars hide until it's left.
class FullscreenVideoPage extends StatefulWidget {
  const FullscreenVideoPage({super.key, required this.video, required this.onPlayPause});

  final VideoPlayerController video;
  final VoidCallback onPlayPause;

  @override
  State<FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<FullscreenVideoPage> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(
      widget.video.value.aspectRatio > 1
          ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : const [DeviceOrientation.portraitUp],
    );
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: widget.video.value.aspectRatio,
              child: TrueColors(child: VideoPlayer(widget.video)),
            ),
          ),
          VideoControls(
            video: widget.video,
            fullscreen: true,
            onPlayPause: widget.onPlayPause,
            onFullscreen: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}
