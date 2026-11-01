import 'package:flutter/material.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../services/content_service.dart';
import '../services/dashboard_data.dart';
import '../services/explore_service.dart';
import '../services/rewards_service.dart';
import '../services/session_service.dart';
import '../services/wallet_service.dart';
import '../widgets/content_type_card.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_coverflow.dart';
import '../widgets/liquid_nav_bar.dart';
import 'app_shell.dart';
import 'booking_sheet.dart';
import 'content_tab.dart';
import 'content_viewer.dart' show typeIcon;
import 'explore_tab.dart';
import 'solver_details_screen.dart';

/// Home tab for Problem Seekers.
class SeekerDashboard extends StatefulWidget {
  const SeekerDashboard({super.key, required this.user, required this.onNavigate});

  final AppUser user;

  /// Switches the shell to another tab.
  final ValueChanged<ShellTab> onNavigate;

  @override
  State<SeekerDashboard> createState() => _SeekerDashboardState();
}

class _SeekerDashboardState extends State<SeekerDashboard> {
  /// The content shortcuts, in the order the cards turn.
  static const _contentTypes = [
    ContentType.reel,
    ContentType.blog,
    ContentType.video,
    ContentType.image,
    ContentType.repo,
    ContentType.podcast,
  ];

  DateTime _updatedAt = DateTime.now();
  bool _refreshing = false;

  /// Book Now goes straight into the booking flow for that solver.
  Future<void> _book(Solver solver) async {
    final viewBookings = await showBookingSheet(context, user: widget.user, solver: solver);
    if (viewBookings == true && mounted) widget.onNavigate(ShellTab.bookings);
  }

  @override
  void initState() {
    super.initState();
    // The joined-communities card; failures just leave it empty.
    CommunityService.instance.load(widget.user).catchError((Object _) {});
    // Recommended solvers, upcoming sessions and the wallet card.
    ExploreService.instance.load(widget.user);
    ExploreService.instance.loadBookings(widget.user).catchError((Object _) {});
    WalletService.instance.load(widget.user);
    // The day streak, and again whenever the app comes back.
    RewardsService.instance.loadStreak(widget.user);
    _lifecycle = AppLifecycleListener(onResume: () => RewardsService.instance.loadStreak(widget.user));
  }

