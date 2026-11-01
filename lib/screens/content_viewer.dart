import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../api/api_client.dart';
import '../core/navigation.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/content_service.dart';
import '../services/explore_service.dart';
import '../services/kyc_service.dart';
import '../services/support_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/clap.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import '../widgets/html_text.dart';
import '../widgets/true_colors.dart';
import '../widgets/video_controls.dart';
import 'booking_sheet.dart';
import 'bookings_tab.dart' show DetailRow;
import 'kyc_screen.dart';
import 'solver_details_screen.dart';

// ---- Shared bits (also used by the Content tab) --------------------------------------

String ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inDays >= 7) return '${d.inDays ~/ 7}w ago';
  if (d.inDays >= 1) return '${d.inDays}d ago';
  if (d.inHours >= 1) return '${d.inHours}h ago';
  return 'just now';
}

String compact(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K' : '$n';

String clock(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

IconData typeIcon(ContentType t) => switch (t) {
  ContentType.reel => Icons.slow_motion_video_rounded,
  ContentType.video => Icons.play_circle_outline_rounded,
  ContentType.blog => Icons.article_outlined,
  ContentType.image => Icons.image_outlined,
  ContentType.repo => Icons.code_rounded,
  ContentType.podcast => Icons.podcasts_rounded,
};

/// Thumbnail with category and access badges: the item's real picture when it
/// has one, otherwise a glass placeholder with the type icon.
class ContentThumb extends StatelessWidget {
  const ContentThumb({
    super.key,
    required this.item,
    this.radius = 16,
    this.iconSize = 34,
    this.showPlay = false,
    this.fit = BoxFit.cover,
  });

  final ContentItem item;
  final double radius;
  final double iconSize;
  final bool showPlay;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      showPlay ? Icons.play_circle_outline_rounded : typeIcon(item.type),
      size: iconSize,
      color: AppColors.white(0.8),
    );
    final url = item.thumbnailUrl;
    // A solver's picture (or cover) still on the device, used until the
    // server's copy has a link, or if that link fails.
    final local = kIsWeb ? null : (item.type == ContentType.image ? item.mediaPath : null) ?? item.coverPath;
    Widget fromDevice() => Image.file(
      File(local!),
      fit: fit,
      errorBuilder: (context, error, stack) => Center(child: icon),
    );
    return GlassWell(
      radius: radius,
      child: Stack(
        children: [
          if (url == null && local == null)
            Center(child: icon)
          else ...[
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: TrueColors(
                  child: url == null
                      ? fromDevice()
                      : Image.network(
                          url,
                          fit: fit,
                          headers: ApiClient.instance.imageHeaders(url),
                          webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                          loadingBuilder: (context, child, progress) => progress == null ? child : Center(child: icon),
                          errorBuilder: (context, error, stack) {
                            // Signed links expire after an hour: fetch fresh ones.
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => ContentService.instance.refreshExpiredLinks(),
                            );
                            return local != null ? fromDevice() : Center(child: icon);
                          },
                        ),
                ),
              ),
            ),
            // Media keeps a play mark over its picture.
            if (item.type.isMedia || showPlay)
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.35)),
                  child: Padding(padding: const EdgeInsets.all(4), child: icon),
                ),
              ),
          ],
          if (item.draft) const Positioned(top: 8, left: 8, child: ContentBadge('Draft')),
          if (item.premium)
            const Positioned(top: 8, right: 8, child: ContentBadge('Premium', icon: Icons.workspace_premium_outlined)),
          if (item.durationSeconds > 0 && item.type != ContentType.reel)
            Positioned(right: 8, bottom: 8, child: ContentBadge(clock(item.durationSeconds))),
        ],
      ),
    );
  }
}

class ContentBadge extends StatelessWidget {
  const ContentBadge(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.white(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: Colors.white), const SizedBox(width: 4)],
          Text(
            text,
            style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

Future<T?> _sheet<T>(BuildContext context, Widget sheet) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: 0.35),
  builder: (_) => sheet,
);

/// Save to one or more folders, or create a new one.
Future<void> showSaveSheet(BuildContext context, AppUser user, ContentItem item) =>
    _sheet<void>(context, _SaveSheet(user: user, item: item));

/// Shares a content item with a token link (no content id in it).
Future<void> shareContent(AppUser user, ContentItem item) async {
  final link = await ContentService.instance.shareLink(user, item);
  await SharePlus.instance.share(
    ShareParams(text: 'Check out "${item.title}" by ${item.solverName} on Synap Mentor: $link', subject: item.title),
  );
}

// ---- Viewer ----------------------------------------------------------------------------

/// Builds the owner's actions for an item: vertical beside a reel, or a row
/// under other content.
typedef OwnerActionsBuilder = Widget Function(ContentItem item, bool vertical);

