import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../core/theme.dart';
import '../services/community_service.dart';
import 'glass.dart';
import 'glass_controls.dart';
import 'true_colors.dart';

/// A community's logo, or its initials when it has none (or while the logo
/// loads). Expired logo links are fetched again. Like a profile picture in a
/// chat app, tapping a logo opens it full size.
class CommunityLogo extends StatelessWidget {
  const CommunityLogo({super.key, required this.community, this.size = 44, this.preview = true});

  final Community community;
  final double size;

  /// Tapping opens the logo full size (only when there is a logo).
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final avatar = GlassAvatar(
      initials: community.initials,
      size: size,
      photoUrl: community.logoUrl,
      onPhotoError: CommunityService.instance.refreshExpiredLogos,
    );
    if (!preview || community.logoUrl == null) return avatar;
    return Semantics(
      button: true,
      label: 'View ${community.name} logo',
      child: GestureDetector(onTap: () => showCommunityLogo(context, community), child: avatar),
    );
  }
}

/// The community's logo full size over the app: tap outside or Close to go
/// back; pinch to zoom.
Future<void> showCommunityLogo(BuildContext context, Community community) {
  final url = community.logoUrl;
  if (url == null) return Future.value();
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.75),
    transitionDuration: const Duration(milliseconds: 220),
    // Scale only: fading would strip the blur from the glass.
    transitionBuilder: (context, animation, _, child) => ScaleTransition(
      scale: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeIn),
      child: child,
    ),
    pageBuilder: (context, _, _) {
      final side = (MediaQuery.sizeOf(context).width - 48).clamp(0.0, 380.0);
      return SafeArea(
        child: Center(
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: side,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          community.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                      ),
                      GlassIconButton(
                        icon: Icons.close_rounded,
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                GlassPanel(
                  radius: 22,
                  padding: const EdgeInsets.all(6),
                  child: SizedBox.square(
                    dimension: side - 12,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(17),
                      child: InteractiveViewer(
                        maxScale: 4,
                        child: TrueColors(
                          child: _FullLogo(url: url, initials: community.initials),
                        ),
                      ),
                    ),
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

/// The logo at full size. The API's own links are protected, so they're
/// downloaded with the session; other links load directly.
class _FullLogo extends StatefulWidget {
  const _FullLogo({required this.url, required this.initials});

  final String url;
  final String initials;

  @override
  State<_FullLogo> createState() => _FullLogoState();
}

class _FullLogoState extends State<_FullLogo> {
  /// Downloaded once while the preview is open.
  late final Future<Uint8List>? _bytes = ApiClient.isApiLink(widget.url)
      ? ApiClient.instance.download(widget.url)
      : null;

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    final initials = widget.initials;
    final fallback = ColoredBox(
      color: AppColors.white(0.06),
      child: Center(
        child: Text(
          initials,
          style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w700, color: Colors.white),
        ),
      ),
    );
    final bytes = _bytes;
    if (bytes == null) {
      return Image.network(
        url,
        fit: BoxFit.contain,
        headers: ApiClient.instance.imageHeaders(url),
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : const Center(child: CircularProgressIndicator(color: Colors.white)),
        errorBuilder: (_, _, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) => CommunityService.instance.refreshExpiredLogos());
          return fallback;
        },
      );
    }
    return FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(color: Colors.white));
        }
        final data = snap.data;
        if (data == null || data.isEmpty) return fallback;
        return Image.memory(data, fit: BoxFit.contain, errorBuilder: (_, _, _) => fallback);
      },
    );
  }
}
