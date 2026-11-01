import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/notification_service.dart';
import 'glass.dart';
import 'glass_controls.dart';

/// A new notification as a glass banner at the top of the screen. It slides
/// away after [NotificationService.bannerTime]; tap to dismiss it sooner. It
/// stays in the Notifications screen either way.
class NotificationBanner extends StatelessWidget {
  const NotificationBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final service = NotificationService.instance;
    return ValueListenableBuilder<AppNotification?>(
      valueListenable: service.banner,
      builder: (context, n, _) {
        // Glass is animated by moving it, never by fading.
        return IgnorePointer(
          ignoring: n == null,
          child: Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              minimum: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: AnimatedSlide(
                offset: n == null ? const Offset(0, -2) : Offset.zero,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                child: n == null
                    ? const SizedBox(height: 72)
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: _BannerCard(notification: n, onTap: service.dismissBanner),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({required this.notification, required this.onTap});

  final AppNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '${notification.title}. ${notification.body}',
      child: GlassPanel(
        radius: 22,
        padding: EdgeInsets.zero,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
              child: Row(
                children: [
                  GlassIconBadge(icon: notificationIcon(notification.type), size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          notification.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                        if (notification.body.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(notification.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The icon for a notification's kind.
IconData notificationIcon(String type) {
  if (type.startsWith('todo')) return Icons.checklist_rounded;
  if (type.contains('wallet') ||
      type.contains('payment') ||
      type.contains('earning') ||
      type.contains('withdrawal') ||
      type.contains('refund') ||
      type.contains('minute_pack')) {
    return Icons.account_balance_wallet_outlined;
  }
  if (type.contains('subscription')) return Icons.workspace_premium_outlined;
  if (type.contains('booking') || type.contains('session') || type.contains('extension')) {
    return Icons.event_outlined;
  }
  if (type.startsWith('ticket')) return Icons.support_agent_outlined;
  if (type.startsWith('kyc') || type.startsWith('solver.')) return Icons.verified_user_outlined;
  if (type.startsWith('community')) return Icons.groups_outlined;
  if (type.startsWith('content') || type.startsWith('channel')) return Icons.layers_outlined;
  return Icons.notifications_none_rounded;
}