/// One screen for every content type. Reels swipe vertically through
/// [items]; other types show the item at [initialIndex]. With [ownerActions]
/// it's the solver's own view: their actions replace the seeker's, and there's
/// no paywall or booking.
class ContentViewer extends StatefulWidget {
  const ContentViewer({
    super.key,
    required this.user,
    required this.items,
    required this.initialIndex,
    required this.onOpenPlans,
    required this.onViewBookings,
    this.ownerActions,
  });

  final AppUser user;
  final List<ContentItem> items;
  final int initialIndex;
  final VoidCallback onOpenPlans;
  final VoidCallback onViewBookings;
  final OwnerActionsBuilder? ownerActions;

  @override
  State<ContentViewer> createState() => _ContentViewerState();
}

class _ContentViewerState extends State<ContentViewer> {
  late final _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  final _viewed = <String>{};

  ContentItem get _item => widget.items[_index];

  @override
  void initState() {
    super.initState();
    _markViewed(_item);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _markViewed(ContentItem item) {
    if (_viewed.add(item.id) && ContentService.instance.canOpen(widget.user, item)) {
      ContentService.instance.recordView(widget.user, item);
    }
  }

  void _plans() {
    Navigator.of(context).pop();
    widget.onOpenPlans();
  }

  @override
  Widget build(BuildContext context) {
    if (_item.type == ContentType.reel) return _reels();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListenableBuilder(
          // KYC completing lifts the free-preview lock.
          listenable: Listenable.merge([ContentService.instance, KycService.instance]),
          builder: (context, _) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    GlassIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(
                        _item.type.plural.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: AppText.heading.copyWith(fontSize: 18),
                      ),
                    ),
                    if (widget.ownerActions == null)
                      SmallPillButton(label: 'Subscriptions', onPressed: _plans)
                    else
                      const SizedBox(width: 44),
                  ],
                ),
              ),
              Expanded(
                child: _DetailPage(
                  user: widget.user,
                  item: _item,
                  onPlans: _plans,
                  onViewBookings: widget.onViewBookings,
                  ownerActions: widget.ownerActions,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Reels fill the whole screen and swipe vertically; back and
  /// Subscriptions float over the top.
  Widget _reels() {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: ListenableBuilder(
          // KYC completing lifts the free-preview lock.
          listenable: Listenable.merge([ContentService.instance, KycService.instance]),
          builder: (context, _) => Stack(
            children: [
              Positioned.fill(
                child: PageView.builder(
                  controller: _pages,
                  scrollDirection: Axis.vertical,
                  itemCount: widget.items.length,
                  onPageChanged: (i) {
                    setState(() => _index = i);
                    _markViewed(widget.items[i]);
                  },
                  itemBuilder: (context, i) => _ReelPage(
                    key: ValueKey(widget.items[i].id),
                    user: widget.user,
                    item: widget.items[i],
                    active: i == _index,
                    onPlans: _plans,
                    onViewBookings: widget.onViewBookings,
                    ownerActions: widget.ownerActions,
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        GlassIconButton(
                          icon: Icons.arrow_back_rounded,
                          tooltip: 'Back',
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                        const Spacer(),
                        if (widget.ownerActions == null) SmallPillButton(label: 'Subscriptions', onPressed: _plans),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Media counts today's free seconds itself while it plays ([_YouTubeMedia],
/// [_NetworkMedia]) and stops at the limit; the page then shows its lock.
mixin _PreviewLimit<T extends StatefulWidget> on State<T> {
  /// Set when the free preview runs out, rebuilding the page into its lock.
  bool limitReached = false;
}

class _ReelPage extends StatefulWidget {
  const _ReelPage({
    super.key,
    required this.user,
    required this.item,
    required this.active,
    required this.onPlans,
    required this.onViewBookings,
    this.ownerActions,
  });

  final AppUser user;
  final ContentItem item;
  final bool active;
  final VoidCallback onPlans;
  final VoidCallback onViewBookings;
  final OwnerActionsBuilder? ownerActions;

  @override
  State<_ReelPage> createState() => _ReelPageState();
}

class _ReelPageState extends State<_ReelPage> with _PreviewLimit {
  /// Media from the server or YouTube; anything else shows its thumbnail.
  bool get _real => widget.item.youtubeId != null || (widget.item.remote && widget.item.type.isMedia);

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final service = ContentService.instance;
    final limited = service.outOfFree(widget.user);
    final locked = !service.canOpen(widget.user, item) || limited;
    final playing = !locked && widget.active && _real;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (playing)
          item.youtubeId != null
              ? _YouTubeMedia(
                  user: widget.user,
                  item: item,
                  vertical: true,
                  onLimit: () => setState(() => limitReached = true),
                )
              : _NetworkMedia(
                  user: widget.user,
                  item: item,
                  vertical: true,
                  onLimit: () => setState(() => limitReached = true),
                )
        else
          ContentThumb(item: item, radius: 0, iconSize: 56),
        // Shade at the bottom so the text over the reel stays readable.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.55, 1],
                colors: [Colors.transparent, Color(0xCC000000)],
              ),
            ),
          ),
        ),
        if (locked)
          Positioned.fill(
            child: ColoredBox(
              color: const Color(0x99000000),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: GlassPanel(
                    radius: 24,
                    padding: const EdgeInsets.all(18),
                    child: _Locked(item: item, limit: limited, onPlans: widget.onPlans, user: widget.user),
                  ),
                ),
              ),
            ),
          ),
        _reelOverlay(item),
      ],
    );
  }

  /// The creator, title and details at the bottom left, and the actions down
  /// the right, above the progress bar.
  Widget _reelOverlay(ContentItem item) {
    final bottom = MediaQuery.paddingOf(context).bottom + 64;
    return Stack(
      children: [
        Positioned(
          right: 12,
          bottom: bottom,
          child: widget.ownerActions?.call(item, true) ?? _ActionColumn(user: widget.user, item: item),
        ),
        Positioned(
          left: 16,
          right: 80,
          bottom: bottom,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.ownerActions == null) ...[
                _SolverRow(user: widget.user, item: item, onViewBookings: widget.onViewBookings, dense: true),
                gap8,
              ],
              IgnorePointer(
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 8)],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Flexible(
                    child: IgnorePointer(
                      child: Text(
                        '${compact(item.views)} views · ${item.subcategory} · ${ago(item.createdAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(fontSize: 12.5, shadows: const [Shadow(blurRadius: 8)]),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SmallPillButton(
                    label: 'Details',
                    onPressed: () => _sheet<void>(context, _DetailsSheet(item: item)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Plays an item's real YouTube video. While it plays, each second counts
/// against today's free minutes; at the limit the video pauses and [onLimit]
/// swaps in the subscription prompt.
class _YouTubeMedia extends StatefulWidget {
  const _YouTubeMedia({required this.user, required this.item, required this.onLimit, this.vertical = false});

  final AppUser user;
  final ContentItem item;
  final VoidCallback onLimit;

  /// Reels play full height, like Shorts.
  final bool vertical;

  @override
  State<_YouTubeMedia> createState() => _YouTubeMediaState();
}

class _YouTubeMediaState extends State<_YouTubeMedia> {
  late final YoutubePlayerController _controller;
  StreamSubscription<YoutubePlayerValue>? _states;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    final service = ContentService.instance;
    final outOfMinutes = service.outOfFree(widget.user);
    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.item.youtubeId!,
      // Reels start on their own, like a feed; longer media waits for a tap.
      autoPlay: widget.vertical && !outOfMinutes,
      params: const YoutubePlayerParams(showFullscreenButton: true, strictRelatedVideos: true),
    );
    _states = _controller.listen((value) {
      final playing = value.playerState == PlayerState.playing;
      if (playing && _ticker == null) {
        _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      } else if (!playing) {
        _ticker?.cancel();
        _ticker = null;
      }
    });
    if (outOfMinutes) WidgetsBinding.instance.addPostFrameCallback((_) => widget.onLimit());
  }

  void _tick() {
    if (!mounted) return;
    if (!ContentService.instance.tickFreeViewing(widget.user)) {
      _controller.pauseVideo();
      widget.onLimit();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _states?.cancel();
    _controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ratio = widget.vertical ? 9 / 16 : 16 / 9;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.vertical ? 0 : 22),
      child: ColoredBox(
        color: Colors.black,
        child: LayoutBuilder(
          builder: (context, box) {
            // A reel fills the screen (cropping the sides if needed); other
            // videos take the largest box of their shape that fits.
            final width = widget.vertical
                ? (box.maxHeight * ratio < box.maxWidth ? box.maxWidth : box.maxHeight * ratio)
                : (box.maxHeight * ratio).clamp(0.0, box.maxWidth);
            return OverflowBox(
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: SizedBox(
                width: width,
                height: width / ratio,
                child: TrueColors(
                  child: YoutubePlayer(
                    controller: _controller,
                    aspectRatio: ratio,
                    // Vertical swipes page between reels instead.
                    enableFullScreenOnVerticalDrag: !widget.vertical,
                    autoFullScreen: !widget.vertical,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Plays media hosted by Synap Mentor (not YouTube) from the stream URL the
/// server hands out, counting free viewing like [_YouTubeMedia].
class _NetworkMedia extends StatefulWidget {
  const _NetworkMedia({required this.user, required this.item, required this.onLimit, this.vertical = false});

  final AppUser user;
  final ContentItem item;
  final VoidCallback onLimit;

  /// Reels play full height and start on their own.
  final bool vertical;

  @override
  State<_NetworkMedia> createState() => _NetworkMediaState();
}

class _NetworkMediaState extends State<_NetworkMedia> {
  VideoPlayerController? _video;
  String? _error;
  Timer? _ticker;

  /// The full-screen page, while it's open.
  Route<void>? _fullscreen;

  Future<void> _openFullscreen() async {
    final video = _video;
    if (video == null || !video.value.isInitialized || _fullscreen != null) return;
    final route = MaterialPageRoute<void>(
      builder: (_) => FullscreenVideoPage(video: video, onPlayPause: _toggle),
    );
    _fullscreen = route;
    await Navigator.of(context, rootNavigator: true).push(route);
    _fullscreen = null;
  }

  /// Leaves full screen, e.g. when the free preview runs out.
  void _closeFullscreen() {
    final route = _fullscreen;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
    _fullscreen = null;
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final service = ContentService.instance;
    try {
      final url = await service.streamUrlOf(widget.item);
      if (url == null || url.isEmpty) throw const AuthException('This media isn\'t available yet.');
      final video = VideoPlayerController.networkUrl(Uri.parse(url));
      _video = video;
      await video.initialize();
      if (!mounted) return;
      video.addListener(_onVideo);
      final outOfMinutes = service.outOfFree(widget.user);
      if (outOfMinutes) {
        widget.onLimit();
      } else if (widget.vertical) {
        await video.play();
      }
      if (mounted) setState(() {});
    } on AuthException catch (e) {
      if (!mounted) return;
      if (service.previewDenied(widget.user, e)) return widget.onLimit();
      setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'This media couldn\'t be played. Please try again.');
    }
  }

  void _onVideo() {
    final playing = _video?.value.isPlaying ?? false;
    if (playing && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else if (!playing) {
      _ticker?.cancel();
      _ticker = null;
    }
    if (mounted) setState(() {});
  }

  void _tick() {
    if (!mounted) return;
    if (!ContentService.instance.tickFreeViewing(widget.user)) {
      _video?.pause();
      _closeFullscreen();
      widget.onLimit();
    }
  }

  void _toggle() {
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    final service = ContentService.instance;
    if (!video.value.isPlaying && service.outOfFree(widget.user)) {
      _closeFullscreen();
      widget.onLimit();
      return;
    }
    if (video.value.isPlaying) {
      video.pause();
    } else {
      // At the end, play starts over.
      final v = video.value;
      if (v.duration > Duration.zero && v.position >= v.duration) video.seekTo(Duration.zero);
      video.play();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    final video = _video;
    video?.removeListener(_onVideo);
    final route = _fullscreen;
    if (route != null && route.isActive) {
      // The full-screen page still shows this video: close it first, then
      // let the video go once that page is gone.
      video?.pause();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
        WidgetsBinding.instance.addPostFrameCallback((_) => video?.dispose());
        WidgetsBinding.instance.scheduleFrame();
      });
    } else {
      video?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final ready = video != null && video.value.isInitialized;
    // A podcast recorded with video plays it; an audio-only one shows its cover.
    final audioOnly =
        widget.item.type == ContentType.podcast &&
        (!ready || video.value.size.width <= 0 || video.value.size.height <= 0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.vertical ? 0 : 22),
      child: ColoredBox(
        color: Colors.black,
        child: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!, style: AppText.body, textAlign: TextAlign.center),
                ),
              )
            : !ready
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : Stack(
                fit: StackFit.expand,
                children: [
                  if (audioOnly)
                    ContentThumb(item: widget.item, radius: 0, iconSize: 56)
                  else if (widget.vertical && video.value.aspectRatio < 1)
                    // A portrait reel fills the screen, cropping its edges.
                    FittedBox(
                      fit: BoxFit.cover,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: video.value.size.width,
                        height: video.value.size.height,
                        child: TrueColors(child: VideoPlayer(video)),
                      ),
                    )
                  else
                    Center(
                      child: AspectRatio(
                        aspectRatio: video.value.aspectRatio,
                        child: TrueColors(child: VideoPlayer(video)),
                      ),
                    ),
                  VideoControls(
                    video: video,
                    onPlayPause: _toggle,
                    reel: widget.vertical,
                    // Audio has nothing to enlarge, and reels already fill the screen.
                    onFullscreen: audioOnly || widget.vertical ? null : _openFullscreen,
                  ),
                ],
              ),
      ),
    );
  }
}

/// Full-screen, pinch-to-zoom view of an image post.
class _ImageZoom extends StatelessWidget {
  const _ImageZoom({required this.item});

  final ContentItem item;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(item.title, style: const TextStyle(fontSize: 16)),
      ),
      body: InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: TrueColors(
            child: (item.mediaUrl ?? item.imageUrl) == null && item.mediaPath != null && !kIsWeb
                ? Image.file(
                    File(item.mediaPath!),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) =>
                        Icon(Icons.broken_image_outlined, size: 56, color: AppColors.white(0.6)),
                  )
                : Image.network(
                    item.mediaUrl ?? item.imageUrl ?? '',
                    fit: BoxFit.contain,
                    headers: ApiClient.instance.imageHeaders(item.mediaUrl ?? item.imageUrl ?? ''),
                    webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                    errorBuilder: (context, error, stack) =>
                        Icon(Icons.broken_image_outlined, size: 56, color: AppColors.white(0.6)),
                  ),
          ),
        ),
      ),
    );
  }
}

class _ActionColumn extends StatelessWidget {
  const _ActionColumn({required this.user, required this.item});

  final AppUser user;
  final ContentItem item;

  @override
  Widget build(BuildContext context) {
    final service = ContentService.instance;
    Widget action(IconData icon, String label, String? count, VoidCallback onTap, {Widget? button}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          button ?? GlassIconButton(icon: icon, tooltip: label, onPressed: onTap),
          if (count != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(count, style: const TextStyle(fontSize: 12, color: Colors.white)),
            ),
        ],
      ),
    );
    return Column(
      children: [
        action(
          Icons.volunteer_activism_outlined,
          'Appreciate',
          '${item.appreciatedBy.length}',
          () => service.toggleAppreciate(user, item),
          button: ClapButton(
            active: service.appreciated(user, item),
            tooltip: 'Appreciate',
            onPressed: (context) => _clap(context, user, item),
          ),
        ),
        action(
          Icons.chat_bubble_outline_rounded,
          'Comments',
          '${item.comments.length}',
          () => _sheet<void>(context, _CommentsSheet(user: user, item: item)),
        ),
        action(Icons.share_outlined, 'Share', null, () => shareContent(user, item)),
        action(
          service.isSaved(user, item) ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          'Save',
          null,
          () => showSaveSheet(context, user, item),
        ),
        action(Icons.flag_outlined, 'Report', null, () => _sheet<void>(context, _ReportSheet(user: user, item: item))),
      ],
    );
  }
}

/// Toggles the appreciation; claps float up when it's given.
void _clap(BuildContext context, AppUser user, ContentItem item) {
  final service = ContentService.instance;
  final clapping = !service.appreciated(user, item);
  service.toggleAppreciate(user, item);
  if (clapping) showClapBurst(context);
}

class _DetailPage extends StatefulWidget {
  const _DetailPage({
    required this.user,
    required this.item,
    required this.onPlans,
    required this.onViewBookings,
    this.ownerActions,
  });

  final AppUser user;
  final ContentItem item;
  final VoidCallback onPlans;
  final VoidCallback onViewBookings;
  final OwnerActionsBuilder? ownerActions;

  @override
  State<_DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<_DetailPage> with _PreviewLimit {
  /// Counts free preview time while a blog, image or repository is open;
  /// media counts its own while it plays.
  Timer? _reading;

  @override
  void initState() {
    super.initState();
    _reading = Timer.periodic(const Duration(seconds: 1), (_) => _tickReading());
  }

  @override
  void dispose() {
    _reading?.cancel();
    super.dispose();
  }

  void _tickReading() {
    if (!mounted) return;
    final item = widget.item;
    final service = ContentService.instance;
    final shown =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (!shown ||
        item.type.isMedia ||
        item.premium ||
        widget.ownerActions != null ||
        !service.metered(widget.user) ||
        service.outOfFree(widget.user) ||
        item.accessError != null ||
        (item.remote && !item.detailLoaded)) {
      return;
    }
    if (!service.tickFreeViewing(widget.user)) setState(() => limitReached = true);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final service = ContentService.instance;
    final locked = !service.canOpen(widget.user, item);
    // Out of free preview locks every type; it lifts once KYC (or a
    // subscription) gives more.
    final limited = widget.ownerActions == null && service.outOfFree(widget.user);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: item.type == ContentType.image ? 4 / 3 : 16 / 9,
                  child: item.accessError != null && !locked && !limited
                      ? GlassPanel(
                          radius: 22,
                          padding: const EdgeInsets.all(16),
                          child: Center(
                            child: Text(item.accessError!, style: AppText.body, textAlign: TextAlign.center),
                          ),
                        )
                      : locked || limited
                      ? GlassPanel(
                          radius: 22,
                          padding: const EdgeInsets.all(12),
                          child: Center(
                            child: _Locked(item: item, limit: limited, onPlans: widget.onPlans, user: widget.user),
                          ),
                        )
                      : item.type.isMedia
                      ? (item.youtubeId != null
                            ? _YouTubeMedia(
                                user: widget.user,
                                item: item,
                                onLimit: () => setState(() => limitReached = true),
                              )
                            : item.remote
                            ? _NetworkMedia(
                                user: widget.user,
                                item: item,
                                onLimit: () => setState(() => limitReached = true),
                              )
                            : ContentThumb(item: item, radius: 22, iconSize: 56))
                      : item.type == ContentType.image && (item.thumbnailUrl != null || item.mediaPath != null)
                      ? GestureDetector(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => _ImageZoom(item: item)),
                          ),
                          child: ContentThumb(item: item, radius: 22, iconSize: 56, fit: BoxFit.contain),
                        )
                      : ContentThumb(item: item, radius: 22, iconSize: 56),
                ),
                if (!locked && widget.ownerActions == null) _FreeMinutes(user: widget.user, item: item),
                gap14,
                Text(
                  item.title,
                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white),
                ),
                gap8,
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in item.tags) ContentBadge(t),
                    ContentBadge(item.premium ? 'Premium' : 'Free'),
                    if (item.draft) const ContentBadge('Draft'),
                  ],
                ),
                gap14,
                _StatsRow(user: widget.user, item: item, owner: widget.ownerActions != null),
                Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 14), color: AppColors.white(0.14)),
                if (limited && !locked)
                  Text(
                    service.kycLimited(widget.user)
                        ? 'Complete KYC verification to keep reading.'
                        : 'Subscribe to keep reading.',
                    style: AppText.body,
                  )
                else if (item.type == ContentType.blog && item.html)
                  HtmlText(item.body.join('\n'))
                else if (item.type == ContentType.blog)
                  for (final p in item.body) ...[Text(p, style: AppText.body), gap14]
                else
                  Text(item.description, style: AppText.body),
                if (item.source != null) ...[gap8, Text(item.source!, style: AppText.caption.copyWith(fontSize: 12))],
                if (item.keyPoints.isNotEmpty) ...[
                  gap14,
                  Text(
                    item.type == ContentType.blog ? 'Key Topics Covered' : 'Key Takeaways',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  gap8,
                  for (final point in item.keyPoints)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle_outline_rounded, size: 18, color: Colors.white),
                          const SizedBox(width: 10),
                          Expanded(child: Text(point, style: AppText.label.copyWith(fontSize: 14))),
                        ],
                      ),
                    ),
                ],
                gap24,
                if (widget.ownerActions != null) ...[
                  widget.ownerActions!(item, false),
                  gap14,
                ] else ...[
                  GlassWell(
                    radius: 18,
                    padding: const EdgeInsets.all(14),
                    child: _SolverRow(user: widget.user, item: item, onViewBookings: widget.onViewBookings),
                  ),
                  gap24,
                ],
                if (item.type == ContentType.repo && item.repoUrl != null) ...[
                  PrimaryPillButton(
                    label: 'Open Repository',
                    onPressed: locked || limited
                        ? null
                        : () => launchUrl(Uri.parse(item.repoUrl!), mode: LaunchMode.externalApplication),
                  ),
                  gap14,
                ],
                Row(
                  children: [
                    Expanded(
                      child: item.type == ContentType.repo
                          ? GlassPillButton(
                              label: 'Content Details',
                              onPressed: () => _sheet<void>(context, _DetailsSheet(item: item)),
                            )
                          : PrimaryPillButton(
                              label: 'Content Details',
                              onPressed: () => _sheet<void>(context, _DetailsSheet(item: item)),
                            ),
                    ),
                    if (widget.ownerActions == null) ...[
                      const SizedBox(width: 10),
                      GlassIconButton(
                        icon: service.isSaved(widget.user, item)
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        tooltip: 'Save',
                        onPressed: () => showSaveSheet(context, widget.user, item),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.user, required this.item, this.owner = false});

  final AppUser user;
  final ContentItem item;

  /// The creator sees the counts; sharing and reporting live in their actions.
  final bool owner;

  @override
  Widget build(BuildContext context) {
    final service = ContentService.instance;
    Widget stat(Widget icon, String text, [VoidCallback? onTap, String? label]) => Semantics(
      button: onTap != null,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              const SizedBox(width: 5),
              Text(text, style: const TextStyle(fontSize: 13, color: Colors.white)),
            ],
          ),
        ),
      ),
    );
    return Row(
      children: [
        stat(const Icon(Icons.visibility_outlined, size: 18, color: Colors.white), compact(item.views)),
        const SizedBox(width: 6),
        stat(
          const Icon(Icons.chat_bubble_outline_rounded, size: 18, color: Colors.white),
          '${item.comments.length}',
          () => _sheet<void>(context, _CommentsSheet(user: user, item: item)),
          'Comments',
        ),
        const SizedBox(width: 6),
        Builder(
          builder: (context) => stat(
            ClapIcon(size: 18, active: owner || service.appreciated(user, item)),
            '${item.appreciatedBy.length}',
            owner ? null : () => _clap(context, user, item),
            'Appreciations',
          ),
        ),
        const Spacer(),
        Text(ago(item.createdAt), style: AppText.caption),
        if (!owner) ...[
          IconButton(
            tooltip: 'Share',
            onPressed: () => shareContent(user, item),
            icon: const Icon(Icons.share_outlined, color: Colors.white),
          ),
          SmallPillButton(
            label: 'Report',
            onPressed: () => _sheet<void>(context, _ReportSheet(user: user, item: item)),
          ),
        ],
      ],
    );
  }
}

