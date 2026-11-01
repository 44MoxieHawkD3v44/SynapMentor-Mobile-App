import 'package:flutter/foundation.dart';

import '../api/account_api.dart';
import '../api/skill_verification_api.dart';
import '../api/solver_booking_api.dart';
import 'auth_service.dart';
import 'community_service.dart';
import 'content_service.dart';
import 'countries.dart';
import 'explore_service.dart';

/// A pricing level and what a solver needs to reach it. Configured by the
/// admin, so the UI never assumes these particular numbers.
class PricingTier {
  const PricingTier({
    required this.rate,
    this.minSessions = 0,
    this.minUniqueSeekers = 0,
    this.minRating = 0,
    this.price,
    this.serverUnlocked,
  });

  /// Wallet minutes per session minute.
  final int rate;
  final int minSessions;
  final int minUniqueSeekers;
  final double minRating;

  /// The tier's price per minute in the API, sent when the solver picks it.
  final num? price;

  /// Whether the API says the signed-in solver has unlocked it.
  final bool? serverUnlocked;
}

/// A daily time range, in minutes from midnight (solver's local time).
class TimeSlot {
  const TimeSlot(this.start, this.end);

  final int start;
  final int end;

  int get minutes => end - start;

  bool overlaps(TimeSlot other) => start < other.end && other.start < end;

  /// 9:00 AM style. Midnight at the end of a day reads 12:00 AM.
  static String label(int minuteOfDay) {
    final h = minuteOfDay ~/ 60 % 24;
    final m = minuteOfDay % 60;
    final hour = h % 12 == 0 ? 12 : h % 12;
    return '$hour:${m.toString().padLeft(2, '0')} ${h < 12 ? 'AM' : 'PM'}';
  }

  @override
  String toString() => '${label(start)} – ${label(end)}';

  @override
  bool operator ==(Object other) => other is TimeSlot && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Weekly slots plus per-date changes made from the calendar.
class SolverSchedule {
  /// Weekday (DateTime.monday … sunday) → slots.
  final weekly = <int, List<TimeSlot>>{};

  /// Date (midnight) → slots for that day only. An empty list means off.
  final overrides = <DateTime, List<TimeSlot>>{};

  /// How far ahead seekers can book, in days (at most 60).
  int windowDays = 60;

  List<TimeSlot> slotsOn(DateTime date) =>
      overrides[DateTime(date.year, date.month, date.day)] ?? weekly[date.weekday] ?? const [];

  int get weeklyMinutes => weekly.values.fold(0, (sum, slots) => sum + slots.fold(0, (s, t) => s + t.minutes));

  SolverSchedule copy() => SolverSchedule()..setFrom(this);

  /// Makes this schedule the same as [other].
  void setFrom(SolverSchedule other) {
    weekly
      ..clear()
      ..addAll({for (final e in other.weekly.entries) e.key: List.of(e.value)});
    overrides
      ..clear()
      ..addAll({for (final e in other.overrides.entries) e.key: List.of(e.value)});
    windowDays = other.windowDays;
  }

  bool sameAs(SolverSchedule other) {
    // A weekday without slots is the same as no entry; a date with an empty
    // list is a day off, so its entry counts.
    bool sameSlots(Map<Object, List<TimeSlot>> a, Map<Object, List<TimeSlot>> b) =>
        {...a.keys, ...b.keys}.every((k) => listEquals(a[k] ?? const [], b[k] ?? const []));

    return windowDays == other.windowDays &&
        sameSlots(weekly, other.weekly) &&
        overrides.length == other.overrides.length &&
        overrides.keys.every(other.overrides.containsKey) &&
        sameSlots(overrides, other.overrides);
  }
}

/// The signed-in solver's skills, verified focus areas and projects.
class SolverExpertise {
  const SolverExpertise(this.skills, this.focusAreas, this.projects);

  final List<String> skills;
  final List<String> focusAreas;
  final List<ProblemSolved> projects;
}

/// What tier progress is measured on. Keyed by the solver's catalog id, or
/// their email before they have a public profile.
class SolverStats {
  const SolverStats(this.id, this.sessions, this.uniqueSeekers, this.rating);

  final String id;
  final int sessions;
  final int uniqueSeekers;
  final double rating;
}

class BookingLink {
  const BookingLink(this.id, this.label, this.url);

  final String id;
  final String label;
  final String url;
}

/// The signed-in solver's pricing, expertise, languages, availability,
/// booking links and podcast setting, from the solver APIs.
class SolverService extends ChangeNotifier {
  static final SolverService instance = SolverService();

