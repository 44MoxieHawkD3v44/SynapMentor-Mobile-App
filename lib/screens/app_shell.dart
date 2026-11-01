import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../widgets/app_tour.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/liquid_nav_bar.dart';
import '../widgets/true_colors.dart';
import '../services/explore_service.dart';
import '../services/kyc_service.dart';
import '../services/onboarding_service.dart';
import '../services/solver_service.dart';
import '../services/notification_service.dart';
import '../services/push_notifications.dart';
import '../services/session_service.dart';
import '../services/skill_verification_service.dart';
import '../services/solver_wallet_service.dart';
import '../services/wallet_service.dart';
import 'booking_sheet.dart' show FlowSheetFrame;
import 'bookings_tab.dart';
import 'community_tab.dart';
import 'content_tab.dart';
import 'explore_tab.dart';
import 'kyc_screen.dart';
import 'login_screen.dart';
import 'notifications_screen.dart';
import 'payments_screen.dart';
import 'rewards_screen.dart';
import 'session_screen.dart';
import 'settings_screen.dart';
import 'skill_verification_screen.dart';
import 'solver_bookings_tab.dart';
import 'solver_content_tab.dart';
import 'solver_payments_tab.dart';
import 'solver_home.dart';
import 'support_screen.dart';
import 'todo_screen.dart';
import 'profile_screen.dart';
import 'seeker_dashboard.dart';

enum ShellTab {
  home('Home', Icons.home_outlined),
  explore('Explore', Icons.explore_outlined),
  bookings('Bookings', Icons.event_outlined),
  community('Community', Icons.groups_outlined),
  content('Content', Icons.layers_outlined),

  /// Solvers only.
  payments('Payments', Icons.account_balance_wallet_outlined);

  const ShellTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Entry point of the Seeker screens; Home is the Seeker dashboard.
class SeekerHomeScreen extends StatelessWidget {
  const SeekerHomeScreen({super.key, required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) => AppShell(
    user: user,
    homeBuilder: (onNavigate) => SeekerDashboard(user: user, onNavigate: onNavigate),
    exploreBuilder: (onNavigate) => ExploreTab(user: user, onViewBookings: () => onNavigate(ShellTab.bookings)),
    bookingsBuilder: (_) => BookingsTab(user: user),
    communityBuilder: (_) => CommunityTab(user: user),
    contentBuilder: (onNavigate) => ContentTab(user: user, onViewBookings: () => onNavigate(ShellTab.bookings)),
  );
}

/// Entry point of the Solver screens; Home is the Solver dashboard.
class SolverHomeScreen extends StatelessWidget {
  const SolverHomeScreen({super.key, required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) => AppShell(
    user: user,
    homeBuilder: (onNavigate) => SolverDashboard(user: user, onNavigate: onNavigate),
    bookingsBuilder: (_) => SolverBookingsTab(user: user),
    paymentsBuilder: (_) => SolverPaymentsTab(user: user),
    communityBuilder: (_) => CommunityTab(user: user),
    contentBuilder: (_) => SolverContentTab(user: user),
  );
}

/// Signed-in frame shared by both roles: menu (drawer) top-left, Synap Wallet
/// top-right, tab content, and the floating liquid-glass navigation.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.user,
    required this.homeBuilder,
    this.exploreBuilder,
    this.bookingsBuilder,
    this.communityBuilder,
    this.contentBuilder,
    this.paymentsBuilder,
  });

  final AppUser user;
  final Widget Function(ValueChanged<ShellTab> onNavigate) homeBuilder;

  /// Explore tab body; a placeholder when null.
  final Widget Function(ValueChanged<ShellTab> onNavigate)? exploreBuilder;

  /// Bookings tab body; a placeholder when null.
  final Widget Function(ValueChanged<ShellTab> onNavigate)? bookingsBuilder;

  /// Community tab body; a placeholder when null. Still locked behind KYC.
  final Widget Function(ValueChanged<ShellTab> onNavigate)? communityBuilder;

  /// Content tab body; a placeholder when null.
  final Widget Function(ValueChanged<ShellTab> onNavigate)? contentBuilder;