/// The creator, with a link to their profile and a quick booking.
class _SolverRow extends StatelessWidget {
  const _SolverRow({required this.user, required this.item, required this.onViewBookings, this.dense = false});

  final AppUser user;
  final ContentItem item;
  final VoidCallback onViewBookings;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final solver = ExploreService.instance.allSolvers.where((s) => s.id == item.solverId).firstOrNull;
    return Row(
      children: [
        GlassAvatar(
          initials: solver?.initials ?? item.solverName[0],
          size: dense ? 34 : 44,
          photoUrl: solver == null ? null : ExploreService.instance.solverPhoto(solver),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.solverName,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
              ),
              if (!dense && solver != null)
                Text(solver.headline, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
            ],
          ),
        ),
        if (solver != null) ...[
          if (!dense) ...[
            SmallPillButton(
              label: 'Profile',
              onPressed: () => Navigator.of(context)
                  .push(glassRoute(SolverDetailsScreen(user: user, solver: solver, onViewBookings: onViewBookings))),
            ),
            const SizedBox(width: 6),
          ],
          SmallPillButton(
            label: 'Book Session',
            primary: true,
            onPressed: () async {
              final view = await showBookingSheet(context, user: user, solver: solver);
              if (view == true && context.mounted) {
                Navigator.of(context).pop();
                onViewBookings();
              }
            },
          ),
        ],
      ],
    );
  }
}