  /// Admin-configured tiers, lowest first, loaded from the API.
  static final tiers = <PricingTier>[];

  /// Replaces the pricing tiers with what the API returned.
  void setTiers(List<PricingTier> list) {
    tiers
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  static const maxWindowDays = 60;

  /// Minutes between the times offered when setting availability.
  static const slotStep = 10;

  final _schedules = <String, SolverSchedule>{}; // solver id → schedule
  final _languages = <String, List<String>>{};
  final _links = <String, List<BookingLink>>{};

  // ---- Pricing -------------------------------------------------------------------

  /// Languages a solver can pick from, loaded from the API.
  static final languageOptions = <String>[];

  /// Tier progress figures per solver, loaded from the API.
  final _stats = <String, SolverStats>{};

  /// Stores a solver's tier progress (sessions, unique seekers, rating) from the API.
  void setStats(SolverStats stats) {
    _stats[stats.id] = stats;
    notifyListeners();
  }

  /// Positive feedback as a percentage, from the rating out of 5.
  static int feedbackPercent(double rating) => (rating / 5 * 100).round();

  SolverStats statsOf(Solver profile) =>
      _stats[profile.id] ?? SolverStats(profile.id, profile.sessions, 0, profile.rating);

  /// Every solver has stats; a new solver starts at zero on the base tier.
  SolverStats statsFor(AppUser user) {
    final own = _stats[user.email];
    if (own != null) return own;
    final profile = profileFor(user);
    return profile != null ? statsOf(profile) : SolverStats(user.email, 0, 0, 0);
  }

  /// Whether the solver meets every requirement of [tier].
  bool unlocked(SolverStats stats, PricingTier tier) =>
      tier.serverUnlocked ??
      stats.sessions >= tier.minSessions &&
          stats.uniqueSeekers >= tier.minUniqueSeekers &&
          stats.rating >= tier.minRating;

  /// Share of the way to [tier], averaged over its requirements (0–1).
  double progressTo(SolverStats stats, PricingTier tier) {
    double part(num value, num target) => target == 0 ? 1 : (value / target).clamp(0.0, 1.0).toDouble();
    return (part(stats.sessions, tier.minSessions) +
            part(stats.uniqueSeekers, tier.minUniqueSeekers) +
            part(stats.rating, tier.minRating)) /
        3;
  }

  final _selectedRates = <String, int>{};

  /// The tier the server has saved, to go back to if a change fails.
  final _savedRates = <String, int>{};

  /// Moves the choice while the slider is dragged; [selectRate] saves it.
  void previewRate(SolverStats stats, int rate) {
    if (_selectedRates[stats.id] == rate) return;
    _selectedRates[stats.id] = rate;
    notifyListeners();
  }

  /// The rate the solver charges: the tier they picked, or the highest one
  /// they've unlocked.
  int rateOf(SolverStats stats) =>
      _selectedRates[stats.id] ??
      (tiers.isEmpty ? 0 : tiers.lastWhere((t) => unlocked(stats, t), orElse: () => tiers.first).rate);

  // The solver's currency from the API: its symbol, the platform's base minute
  // value (INR) and the exchange rate into the currency.
  String? _currencySymbol;
  double _baseRateInr = 5;
  double _fxRate = 1;

  Future<void> _loadCurrency() async {
    try {
      final c = await AccountApi.solverCountry();
      _currencySymbol = (c['symbol'] as String?) ?? (c['currency'] as String?);
      if (c['base_rate_inr'] is num) _baseRateInr = (c['base_rate_inr'] as num).toDouble();
      if (c['fx_rate'] is num && (c['fx_rate'] as num) > 0) _fxRate = (c['fx_rate'] as num).toDouble();
      notifyListeners();
    } catch (_) {
      // Shown in the profile country's currency until it loads.
    }
  }

  /// A tier's price per minute in the solver's currency, e.g. "10₹/min".
  String priceLabel(AppUser user, PricingTier tier) => '${priceOf(user, tier)}/min';

  /// A tier's price in the solver's currency, e.g. "10₹".
  String priceOf(AppUser user, PricingTier tier) {
    final symbol = _currencySymbol ?? Countries.byName(user.profile.countryName)?.currencySymbol ?? '₹';
    final amount = (tier.price?.toDouble() ?? _baseRateInr * tier.rate) * _fxRate;
    final text = amount == amount.roundToDouble() ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2);
    return '$text$symbol';
  }

