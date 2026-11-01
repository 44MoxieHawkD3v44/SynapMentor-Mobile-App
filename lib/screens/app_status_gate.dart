import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../services/app_status_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';

/// Sits above the whole app. While the admin has the app under maintenance,
/// a card covers everything and nothing underneath can be used; it goes
/// away by itself when maintenance ends. When a newer version is out, a card
/// offers the update: a required one blocks the app, an optional one can be
/// put off.
class AppStatusGate extends StatefulWidget {
  const AppStatusGate({super.key});

  @override
  State<AppStatusGate> createState() => _AppStatusGateState();
}

class _AppStatusGateState extends State<AppStatusGate> {
  final _status = AppStatusService.instance;
  bool _checking = false;

  Future<void> _retry() async {
    setState(() => _checking = true);
    await _status.checkMaintenance();
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _openStore(AppUpdate update) async {
    final uri = Uri.tryParse(update.downloadUrl);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _status,
      builder: (context, _) {
        final maintenance = _status.maintenance;
        if (maintenance != null) {
          return _Blocking(
            child: _Card(
              icon: Icons.construction_rounded,
              title: 'APP IS UNDER MAINTENANCE',
              message: maintenance,
              note: 'We\'ll be back shortly. The app opens again by itself once we\'re done.',
              actions: [PrimaryPillButton(label: 'Check Again', loading: _checking, onPressed: _retry)],
            ),
          );
        }
        final update = _status.update;
        if (update == null || !_status.showingUpdate) return const SizedBox.shrink();
        final card = _status.prompt
            ? _Card(
                icon: Icons.system_update_rounded,
                title: 'UPDATE TO THE LATEST VERSION',
                message: update.notes.isEmpty
                    ? 'Version ${update.version} is ready with the latest improvements and fixes.'
                    : 'What\'s new in ${update.version}:\n${update.notes}',
                note: update.downloadUrl.isEmpty ? 'The update will be in the store shortly.' : null,
                actions: [
                  PrimaryPillButton(
                    label: 'Update Now',
                    onPressed: update.downloadUrl.isEmpty ? null : () => _openStore(update),
                  ),
                  if (!update.mandatory) ...[
                    gap8,
                    GlassPillButton(label: 'Not Now', onPressed: () => _status.showPrompt(false)),
                  ],
                ],
              )
            : _Card(
                icon: Icons.new_releases_outlined,
                title: update.mandatory ? 'UPDATE REQUIRED' : 'NEW VERSION AVAILABLE',
                message: update.mandatory
                    ? 'A required update is available. Update to keep using Synap Mentor.'
                    : 'Synap Mentor ${update.version} is available.',
                actions: [
                  PrimaryPillButton(label: 'Update', onPressed: () => _status.showPrompt(true)),
                  if (!update.mandatory) ...[gap8, GlassPillButton(label: 'Later', onPressed: _status.dismissUpdate)],
                ],
              );
        return _Blocking(child: card);
      },
    );
  }
}

/// Dims the app and swallows every tap on it, with [child] in the middle.
class _Blocking extends StatelessWidget {
  const _Blocking({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: ModalBarrier(color: Colors.black.withValues(alpha: 0.45), dismissible: false)),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Material(type: MaterialType.transparency, child: child),
            ),
          ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.icon, required this.title, required this.message, required this.actions, this.note});

  final IconData icon;
  final String title;
  final String message;
  final String? note;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 26,
      blur: 5,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: GlassIconBadge(icon: icon, size: 56)),
            gap14,
            Text(title, style: AppText.title, textAlign: TextAlign.center),
            gap8,
            Text(message, style: AppText.body, textAlign: TextAlign.center),
            if (note != null) ...[gap8, Text(note!, style: AppText.caption, textAlign: TextAlign.center)],
            gap24,
            ...actions,
          ],
        ),
      ),
    );
  }
}