class _FreeMinutes extends StatelessWidget {
  const _FreeMinutes({required this.user, required this.item});

  final AppUser user;
  final ContentItem item;

  @override
  Widget build(BuildContext context) {
    final service = ContentService.instance;
    if (!service.metered(user) || item.premium) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        service.kycLimited(user)
            ? 'Free preview left: ${clock(service.freeSecondsLeft(user))}'
            : 'Free minutes left today: ${clock(service.freeSecondsLeft(user))}',
        textAlign: TextAlign.center,
        style: AppText.caption.copyWith(fontSize: 11.5),
      ),
    );
  }
}

class _Locked extends StatelessWidget {
  const _Locked({required this.item, required this.limit, required this.onPlans, this.user});

  final ContentItem item;
  final bool limit;
  final VoidCallback onPlans;

  /// The viewer, to offer KYC when that's what unlocks more viewing.
  final AppUser? user;

  @override
  Widget build(BuildContext context) {
    final viewer = user;
    if (limit && viewer != null && ContentService.instance.kycLimited(viewer)) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.verified_user_outlined, size: 36, color: Colors.white),
          gap8,
          const Text(
            'Complete KYC verification to continue',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'You\'ve used your 5 free preview minutes. Verify your identity to keep watching.',
            style: AppText.caption,
            textAlign: TextAlign.center,
          ),
          gap14,
          SmallPillButton(
            label: 'Verify Now',
            primary: true,
            onPressed: () async {
              await Navigator.of(context).push(glassRoute(KycScreen(user: viewer)));
              await ContentService.instance.refreshAccess(viewer, item);
            },
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.lock_outline_rounded, size: 36, color: Colors.white),
        gap8,
        Text(
          limit ? 'You\'ve used today\'s 10 free minutes' : 'Premium content',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          limit ? 'Subscribe to keep watching.' : 'Subscribe to watch ${item.type.plural.toLowerCase()} like this.',
          style: AppText.caption,
          textAlign: TextAlign.center,
        ),
        gap14,
        SmallPillButton(label: 'View Plans', primary: true, onPressed: onPlans),
      ],
    );
  }
}