  /// Payments tab body (solvers); a placeholder when null.
  final Widget Function(ValueChanged<ShellTab> onNavigate)? paymentsBuilder;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  ShellTab _tab = ShellTab.home;

  // What the app tour points at.
  final _menuKey = GlobalKey();
  final _walletKey = GlobalKey();
  final _profileKey = GlobalKey();
  final _bellKey = GlobalKey();
  final _navKey = GlobalKey();
  bool _touring = false;

  String get _account => '${widget.user.role.name}:${widget.user.email}';

  @override
  void initState() {
    super.initState();
    // Notifications and live updates for both roles while signed in.
    NotificationService.instance.start(widget.user);
    // A tapped push notification opens what it's about, also when it started the app.
    PushNotifications.instance.openRequested.addListener(_openFromPush);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openFromPush());
    // First time here: the app tour, once the home screen is laid out.
    AppTourMemory.replay.addListener(_startTour);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!await AppTourMemory.seen(_account) && mounted) _startTour();
    });
    // The mandatory setup (profile, and for solvers availability, KYC and
    // skills) decides what's unlocked.
    OnboardingService.refresh(widget.user).then((_) {
      if (mounted) setState(() {});
    });
    // The solver's home shows their earnings, so the wallet loads up front.
    if (widget.user.role == UserRole.solver) {
      // Anonymous sessions earn the admin-set multiplier.
      ExploreService.instance.loadBookingConfig();
      SolverWalletService.instance.load(widget.user);
      // Booked sessions show on the home screen and in TODO.
      ExploreService.instance.loadSolverBookings(widget.user).catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    AppTourMemory.replay.removeListener(_startTour);
    PushNotifications.instance.openRequested.removeListener(_openFromPush);
    NotificationService.instance.stop();
    super.dispose();
  }

  /// A tapped push: a chat message opens that session (or its chat history once
  /// it's over); anything else opens Notifications.
  Future<void> _openFromPush() async {
    final open = PushNotifications.instance.openRequested;
    final target = open.value;
    if (target == null || !mounted) return;
    open.value = null;
    NotificationService.instance.refreshFromPush();
    final session = target.chatSession;
    if (session != null) {
      final booking = await _bookingWithSession(session);
      if (!mounted) return;
      if (booking != null) {
        final live = SessionService.instance.phaseOf(booking) != SessionPhase.completed && booking.cancellation == null;
        if (live) {
          await Navigator.of(context).push(glassRoute(SessionScreen(user: widget.user, booking: booking)));
        } else {
          await showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black.withValues(alpha: 0.35),
            builder: (_) => ChatLogSheet(booking: booking, asSolver: widget.user.role == UserRole.solver),
          );
        }
        return;
      }
    }
    if (mounted) await Navigator.of(context).push(glassRoute(const NotificationsScreen()));
  }

  /// The user's booking for [sessionId], loading the bookings once if it isn't
  /// known yet.
  Future<Booking?> _bookingWithSession(String sessionId) async {
    final explore = ExploreService.instance;
    final solver = widget.user.role == UserRole.solver;
    Booking? find() => (solver ? explore.bookingsForSolver(widget.user) : explore.bookingsFor(widget.user))
        .where((b) => b.sessionId == sessionId)
        .firstOrNull;
    if (find() case final b?) return b;
    try {
      await (solver ? explore.loadSolverBookings(widget.user) : explore.loadBookings(widget.user));
    } catch (_) {
      return null;
    }
    return find();
  }

  /// The bottom-bar tabs for this role. Solvers have Payments in the middle
  /// instead of Explore.
  List<ShellTab> get _tabs => widget.user.role == UserRole.solver
      ? const [ShellTab.home, ShellTab.bookings, ShellTab.payments, ShellTab.community, ShellTab.content]
      : const [ShellTab.home, ShellTab.explore, ShellTab.bookings, ShellTab.community, ShellTab.content];

  void _go(ShellTab tab) => setState(() => _tab = tab);

  /// The tour runs on Home, where the menu and the main bar are.
  void _startTour() {
    if (!mounted) return;
    setState(() => _tab = ShellTab.home);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _touring = true);
    });
  }

  void _endTour() {
    setState(() => _touring = false);
    AppTourMemory.markSeen(_account);
  }

  /// A tab's place in the main bar; the bar gives every tab the same width.
  Rect? _tabRect(ShellTab tab) {
    final bar = rectOf(_navKey)?.deflate(6);
    final i = _tabs.indexOf(tab);
    if (bar == null || i < 0) return null;
    final w = bar.width / _tabs.length;
    return Rect.fromLTWH(bar.left + w * i, bar.top, w, bar.height);
  }

  List<TourStep> get _tourSteps {
    final solver = widget.user.role == UserRole.solver;
    TourStep tab(ShellTab t, String body) =>
        TourStep(title: t.label, body: body, icon: t.icon, target: () => _tabRect(t));
    return [
      TourStep(
        title: 'Welcome to Synap Mentor',
        body: solver
            ? 'A quick look around: where to find your sessions, earnings, content and settings. It takes under a minute.'
            : 'A quick look around: how to find solvers, book sessions and get help. It takes under a minute.',
        icon: Icons.waving_hand_outlined,
      ),
      TourStep(
        title: 'Menu',
        body: solver
            ? 'Your profile, notifications, Skill and KYC Verification, TODO, Settings and Support live here.'
            : 'Your profile, notifications, verification, rewards, TODO, Settings and Support live here.',
        icon: Icons.menu_rounded,
        target: () => rectOf(_menuKey),
      ),
      if (!solver)
        TourStep(
          title: 'Synap Wallet',
          body: 'Your minutes balance. Buy minute packs or a subscription, and see every payment.',
          icon: Icons.account_balance_wallet_outlined,
          target: () => rectOf(_walletKey),
        ),
      TourStep(
        title: 'Notifications',
        body: 'Updates about your bookings, payments and more. A red dot means something new.',
        icon: Icons.notifications_none_rounded,
        target: () => rectOf(_bellKey),
      ),
      TourStep(
        title: 'Profile',
        body: solver
            ? 'Complete your profile and set your pricing, expertise, availability and booking links.'
            : 'Complete your profile so solvers know who they\'re helping.',
        icon: Icons.person_outline_rounded,
        target: () => rectOf(_profileKey),
      ),
      tab(
        ShellTab.home,
        solver
            ? 'Your dashboard: today\'s sessions, earnings and what needs your attention.'
            : 'Your dashboard: upcoming sessions and quick actions.',
      ),
      if (!solver) tab(ShellTab.explore, 'Find solvers by skill, see their reviews and book a session.'),
      tab(
        ShellTab.bookings,
        solver
            ? 'Sessions booked with you. Join the live meeting or chat when it\'s time.'
            : 'Your sessions: join the live meeting or chat, reschedule, and leave reviews.',
      ),
      if (solver) tab(ShellTab.payments, 'Your earned minutes, payment methods and withdrawals.'),
      tab(ShellTab.community, 'Join communities, start threads and learn with others.'),
      tab(
        ShellTab.content,
        solver
            ? 'Publish blogs, videos and podcasts, and see how they perform.'
            : 'Blogs, videos and podcasts from solvers.',
      ),
      const TourStep(
        title: 'You\'re all set',
        body: 'You can take this tour again anytime from Settings.',
        icon: Icons.check_circle_outline_rounded,
      ),
    ];
  }

  Future<void> _openProfile({bool availability = false}) async {
    // Solvers get the same screen with their extra tabs.
    final Widget page = ProfileScreen(user: widget.user, openAvailability: availability);
    await Navigator.of(context).push(glassRoute(page));
    // Name changes show up in the dashboard and the drawer.
    if (mounted) setState(() {});
    await _afterSetupStep();
  }

  Future<void> _openVerification() async {
    // Solvers get the same screen with email and mobile verification first.
    await Navigator.of(context).push(glassRoute(KycScreen(user: widget.user)));
    await _afterSetupStep();
  }

  // ---- Mandatory setup -------------------------------------------------------------

  Onboarding get _onboarding => OnboardingService.of(widget.user);

  /// Opens the next setup step.
  Future<void> _continueSetup() async {
    switch (_onboarding.next) {
      case OnboardingStep.profile:
        await _openProfile();
      case OnboardingStep.availability:
        await _openProfile(availability: true);
      case OnboardingStep.kyc:
        await _openVerification();
      case OnboardingStep.skills:
        await Navigator.of(context).push(glassRoute(SkillVerificationScreen(user: widget.user)));
        await _afterSetupStep();
      case null:
        break;
    }
  }

  /// Back from a setup step: picks up what changed. A seeker whose profile is
  /// now complete is offered KYC once; it's their choice.
  Future<void> _afterSetupStep() async {
    await OnboardingService.refresh(widget.user);
    if (!mounted) return;
    setState(() {});
    if (widget.user.role != UserRole.seeker || _onboarding.next != null) return;
    if (await OnboardingService.kycOffered(widget.user) || !mounted) return;
    if (KycService.instance.stateFor(widget.user).completed) return;
    await OnboardingService.markKycOffered(widget.user);
    if (!mounted) return;
    final verify = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => const _KycOfferSheet(),
    );
    if (verify == true && mounted) await _openVerification();
  }

  /// What a seeker must do before a tab opens, or null when it's open.
  /// Content needs KYC and a subscription. Community is open for now (KYC
  /// temporarily not required). Bookings stay open: the booking flow itself
  /// requires KYC for everything except anonymous bookings, and anonymous
  /// bookers still see their sessions.
  ///
  /// Solvers can't take bookings until both KYC and Skill Verification are
  /// complete.
  _TabLock? _lockFor(ShellTab tab) {
    final setup = _onboarding;
    if (setup.locked && tab != ShellTab.home) {
      return (
        message: switch (setup.next!) {
          OnboardingStep.profile => 'Complete your profile to use ${tab.label}.',
          OnboardingStep.availability => 'Set your availability to use ${tab.label}.',
          OnboardingStep.kyc => 'Complete KYC verification to use ${tab.label}.',
          OnboardingStep.skills => 'Verify a skill to use ${tab.label}.',
        },
        actionLabel: switch (setup.next!) {
          OnboardingStep.profile => 'Complete Profile',
          OnboardingStep.availability => 'Set Availability',
          OnboardingStep.kyc => 'Verify KYC',
          OnboardingStep.skills => 'Verify Skills',
        },
        onAction: _continueSetup,
      );
    }
    if (kEnforceVerification && widget.user.role == UserRole.solver && tab == ShellTab.bookings) {
      final kycDone = KycService.instance.stateFor(widget.user).completed;
      final skillsDone = SkillVerificationService.instance.verifiedSkills(widget.user).isNotEmpty;
      if (kycDone && skillsDone) return null;
      return (
        message:
            'Complete ${kycDone ? 'Skill Verification' : (skillsDone ? 'KYC Verification' : 'KYC and Skill Verification')} '
            'to access bookings.',
        actionLabel: kycDone ? 'Verify Skills' : 'Verify KYC',
        onAction: kycDone
            ? () => Navigator.of(context).push(glassRoute(SkillVerificationScreen(user: widget.user)))
            : _openVerification,
      );
    }
    // No tab-level locks for seekers for now: KYC isn't required for
    // Community or Content, and Content enforces Premium access and the
    // daily free minutes itself.
    return null;
  }

  void _openSupport() => Navigator.of(context).push(glassRoute(SupportScreen(user: widget.user)));

  /// A seeker's wallet; solvers have the Payments tab instead.
  void _openPayments([PaymentsTab tab = PaymentsTab.overview]) =>
      Navigator.of(context)
          .push(glassRoute(PaymentsScreen(user: widget.user, initialTab: tab, onContactSupport: _openSupport)));

  /// The screen of an unlocked tab other than Home.
  Widget _tabBody(ShellTab tab) {
    final builder = switch (tab) {
      ShellTab.home => widget.homeBuilder,
      ShellTab.explore => widget.exploreBuilder,
      ShellTab.bookings => widget.bookingsBuilder,
      ShellTab.community => widget.communityBuilder,
      ShellTab.content => widget.contentBuilder,
      ShellTab.payments => widget.paymentsBuilder,
    };
    return builder?.call(_go) ?? const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back from a secondary tab returns to Home rather than leaving the app.
      canPop: _tab == ShellTab.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(ShellTab.home);
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // Light scrim: the drawer glass does the real separation, and together
        // they leave the app behind the menu at roughly 65% brightness.
        drawerScrimColor: AppColors.primary.withValues(alpha: 0.25),
        drawer: _GlassDrawer(
          user: widget.user,
          onOpenProfile: _openProfile,
          onOpenVerification: _openVerification,
          onOpenSupport: _openSupport,
          // Only in the seeker's menu.
          onOpenRewards: () => Navigator.of(context).push(glassRoute(RewardsScreen(user: widget.user))),
          onOpenSettings: () => Navigator.of(context).push(glassRoute(SettingsScreen(user: widget.user))),
        ),
        body: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _TopBar(
                    menuKey: _menuKey,
                    walletKey: _walletKey,
                    profileKey: _profileKey,
                    bellKey: _bellKey,
                    onOpenProfile: _openProfile,
                    // Solvers reach payments from the bottom bar instead.
                    onOpenWallet: widget.user.role == UserRole.solver
                        ? null
                        : () => _onboarding.locked ? _continueSetup() : _openPayments(),
                    onBack: _tab == ShellTab.home ? null : () => _go(ShellTab.home),
                  ),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: Listenable.merge([
                        KycService.instance,
                        WalletService.instance,
                        SkillVerificationService.instance,
                        SolverService.instance,
                      ]),
                      builder: (context, _) => IndexedStack(
                        index: _tabs.indexOf(_tab),
                        children: [
                          // Solvers aren't shown the setup card; their locked
                          // tabs still lead to the next step.
                          _onboarding.locked && widget.user.role != UserRole.solver
                              ? Column(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                                      child: _SetupCard(
                                        user: widget.user,
                                        setup: _onboarding,
                                        onContinue: _continueSetup,
                                      ),
                                    ),
                                    Expanded(child: widget.homeBuilder(_go)),
                                  ],
                                )
                              : widget.homeBuilder(_go),
                          for (final tab in _tabs.skip(1))
                            if (_lockFor(tab) case final lock?)
                              _LockedTab(icon: tab.icon, title: tab.label, lock: lock)
                            else
                              _tabBody(tab),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // The main bar belongs to Home only; the other tabs are full screens
            // with a back arrow (and Content brings its own section bar).
            if (_tab == ShellTab.home)
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.only(bottom: 14),
                  child: LiquidNavBar(
                    key: _navKey,
                    items: [for (final tab in _tabs) LiquidNavItem(tab.label, tab.icon)],
                    currentIndex: _tabs.indexOf(_tab),
                    onSelected: (i) => _go(_tabs[i]),
                  ),
                ),
              ),
            if (_touring)
              Positioned.fill(
                child: AppTour(steps: _tourSteps, onDone: _endTour),
              ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onOpenProfile,
    this.onOpenWallet,
    this.onBack,
    this.menuKey,
    this.walletKey,
    this.profileKey,
    this.bellKey,
  });

  final VoidCallback onOpenProfile;
  final Key? bellKey;

  /// Where the app tour finds the menu, wallet and profile buttons.
  final Key? menuKey;
  final Key? walletKey;
  final Key? profileKey;

  /// Null hides the Synap Wallet button.
  final VoidCallback? onOpenWallet;

  /// Set on secondary tabs: shows a back arrow (to Home) instead of the menu.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          onBack != null
              ? GlassIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back to Home', onPressed: onBack!)
              : GlassIconButton(
                  key: menuKey,
                  icon: Icons.menu_rounded,
                  tooltip: 'Menu',
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
          const Spacer(),
          if (onOpenWallet != null) ...[
            GlassIconButton(
              key: walletKey,
              icon: Icons.account_balance_wallet_outlined,
              tooltip: 'Synap Wallet',
              onPressed: onOpenWallet!,
            ),
            const SizedBox(width: 8),
          ],
          _NotificationBell(key: bellKey),
          const SizedBox(width: 8),
          GlassIconButton(
            key: profileKey,
            icon: Icons.person_outline_rounded,
            tooltip: 'Profile',
            onPressed: onOpenProfile,
          ),
        ],
      ),
    );
  }
}