  /// Used when pricing a booking with [profile].
  int rateFor(Solver profile) => tiers.isEmpty ? profile.rate : rateOf(statsOf(profile));

  /// Picks an unlocked tier. Applies to new bookings.
  /// Why the last pricing or language change didn't save, if it didn't.
  String? saveError;

  /// Switches at once and saves the tier's price; switches back if the save
  /// fails.
  Future<void> selectRate(SolverStats stats, int rate) async {
    final tier = tiers.where((t) => t.rate == rate).firstOrNull;
    if (tier == null) throw const AuthException('That tier isn\'t available.');
    if (!unlocked(stats, tier)) throw const AuthException('That tier is still locked.');
    final previous = _savedRates[stats.id];
    _selectedRates[stats.id] = rate;
    if (previous == rate) return notifyListeners();
    saveError = null;
    notifyListeners();
    final price = tier.price;
    if (price == null) return;
    try {
      await AccountApi.setPrice(price);
    } on AuthException catch (e) {
      // The server's reason (e.g. what's still needed) is shown as it is.
      previous == null ? _selectedRates.remove(stats.id) : _selectedRates[stats.id] = previous;
      saveError = e.message;
      notifyListeners();
      return;
    }
    _savedRates[stats.id] = rate;
    // The saved price, tier and unlock progress, as the server now has them.
    await AuthService.instance.reloadProfile().catchError((Object _) {});
  }

  /// Why the next tier is locked, from the server, e.g. "To unlock ₹10/min
  /// you need 4 completed sessions (you have 0)…". Null when all are unlocked.
  String? lockReason;

  /// Takes the signed-in solver's pricing tiers, progress, chosen price and
  /// languages from their profile.
  void applyProfile(AppUser user, Map<String, dynamic> p) {
    num number(Object? v) => v is num ? v : 0;
    final unlock = p['tier_unlock_data'];
    var sessions = number(p['completed_sessions']).toInt();
    var uniqueSeekers = 0;
    var feedback = number(p['rating']) / 5 * 100;
    if (unlock is Map) {
      final reason = '${unlock['lockReason'] ?? ''}'.trim();
      lockReason = reason.isEmpty ? null : reason;
    }
    if (unlock is Map && unlock['tiers'] is List) {
      final list = <PricingTier>[];
      for (final t in unlock['tiers'] as List) {
        if (t is! Map) continue;
        final progress = t['progress'] is Map ? t['progress'] as Map : const {};
        Map part(String key) => progress[key] is Map ? progress[key] as Map : const {};
        if (progress.isNotEmpty) {
          sessions = number(part('sessions')['current']).toInt();
          uniqueSeekers = number(part('uniqueSeekers')['current']).toInt();
          feedback = number(part('usefulFeedback')['current']).toDouble();
        }
        final multiplier = number(t['multiplier']);
        list.add(
          PricingTier(
            rate: multiplier < 1 ? 1 : multiplier.round(),
            price: t['price'] is num ? t['price'] as num : null,
            minSessions: number(part('sessions')['required']).toInt(),
            minUniqueSeekers: number(part('uniqueSeekers')['required']).toInt(),
            minRating: number(part('usefulFeedback')['required']) / 100 * 5,
            serverUnlocked: t['unlocked'] is bool ? t['unlocked'] as bool : null,
          ),
        );
      }
      tiers
        ..clear()
        ..addAll(list);
      final current = list.where((t) => t.price == p['price_per_minute']).firstOrNull;
      if (current != null) _selectedRates[user.email] = _savedRates[user.email] = current.rate;
    }
    _stats[user.email] = SolverStats(user.email, sessions, uniqueSeekers, feedback / 100 * 5);
    final spoken = p['spoken_languages'];
    if (spoken is List) _languages[user.email] = [for (final l in spoken) '$l'];
    notifyListeners();
    if (user.role == UserRole.solver) _loadCurrency();
  }

  // ---- Expertise (API) ---------------------------------------------------------------

  final _expertise = <String, SolverExpertise>{};

  /// The signed-in solver's skills, verified focus areas and projects, once
  /// loaded.
  SolverExpertise? expertiseOf(AppUser user) => _expertise[user.email];

  /// Why the expertise didn't load, if it didn't.
  String? expertiseError;