// ---- Sheets -------------------------------------------------------------------------------

class _DetailsSheet extends StatelessWidget {
  const _DetailsSheet({required this.item});

  final ContentItem item;

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Content Details',
      body: GlassWell(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          children: [
            DetailRow('Views', compact(item.views)),
            DetailRow('Appreciations', '${item.appreciatedBy.length}'),
            DetailRow('Comments', '${item.comments.length}'),
            DetailRow('Type', item.type.label),
            DetailRow('Category', item.category),
            DetailRow('Sub-category', item.subcategory),
            DetailRow('Access', item.premium ? 'Premium' : 'Free'),
            if (item.durationSeconds > 0) DetailRow('Duration', clock(item.durationSeconds)),
            if (item.readMinutes > 0) DetailRow('Reading time', '${item.readMinutes} min'),
            DetailRow('Created', ago(item.createdAt)),
            DetailRow('By', item.solverName),
          ],
        ),
      ),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class _CommentsSheet extends StatefulWidget {
  const _CommentsSheet({required this.user, required this.item});

  final AppUser user;
  final ContentItem item;

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _post() {
    if (_input.text.trim().isEmpty) return;
    ContentService.instance.comment(widget.user, widget.item, _input.text);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ContentService.instance,
      builder: (context, _) => FlowSheetFrame(
        title: 'Comments (${widget.item.comments.length})',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.item.comments.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'No comments yet. Start the conversation.',
                  style: AppText.body,
                  textAlign: TextAlign.center,
                ),
              ),
            for (final c in widget.item.comments.reversed)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GlassWell(
                  radius: 14,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${c.author} · ${ago(c.at)}', style: AppText.caption.copyWith(fontSize: 11.5)),
                      const SizedBox(height: 4),
                      Text(c.text, style: AppText.label.copyWith(fontSize: 14)),
                    ],
                  ),
                ),
              ),
          ],
        ),
        footer: Row(
          children: [
            Expanded(
              child: GlassTextField(
                controller: _input,
                hint: 'Add a comment',
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _post(),
              ),
            ),
            const SizedBox(width: 8),
            GlassIconButton(icon: Icons.send_rounded, tooltip: 'Post', onPressed: _post),
          ],
        ),
      ),
    );
  }
}