/// Opens Notifications; a red dot shows while any are unread.
class _NotificationBell extends StatelessWidget {
  const _NotificationBell({super.key});

  @override
  Widget build(BuildContext context) {
    final service = NotificationService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final unread = service.unread;
        return Semantics(
          label: unread > 0 ? 'Notifications, $unread unread' : 'Notifications',
          button: true,
          excludeSemantics: true,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              GlassIconButton(
                icon: Icons.notifications_none_rounded,
                tooltip: 'Notifications',
                onPressed: () => Navigator.of(context).push(glassRoute(const NotificationsScreen())),
              ),
              if (unread > 0)
                Positioned(
                  top: 9,
                  right: 10,
                  child: IgnorePointer(
                    // Stays red in light mode too.
                    child: TrueColors(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF3B30),
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.primary, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _GlassDrawer extends StatelessWidget {
  const _GlassDrawer({
    required this.user,
    required this.onOpenProfile,
    required this.onOpenVerification,
    required this.onOpenSupport,
    required this.onOpenRewards,
    required this.onOpenSettings,
  });

  final AppUser user;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenVerification;
  final VoidCallback onOpenSupport;
  final VoidCallback onOpenRewards;
  final VoidCallback onOpenSettings;

  static const _seekerItems = [
    ('Profile', Icons.person_outline_rounded),
    ('Notifications', Icons.notifications_none_rounded),
    ('Verification', Icons.verified_user_outlined),
    ('Rewards', Icons.card_giftcard_outlined),
    ('TODO', Icons.checklist_rounded),
    ('Settings', Icons.settings_outlined),
    ('Support', Icons.support_agent_outlined),
  ];

  static const _solverItems = [
    ('Profile', Icons.person_outline_rounded),
    ('Notifications', Icons.notifications_none_rounded),
    ('Skill Verification', Icons.workspace_premium_outlined),
    ('KYC Verification', Icons.verified_user_outlined),
    ('TODO', Icons.checklist_rounded),
    ('Settings', Icons.settings_outlined),
    ('Support', Icons.support_agent_outlined),
  ];

  List<(String, IconData)> get _items => user.role == UserRole.solver ? _solverItems : _seekerItems;

  void _open(BuildContext context, String title) {
    final navigator = Navigator.of(context);
    navigator.pop(); // close the drawer
    if (title == 'Profile') return onOpenProfile();
    if (title == 'Verification' || title == 'KYC Verification') return onOpenVerification();
    if (title == 'Support') return onOpenSupport();
    if (title == 'Rewards') return onOpenRewards();
    if (title == 'Settings') return onOpenSettings();
    if (title == 'Notifications') {
      navigator.push(glassRoute(const NotificationsScreen()));
      return;
    }
    if (title == 'TODO') {
      navigator.push(glassRoute(TodoScreen(user: user)));
      return;
    }
    if (title == 'Skill Verification') navigator.push(glassRoute(SkillVerificationScreen(user: user)));
  }

  void _logout(BuildContext context) {
    AuthService.instance.signOut();
    Navigator.of(context).pushAndRemoveUntil(glassRoute(const LoginScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final initials = user.name.trim().split(RegExp(r'\s+')).take(2).map((p) => p[0].toUpperCase()).join();
    return Drawer(
      width: math.min(320, MediaQuery.sizeOf(context).width * 0.84),
      backgroundColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
      // The menu runs the full height of the screen, docked to the left edge;
      // its content stays clear of the status and navigation bars.
      child: SizedBox.expand(
        // Stronger separation than other glass: whatever passes behind the
        // menu is dimmed, compressed in contrast and softened, so it always
        // reads as a layer behind the sharp menu content.
        child: GlassPanel(
          radius: 30,
          squareLeft: true,
          blur: 6,
          dim: 0.8,
          contrast: 0.58,
          tintTop: 0.18,
          tintBottom: 0.25,
          rimTop: 0.35,
          rimBottom: 0.08,
          padding: EdgeInsets.fromLTRB(
            14,
            MediaQuery.paddingOf(context).top + 28,
            14,
            MediaQuery.paddingOf(context).bottom + 14,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    GlassAvatar(initials: initials, size: 52, photoPath: user.profile.photoPath),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                          const SizedBox(height: 2),
                          Text(user.role.label, style: AppText.caption),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              gap24,
              Container(height: 1, color: AppColors.white(0.14)),
              gap8,
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    for (final (label, icon) in _items)
                      if (label == 'Notifications')
                        ListenableBuilder(
                          listenable: NotificationService.instance,
                          builder: (context, _) => _DrawerTile(
                            icon: icon,
                            label: label,
                            count: NotificationService.instance.unread,
                            onTap: () => _open(context, label),
                          ),
                        )
                      else
                        _DrawerTile(icon: icon, label: label, onTap: () => _open(context, label)),
                  ],
                ),
              ),
              Container(height: 1, color: AppColors.white(0.14)),
              gap8,
              _DrawerTile(icon: Icons.logout_rounded, label: 'Logout', chevron: false, onTap: () => _logout(context)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.chevron = true,
    this.count = 0,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool chevron;

  /// Shown as a badge when above zero, e.g. unread notifications.
  final int count;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        highlightColor: AppColors.white(0.08),
        splashColor: AppColors.white(0.1),
        hoverColor: AppColors.white(0.06),
        focusColor: AppColors.white(0.12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 22, color: Colors.white),
              const SizedBox(width: 14),
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 15, color: Colors.white)),
              ),
              if (count > 0)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.primary),
                  ),
                ),
              if (chevron) Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.white(0.6)),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _TabLock = ({String message, String actionLabel, VoidCallback onAction});

/// A seeker's mandatory setup on Home: how complete the profile is and
/// exactly what's still missing.
class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.user, required this.setup, required this.onContinue});

  final AppUser user;
  final Onboarding setup;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final total = OnboardingService.profileChecklist(user).length;
    final percent = setup.profilePercent(total);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
      child: GlassPanel(
        radius: 24,
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const GlassIconBadge(icon: Icons.task_alt_rounded, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Complete your profile',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                        Text(
                          'Fill in your profile to start using Synap Mentor.',
                          style: AppText.caption.copyWith(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              gap14,
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: percent / 100,
                        minHeight: 6,
                        backgroundColor: AppColors.white(0.14),
                        valueColor: const AlwaysStoppedAnimation(Colors.white),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '$percent%',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ],
              ),
              gap8,
              Text('Still needed:', style: AppText.caption.copyWith(fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final item in setup.missingProfile)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppColors.white(0.35)),
                      ),
                      child: Text(item, style: const TextStyle(fontSize: 12, color: Colors.white)),
                    ),
                ],
              ),
              gap14,
              PrimaryPillButton(label: 'Complete Profile', onPressed: onContinue),
            ],
          ),
        ),
      ),
    );
  }
}