  /// Loads skills and focus areas from the expertise endpoint, and projects
  /// from it and from the Skill Verification portfolios.
  Future<void> loadExpertise(AppUser user) async {
    if (user.role != UserRole.solver) return;
    try {
      final results = await Future.wait([
        AccountApi.solverExpertise(),
        SkillVerificationApi.portfolios().catchError((Object _) => <Map<String, dynamic>>[]),
      ]);
      final data = results[0] as Map<String, dynamic>;
      final portfolios = results[1] as List<Map<String, dynamic>>;
      List<Map> list(Object? v) => [if (v is List) ...v.whereType<Map>()];
      String text(Object? v) => (v is String ? v : '').trim();
      final skills = <String>{
        for (final s in list(data['skills'])) text(s['skill_name']),
        for (final v in list(data['verified_skills'])) text(v['skill']),
        for (final p in portfolios) text(p['skill_category']),
      }..remove('');
      final focusAreas = <String>{
        for (final v in list(data['verified_skills']))
          if (v['focus_areas'] is List) ...(v['focus_areas'] as List).map(text),
        for (final p in portfolios) ...text(p['focus_areas']).split(',').map((f) => f.trim()),
      }..remove('');
      final projects = <ProblemSolved>[
        for (final p in portfolios)
          for (final pr in list(p['projects']))
            if (text(pr['problem_statement']).isNotEmpty)
              ProblemSolved(text(pr['problem_statement']), text(pr['solution_explanation'])),
        for (final pr in list(data['projects']))
          if (text(pr['title']).isNotEmpty) ProblemSolved(text(pr['title']), text(pr['description'])),
      ];
      final spoken = [for (final l in list(data['languages'])) text(l['language_name'])]..remove('');
      _expertise[user.email] = SolverExpertise(skills.toList(), focusAreas.toList(), projects);
      if (spoken.isNotEmpty && !_languages.containsKey(user.email)) _languages[user.email] = spoken;
      expertiseError = null;
    } on AuthException catch (e) {
      expertiseError = e.message;
    }
    notifyListeners();
  }

  // ---- Languages -------------------------------------------------------------------

  List<String> languages(AppUser user) =>
      _languages.putIfAbsent(user.email, () => List.of(profileFor(user)?.languages ?? const []));

  /// Updates the list at once and saves it to the profile; restores it if the
  /// save fails.
  Future<void> setLanguages(AppUser user, List<String> languages) async {
    final previous = _languages[user.email];
    _languages[user.email] = languages;
    saveError = null;
    notifyListeners();
    if (user.role != UserRole.solver) return;
    try {
      await AccountApi.updateProfile('solver', {'spoken_languages': languages});
    } on AuthException catch (e) {
      if (previous != null) _languages[user.email] = previous;
      saveError = e.message;
      notifyListeners();
    }
  }

  // ---- Availability ----------------------------------------------------------------

  /// The signed-in solver's schedule, starting from their current hours.
  SolverSchedule scheduleOf(AppUser user) {
    final profile = profileFor(user);
    return _schedules.putIfAbsent(_scheduleKey(user), () {
      final schedule = SolverSchedule();
      for (final w in profile?.availability ?? const <AvailabilityWindow>[]) {
        schedule.weekly.putIfAbsent(w.weekday, () => []).add(TimeSlot(w.startHour * 60, w.endHour * 60));
      }
      for (final slots in schedule.weekly.values) {
        slots.sort((a, b) => a.start.compareTo(b.start));
      }
      return schedule;
    });
  }

  String _scheduleKey(AppUser user) => profileFor(user)?.id ?? user.email;

  /// The schedule as last saved. Edits change [scheduleOf] only, until
  /// they're saved with [saveAvailability] or undone with [discardAvailability].
  final _savedSchedules = <String, SolverSchedule>{};

  bool savingAvailability = false;

  /// The schedule has edits that aren't saved yet.
  bool availabilityChanged(AppUser user) {
    final saved = _savedSchedules[_scheduleKey(user)];
    return saved != null && !scheduleOf(user).sameAs(saved);
  }

  // ---- Booking setup (API) -----------------------------------------------------------

  /// Solvers whose schedule, podcast setting and links came from the API;
  /// their changes are saved there.
  final _setupLoaded = <String>{};

  /// The public booking path from the API, e.g. `/book/<pseudo name>`.
  final _profilePaths = <String, String>{};

  static const _dayNames = {
    DateTime.monday: 'Monday',
    DateTime.tuesday: 'Tuesday',
    DateTime.wednesday: 'Wednesday',
    DateTime.thursday: 'Thursday',
    DateTime.friday: 'Friday',
    DateTime.saturday: 'Saturday',
    DateTime.sunday: 'Sunday',
  };