class _SaveSheet extends StatefulWidget {
  const _SaveSheet({required this.user, required this.item});

  final AppUser user;
  final ContentItem item;

  @override
  State<_SaveSheet> createState() => _SaveSheetState();
}

class _SaveSheetState extends State<_SaveSheet> {
  final _folder = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  void _create() {
    try {
      final name = _folder.text.trim();
      ContentService.instance
        ..createFolder(widget.user, name)
        ..setSaved(widget.user, widget.item, name, true);
      _folder.clear();
      setState(() => _error = null);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ContentService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final folders = service.folders(widget.user);
        return FlowSheetFrame(
          title: 'Save to Folder',
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final entry in folders.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GlassOption(
                    height: 52,
                    radius: 16,
                    selected: entry.value.contains(widget.item.id),
                    onTap: () =>
                        service.setSaved(widget.user, widget.item, entry.key, !entry.value.contains(widget.item.id)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          const Icon(Icons.folder_outlined, color: Colors.white),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '${entry.key} (${entry.value.length})',
                              style: AppText.label.copyWith(fontSize: 14),
                            ),
                          ),
                          Icon(
                            entry.value.contains(widget.item.id)
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              gap14,
              const Text(
                'New Folder',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white),
              ),
              gap8,
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: GlassTextField(
                      controller: _folder,
                      hint: 'Folder name',
                      icon: Icons.create_new_folder_outlined,
                      textCapitalization: TextCapitalization.words,
                      errorText: _error,
                      onSubmitted: (_) => _create(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: GlassIconButton(icon: Icons.add_rounded, tooltip: 'Create folder', onPressed: _create),
                  ),
                ],
              ),
            ],
          ),
          footer: PrimaryPillButton(label: 'Done', onPressed: () => Navigator.of(context).pop()),
        );
      },
    );
  }
}

