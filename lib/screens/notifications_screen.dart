import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/notification_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/notification_banner.dart';

/// Every notification the user has received, newest first. Banners vanish
/// after a few seconds; this keeps them.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final _service = NotificationService.instance;

  @override
  void initState() {
    super.initState();
    _service.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _service,
          builder: (context, _) {
            final items = _service.items;
            return Column(
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
                          'NOTIFICATIONS',
                          textAlign: TextAlign.center,
                          style: AppText.heading.copyWith(fontSize: 20),
                        ),
                      ),
                      const SizedBox(width: 44),
                    ],
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    color: AppColors.primary,
                    backgroundColor: Colors.white,
                    onRefresh: _service.load,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 640),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                InlineNotice(message: _service.loadError, tone: NoticeTone.error),
                                if (items.isNotEmpty) ...[
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _service.unread == 0 ? 'All caught up' : '${_service.unread} unread',
                                          style: AppText.caption,
                                        ),
                                      ),
                                      if (_service.unread > 0) ...[
                                        SmallPillButton(label: 'Mark all read', onPressed: _service.markAllRead),
                                        const SizedBox(width: 8),
                                      ],
                                      SmallPillButton(label: 'Clear all', onPressed: _confirmClear),
                                    ],
                                  ),
                                  gap14,
                                ],
                                if (items.isEmpty)
                                  GlassPanel(
                                    radius: 24,
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
                                    child: Column(
                                      children: [
                                        const GlassIconBadge(icon: Icons.notifications_none_rounded, size: 64),
                                        gap14,
                                        const Text('No notifications yet', style: AppText.title),
                                        const SizedBox(height: 6),
                                        Text(
                                          'Updates about your bookings, payments, verification and more show up here.',
                                          style: AppText.caption,
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  )
                                else
                                  for (final n in items) ...[
                                    _NotificationTile(notification: n, onTap: () => _service.markRead(n)),
                                    const SizedBox(height: 10),
                                  ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmClear() async {
    final clear = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: GlassPanel(
          radius: 26,
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('CLEAR ALL?', style: AppText.title, textAlign: TextAlign.center),
              gap14,
              Text(
                'Every notification is deleted. This can\'t be undone.',
                style: AppText.body,
                textAlign: TextAlign.center,
              ),
              gap24,
              PrimaryPillButton(label: 'Clear All', onPressed: () => Navigator.of(context).pop(true)),
              gap8,
              GlassPillButton(label: 'Keep Them', onPressed: () => Navigator.of(context).pop(false)),
            ],
          ),
        ),
      ),
    );
    if (clear == true) await _service.clearAll();
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});

  final AppNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = notification;
    return GlassWell(
      radius: 18,
      active: !n.read,
      fillTop: n.read ? 0 : 0.06,
      fillBottom: n.read ? 0 : 0.03,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GlassIconBadge(icon: notificationIcon(n.type), size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              n.title,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: n.read ? FontWeight.w500 : FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          if (!n.read)
                            Container(
                              width: 8,
                              height: 8,
                              margin: const EdgeInsets.only(left: 8),
                              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                            ),
                        ],
                      ),
                      if (n.body.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(n.body, style: AppText.caption.copyWith(color: AppColors.white(0.85))),
                      ],
                      const SizedBox(height: 6),
                      Text(relativeTime(n.createdAt), style: AppText.caption.copyWith(fontSize: 11.5)),
                    ],
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
