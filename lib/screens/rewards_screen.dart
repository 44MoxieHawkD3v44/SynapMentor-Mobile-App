import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/kyc_service.dart';
import '../services/rewards_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import 'booking_sheet.dart';
import 'kyc_screen.dart';
import 'support_screen.dart';

enum _Tab {
  overview('Overview', Icons.bar_chart_rounded),
  activity('Recent Activity', Icons.history_rounded),
  referrals('Referrals', Icons.group_add_outlined),
  streaks('Streaks', Icons.local_fire_department_outlined);

  const _Tab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Reward points: overview and conversion to minutes, verification rewards,
/// referrals and daily streaks, all in one screen.
class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key, required this.user});

  final AppUser user;

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen> {
  final _rewards = RewardsService.instance;
  final _points = TextEditingController();

  _Tab _tab = _Tab.overview;
  bool _converting = false;
  String? _pointsError;
  String? _notice;
  NoticeTone _noticeTone = NoticeTone.success;

  AppUser get _user => widget.user;

  @override
  void initState() {
    super.initState();
    // KYC state decides the verification rewards, so both are loaded.
    _rewards.load(_user);
    KycService.instance.refresh(_user).catchError((Object _) {});
  }

  @override
  void dispose() {
    _points.dispose();
    super.dispose();
  }

  void _say(String message, {NoticeTone tone = NoticeTone.success}) => setState(() {
    _notice = message;
    _noticeTone = tone;
  });

  Future<void> _convert() async {
    final points = int.tryParse(_points.text.trim());
    final rate = _rewards.config.pointsPerMinute;
    setState(() {
      _pointsError = points == null || points <= 0 || points % rate != 0 ? 'Enter points in multiples of $rate.' : null;
      _notice = null;
    });
    if (_pointsError != null) return;
    FocusScope.of(context).unfocus();
    setState(() => _converting = true);
    try {
      final minutes = await _rewards.convert(_user, points!);
      _points.clear();
      _say(
        'Converted $points points to $minutes Synap ${minutes == 1 ? 'Minute' : 'Minutes'}. '
        'They\'re in your Synap Wallet.',
      );
    } on AuthException catch (e) {
      if (mounted) setState(() => _pointsError = e.message);
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) _say('$label copied.');
  }

  String get _shareMessage =>
      'Join me on Synap Mentor, where problem seekers meet the solvers who can crack them. '
      'Use my referral code ${_rewards.referralCodeFor(_user)}: ${_rewards.referralLinkFor(_user)}';

  Future<void> _shareTo(String app, Uri uri) async {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) _say('Couldn\'t open $app. Tap More to share another way.', tone: NoticeTone.error);
  }

  Future<void> _shareMore() =>
      SharePlus.instance.share(ShareParams(text: _shareMessage, subject: 'Join me on Synap Mentor'));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
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
                    child: Text('REWARDS', textAlign: TextAlign.center, style: AppText.heading.copyWith(fontSize: 20)),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([_rewards, KycService.instance]),
                builder: (context, _) => ListView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                for (final tab in _Tab.values) ...[
                                  if (tab != _Tab.values.first) const SizedBox(width: 8),
                                  Expanded(
                                    child: GlassOption(
                                      height: 66,
                                      radius: 18,
                                      selected: _tab == tab,
                                      onTap: () => setState(() {
                                        _tab = tab;
                                        _notice = null;
                                      }),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(tab.icon, size: 20, color: Colors.white),
                                          const SizedBox(height: 5),
                                          FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(tab.label, style: AppText.label.copyWith(fontSize: 12.5)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            gap14,
                            InlineNotice(message: _notice, tone: _noticeTone),
                            InlineNotice(message: _rewards.loadError, tone: NoticeTone.error),
                            StepSwitcher(
                              child: KeyedSubtree(
                                key: ValueKey(_tab),
                                child: switch (_tab) {
                                  _Tab.overview => _buildOverview(),
                                  _Tab.activity => _buildActivity(),
                                  _Tab.referrals => _buildReferrals(),
                                  _Tab.streaks => _StreakView(user: _user),
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Overview ------------------------------------------------------------------

  Widget _buildOverview() {
    final config = _rewards.config;
    final available = _rewards.available(_user);
    final bookings = _rewards.bookingCount(_user);
    final nextMilestone = (config.bookingMilestones.keys.where((k) => k > bookings).toList()..sort()).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GlassPanel(
          radius: 24,
          padding: EdgeInsets.all(16),
          child: _Heading(
            icon: Icons.card_giftcard_outlined,
            title: 'Points & Benefits',
            subtitle: 'Earn points as you use Synap Mentor and convert them into Synap Minutes.',
          ),
        ),
        gap14,
        Row(
          children: [
            Expanded(child: _Stat(Icons.stars_outlined, '${_rewards.totalEarned(_user)}', 'Total Points Earned')),
            const SizedBox(width: 10),
            Expanded(child: _Stat(Icons.account_balance_wallet_outlined, '$available', 'Available Points')),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _Stat(Icons.redeem_outlined, '${_rewards.redeemed(_user)}', 'Points Redeemed')),
            const SizedBox(width: 10),
            Expanded(child: _Stat(Icons.local_fire_department_outlined, '${_rewards.streak(_user)}', 'Day Streak')),
          ],
        ),
        gap14,
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Convert Points to Minutes', style: _heading),
              const SizedBox(height: 4),
              Text(
                '${config.pointsPerMinute} points = 1 Synap Minute · $available points available',
                style: AppText.caption,
              ),
              gap14,
              GlassTextField(
                controller: _points,
                hint: 'Points to convert (multiples of ${config.pointsPerMinute})',
                icon: Icons.stars_outlined,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                errorText: _pointsError,
                onChanged: (_) {
                  if (_pointsError != null) setState(() => _pointsError = null);
                },
              ),
              gap14,
              PrimaryPillButton(
                label: 'Convert',
                loading: _converting,
                onPressed: available < config.pointsPerMinute ? null : _convert,
              ),
            ],
          ),
        ),
        gap24,
        const Text('Ways to Earn', style: _heading),
        gap14,
        // Points come from the admin's settings; no stand-in numbers.
        if (!_rewards.configLoaded)
          Text(_rewards.loadError ?? 'Loading…', style: AppText.caption)
        else
          _EarnCarousel(
            ways: [
              _EarnWay(
                icon: Icons.verified_user_outlined,
                title: 'Complete Verification',
                subtitle: 'Earn up to ${config.verificationTotal} points',
                onTap: () => Navigator.of(context).push(glassRoute(KycScreen(user: _user))),
              ),
              _EarnWay(
                icon: Icons.group_add_outlined,
                title: 'Invite Friends',
                subtitle: '${config.referral} points when a friend books their first session',
                onTap: () => setState(() => _tab = _Tab.referrals),
              ),
              _EarnWay(
                icon: Icons.local_fire_department_outlined,
                title: 'Keep Your Streak',
                subtitle: 'Earn points for weekly, monthly and yearly streaks',
                onTap: () => setState(() => _tab = _Tab.streaks),
              ),
              _EarnWay(
                icon: Icons.report_gmailerrorred_outlined,
                title: 'Report Issues',
                subtitle: '${config.validatedReport} points per validated report',
                onTap: () => Navigator.of(context).push(glassRoute(SupportScreen(user: _user))),
              ),
              _EarnWay(
                icon: Icons.emoji_events_outlined,
                title: 'Booking Milestones',
                subtitle: nextMilestone == null
                    ? 'All milestones reached. $bookings bookings!'
                    : '$bookings of $nextMilestone bookings · +${config.bookingMilestones[nextMilestone]} points next',
              ),
            ],
          ),
      ],
    );
  }

  // ---- Verification --------------------------------------------------------------

  /// Every points movement, newest first.
  Widget _buildActivity() {
    final activity = _rewards.activity(_user);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Recent Activity', style: _heading),
        gap14,
        if (activity.isEmpty)
          Text('No reward activity yet.', style: AppText.body, textAlign: TextAlign.center)
        else
          for (final entry in activity) ...[
            GlassWell(
              radius: 18,
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(
                    entry.points > 0 ? Icons.check_circle_outline_rounded : Icons.swap_horiz_rounded,
                    size: 22,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white),
                        ),
                        Text(
                          '${formatDay(entry.date)}, ${formatClock(entry.date)}',
                          style: AppText.caption.copyWith(fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${entry.points > 0 ? '+' : ''}${entry.points}\npoints',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  // ---- Referrals -----------------------------------------------------------------

  Widget _buildReferrals() {
    final config = _rewards.config;
    final code = _rewards.referralCodeFor(_user);
    final link = _rewards.referralLinkFor(_user);
    final referrals = _rewards.referrals(_user);
    final successful = referrals.where((r) => r.rewarded).length;
    final message = Uri.encodeComponent(_shareMessage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Referral Program', style: _heading),
              const SizedBox(height: 4),
              Text(
                'Invite friends and earn ${config.referral} points for each friend who books a session.',
                style: AppText.caption,
              ),
              gap14,
              Row(
                children: [
                  Expanded(child: _Stat(Icons.group_outlined, '$successful', 'Successful Referrals', compact: true)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _Stat(
                      Icons.stars_outlined,
                      '${successful * config.referral}',
                      'Points Earned',
                      compact: true,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _Stat(
                      Icons.hourglass_empty_rounded,
                      '${referrals.length - successful}',
                      'Pending Invites',
                      compact: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        gap14,
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Your Referral Code & Link', style: _heading),
              const SizedBox(height: 4),
              Text(
                'You\'ll earn ${config.referral} points only after your invitee books their first session, '
                'not at signup.',
                style: AppText.caption,
              ),
              gap14,
              const Text('Referral Code', style: _label),
              gap8,
              _CopyField(value: code, onCopy: () => _copy('Referral code', code)),
              gap14,
              const Text('Referral Link', style: _label),
              gap8,
              _CopyField(value: link, onCopy: () => _copy('Referral link', link)),
              gap24,
              const Text('Share via', style: _label),
              gap8,
              OptionGrid(
                spacing: 8,
                children: [
                  _ShareButton(
                    Icons.chat_outlined,
                    'WhatsApp',
                    () => _shareTo('WhatsApp', Uri.parse('https://wa.me/?text=$message')),
                  ),
                  _ShareButton(
                    Icons.work_outline_rounded,
                    'LinkedIn',
                    () => _shareTo(
                      'LinkedIn',
                      Uri.parse('https://www.linkedin.com/sharing/share-offsite/?url=${Uri.encodeComponent(link)}'),
                    ),
                  ),
                  _ShareButton(
                    Icons.alternate_email_rounded,
                    'X (Twitter)',
                    () => _shareTo('X', Uri.parse('https://twitter.com/intent/tweet?text=$message')),
                  ),
                  _ShareButton(
                    Icons.send_outlined,
                    'Telegram',
                    () => _shareTo(
                      'Telegram',
                      Uri.parse('https://t.me/share/url?url=${Uri.encodeComponent(link)}&text=$message'),
                    ),
                  ),
                  _ShareButton(
                    Icons.mail_outline_rounded,
                    'Email',
                    () => _shareTo(
                      'your email app',
                      Uri.parse('mailto:?subject=${Uri.encodeComponent('Join me on Synap Mentor')}&body=$message'),
                    ),
                  ),
                  _ShareButton(Icons.ios_share_rounded, 'More', _shareMore),
                ],
              ),
            ],
          ),
        ),
        gap14,
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Recent Referrals', style: _heading),
              gap8,
              if (referrals.isEmpty)
                Text('No referrals yet. Share your code above to start earning.', style: AppText.caption)
              else
                for (final r in referrals)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        GlassAvatar(initials: r.name.isEmpty ? '?' : r.name[0].toUpperCase(), size: 36),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.name, style: AppText.label.copyWith(fontSize: 14)),
                              Text('Joined ${formatDay(r.joinedAt)}', style: AppText.caption.copyWith(fontSize: 11.5)),
                            ],
                          ),
                        ),
                        _Badge(r.rewarded ? '+${config.referral} points' : 'Pending first booking'),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  static const _heading = TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: Colors.white);
  static const _label = TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white);
}

// ---- Streaks ---------------------------------------------------------------------------

class _StreakView extends StatefulWidget {
  const _StreakView({required this.user});

  final AppUser user;

  @override
  State<_StreakView> createState() => _StreakViewState();
}

class _StreakViewState extends State<_StreakView> with SingleTickerProviderStateMixin {
  final _rewards = RewardsService.instance;
  late final AnimationController _celebrate = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  /// While celebrating, the count starts one below and ticks up.
  late int _shown = _rewards.streak(widget.user);
  bool _celebrating = false;

  @override
  void initState() {
    super.initState();
    _rewards.addListener(_onStreak);
    _onStreak();
  }

  @override
  void dispose() {
    _rewards.removeListener(_onStreak);
    _celebrate.dispose();
    super.dispose();
  }

  /// The streak loaded or changed: shows it, celebrating a rise.
  void _onStreak() {
    if (_celebrating) return;
    final streak = _rewards.streak(widget.user);
    if (!_rewards.takeStreakIncrease(widget.user)) {
      if (_shown != streak && mounted) setState(() => _shown = streak);
      return;
    }
    _celebrating = true;
    _shown = (streak - 1).clamp(0, streak);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setState(() {});
      _celebrate.forward(from: 0);
      await Future<void>.delayed(const Duration(milliseconds: 380));
      _celebrating = false;
      if (mounted) setState(() => _shown = _rewards.streak(widget.user));
    });
  }

  void _showMilestone(int days, int points) {
    final streak = _rewards.streak(widget.user);
    final earned = streak >= days;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: 0.3),
      transitionDuration: const Duration(milliseconds: 260),
      // Scale only: fading would strip the blur from the glass.
      transitionBuilder: (context, animation, _, child) => ScaleTransition(
        scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn),
        child: child,
      ),
      pageBuilder: (context, _, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Material(
              type: MaterialType.transparency,
              child: GlassPanel(
                radius: 26,
                blur: 5,
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GlassIconBadge(icon: earned ? Icons.check_rounded : Icons.local_fire_department_outlined, size: 56),
                    gap14,
                    Text('$days-DAY STREAK', style: AppText.title, textAlign: TextAlign.center),
                    const SizedBox(height: 4),
                    Text(
                      '+$points points',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    gap8,
                    Text(
                      earned
                          ? 'Reached! The points were added to your rewards.'
                          : '${days - streak} more active ${days - streak == 1 ? 'day' : 'days'} to go. '
                                'Stay active every day to earn it.',
                      style: AppText.caption,
                      textAlign: TextAlign.center,
                    ),
                    gap14,
                    SmallPillButton(label: 'Got it', onPressed: () => Navigator.of(context).pop()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final streak = _rewards.streak(user);
    final next = _rewards.nextStreakReward(user);
    final now = DateTime.now();
    final weekStart = DateTime(now.year, now.month, now.day - (now.weekday % 7)); // Sunday
    final rewards = _rewards.config.streakRewards.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassPanel(
          radius: 28,
          padding: const EdgeInsets.fromLTRB(18, 28, 18, 22),
          child: Column(
            children: [
              AnimatedBuilder(
                animation: _celebrate,
                builder: (context, child) {
                  final t = _celebrate.value;
                  final scale = _celebrate.isAnimating
                      ? 1 + 0.18 * Curves.easeOut.transform((t * 2).clamp(0, 1)) * (1 - Curves.easeIn.transform(t))
                      : 1.0;
                  return Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      // Expanding ring on update. Plain stroke, not glass, so fading it is safe.
                      if (_celebrate.isAnimating)
                        Container(
                          width: 150 + 60 * t,
                          height: 150 + 60 * t,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.white(0.45 * (1 - t)), width: 1.5),
                          ),
                        ),
                      Transform.scale(scale: scale, child: child),
                      if (_celebrate.isAnimating)
                        Positioned(
                          top: -6 - 18 * t,
                          right: 4,
                          child: Opacity(
                            opacity: (1 - t).clamp(0, 1),
                            child: const Text(
                              '+1',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
                            ),
                          ),
                        ),
                    ],
                  );
                },
                child: const _GlassFlame(),
              ),
              gap14,
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 420),
                transitionBuilder: (child, animation) => SlideTransition(
                  position: Tween(
                    begin: const Offset(0, 0.5),
                    end: Offset.zero,
                  ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack)),
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: Text(
                  '$_shown',
                  key: ValueKey(_shown),
                  style: const TextStyle(fontSize: 52, fontWeight: FontWeight.w800, height: 1, color: Colors.white),
                ),
              ),
              const SizedBox(height: 4),
              Text('Day Streak', style: AppText.title.copyWith(fontSize: 18)),
              if (_rewards.isActive(user, now)) ...[
                gap8,
                Text('You\'re active today. Keep it going tomorrow!', style: AppText.body, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
        gap14,
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
          child: _WeekTrack(weekStart: weekStart, user: user),
        ),
        gap14,
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                next == null ? 'ALL STREAK REWARDS EARNED' : 'NEXT REWARD: +${next.value} POINTS AT ${next.key} DAYS',
                style: AppText.caption.copyWith(color: Colors.white, letterSpacing: 1),
                textAlign: TextAlign.center,
              ),
              gap14,
              OptionGrid(
                columns: 4,
                spacing: 8,
                children: [
                  for (final r in rewards)
                    GlassOption(
                      height: 70,
                      selected: next?.key == r.key,
                      onTap: () => _showMilestone(r.key, r.value),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            r.key == 365 ? '1 Year' : '${r.key} Days',
                            style: AppText.caption.copyWith(fontSize: 11.5, color: Colors.white),
                          ),
                          const SizedBox(height: 4),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              streak >= r.key ? 'Earned' : '+${r.value}',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        gap14,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('What keeps your streak going', style: AppText.label.copyWith(fontWeight: FontWeight.w600)),
              gap8,
              for (final (icon, text) in const [
                (Icons.event_available_outlined, 'Booking a session'),
                (Icons.play_circle_outline_rounded, 'Watching content'),
                (Icons.groups_outlined, 'Taking part in the community'),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(icon, size: 17, color: AppColors.white(0.85)),
                      const SizedBox(width: 10),
                      Text(text, style: AppText.caption.copyWith(color: AppColors.white(0.85))),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The streak flame as glass: a translucent white-to-clear flame over a
/// fainter, larger flame that gives it depth. No disc, just the flame.
class _GlassFlame extends StatelessWidget {
  const _GlassFlame();

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 150,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // A soft blue glow behind the flame.
          Container(
            width: 112,
            height: 112,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [AppColors.glowBlue.withValues(alpha: 0.55), AppColors.glowBlue.withValues(alpha: 0)],
              ),
              boxShadow: [
                BoxShadow(color: AppColors.glowBlue.withValues(alpha: 0.45), blurRadius: 40, spreadRadius: 6),
                BoxShadow(color: AppColors.glowCyan.withValues(alpha: 0.2), blurRadius: 70, spreadRadius: 10),
              ],
            ),
          ),
          Icon(Icons.local_fire_department_rounded, size: 150, color: AppColors.white(0.08)),
          ShaderMask(
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.white, AppColors.white(0.6), AppColors.white(0.22)],
            ).createShader(bounds),
            child: Icon(
              Icons.local_fire_department_rounded,
              size: 124,
              color: Colors.white,
              shadows: [Shadow(color: AppColors.glowBlue.withValues(alpha: 0.9), blurRadius: 24)],
            ),
          ),
        ],
      ),
    );
  }
}