/// Content reports go to the admin like any other report, and appear in
/// Support → Chat History → Report History.
class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.user, required this.item});

  final AppUser user;
  final ContentItem item;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final _details = TextEditingController();
  String? _category;
  bool _sending = false;
  bool _sent = false;
  final _errors = <String, String?>{};
  String? _error;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _errors
        ..['category'] = _category == null ? 'Select a reason.' : null
        ..['details'] = _details.text.trim().length < 10 ? 'Use at least 10 characters.' : null;
    });
    if (_errors.values.any((e) => e != null)) return;
    setState(() => _sending = true);
    try {
      await SupportService.instance.create(
        user: widget.user,
        kind: TicketKind.report,
        category: _category!,
        subject: 'Content: ${widget.item.title}',
        description: _details.text,
        links: ['https://synapmentor.app/content/${widget.item.id}'],
      );
      if (mounted) setState(() => _sent = true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Report Content',
      body: _sent
          ? Column(
              children: [
                const GlassIconBadge(icon: Icons.check_rounded, size: 64),
                gap14,
                Text(
                  'Thanks. Our team will review this. You can follow it in Support → Chat History.',
                  style: AppText.body,
                  textAlign: TextAlign.center,
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Reporting "${widget.item.title}"', style: AppText.caption),
                gap14,
                InlineNotice(message: _error, tone: NoticeTone.error),
                const Text('Reason *', style: _label),
                gap8,
                GlassSelectField(
                  value: _category,
                  hint: 'Select a reason',
                  errorText: _errors['category'],
                  onTap: () async {
                    final picked = await showGlassPicker(
                      context,
                      title: 'Reason',
                      options: SupportService.reportCategories,
                      label: (c) => c,
                      selected: _category,
                    );
                    if (picked != null) setState(() => _category = picked);
                  },
                ),
                gap14,
                const Text('Details *', style: _label),
                gap8,
                GlassTextField(
                  controller: _details,
                  hint: 'What\'s wrong with this content? (min 10 characters)',
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  errorText: _errors['details'],
                  onChanged: (_) => setState(() => _errors['details'] = null),
                ),
              ],
            ),
      footer: _sent
          ? PrimaryPillButton(label: 'Done', onPressed: () => Navigator.of(context).pop())
          : Row(
              children: [
                Expanded(
                  child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PrimaryPillButton(label: 'Submit Report', loading: _sending, onPressed: _submit),
                ),
              ],
            ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}
