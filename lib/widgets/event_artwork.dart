import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/community_service.dart';
import 'glass.dart';
import 'true_colors.dart';

/// The picture types and size the event artwork upload accepts.
const _artworkTypes = ['jpg', 'jpeg', 'png', 'webp', 'gif'];
const _maxArtworkBytes = 5 * 1024 * 1024;

/// Lets the host pick a cover or poster from the device. Returns the file, or
/// null when nothing was picked; [onError] says why a picked file can't be used.
Future<({String path, String name})?> pickEventArtwork({required void Function(String message) onError}) async {
  final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: _artworkTypes);
  if (file == null) return null;
  final extension = (file.extension ?? file.name.split('.').last).toLowerCase();
  final bytes = await file.length();
  final path = file.path;
  if (!_artworkTypes.contains(extension)) {
    onError('Choose a JPG, PNG, WebP or GIF picture.');
  } else if (bytes != null && bytes > _maxArtworkBytes) {
    onError('The picture must be under 5 MB. Choose a smaller one.');
  } else if (path == null) {
    onError('Couldn\'t read that picture. Try another one.');
  } else {
    return (path: path, name: file.name);
  }
  return null;
}

/// An event's cover across the top of its card, cropped to fill 16:7 (or
/// its poster when it has no cover). Without either, a cover made from the
/// event's title.
class EventCoverBanner extends StatelessWidget {
  const EventCoverBanner({super.key, required this.event, this.radius = 14});

  final CommunityEvent event;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final url = event.bannerUrl;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AspectRatio(
          aspectRatio: 16 / 7,
          child: url == null
              ? _TitleArtwork(event: event, radius: radius, wide: true)
              : _NetworkArtwork(url: url, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

/// An event's poster in full, uncropped, as the details show it. Without one,
/// a poster made from the event's title.
class EventPoster extends StatelessWidget {
  const EventPoster({super.key, required this.event});

  final CommunityEvent event;

  @override
  Widget build(BuildContext context) {
    final url = event.posterUrl;
    if (url == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
            child: AspectRatio(
              aspectRatio: 4 / 5,
              child: _TitleArtwork(event: event, radius: 18, wide: false),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GestureDetector(
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => _PosterView(event: event))),
        child: GlassWell(
          radius: 18,
          padding: const EdgeInsets.all(6),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.55),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: _NetworkArtwork(url: url, fit: BoxFit.contain, minHeight: 180),
            ),
          ),
        ),
      ),
    );
  }
}

/// Stands in for missing artwork: the event's type, title and date on glass,
/// as a [wide] cover or a portrait poster.
class _TitleArtwork extends StatelessWidget {
  const _TitleArtwork({required this.event, required this.radius, required this.wide});

  final CommunityEvent event;
  final double radius;
  final bool wide;

  static IconData _icon(EventType type) => switch (type) {
    EventType.conference => Icons.groups_rounded,
    EventType.workshop => Icons.build_outlined,
    EventType.meetup => Icons.handshake_outlined,
    EventType.webinar => Icons.videocam_outlined,
    EventType.hackathon => Icons.code_rounded,
    EventType.other => Icons.event_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: radius,
      fillTop: 0.12,
      fillBottom: 0.03,
      padding: EdgeInsets.all(wide ? 14 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_icon(event.type), size: wide ? 16 : 20, color: Colors.white),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  event.typeLabel.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: wide ? 11 : 12.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: AppColors.white(0.8),
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: Align(
              alignment: wide ? Alignment.centerLeft : Alignment.center,
              child: Text(
                event.title,
                maxLines: wide ? 2 : 4,
                overflow: TextOverflow.ellipsis,
                textAlign: wide ? TextAlign.left : TextAlign.center,
                style: TextStyle(
                  fontSize: wide ? 18 : 24,
                  height: 1.2,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          Text(
            '${formatDay(event.start)} · ${formatClock(event.start)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(fontSize: wide ? 11.5 : 13),
          ),
        ],
      ),
    );
  }
}

/// A picture chosen on the device, before it's uploaded.
class ArtworkPreview extends StatelessWidget {
  const ArtworkPreview({super.key, required this.path, required this.aspectRatio});

  final String path;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: TrueColors(
          child: Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
          ),
        ),
      ),
    );
  }
}

/// Loads an artwork link; a link that has expired fetches fresh ones.
class _NetworkArtwork extends StatelessWidget {
  const _NetworkArtwork({required this.url, required this.fit, this.minHeight});

  final String url;
  final BoxFit fit;
  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    final placeholder = SizedBox(
      height: minHeight,
      child: ColoredBox(
        color: AppColors.white(0.06),
        child: Center(child: Icon(Icons.image_outlined, size: 28, color: AppColors.white(0.5))),
      ),
    );
    return TrueColors(
      child: Image.network(
        url,
        fit: fit,
        width: double.infinity,
        loadingBuilder: (_, child, progress) => progress == null ? child : placeholder,
        errorBuilder: (_, _, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) => CommunityService.instance.refreshExpiredArtwork());
          return placeholder;
        },
      ),
    );
  }
}

/// The poster full screen: pinch to zoom.
class _PosterView extends StatelessWidget {
  const _PosterView({required this.event});

  final CommunityEvent event;

  @override
  Widget build(BuildContext context) {
    final url = event.posterUrl;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(event.title, style: const TextStyle(fontSize: 16)),
      ),
      body: url == null
          ? const SizedBox.shrink()
          : InteractiveViewer(
              maxScale: 5,
              child: Center(
                child: _NetworkArtwork(url: url, fit: BoxFit.contain),
              ),
            ),
    );
  }
}
