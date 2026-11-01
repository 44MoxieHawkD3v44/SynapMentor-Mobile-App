import 'package:flutter/material.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../services/content_service.dart';
import '../services/explore_service.dart';
import '../services/session_service.dart';
import '../services/solver_service.dart';
import '../services/solver_wallet_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/liquid_nav_bar.dart';
import '../widgets/community_logo.dart';
import 'app_shell.dart';
import 'community_screen.dart';
import 'content_viewer.dart' show compact;
import 'solver_bookings_tab.dart';
import 'solver_content_tab.dart';
import 'solver_payments_tab.dart';

String _when(DateTime t) => '${formatDay(t)} · ${formatClock(t)}';

/// Solver Home: stats, live sessions, recent earnings, their content and the
/// community they run.
class SolverDashboard extends StatelessWidget {
  const SolverDashboard({super.key, required this.user, required this.onNavigate});

  final AppUser user;
  final ValueChanged<ShellTab> onNavigate;

  @override
  Widget build(BuildContext context) {
    final service = SolverService.instance;
    final profile = service.profileFor(user);
    return ListenableBuilder(
      listenable: Listenable.merge([
        CommunityService.instance,
        ContentService.instance,
        SessionService.instance,
        ExploreService.instance,
        SolverService.instance,
        SolverWalletService.instance,
      ]),
      builder: (context, _) {
        final active = ExploreService.instance
            .bookingsForSolver(user)
            .where((b) => b.cancellation == null && SessionService.instance.phaseOf(b) == SessionPhase.live)
            .toList();
        final earnings = SolverWalletService.instance.sessionEarnings(user);
        final content = service.content(user);
        final community = service.community(user);
        return ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, LiquidNavBar.clearance + MediaQuery.paddingOf(context).bottom),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Welcome back,', style: AppText.body),
                    Text(
                      user.name,
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    gap14,
                    Row(
                      children: [
                        Expanded(
                          child: _Stat(Icons.task_alt_rounded, 'Sessions Completed', '${profile?.sessions ?? 0}'),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _Stat(
                            Icons.schedule_rounded,
                            'Earned Synap Minutes',
                            '${SolverWalletService.instance.totalEarned(user)} min',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: _Stat(Icons.star_outline_rounded, 'Rating', profile?.ratingLabel ?? '—')),
                      ],
                    ),
                    gap14,
                    _Section(
                      icon: Icons.videocam_outlined,
                      title: 'Active Sessions',
                      subtitle: 'Your ongoing sessions with seekers',
                      link: 'View All',
                      onLink: () => onNavigate(ShellTab.bookings),
                      children: active.isEmpty
                          ? [const _Empty('No live sessions right now.')]
                          : [for (final b in active.take(2)) SolverBookingCard(user: user, booking: b)],
                    ),
                    gap14,
                    _Section(
                      icon: Icons.payments_outlined,
                      title: 'Recent Earnings',
                      subtitle: 'Your recent session payments',
                      link: 'View Detailed Earnings',
                      onLink: () {
                        onNavigate(ShellTab.payments);
                        SolverPaymentsTab.openHistory.value++;
                      },
                      children: earnings.isEmpty
                          ? [const _Empty('Earnings from completed sessions appear here.')]
                          : [for (final e in earnings.take(2)) _EarningCard(earning: e)],
                    ),
                    gap14,
                    _Section(
                      icon: Icons.menu_book_outlined,
                      title: 'Your Content',
                      subtitle: 'Tutorials and resources you\'ve created',
                      link: 'View All',
                      onLink: () => onNavigate(ShellTab.content),
                      children: [
                        if (content.isEmpty)
                          const _Empty('You haven\'t published any content yet.')
                        else
                          for (final item in content.take(3))
                            _ContentRow(item: item, onTap: () => openOwnContent(context, user, [item], item)),
                      ],
                    ),
                    gap14,
                    _Section(
                      icon: Icons.groups_outlined,
                      title: 'Your Community',
                      subtitle: 'The community you run',
                      children: [
                        if (community == null)
                          const _Empty('You don\'t run a community yet.')
                        else
                          _CommunityCard(
                            user: user,
                            community: community,
                            onOpen: () =>
                                Navigator.of(context)
                                    .push(glassRoute(CommunityScreen(user: user, community: community))),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---- Pieces -----------------------------------------------------------------------------

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.label, this.value);

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 18,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: Colors.white),
          const SizedBox(height: 6),
          Text(label, maxLines: 2, style: AppText.caption.copyWith(fontSize: 11.5, color: AppColors.white(0.85))),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
    this.link,
    this.onLink,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;
  final String? link;
  final VoidCallback? onLink;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, size: 24, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                      Text(subtitle, style: AppText.caption),
                    ],
                  ),
                ),
                if (link != null) ...[
                  UnderlineLink(label: link!, bold: true, onTap: onLink),
                  const Icon(Icons.arrow_forward_rounded, size: 16, color: Colors.white),
                ],
              ],
            ),
          ),
          for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(height: 10), child],
        ],
      ),
    );
  }
}

class _EarningCard extends StatelessWidget {
  const _EarningCard({required this.earning});

  final WalletEntry earning;

  @override
  Widget build(BuildContext context) {
    final e = earning;
    return GlassWell(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                const SizedBox(height: 2),
                Text('${e.seeker} · ${_when(e.at)}', style: AppText.caption.copyWith(fontSize: 12)),
                Text(
                  '${e.sessionMinutes} min session${e.anonymous ? ' · ${ExploreService.anonymousLabel} anonymous' : ''}',
                  style: AppText.caption.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '+${e.minutes} min',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _ContentRow extends StatelessWidget {
  const _ContentRow({required this.item, required this.onTap});

  final ContentItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 18,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                      ),
                      Text('${item.type.label} · published', style: AppText.caption.copyWith(fontSize: 12)),
                    ],
                  ),
                ),
                Text('${compact(item.views)} views', style: AppText.caption),
                const Icon(Icons.chevron_right_rounded, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CommunityCard extends StatelessWidget {
  const _CommunityCard({required this.user, required this.community, required this.onOpen});

  final AppUser user;
  final Community community;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = community;
    final service = CommunityService.instance;
    final events = service.events.where((e) => e.communityId == c.id).length;
    return GlassWell(
      radius: 20,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CommunityLogo(community: c, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                    Text(c.tagline, style: AppText.caption),
                  ],
                ),
              ),
              const _Badge('Owner'),
            ],
          ),
          gap14,
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _Meta(Icons.group_outlined, '${service.memberCount(user, c)} members', AppText.caption),
              _Meta(Icons.forum_outlined, '${c.discussions.length} discussions', AppText.caption),
              _Meta(Icons.event_outlined, '$events events', AppText.caption),
            ],
          ),
          gap14,
          PrimaryPillButton(label: 'Open Community', onPressed: onOpen),
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text, this.style);

  final IconData icon;
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.white(0.85)),
        const SizedBox(width: 5),
        Text(text, style: style),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.white(0.4)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.white),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Text(text, style: AppText.body, textAlign: TextAlign.center),
    );
  }
}
