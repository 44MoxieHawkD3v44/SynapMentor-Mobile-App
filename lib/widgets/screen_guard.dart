import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/screen_protection.dart';
import 'auth_scaffold.dart';
import 'glass.dart';
import 'glass_background.dart';
import 'glass_controls.dart';

/// Sits above the whole app (iOS). While the screen is being recorded or
/// mirrored, the app is hidden behind a card until it stops; after a
/// screenshot, a note says screenshots aren't allowed. Android blocks both
/// itself, so this never shows there.
class ScreenGuard extends StatelessWidget {
  const ScreenGuard({super.key});

  @override
  Widget build(BuildContext context) {
    final protection = ScreenProtection.instance;
    return ListenableBuilder(
      listenable: protection,
      builder: (context, _) {
        if (protection.covered) return const _RecordingCover();
        final note = protection.screenshotTaken;
        // Glass is animated by moving it, never by fading.
        return IgnorePointer(
          child: Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              minimum: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: AnimatedSlide(
                offset: note ? Offset.zero : const Offset(0, -2),
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: GlassPanel(
                    radius: 22,
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Material(
                      type: MaterialType.transparency,
                      child: Row(
                        children: [
                          const Icon(Icons.no_photography_outlined, color: Colors.white, size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Screenshots aren\'t allowed in Synap Mentor. Please respect our solvers\' content.',
                              style: AppText.label.copyWith(fontSize: 13.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Hides everything (the background is solid) and takes every tap.
class _RecordingCover extends StatelessWidget {
  const _RecordingCover();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: GlassBackground()),
        const Positioned.fill(child: ModalBarrier(dismissible: false)),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Material(
                type: MaterialType.transparency,
                child: GlassPanel(
                  radius: 26,
                  blur: 5,
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const GlassIconBadge(icon: Icons.videocam_off_outlined, size: 56),
                      gap14,
                      Text('SCREEN RECORDING ISN\'T ALLOWED', style: AppText.title, textAlign: TextAlign.center),
                      gap8,
                      Text(
                        'Stop recording or mirroring your screen to keep using Synap Mentor. '
                        'The app opens again by itself.',
                        style: AppText.body,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