  /// Custom links take a fixed length; the link form only asks for a name.
  static const linkMinutes = 30;

  static String _hhmm(int minuteOfDay) {
    final m = minuteOfDay >= 24 * 60 ? 24 * 60 - 1 : minuteOfDay;
    return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  }

  static int _minuteOf(String hhmm) {
    final parts = hhmm.split(':');
    final minutes = (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 0);
    return minutes >= 24 * 60 - 1 ? 24 * 60 : minutes;
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Loads the solver's weekly schedule, podcast setting and booking links.
  Future<void> loadBookingSetup(AppUser user) async {
    if (user.role != UserRole.solver) return;
    final me = ExploreService.instance.ownSolver(user);
    final today = DateTime.now();
    final days = [for (var i = 0; i < 7; i++) DateTime(today.year, today.month, today.day + i)];
    final results = await Future.wait([
      SolverBookingApi.podcastEnabled(),
      SolverBookingApi.links(),
      SolverBookingApi.profileLinkPath().catchError((Object _) => null),
      Future.wait([for (final d in days) SolverBookingApi.savedWindows(_date(d))]),
    ]);
    _podcastOverrides[me.id] = results[0] as bool;
    _links[user.email] = [
      for (final l in results[1] as List<Map<String, dynamic>>)
        if (l['is_active'] != false)
          BookingLink('${l['id']}', '${l['title'] ?? 'Booking link'}', '${l['share_url'] ?? ''}'),
    ];
    final path = results[2] as String?;
    if (path != null && path.isNotEmpty) _profilePaths[user.email] = path;
    // The saved windows of the coming week give the weekly pattern.
    final schedule = scheduleOf(user);
    final changed = availabilityChanged(user);
    // Date changes and the booking window aren't loaded; the saved ones stay.
    final saved = (_savedSchedules[_scheduleKey(user)] ?? schedule).copy();
    final windows = results[3] as List<List<({String start, String end})>>;
    saved.weekly.clear();
    for (final (i, d) in days.indexed) {
      saved.weekly[d.weekday] = [for (final w in windows[i]) TimeSlot(_minuteOf(w.start), _minuteOf(w.end))]
        ..sort((a, b) => a.start.compareTo(b.start));
    }
    _savedSchedules[_scheduleKey(user)] = saved;
    // Edits not saved yet stay as they are.
    if (!changed) schedule.setFrom(saved);
    _setupLoaded.add(user.email);
    notifyListeners();
  }

  /// Whether the solver's availability has loaded from the server.
  bool availabilityLoaded(AppUser user) => _setupLoaded.contains(user.email);

  /// Whether the solver has saved any available hours.
  bool hasAvailability(AppUser user) {
    final schedule = _savedSchedules[_scheduleKey(user)] ?? scheduleOf(user);
    return schedule.weekly.values.any((slots) => slots.isNotEmpty) ||
        schedule.overrides.values.any((slots) => slots.isNotEmpty);
  }

  /// Saves the whole schedule, so seekers see it straight away. False when
  /// it couldn't be saved ([saveError] says why).
  Future<bool> saveAvailability(AppUser user) async {
    if (!_setupLoaded.contains(user.email) || savingAvailability) return false;
    final schedule = scheduleOf(user);
    final timezone = user.profile.timezone;
    if (timezone == null || timezone.isEmpty || timezone == 'UTC') {
      saveError = 'Set your timezone in Profile before setting availability.';
      notifyListeners();
      return false;
    }
    List<String> ranges(List<TimeSlot> slots) => [for (final s in slots) '${_hhmm(s.start)}-${_hhmm(s.end)}'];
    final sent = schedule.copy();
    saveError = null;
    savingAvailability = true;
    notifyListeners();
    try {
      await SolverBookingApi.saveWeekly(
        weekly: {for (final e in _dayNames.entries) e.value: ranges(sent.weekly[e.key] ?? const [])},
        overrides: {for (final e in sent.overrides.entries) _date(e.key): ranges(e.value)},
        timezone: timezone,
        daysForward: sent.windowDays.clamp(1, 90),
      );
      _savedSchedules[_scheduleKey(user)] = sent;
      return true;
    } catch (e) {
      saveError = e is AuthException ? e.message : 'Your availability couldn\'t be saved. Please try again.';
      return false;
    } finally {
      savingAvailability = false;
      notifyListeners();
    }
  }

  /// Undoes the edits that weren't saved.
  void discardAvailability(AppUser user) {
    final saved = _savedSchedules[_scheduleKey(user)];
    if (saved == null) return;
    scheduleOf(user).setFrom(saved);
    saveError = null;
    notifyListeners();
  }

  void addWeeklySlot(AppUser user, int weekday, TimeSlot slot) {
    final slots = scheduleOf(user).weekly.putIfAbsent(weekday, () => []);
    _checkFree(slots, slot);
    slots
      ..add(slot)
      ..sort((a, b) => a.start.compareTo(b.start));
    notifyListeners();
  }

  void removeWeeklySlot(AppUser user, int weekday, TimeSlot slot) {
    scheduleOf(user).weekly[weekday]?.remove(slot);
    notifyListeners();
  }

  /// Changes one date only, leaving the weekly schedule as it is. Replace
  /// [old] with [slot], add [slot] when [old] is null, or remove [old] when
  /// [slot] is null.
  void editDate(AppUser user, DateTime date, {TimeSlot? old, TimeSlot? slot}) {
    final schedule = scheduleOf(user);
    final day = DateTime(date.year, date.month, date.day);
    final slots = List.of(schedule.slotsOn(day));
    if (old != null) slots.remove(old);
    if (slot != null) {
      _checkFree(slots, slot);
      slots.add(slot);
    }
    slots.sort((a, b) => a.start.compareTo(b.start));
    schedule.overrides[day] = slots;
    notifyListeners();
  }

  void resetDate(AppUser user, DateTime date) {
    scheduleOf(user).overrides.remove(DateTime(date.year, date.month, date.day));
    notifyListeners();
  }

  void setWindowDays(AppUser user, int days) {
    scheduleOf(user).windowDays = days.clamp(1, maxWindowDays);
    notifyListeners();
  }

  void _checkFree(List<TimeSlot> existing, TimeSlot slot) {
    if (slot.end <= slot.start) throw const AuthException('The end time must be after the start time.');
    if (existing.any(slot.overlaps)) {
      throw const AuthException('That time overlaps a slot you already have. Choose a free time.');
    }
  }

  // ---- Booking links -----------------------------------------------------------------

  /// The public booking link: the server's path on the same site as the
  /// custom links when it's known.
  String profileLink(AppUser user) {
    final path = _profilePaths[user.email];
    if (path == null) return 'https://synapmentor.app/solver/${profileFor(user)?.id ?? 'me'}';
    final shared = links(user).map((l) => Uri.tryParse(l.url)).whereType<Uri>().where((u) => u.hasScheme).firstOrNull;
    return '${shared?.origin ?? 'https://synapmentor.app'}$path';
  }

  List<BookingLink> links(AppUser user) => _links.putIfAbsent(user.email, () => []);

  Future<BookingLink> createLink(AppUser user, String label) async {
    final name = label.trim();
    if (name.isEmpty) throw const AuthException('Give the link a name.');
    // Priced at the solver's own tier, as the server set it.
    final rate = rateOf(statsFor(user));
    final price = tiers.where((t) => t.rate == rate).firstOrNull?.price ?? _baseRateInr * rate;
    final l = await SolverBookingApi.createLink(title: name, durationMinutes: linkMinutes, price: price.round());
    final link = BookingLink('${l['id']}', '${l['title'] ?? name}', '${l['share_url'] ?? ''}');
    links(user).add(link);
    notifyListeners();
    return link;
  }

  Future<void> deleteLink(AppUser user, BookingLink link) async {
    await SolverBookingApi.deleteLink(link.id);
    links(user).remove(link);
    notifyListeners();
  }

  /// The solver's public profile in the directory, matched by name.
  Solver? profileFor(AppUser user) => ExploreService.instance.allSolvers.where((s) => s.name == user.name).firstOrNull;

  // ---- Podcasts ----------------------------------------------------------------------

  final _podcastOverrides = <String, bool>{};

  /// Whether [solver] takes podcast bookings right now.
  bool podcastEnabled(Solver solver) => _podcastOverrides[solver.id] ?? solver.podcastEnabled;

  Future<void> setPodcastEnabled(AppUser user, bool enabled) async {
    await SolverBookingApi.setPodcastEnabled(enabled);
    _podcastOverrides[ExploreService.instance.ownSolver(user).id] = enabled;
    notifyListeners();
  }

  /// The solver's published content, newest first.
  List<ContentItem> content(AppUser user) => ContentService.instance.mine(user).where((i) => !i.draft).toList();

  Community? community(AppUser user) => CommunityService.instance.ownedBy(user);
}