  AppLifecycleListener? _lifecycle;

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await Future.wait([
      CommunityService.instance.load(widget.user).catchError((Object _) {}),
      ExploreService.instance.load(widget.user),
      ExploreService.instance.loadBookings(widget.user).catchError((Object _) {}),
      WalletService.instance.load(widget.user),
      RewardsService.instance.loadStreak(widget.user),
    ]);
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _updatedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    final go = widget.onNavigate;
    return RefreshIndicator(
      onRefresh: _refresh,
      color: AppColors.primary,
      backgroundColor: Colors.white,
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, LiquidNavBar.clearance + MediaQuery.paddingOf(context).bottom),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Welcome back, ${widget.user.name}',
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      _StreakChip(user: widget.user),
                      const Spacer(),
                      GlassIconButton(
                        icon: Icons.refresh_rounded,
                        tooltip: 'Refresh',
                        onPressed: _refreshing ? () {} : _refresh,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.schedule_rounded, size: 16, color: AppColors.white(0.72)),
                      const SizedBox(width: 6),
                      Text('Updated ${_clock(_updatedAt)}', style: AppText.caption),
                      if (_refreshing) ...[
                        const SizedBox(width: 10),
                        const SizedBox.square(
                          dimension: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.6, color: Colors.white),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 20),
                  _Section(
                    icon: Icons.trending_up_rounded,
                    title: 'Solvers',
                    onViewAll: () => go(ShellTab.explore),
                    child: ListenableBuilder(
                      listenable: ExploreService.instance,
                      builder: (context, _) {
                        final explore = ExploreService.instance;
                        final solvers = explore.solvers;
                        if (solvers.isEmpty) return const _EmptyNote('No solvers available yet.');
                        return GlassCoverflow(
                          height: 280,
                          flat: true,
                          viewportFraction: 0.9,
                          itemCount: solvers.length,
                          itemBuilder: (context, i, focused) => SolverCard(
                            solver: solvers[i],
                            favorite: explore.isFavorite(widget.user, solvers[i]),
                            onFavorite: () => explore.toggleFavorite(widget.user, solvers[i]),
                            onBook: () => _book(solvers[i]),
                            onView: () => Navigator.of(context).push(
                              glassRoute(
                                SolverDetailsScreen(
                                  user: widget.user,
                                  solver: solvers[i],
                                  onViewBookings: () => go(ShellTab.bookings),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    icon: Icons.videocam_outlined,
                    title: 'Upcoming Sessions',
                    onViewAll: () => go(ShellTab.bookings),
                    child: ListenableBuilder(
                      listenable: Listenable.merge([ExploreService.instance, SessionService.instance]),
                      builder: (context, _) {
                        final sessions = _upcomingSessions();
                        if (sessions.isEmpty) return const _EmptyNote('No upcoming sessions.');
                        return GlassWell(
                          radius: 22,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Column(
                            children: [
                              for (final (i, session) in sessions.indexed) ...[
                                if (i > 0) Container(height: 1, color: AppColors.white(0.12)),
                                _SessionRow(session: session, onTap: () => go(ShellTab.bookings)),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    icon: Icons.play_arrow_outlined,
                    title: 'Content',
                    onViewAll: () => go(ShellTab.content),
                    // The kinds of content as tall cards turning past in 3D.
                    child: GlassCoverflow(
                      height: 230,
                      viewportFraction: 0.42,
                      interval: const Duration(milliseconds: 2600),
                      itemCount: _contentTypes.length,
                      itemBuilder: (context, i, focused) => ContentTypeCard(
                        type: _contentTypes[i],
                        icon: typeIcon(_contentTypes[i]),
                        focused: focused,
                        onTap: () {
                          ContentTab.section.value = _contentTypes[i];
                          go(ShellTab.content);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    icon: Icons.groups_outlined,
                    title: 'Community',
                    onViewAll: () => go(ShellTab.community),
                    child: ListenableBuilder(
                      listenable: CommunityService.instance,
                      builder: (context, _) {
                        final communities = _communities();
                        if (communities.isEmpty) return const _EmptyNote('No communities yet.');
                        return _Carousel(
                          height: 72,
                          itemCount: communities.length,
                          itemBuilder: (context, i) =>
                              _CommunityTile(community: communities[i], onTap: () => go(ShellTab.community)),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The seeker's next two sessions, from their bookings.
  List<SessionSummary> _upcomingSessions() {
    final sessions = SessionService.instance;
    final zone = ExploreService.userZone(widget.user);
    final upcoming = ExploreService.instance
        .bookingsFor(widget.user)
        .where((b) => b.cancellation == null && sessions.phaseOf(b) != SessionPhase.completed)
        .take(2);
    return [
      for (final b in upcoming)
        SessionSummary(
          title: b.title,
          initials: b.solver.initials,
          date: formatDay(zone.wall(b.start)),
          time: formatClock(zone.wall(b.start)),
          duration: '${b.minutes} min',
          photoUrl: ExploreService.instance.solverPhoto(b.solver),
        ),
    ];
  }

  /// Communities the seeker joined, or public ones to discover.
  List<CommunitySummary> _communities() {
    final service = CommunityService.instance;
    final joined = service.joined(widget.user);
    final list = joined.isNotEmpty ? joined : service.publicCommunities;
    return [
      for (final c in list.take(6))
        CommunitySummary(c.name, '${service.memberCount(widget.user, c)} members', Icons.groups_outlined),
    ];
  }

  static String _clock(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$hour:${two(t.minute)}:${two(t.second)} ${t.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// The seeker's day streak, as the server has it.
class _StreakChip extends StatelessWidget {
  const _StreakChip({required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: RewardsService.instance, builder: (context, _) => _chip());
  }

  Widget _chip() {
    final rewards = RewardsService.instance;
    final streak = rewards.streak(user);
    final hint = streak == 0
        ? 'Be active today to start one'
        : rewards.isActive(user, DateTime.now())
        ? 'Keep it up!'
        : 'Be active today to keep it';
    return GlassWell(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_fire_department_outlined, size: 22, color: Colors.white),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$streak Day Streak',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              Text(hint, style: AppText.caption.copyWith(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

/// A floating glass section: icon + title + "View All", then its content.
class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.onViewAll, required this.child});

  final IconData icon;
  final String title;
  final VoidCallback onViewAll;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 28,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 12),
            child: Row(
              children: [
                Icon(icon, size: 24, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
                UnderlineLink(label: 'View All', bold: true, onTap: onViewAll),
                const Icon(Icons.arrow_forward_rounded, size: 16, color: Colors.white),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Text(text, style: AppText.body, textAlign: TextAlign.center),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.onTap});

  final SessionSummary session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GlassAvatar(initials: session.initials, size: 44, photoUrl: session.photoUrl),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.title,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    _Meta(icon: Icons.calendar_today_outlined, text: session.date),
                    _Meta(icon: Icons.schedule_rounded, text: session.time),
                    _Meta(icon: Icons.hourglass_empty_rounded, text: session.duration),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    SmallPillButton(label: 'View', onPressed: onTap),
                    const SizedBox(width: 8),
                    SmallPillButton(label: 'Join Now', primary: true, onPressed: onTap),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Horizontal strip with glass chevrons on either side.
class _Carousel extends StatefulWidget {
  const _Carousel({required this.height, required this.itemCount, required this.itemBuilder});

  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _page(int direction) {
    if (!_controller.hasClients) return;
    final target = (_controller.offset + direction * 220).clamp(0.0, _controller.position.maxScrollExtent);
    _controller.animateTo(target, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    Widget chevron(IconData icon, String label, int direction) => IconButton(
      onPressed: () => _page(direction),
      tooltip: label,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, color: Colors.white),
    );
    return SizedBox(
      height: widget.height,
      child: Row(
        children: [
          chevron(Icons.chevron_left_rounded, 'Scroll left', -1),
          Expanded(
            child: ListView.separated(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              itemCount: widget.itemCount,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: widget.itemBuilder,
            ),
          ),
          chevron(Icons.chevron_right_rounded, 'Scroll right', 1),
        ],
      ),
    );
  }
}

class _CommunityTile extends StatelessWidget {
  const _CommunityTile({required this.community, required this.onTap});

  final CommunitySummary community;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 184,
      child: GlassWell(
        radius: 18,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 42,
                    child: GlassWell(
                      radius: 21,
                      fillTop: 0.06,
                      fillBottom: 0.03,
                      child: Icon(community.icon, size: 20, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          community.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                        ),
                        const SizedBox(height: 2),
                        Text(community.members, style: AppText.caption.copyWith(fontSize: 11.5)),
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

class _Meta extends StatelessWidget {
  const _Meta({required this.text, this.icon});

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 15, color: AppColors.white(0.85)), const SizedBox(width: 4)],
        Text(text, style: TextStyle(fontSize: 12.5, color: AppColors.white(0.85))),
      ],
    );
  }
}
