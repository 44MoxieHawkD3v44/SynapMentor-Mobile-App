import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api/auth_api.dart';
import '../api/rewards_api.dart';
import 'auth_service.dart';
import 'wallet_service.dart';

/// Reward values. These come from the Admin Panel in the real app, so nothing
/// in the UI should assume these particular numbers.
class RewardsConfig {
  const RewardsConfig({
    this.faceVerification = 100,
    this.idVerification = 200,
    this.referral = 200,
    this.validatedReport = 50,
    this.pointsPerMinute = 100,
    this.streakRewards = const {7: 50, 14: 100, 28: 300, 365: 5000},
    this.bookingMilestones = const {25: 200, 50: 500, 100: 1000},
  });

  final int faceVerification;
  final int idVerification;

  /// Credited to the referrer when the invited user makes their first booking.
  final int referral;
  final int validatedReport;

  /// Reward points needed for one Synap Minute.
  final int pointsPerMinute;

  /// Streak length in days → points.
  final Map<int, int> streakRewards;

  /// Completed bookings → points.
  final Map<int, int> bookingMilestones;

  int get verificationTotal => faceVerification + idVerification;
}

class RewardEntry {
  const RewardEntry(this.title, this.points, this.date);

  final String title;

  /// Negative when points were converted to minutes.
  final int points;
  final DateTime date;
}

class Referral {
  Referral(this.name, this.joinedAt);

  final String name;
  final DateTime joinedAt;
  bool rewarded = false;
}

class _Account {
  final ledger = <RewardEntry>[];
  final referrals = <Referral>[];

  /// Dates (midnight, local) with at least one activity.
  final activeDays = <DateTime>{};
  int bookings = 0;

  /// The streak the user last saw, so the Streaks tab can celebrate increases
  /// (null until the first one has loaded).
  int? seenStreak;

  /// The last day with activity, from the server.
  DateTime? lastActive;

  int? available;
  int? redeemed;
  int? streak;
  String? code;
  String? link;
}

/// Rewards: points ledger, referrals, streaks and milestones, all loaded from
/// the rewards API (seekers only). The server credits every reward itself.
class RewardsService extends ChangeNotifier {
  static final RewardsService instance = RewardsService();

  RewardsConfig config = const RewardsConfig();

  /// The admin's values have arrived; until then [config] holds stand-ins.
  bool configLoaded = false;

  final _accounts = <String, _Account>{};

  // ---- API (seekers) -------------------------------------------------------------

  /// Why part of the rewards couldn't be loaded, e.g. points need identity
  /// verification first.
  String? loadError;

  /// Loads the seeker's reward values, points, history, referrals and streak.
  /// Each part loads on its own, so one refusal doesn't hide the rest.
  Future<void> load(AppUser user) async {
    if (user.role != UserRole.seeker) return;
    final account = _account(user);
    final errors = <String>[];
    Future<void> part(Future<void> Function() load) async {
      try {
        await load();
      } catch (e) {
        errors.add(e is AuthException ? e.message : 'Couldn\'t load part of your rewards.');
      }
    }

    await Future.wait([
      part(() async {
        config = _configFrom(await RewardsApi.config());
        configLoaded = true;
      }),
      part(() async {
        final w = await RewardsApi.wallet();
        account
          ..available = _int(w['available_points'])
          ..redeemed = _int(w['redeemed_points']);
      }),
      part(() async {
        account.ledger
          ..clear()
          ..addAll([
            for (final e in (await RewardsApi.history()).reversed)
              RewardEntry(
                e['description'] as String? ?? 'Reward',
                e['reward_type'] == 'conversion' ? -_int(e['points_earned']).abs() : _int(e['points_earned']),
                (DateTime.tryParse('${e['created_at']}') ?? DateTime.now()).toLocal(),
              ),
          ]);
      }),
      part(() async {
        final r = await RewardsApi.referralCode();
        account
          ..code = r['referral_code'] as String?
          ..link = r['referral_link'] as String?;
      }),
      part(() async {
        account.referrals
          ..clear()
          ..addAll([
            for (final r in (await RewardsApi.referrals()).reversed)
              Referral(
                'Invited friend',
                (DateTime.tryParse('${r['claimed_at'] ?? r['created_at']}') ?? DateTime.now()).toLocal(),
              )..rewarded = r['reward_status'] == 'claimed',
          ]);
      }),
      part(() => _loadStreak(user)),
    ]);
    loadError = errors.firstOrNull;
    notifyListeners();
  }

  /// Reloads just the day streak, e.g. when the dashboard opens or after a
  /// session, without the rest of the rewards.
  Future<void> loadStreak(AppUser user) async {
    if (user.role != UserRole.seeker) return;
    try {
      await _loadStreak(user);
      notifyListeners();
    } catch (_) {
      // Keeps the last known streak.
    }
  }

  /// The day streak, its last active day and completed sessions, from the
  /// profile and the dashboard. The server records activity itself (booking,
  /// watching content, community posts).
  Future<void> _loadStreak(AppUser user) async {
    final account = _account(user);
    final (profile, dashboard) = await (
      AuthApi.profile('seeker'),
      // The dashboard adds the last active day; the profile alone still works.
      RewardsApi.dashboard().then<Map<String, dynamic>?>((d) => d, onError: (Object _) => null),
    ).wait;
    final stats = dashboard?['stats'];
    final streaks = dashboard?['streaks'];
    final fromStats = stats is Map ? _int(stats['streak_count']) : 0;
    // The dashboard's figures can be cached for a couple of minutes; the
    // higher of the two is the newest.
    account
      ..streak = math.max(_int(profile['streak_count']), fromStats)
      ..bookings = _int(profile['total_sessions']);
    final last = streaks is Map ? DateTime.tryParse('${streaks['last_activity'] ?? ''}') : null;
    account.lastActive = last == null ? null : DateTime(last.year, last.month, last.day);
    // The streak's days run back from the last active day (today when the
    // server doesn't say).
    final now = DateTime.now();
    final end = account.lastActive ?? DateTime(now.year, now.month, now.day);
    account.activeDays
      ..clear()
      ..addAll([for (var i = 0; i < account.streak!; i++) DateTime(end.year, end.month, end.day - i)]);
    account.seenStreak ??= streak(user);
  }