/// Sun–Sat as clear-glass circles joined by a track. Gaps between active
/// days are filled, and a short bar with a knob reaches from today toward
/// tomorrow, showing the streak moving forward.
class _WeekTrack extends StatelessWidget {
  const _WeekTrack({required this.weekStart, required this.user});

  final DateTime weekStart;
  final AppUser user;

  static const _labelHeight = 16.0;
  static const _gap = 10.0;
  static const _circle = 38.0;

  @override
  Widget build(BuildContext context) {
    final rewards = RewardsService.instance;
    final now = DateTime.now();
    final days = [for (var i = 0; i < 7; i++) DateTime(weekStart.year, weekStart.month, weekStart.day + i)];
    final todayIndex = days.indexWhere((d) => d.year == now.year && d.month == now.month && d.day == now.day);
    final active = [for (final d in days) rewards.isActive(user, d)];
    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = constraints.maxWidth / 7;
        return SizedBox(
          height: _labelHeight + _gap + _circle + 4,
          child: CustomPaint(
            painter: _TrackPainter(
              cell: cell,
              centerY: _labelHeight + _gap + _circle / 2,
              radius: _circle / 2,
              active: active,
              todayIndex: todayIndex,
            ),
            child: Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: _DayCell(day: days[i], active: active[i], today: i == todayIndex),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TrackPainter extends CustomPainter {
  const _TrackPainter({
    required this.cell,
    required this.centerY,
    required this.radius,
    required this.active,
    required this.todayIndex,
  });

  final double cell;
  final double centerY;
  final double radius;
  final List<bool> active;
  final int todayIndex;

  @override
  void paint(Canvas canvas, Size size) {
    double x(int i) => cell * (i + 0.5);
    final base = Paint()
      ..color = AppColors.white(0.12)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final filled = Paint()
      ..color = AppColors.white(0.75)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 6; i++) {
      final from = Offset(x(i) + radius + 2, centerY);
      final to = Offset(x(i + 1) - radius - 2, centerY);
      if (to.dx <= from.dx) continue;
      // Filled when the streak runs through both days (or into today).
      final joined = active[i] && (active[i + 1] || i + 1 == todayIndex);
      canvas.drawLine(from, to, joined ? filled : base);
    }
    // Progress from today toward tomorrow, with a knob at its tip.
    if (todayIndex >= 0 && todayIndex < 6) {
      final start = Offset(x(todayIndex) + radius + 2, centerY);
      final end = Offset(x(todayIndex) + cell * 0.5, centerY);
      if (end.dx > start.dx) {
        canvas.drawLine(start, end, filled);
        canvas.drawCircle(end, 5.5, Paint()..color = Colors.white);
        canvas.drawCircle(
          end,
          8,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = AppColors.white(0.35),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.cell != cell || old.todayIndex != todayIndex || !listEquals(old.active, active);
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.day, required this.active, required this.today});

  final DateTime day;
  final bool active;
  final bool today;

  @override
  Widget build(BuildContext context) {
    const labels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    return Semantics(
      label: '${labels[day.weekday % 7]} ${day.day}${active ? ', active' : ''}${today ? ', today' : ''}',
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox(
            height: _WeekTrack._labelHeight,
            child: Text(
              labels[day.weekday % 7],
              style: AppText.caption.copyWith(
                fontSize: 12,
                color: today ? Colors.white : AppColors.white(0.72),
                fontWeight: today ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(height: _WeekTrack._gap),
          SizedBox.square(
            dimension: _WeekTrack._circle,
            child: GlassWell(
              radius: _WeekTrack._circle / 2,
              active: today,
              fillTop: active ? 0.14 : 0,
              fillBottom: active ? 0.07 : 0,
              child: Center(
                child: active && !today
                    ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
                    : Text(
                        '${day.day}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: today ? FontWeight.w700 : FontWeight.w400,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Pieces ------------------------------------------------------------------------------

class _Heading extends StatelessWidget {
  const _Heading({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GlassIconBadge(icon: icon, size: 48),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              const SizedBox(height: 2),
              Text(subtitle, style: AppText.caption),
            ],
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.value, this.label, {this.compact = false});

  final IconData icon;
  final String value;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 18,
      padding: EdgeInsets.all(compact ? 10 : 14),
      child: Column(
        crossAxisAlignment: compact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Icon(icon, size: 20, color: Colors.white),
              if (!compact) ...[
                const SizedBox(width: 10),
                Text(
                  value,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ],
            ],
          ),
          if (compact) ...[
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: compact ? TextAlign.center : TextAlign.start,
            style: AppText.caption.copyWith(fontSize: compact ? 11 : 12.5),
          ),
        ],
      ),
    );
  }
}

/// One way to earn points, shown as a card in [_EarnCarousel].
class _EarnWay {
  const _EarnWay({required this.icon, required this.title, required this.subtitle, this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
}

/// The ways to earn as wide banner cards that glide to the next one every
/// few seconds and loop; swiping takes over until the finger lifts.
class _EarnCarousel extends StatefulWidget {
  const _EarnCarousel({required this.ways});

  final List<_EarnWay> ways;

  @override
  State<_EarnCarousel> createState() => _EarnCarouselState();
}

class _EarnCarouselState extends State<_EarnCarousel> {
  static const _interval = Duration(seconds: 4);

  // Starts far into an endless list so it can loop both ways.
  static const _start = 1000;
  final _pages = PageController(viewportFraction: 0.88, initialPage: _start);
  Timer? _timer;
  int _page = _start;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_interval, (_) => _advance());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  void _advance() {
    if (_dragging || !_pages.hasClients || MediaQuery.disableAnimationsOf(context)) return;
    _pages.nextPage(duration: const Duration(milliseconds: 900), curve: Curves.easeInOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.ways.length;
    if (count == 0) return const SizedBox.shrink();
    return Column(
      children: [
        SizedBox(
          height: 128,
          child: Listener(
            onPointerDown: (_) => _dragging = true,
            onPointerUp: (_) => _dragging = false,
            onPointerCancel: (_) => _dragging = false,
            child: PageView.builder(
              controller: _pages,
              padEnds: false,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _EarnCard(way: widget.ways[i % count]),
              ),
            ),
          ),
        ),
        gap14,
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < count; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: i == _page % count ? 18 : 6,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: AppColors.white(i == _page % count ? 1 : 0.35),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _EarnCard extends StatelessWidget {
  const _EarnCard({required this.way});

  final _EarnWay way;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 22,
      padding: EdgeInsets.zero,
      floating: false,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: way.onTap,
          child: Stack(
            children: [
              // A large faint icon behind the text, like a banner graphic.
              Positioned(right: -14, bottom: -18, child: Icon(way.icon, size: 112, color: AppColors.white(0.07))),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                child: Row(
                  children: [
                    GlassIconBadge(icon: way.icon, size: 52),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            way.title.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            way.subtitle,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    if (way.onTap != null) ...[
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                        child: const Icon(Icons.arrow_forward_rounded, size: 18, color: AppColors.primary),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CopyField extends StatelessWidget {
  const _CopyField({required this.value, required this.onCopy});

  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      height: kControlHeight,
      padding: const EdgeInsets.fromLTRB(18, 0, 6, 0),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              value,
              maxLines: 1,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ),
          SmallPillButton(label: 'Copy', onPressed: onCopy),
        ],
      ),
    );
  }
}

class _ShareButton extends StatelessWidget {
  const _ShareButton(this.icon, this.label, this.onTap);

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassOption(
      height: 64,
      selected: false,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: Colors.white),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, style: AppText.caption.copyWith(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.white(0.35)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: Colors.white),
      ),
    );
  }
}