/// Offered once to a seeker whose profile is complete. Verifying is their
/// choice; it can be done later from the menu.
class _KycOfferSheet extends StatelessWidget {
  const _KycOfferSheet();

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Profile complete',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: GlassIconBadge(icon: Icons.verified_user_outlined, size: 64)),
          gap14,
          Text(
            'Next, you can verify your identity (KYC). It unlocks every booking type and keeps your account '
            'secure. You can do it now, or later from the menu under Verification.',
            style: AppText.body,
            textAlign: TextAlign.center,
          ),
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Later', onPressed: () => Navigator.of(context).pop(false)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: 'Verify Now', onPressed: () => Navigator.of(context).pop(true)),
          ),
        ],
      ),
    );
  }
}

/// A tab that's locked until a setup step is done, with the action that
/// unlocks it.
class _LockedTab extends StatelessWidget {
  const _LockedTab({required this.icon, required this.title, required this.lock});

  final IconData icon;
  final String title;
  final _TabLock lock;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, LiquidNavBar.clearance + MediaQuery.paddingOf(context).bottom),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: GlassPanel(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlassIconBadge(icon: icon, size: 72),
                gap24,
                Text(title.toUpperCase(), style: AppText.heading.copyWith(fontSize: 22), textAlign: TextAlign.center),
                gap8,
                Text(lock.message, style: AppText.body, textAlign: TextAlign.center),
                gap24,
                GlassFormColumn(
                  children: [PrimaryPillButton(label: lock.actionLabel, onPressed: lock.onAction)],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