  static int _int(Object? v) => v is num ? v.toInt() : 0;

  /// The admin's reward values. Streak rewards are weekly, monthly,
  /// quarterly and yearly, shown as 7, 30, 90 and 365 days.
  RewardsConfig _configFrom(Map<String, dynamic> c) {
    List<int> ints(Object? v) => [
      if (v is List)
        for (final x in v) _int(x),
    ];
    final thresholds = ints(c['booking_milestone_thresholds']);
    final points = ints(c['booking_milestone_points']);
    return RewardsConfig(
      faceVerification: _int(c['kyc_standard_points']),
      idVerification: _int(c['kyc_full_points']),
      referral: _int(c['referral_points']),
      validatedReport: _int(c['report_solver_points']),
      pointsPerMinute: _int(c['points_per_minute']) > 0 ? _int(c['points_per_minute']) : 100,
      streakRewards: {
        for (final (days, key) in const [
          (7, 'streak_week_points'),
          (30, 'streak_month_points'),
          (90, 'streak_quarter_points'),
          (365, 'streak_year_points'),
        ])
          if (_int(c[key]) > 0) days: _int(c[key]),
      },
      bookingMilestones: {for (var i = 0; i < thresholds.length && i < points.length; i++) thresholds[i]: points[i]},
    );
  }

  // ---- Reads -------------------------------------------------------------------

  List<RewardEntry> activity(AppUser user) => _account(user).ledger.reversed.toList();

  int totalEarned(AppUser user) {
    final account = _account(user);
    if (account.available != null) return account.available! + (account.redeemed ?? 0);
    return account.ledger.where((e) => e.points > 0).fold(0, (s, e) => s + e.points);
  }

  int redeemed(AppUser user) =>
      _account(user).redeemed ?? -_account(user).ledger.where((e) => e.points < 0).fold(0, (s, e) => s + e.points);

  int available(AppUser user) => _account(user).available ?? totalEarned(user) - redeemed(user);

  int bookingCount(AppUser user) => _account(user).bookings;

  List<Referral> referrals(AppUser user) => List.unmodifiable(_account(user).referrals.reversed);

  // ---- Referrals ---------------------------------------------------------------

  /// The user's referral code from the API (or their profile), empty until
  /// it loads.
  String referralCodeFor(AppUser user) => _account(user).code ?? user.referralCode ?? '';

  String referralLinkFor(AppUser user) =>
      _account(user).link ?? 'https://synapmentor.app/register?ref=${referralCodeFor(user)}';

  // ---- Events ------------------------------------------------------------------

  // ---- Streaks -----------------------------------------------------------------

  /// Consecutive active days ending today, or yesterday if today has no
  /// activity yet (the streak isn't broken until the day ends).
  int streak(AppUser user) {
    final account = _account(user);
    final fromApi = account.streak;
    if (fromApi != null) {
      // A day with no activity breaks it, even before the server next
      // updates it.
      final last = account.lastActive;
      final now = DateTime.now();
      if (last != null && last.isBefore(DateTime(now.year, now.month, now.day - 1))) return 0;
      return fromApi;
    }
    final days = _account(user).activeDays;
    final now = DateTime.now();
    var day = DateTime(now.year, now.month, now.day);
    if (!days.contains(day)) day = day.subtract(const Duration(days: 1));
    var count = 0;
    while (days.contains(day)) {
      count++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return count;
  }

  bool isActive(AppUser user, DateTime day) =>
      _account(user).activeDays.contains(DateTime(day.year, day.month, day.day));

  /// The next streak reward still ahead, if any.
  MapEntry<int, int>? nextStreakReward(AppUser user) {
    final current = streak(user);
    final ahead = config.streakRewards.entries.where((e) => e.key > current).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return ahead.firstOrNull;
  }

  /// True once per increase, so the streak animation plays a single time.
  bool takeStreakIncrease(AppUser user) {
    final account = _account(user);
    if (account.streak == null) return false;
    final current = streak(user);
    final increased = current > (account.seenStreak ?? current);
    account.seenStreak = current;
    return increased;
  }

  // ---- Conversion --------------------------------------------------------------

  /// Converts [points] (a multiple of the conversion rate) into Synap Minutes
  /// credited to the wallet.
  Future<int> convert(AppUser user, int points) async {
    final rate = config.pointsPerMinute;
    if (points <= 0 || points % rate != 0) throw AuthException('Enter points in multiples of $rate.');
    if (points > available(user)) throw const AuthException('You don\'t have that many points available.');
    if (user.role != UserRole.seeker) throw const AuthException('Only seekers can convert reward points.');
    final result = await RewardsApi.convert(points);
    final minutes = _int(result['minutes_credited']);
    WalletService.instance.creditRewardMinutes(user, minutes: minutes, points: _int(result['points_deducted']));
    await load(user);
    return minutes;
  }

  // ---- Internals ---------------------------------------------------------------

  _Account _account(AppUser user) => _accounts.putIfAbsent(user.email, _Account.new);
}
