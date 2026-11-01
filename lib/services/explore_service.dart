import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/explore_api.dart';
import '../api/session_store.dart';
import '../api/solver_booking_api.dart';

import 'auth_service.dart';
import 'countries.dart';
import 'kyc_service.dart';
import 'session_service.dart';
import 'skill_verification_service.dart';
import 'solver_service.dart';
import 'wallet_service.dart';

/// Up to two capital initials of [name], e.g. "JD" for "Jane Doe".
String initialsOf(String name) =>
    name.trim().split(RegExp(r's+')).where((p) => p.isNotEmpty).take(2).map((p) => p[0].toUpperCase()).join();

class ProblemSolved {
  const ProblemSolved(this.problem, this.solution);

  final String problem;
  final String solution;
}

class SolverReview {
  const SolverReview(this.author, this.rating, this.text);

  /// Reviewers appear under their pseudo name.
  final String author;
  final double rating;
  final String text;
}

/// A weekly availability window in the solver's own timezone. Hours are 0–24.
class AvailabilityWindow {
  const AvailabilityWindow(this.weekday, this.startHour, this.endHour);

  final int weekday; // DateTime.monday … DateTime.sunday
  final int startHour;
  final int endHour;
}

class Solver {
  const Solver({
    required this.id,
    required this.name,
    required this.headline,
    required this.about,
    required this.skills,
    required this.category,
    required this.subcategories,
    required this.rating,
    required this.sessions,
    required this.location,
    required this.timezone,
    required this.languages,
    required this.rate,
    required this.availableNow,
    required this.podcastEnabled,
    required this.availability,
    required this.problemsSolved,
    required this.reviews,
    this.remote = false,
    this.nextAvailableAt,
    this.verifiedSkills = const [],
    this.pricePaise,
  });

  /// The solver's price per session minute in paise, from the server's
  /// `price_per_minute`. Null when the server didn't send one.
  final int? pricePaise;

  /// From the solver directory API: free slots come from the server.
  final bool remote;

  /// The next bookable start (UTC), from the API.
  final DateTime? nextAvailableAt;

  /// Each skill the solver is verified in, with its focus areas.
  final List<({String skill, List<String> areas})> verifiedSkills;

  final String id;
  final String name;
  final String headline;
  final String about;
  final List<String> skills;
  final String category;
  final List<String> subcategories;
  final double rating;
  final int sessions;
  final String location;
  final TimezoneInfo timezone;
  final List<String> languages;

  /// Wallet minutes per session minute (the server's price multiplier).
  final int rate;

  /// The server's price per session minute in the seeker's currency, e.g.
  /// "₹10/min"; the wallet minutes per minute when no price came with it.
  String get priceLabel => pricePaise != null ? '${formatMoney(pricePaise!)}/min' : '$rate wallet min/min';
  final bool availableNow;

  /// Only these solvers appear under Podcasts and offer podcast bookings.
  final bool podcastEnabled;
  final List<AvailabilityWindow> availability;
  final List<ProblemSolved> problemsSolved;
  final List<SolverReview> reviews;

  String get initials => initialsOf(name);

  String get ratingLabel => rating == rating.roundToDouble() ? rating.toStringAsFixed(1) : rating.toStringAsFixed(2);
}

enum BookingType {
  normal('Normal Booking', 10, [10, 20, 30, 40, 50, 60]),
  anonymous('Anonymous Booking', 10, [10, 20, 30, 40, 50, 60]),
  podcast('Podcast Booking', 60, [60, 90, 120]);

  const BookingType(this.label, this.minMinutes, this.durations);
  final String label;

  /// Anonymous bookings cost [ExploreService.anonymousMultiplier] times the
  /// normal minutes; the others cost the normal minutes.
  double get multiplier => this == anonymous ? ExploreService.anonymousMultiplier : 1;
  final int minMinutes;
  final List<int> durations;

  /// Anonymous bookings skip KYC; everything else needs it.
  bool get needsKyc => this != anonymous;
}

enum SessionMode {
  meet('Meet'),
  chat('Chat');

  const SessionMode(this.label);
  final String label;
}

class Booking {
  const Booking({
    required this.id,
    required this.userEmail,
    required this.solver,
    required this.type,
    required this.mode,
    required this.start,
    required this.minutes,
    required this.title,
    required this.description,
    required this.walletMinutes,
    this.seekerName,
    this.rescheduled = false,
    this.cancellation,
    this.sessionId,
    this.serverStatus,
    this.faceVerified = false,
  });

  final String id;

  /// The live session behind the booking, from the API.
  final String? sessionId;

  /// The booking's status on the server (e.g. `confirmed`, `completed`).
  final String? serverStatus;

  /// The viewer has already passed this session's face check on the server.
  final bool faceVerified;

  /// The seeker who booked.
  final String userEmail;

  /// The seeker's name when they booked. Solvers see it for normal bookings.
  final String? seekerName;

  /// Moved to a new time at least once.
  final bool rescheduled;

  /// Set when the session was cancelled.
  final Cancellation? cancellation;
  final Solver solver;
  final BookingType type;
  final SessionMode mode;

  /// Session start, as a UTC instant.
  final DateTime start;
  final int minutes;
  final String title;
  final String description;
  final int walletMinutes;

  /// How the solver sees the seeker: anonymous bookers get a stable number.
  String get seekerLabel =>
      type == BookingType.anonymous ? 'Anonymous #${id.hashCode.abs() % 900 + 100}' : (seekerName ?? 'Seeker');

  /// The seeker's initials, or "?" for an anonymous booking.
  String get seekerInitials => type == BookingType.anonymous ? '?' : initialsOf(seekerLabel);

  Booking rescheduledTo(DateTime newStart) => Booking(
    id: id,
    userEmail: userEmail,
    solver: solver,
    type: type,
    mode: mode,
    start: newStart,
    minutes: minutes,
    title: title,
    description: description,
    walletMinutes: walletMinutes,
    seekerName: seekerName,
    rescheduled: true,
    sessionId: sessionId,
  );
}

/// Who cancelled a session and why.
class Cancellation {
  const Cancellation({required this.by, required this.reason, required this.at});

  final String by;
  final String reason;
  final DateTime at;
}

/// What the seeker asked "Pick a Solver for Me" for, carried into booking.
class BookingPrefill {
  const BookingPrefill({required this.slot, required this.title, required this.description});

  /// UTC instant.
  final DateTime slot;
  final String title;
  final String description;
}

/// The solver directory, favourites, free slots and bookings. For seekers
/// they come from the explore and bookings APIs; the server freezes the wallet
/// minutes when a session is booked.
class ExploreService extends ChangeNotifier {
  static final ExploreService instance = ExploreService();

  // ---- API (seekers) -------------------------------------------------------------

  /// The value of one wallet minute in ₹, used only to estimate wallet
  /// minutes before booking: a solver charging ₹10/min costs 2 wallet minutes
  /// per session minute. The server's base minute value (an admin setting)
  /// isn't sent to seekers, so the minutes it freezes at booking
  /// (`minutes_deducted`) and each booking's `price_multiplier` are what count.
  static const _baseMinuteValue = 5;

  /// How many times the normal minutes an anonymous booking costs (and earns
  /// the solver): the admin's setting from the server's booking config. 2 is
  /// the server's own default, used until the config has loaded.
  static double anonymousMultiplier = 2;

  /// [anonymousMultiplier] for labels, e.g. "2×" or "1.5×".
  static String get anonymousLabel {
    final m = anonymousMultiplier;
    return '${m == m.roundToDouble() ? m.toStringAsFixed(0) : '$m'}×';
  }

  /// Loads the admin's booking settings: [anonymousMultiplier] and
  /// [SessionService.extensionWindow] (`extension_window_minutes`).
  Future<void> loadBookingConfig() async {
    try {
      final config = await ExploreApi.bookingConfig();
      final m = config['anonymous_minutes_multiplier'];
      if (m is num && m > 0) anonymousMultiplier = m.toDouble();
      final window = config['extension_window_minutes'];
      if (window is num && window > 0) SessionService.extensionWindow = Duration(minutes: window.round());
      notifyListeners();
    } on AuthException {
      // Keeps the last known setting.
    }
  }

  /// Why the solver directory couldn't be loaded, if it couldn't.
  String? loadError;

  /// Free ranges per solver and day ("id|yyyy-mm-dd"), as UTC instants.
  final _freeRanges = <String, List<({DateTime start, DateTime end})>>{};
  final _rangeLoads = <String, Future<void>>{};

  /// Loads the bookable solvers, their categories and the seeker's
  /// favourites.
  Future<void> load(AppUser user) async {
    unawaited(loadBookingConfig());
    try {
      final results = await Future.wait([ExploreApi.solvers(), ExploreApi.categories()]);
      final known = {for (final s in _catalog) s.id: s};
      final list = [for (final s in results[0] as List<Map<String, dynamic>>) _solverFrom(s, known[s['solver_id']])];
      _catalog
        ..removeWhere((s) => s.remote)
        ..addAll(list);
      _categories
        ..clear()
        ..addAll(results[1] as Map<String, List<String>>);
      loadError = null;
    } on AuthException catch (e) {
      loadError = e.message;
    }
    if (user.role == UserRole.seeker) {
      try {
        _favorites[user.email] = (await ExploreApi.favorites()).toSet();
      } on AuthException {
        // Favourites stay as they were.
      }
    }
    notifyListeners();
  }

  /// Profile pictures by solver id, and seekers' by booking id, as they come
  /// with the solver directory and bookings.
  final _solverPhotos = <String, String>{};
  final _seekerPhotos = <String, String>{};

  /// [solver]'s profile picture, when known.
  String? solverPhoto(Solver solver) => _solverPhotos[solver.id];

  /// The seeker's profile picture for [booking] (never for anonymous ones).
  String? seekerPhoto(Booking booking) => booking.type == BookingType.anonymous ? null : _seekerPhotos[booking.id];

  /// Records a picture found elsewhere, e.g. in a session's lobby.
  void rememberPhoto({String? solverId, String? bookingId, required String url}) {
    if (solverId != null) _solverPhotos[solverId] = url;
    if (bookingId != null) _seekerPhotos[bookingId] = url;
  }

  Solver _solverFrom(Map<String, dynamic> s, Solver? known) {
    String text(String key) => (s[key] as String?)?.trim() ?? '';
    if (ApiClient.photoLink(s['avatar_url']) case final photo?) _solverPhotos['${s['solver_id']}'] = photo;
    final name = '${text('first_name')} ${text('last_name')}'.trim();
    final bio = text('bio');
    final verified = [
      for (final v in s['verified_skills'] as List? ?? const [])
        if (v is Map) (skill: '${v['skill']}', areas: [for (final a in v['focus_areas'] as List? ?? const []) '$a']),
    ];
    final price = s['price_per_minute'];
    final rate = price is num ? (price / _baseMinuteValue).round().clamp(1, 100) : 1;
    final completed = s['completed_sessions'] is int ? s['completed_sessions'] as int : 0;
    return Solver(
      id: '${s['solver_id']}',
      name: name.isNotEmpty ? name : (text('pseudo_name').isEmpty ? 'Solver' : text('pseudo_name')),
      headline: verified.isEmpty ? text('level_name') : verified.map((v) => v.skill).join(' · '),
      about: bio,
      skills: [for (final k in s['skills'] as List? ?? const []) '$k'],
      category: verified.firstOrNull?.skill ?? '',
      subcategories: [for (final v in verified) ...v.areas],
      rating: s['rating'] is num ? (s['rating'] as num).toDouble() : 0,
      sessions: completed > 0 ? completed : (s['total_sessions'] is int ? s['total_sessions'] as int : 0),
      location: [text('city'), text('country')].where((p) => p.isNotEmpty).join(', '),
      timezone: known?.timezone ?? const TimezoneInfo('UTC', 'GMT+0:00'),
      languages: [for (final l in s['languages'] as List? ?? const []) '$l'],
      rate: rate,
      availableNow: s['is_online'] == true,
      podcastEnabled: s['accept_podcast_bookings'] == true,
      availability: const [],
      problemsSolved: known?.problemsSolved ?? const [],
      reviews: const [],
      remote: true,
      nextAvailableAt: DateTime.tryParse('${s['next_available_at']}')?.toUtc(),
      verifiedSkills: verified,
      pricePaise: price is num ? (price * 100).round() : null,
    );
  }

  /// The prices per minute (paise) the listed solvers charge, lowest first.
  List<int> get priceTiers => {
    for (final s in _catalog)
      if (s.pricePaise != null) s.pricePaise!,
  }.toList()..sort();

  /// Loads the problems a solver solved, for their profile.
  Future<void> loadStories(Solver solver) async {
    if (!solver.remote) return;
    final stories = [
      for (final s in await ExploreApi.solveStories(solver.id))
        ProblemSolved('${s['problem'] ?? ''}', '${s['solution'] ?? ''}'),
    ];
    final index = _catalog.indexWhere((s) => s.id == solver.id);
    if (index < 0) return;
    final old = _catalog[index];
    _catalog[index] = Solver(
      id: old.id,
      name: old.name,
      headline: old.headline,
      about: old.about,
      skills: old.skills,
      category: old.category,
      subcategories: old.subcategories,
      rating: old.rating,
      sessions: old.sessions,
      location: old.location,
      timezone: old.timezone,
      languages: old.languages,
      rate: old.rate,
      availableNow: old.availableNow,
      podcastEnabled: old.podcastEnabled,
      availability: old.availability,
      problemsSolved: stories,
      reviews: old.reviews,
      remote: true,
      nextAvailableAt: old.nextAvailableAt,
      verifiedSkills: old.verifiedSkills,
      pricePaise: old.pricePaise,
    );
    notifyListeners();
  }

  static String _dateKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  /// Fetches a solver's free ranges for the user's local [days] (wall-clock
  /// dates in their zone), so [openSlots] can offer them.
  Future<void> loadSlots(Solver solver, List<DateTime> days, UserZone zone, {bool refresh = false}) async {
    if (!solver.remote) return;
    // The server allows a limited number of these a minute: a refused day
    // waits and asks again instead of going missing.
    Future<List<({String start, String end})>> fetch(String date) async {
      for (var attempt = 0; ; attempt++) {
        try {
          return await ExploreApi.freeRanges(solver.id, date);
        } on ApiException catch (e) {
          if (e.statusCode != 429 || attempt >= 3) rethrow;
          await Future<void>.delayed(Duration(seconds: 4 * (attempt + 1)));
        }
      }
    }

    // Days load one after another, the first (the one on screen) first.
    for (final day in days) {
      await () {
        final key = '${solver.id}|${_dateKey(day)}';
        if (refresh) _rangeLoads.remove(key);
        return _rangeLoads[key] ??= fetch(_dateKey(day))
            .then((ranges) {
              DateTime at(String hhmm) {
                final parts = hhmm.split(':');
                final minutes =
                    (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 0);
                // The server's clock time on that date, at that date's offset.
                return zone.toUtc(DateTime.utc(day.year, day.month, day.day).add(Duration(minutes: minutes)));
              }

              _freeRanges[key] = [for (final r in ranges) (start: at(r.start), end: at(r.end))];
            })
            .catchError((Object _) {
              _rangeLoads.remove(key);
            });
      }();
      // Each day shows as soon as it's in.
      notifyListeners();
    }
  }

  /// A solver's free ranges (UTC) on the user's local [day], once loaded.
  List<({DateTime start, DateTime end})>? freeRangesOn(Solver solver, DateTime day) =>
      _freeRanges['${solver.id}|${_dateKey(day)}'];

  /// Whether a solver's free slots for [day] are still loading.
  bool slotsLoading(Solver solver, DateTime day) =>
      solver.remote && !_freeRanges.containsKey('${solver.id}|${_dateKey(day)}');

  Booking _bookingFrom(AppUser user, Map<String, dynamic> b) {
    final solverId = '${b['solver_id']}';
    if (ApiClient.photoLink(b['solver_avatar_url']) case final photo?) _solverPhotos[solverId] = photo;
    final solver =
        _catalog.where((s) => s.id == solverId).firstOrNull ??
        Solver(
          id: solverId,
          name: (b['solver_name'] as String?)?.trim().isNotEmpty == true ? b['solver_name'] as String : 'Solver',
          headline: '',
          about: '',
          skills: [for (final k in b['solver_skills'] as List? ?? const []) '$k'],
          category: '',
          subcategories: const [],
          rating: b['solver_rating'] is num ? (b['solver_rating'] as num).toDouble() : 0,
          sessions: 0,
          location: '',
          timezone: const TimezoneInfo('UTC', 'GMT+0:00'),
          languages: const [],
          // The multiplier the server priced this booking at.
          rate: b['price_multiplier'] is num ? (b['price_multiplier'] as num).ceil().clamp(1, 100) : 1,
          availableNow: false,
          podcastEnabled: false,
          availability: const [],
          problemsSolved: const [],
          reviews: const [],
          remote: true,
        );
    final type = '${b['booking_type']}'.toLowerCase();
    final cancelled = b['status'] == 'cancelled' || b['status'] == 'declined' || b['status'] == 'expired';
    return Booking(
      id: '${b['booking_id']}',
      sessionId: b['session_id'] as String?,
      serverStatus: b['status'] as String?,
      faceVerified: b['face_verified'] == true,
      userEmail: user.email,
      solver: solver,
      type: b['is_anonymous'] == true || type == 'anonymous'
          ? BookingType.anonymous
          : type == 'podcast'
          ? BookingType.podcast
          : BookingType.normal,
      mode: b['session_mode'] == 'chat' ? SessionMode.chat : SessionMode.meet,
      start: (DateTime.tryParse('${b['scheduled_start_time']}') ?? DateTime.now()).toUtc(),
      minutes: b['duration_minutes'] is int ? b['duration_minutes'] as int : 0,
      title: b['title'] as String? ?? 'Session',
      description: b['description'] as String? ?? '',
      walletMinutes: b['minutes_deducted'] is int ? b['minutes_deducted'] as int : 0,
      seekerName: user.name,
      cancellation: cancelled
          ? Cancellation(
              by: '${b['cancelled_by_role'] ?? (b['status'] == 'expired' ? 'system' : 'solver')}',
              reason: b['cancellation_reason'] as String? ?? 'This session was ${b['status']}.',
              at: (DateTime.tryParse('${b['scheduled_start_time']}') ?? DateTime.now()).toUtc(),
            )
          : null,
    );
  }

  // ---- The solver's bookings (API) -------------------------------------------------

  /// Sessions seekers booked with the signed-in solver, from the API.
  final _solverBookings = <String, List<Booking>>{};
  final _ownProfiles = <String, Solver>{};

  /// The signed-in solver as a [Solver]: their public profile when listed,
  /// otherwise built from their account.
  Solver ownSolver(AppUser user) =>
      SolverService.instance.profileFor(user) ??
      _ownProfiles.putIfAbsent(
        user.email,
        () => Solver(
          id: SessionStore.instance.userId ?? user.email,
          name: user.name,
          headline: '',
          about: user.profile.bio,
          skills: const [],
          category: '',
          subcategories: const [],
          rating: 0,
          sessions: 0,
          location: user.profile.city ?? '',
          timezone: const TimezoneInfo('UTC', 'GMT+0:00'),
          languages: const [],
          rate: 1,
          availableNow: false,
          podcastEnabled: false,
          availability: const [],
          problemsSolved: const [],
          reviews: const [],
          remote: true,
        ),
      );

  /// Loads the sessions seekers booked with the solver.
  Future<void> loadSolverBookings(AppUser user) async {
    if (user.role != UserRole.solver) return;
    final me = ownSolver(user);
    _solverBookings[user.email] = [
      for (final b in await SolverBookingApi.bookings())
        () {
          final type = '${b['booking_type']}'.toLowerCase();
          final status = '${b['status']}';
          final cancelled = status == 'cancelled' || status == 'declined' || status == 'no_show';
          final start = (DateTime.tryParse('${b['scheduled_start_time']}') ?? DateTime.now()).toUtc();
          if (ApiClient.photoLink(b['seeker_avatar_url']) case final photo?) {
            _seekerPhotos['${b['booking_id']}'] = photo;
          }
          return Booking(
            id: '${b['booking_id']}',
            sessionId: b['session_id'] as String?,
            serverStatus: status,
            faceVerified: b['solver_face_verified'] == true,
            userEmail: 'seeker:${b['seeker_id'] ?? b['booking_id']}',
            solver: me,
            type: b['is_anonymous'] == true || type == 'anonymous'
                ? BookingType.anonymous
                : type == 'podcast'
                ? BookingType.podcast
                : BookingType.normal,
            mode: b['session_mode'] == 'chat' ? SessionMode.chat : SessionMode.meet,
            start: start,
            minutes: b['duration_minutes'] is int ? b['duration_minutes'] as int : 0,
            title: b['title'] as String? ?? 'Session',
            description: b['description'] as String? ?? '',
            walletMinutes: 0,
            seekerName: (b['seeker_name'] as String?)?.trim().isNotEmpty == true ? b['seeker_name'] as String : null,
            cancellation: cancelled
                ? Cancellation(
                    by: status == 'no_show' ? 'system' : 'solver or seeker',
                    reason: 'This session was $status.',
                    at: start,
                  )
                : null,
          );
        }(),
    ];
    notifyListeners();
    unawaited(SessionService.instance.refreshEnds(_solverBookings[user.email]!));
  }

  /// Whether [booking] came from the solver bookings API.
  bool isSolverBooking(Booking booking) => _solverBookings.values.any((list) => list.any((b) => b.id == booking.id));

  /// Cancels a session from the solver's side; the seeker gets a full refund.
  /// Allowed until 1 hour before it starts.
  Future<Booking> cancelForSolver(AppUser user, Booking booking, String reason) async {
    if (booking.start.difference(DateTime.now().toUtc()) <= const Duration(hours: 1)) {
      throw const AuthException(
        'This session starts in less than an hour and can no longer be cancelled. Please contact support.',
      );
    }
    await SolverBookingApi.cancel(booking.id, reason);
    final cancelled = Booking(
      id: booking.id,
      userEmail: booking.userEmail,
      solver: booking.solver,
      type: booking.type,
      mode: booking.mode,
      start: booking.start,
      minutes: booking.minutes,
      title: booking.title,
      description: booking.description,
      walletMinutes: booking.walletMinutes,
      seekerName: booking.seekerName,
      rescheduled: booking.rescheduled,
      sessionId: booking.sessionId,
      cancellation: Cancellation(by: 'You', reason: reason.trim(), at: DateTime.now().toUtc()),
    );
    final list = _solverBookings[user.email];
    if (list != null) {
      final index = list.indexWhere((b) => b.id == booking.id);
      if (index >= 0) list[index] = cancelled;
    }
    notifyListeners();
    return cancelled;
  }

  /// Loads the seeker's bookings.
  Future<void> loadBookings(AppUser user) async {
    if (user.role != UserRole.seeker) return;
    final list = [for (final b in await ExploreApi.bookings()) _bookingFrom(user, b)];
    _bookings
      ..removeWhere((b) => b.userEmail == user.email && (b.solver.remote || list.any((n) => n.id == b.id)))
      ..addAll(list);
    notifyListeners();
    unawaited(SessionService.instance.refreshEnds(list));
  }

  /// Gap between the start times offered for a booking.
  static const slotStep = Duration(minutes: 10);

  /// Earliest a booked session can start from now, rounded up to the next
  /// 5 minutes (7:10 PM gives 7:15 PM), as on the web.
  static const bookingLead = Duration(minutes: 5);

  static DateTime earliestBookingStart() {
    final t = DateTime.now().toUtc().add(bookingLead);
    var minute = DateTime.utc(t.year, t.month, t.day, t.hour, t.minute);
    if (t.isAfter(minute)) minute = minute.add(const Duration(minutes: 1));
    return minute.add(Duration(minutes: (5 - minute.minute % 5) % 5));
  }

  final _favorites = <String, Set<String>>{};
  final _bookings = <Booking>[];

  /// The solver directory and categories, loaded from the API.
  final _catalog = <Solver>[];
  final _categories = <String, List<String>>{};

  /// Solvers Seekers can find and book: a solver with an account here shows
  /// only once both their KYC and Skill Verification are complete.
  List<Solver> get solvers => _catalog.where(_listed).toList();

  /// Every profile, listed or not (a solver's own profile, lookups by id).
  List<Solver> get allSolvers => _catalog;

  bool _listed(Solver solver) {
    if (!kEnforceVerification) return true;
    final account = AuthService.instance.solverAccountNamed(solver.name);
    if (account == null) return true;
    return KycService.instance.stateFor(account).completed &&
        SkillVerificationService.instance.verifiedSkills(account).isNotEmpty;
  }

  Map<String, List<String>> get categories => _categories;

  List<String> get languages => {for (final s in _catalog) ...s.languages}.toList()..sort();

  // ---- Favorites -------------------------------------------------------------

  Set<String> favoritesOf(AppUser user) => _favorites.putIfAbsent(user.email, () => {});

  bool isFavorite(AppUser user, Solver solver) => favoritesOf(user).contains(solver.id);

  /// Switches at once and saves; switches back if the save fails.
  void toggleFavorite(AppUser user, Solver solver) {
    final favorites = favoritesOf(user);
    void flip() {
      if (!favorites.remove(solver.id)) favorites.add(solver.id);
      notifyListeners();
    }

    flip();
    if (solver.remote && user.role == UserRole.seeker) {
      ExploreApi.setFavorite(solver.id, favorite: favorites.contains(solver.id)).catchError((Object _) => flip());
    }
  }

  // ---- Time --------------------------------------------------------------------

  /// The user's profile timezone, or the device's when none is set yet.
  static UserZone userZone(AppUser user) {
    final country = Countries.byName(user.profile.countryName);
    return UserZone(country?.timezones.where((t) => t.id == user.profile.timezone).firstOrNull);
  }

  /// Start times (UTC) on the user's local [day] at which [solver] is free for
  /// [minutes]. [day] is a wall-clock date in the user's zone.
  /// [ignoreBookingId] lets a booking being rescheduled keep its own slot free.
  /// For the server's solvers the free ranges come from [loadSlots].
  List<DateTime> openSlots(Solver solver, DateTime day, int minutes, Duration userOffset, {String? ignoreBookingId}) {
    final earliest = earliestBookingStart();
    final slots = <DateTime>[];
    if (solver.remote) {
      final ranges = _freeRanges['${solver.id}|${_dateKey(day)}'] ?? const [];
      // A booking being rescheduled frees its own time again.
      final own = _bookings.where((b) => b.id == ignoreBookingId).firstOrNull;
      final all = [...ranges, if (own != null) (start: own.start, end: own.start.add(Duration(minutes: own.minutes)))];
      for (final r in all) {
        // Steps count from the range's start, or from the earliest start
        // today once that's later; the session must end within the range.
        final first = r.start.isBefore(earliest) ? earliest : r.start;
        for (var t = first; !t.add(Duration(minutes: minutes)).isAfter(r.end); t = t.add(slotStep)) {
          if (!slots.contains(t)) slots.add(t);
        }
      }
    }
    return slots..sort();
  }

  /// The next bookable start time, from the solver directory.
  DateTime? nextOpenSlot(Solver solver, Duration userOffset, {int minutes = 10}) => solver.nextAvailableAt;

  // ---- Pick a solver -----------------------------------------------------------

  /// A solver verified in [category]/[subcategory], picked by the server, or
  /// null when none matches.
  Future<Solver?> pickSolver({required String category, required String subcategory, required DateTime slot}) async {
    final String? id;
    try {
      id = await ExploreApi.matchSolver(category: category, subcategory: subcategory);
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
    return _catalog.where((s) => s.id == id).firstOrNull;
  }

  // ---- Wallet & bookings -------------------------------------------------------

  int walletBalance(AppUser user) => WalletService.instance.balance(user);

  /// Uses the tier the solver currently charges.
  static int walletCost(Solver solver, BookingType type, int minutes) =>
      (minutes * SolverService.instance.rateFor(solver) * type.multiplier).ceil();

  List<Booking> get bookings => List.unmodifiable(_bookings);

  /// The user's bookings, oldest start first.
  List<Booking> bookingsFor(AppUser user) {
    return _bookings.where((b) => b.userEmail == user.email).toList()..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Sessions seekers booked with this solver, oldest start first. Includes
  /// cancelled ones; see [Booking.cancellation].
  List<Booking> bookingsForSolver(AppUser user) =>
      List.of(_solverBookings[user.email] ?? const <Booking>[])..sort((a, b) => a.start.compareTo(b.start));

  /// Moves a booking to [newStart] (UTC). Seekers can't cancel; they can only
  /// reschedule, and only more than an hour before the session. Solvers who
  /// can't attend reschedule the same way.
  Future<Booking> reschedule(Booking booking, DateTime newStart) async {
    if (isSolverBooking(booking)) {
      throw const AuthException(
        'Solvers can\'t reschedule a booked session yet. You can cancel it instead; the seeker gets a full refund.',
      );
    }
    if (booking.start.difference(DateTime.now().toUtc()) <= const Duration(hours: 1)) {
      throw const AuthException('Sessions can only be rescheduled more than 1 hour before they start.');
    }
    final r = await ExploreApi.reschedule(booking.id, newStart);
    final moved = booking.rescheduledTo((DateTime.tryParse('${r['new_scheduled_start_time']}') ?? newStart).toUtc());
    final index = _bookings.indexWhere((b) => b.id == booking.id);
    if (index >= 0) _bookings[index] = moved;
    // Its old time is free again and the new one taken.
    _freeRanges.removeWhere((k, _) => k.startsWith('${booking.solver.id}|'));
    _rangeLoads.removeWhere((k, _) => k.startsWith('${booking.solver.id}|'));
    notifyListeners();
    return moved;
  }

  Future<Booking> book({
    required AppUser user,
    required Solver solver,
    required BookingType type,
    required SessionMode mode,
    required DateTime start,
    required int minutes,
    required String title,
    required String description,
    required bool kycCompleted,
  }) async {
    if (kEnforceVerification && type.needsKyc && !kycCompleted) {
      throw const AuthException('Complete KYC verification to make this booking, or choose Anonymous Booking.');
    }
    if (minutes < type.minMinutes) throw AuthException('The minimum for this booking is ${type.minMinutes} minutes.');
    if (type == BookingType.podcast && (!SolverService.instance.podcastEnabled(solver) || mode != SessionMode.meet)) {
      throw const AuthException('Podcasts are Meet sessions with podcast-enabled solvers only.');
    }
    // The server checks the slot, KYC and the wallet, and freezes the minutes.
    final created = await ExploreApi.book({
      'solver_id': solver.id,
      'booking_type': switch (type) {
        BookingType.normal => 'normal',
        BookingType.anonymous => 'anonymous',
        BookingType.podcast => 'podcast',
      },
      'session_mode': mode == SessionMode.chat ? 'chat' : 'meeting',
      'title': title.trim(),
      if (description.trim().isNotEmpty) 'description': description.trim(),
      'scheduled_start_time': start.toUtc().toIso8601String(),
      'duration_minutes': minutes,
      if (solver.category.isNotEmpty) 'category': solver.category,
      'idempotency_key': '${user.email.hashCode}-${solver.id}-${start.millisecondsSinceEpoch}-$minutes',
      // Podcasts are recorded; booking one is the seeker's consent.
      if (type == BookingType.podcast) 'recording_consent': true,
    });
    final booking = Booking(
      id: '${created['booking_id']}',
      sessionId: created['session_id'] as String?,
      userEmail: user.email,
      solver: solver,
      type: type,
      mode: mode,
      start: (DateTime.tryParse('${created['scheduled_start_time']}') ?? start).toUtc(),
      minutes: created['duration_minutes'] is int ? created['duration_minutes'] as int : minutes,
      title: title,
      description: description,
      walletMinutes: created['minutes_deducted'] is int
          ? created['minutes_deducted'] as int
          : walletCost(solver, type, minutes),
      seekerName: user.name,
    );
    _bookings.add(booking);
    _freeRanges.removeWhere((k, _) => k.startsWith('${solver.id}|'));
    _rangeLoads.removeWhere((k, _) => k.startsWith('${solver.id}|'));
    notifyListeners();
    // The frozen minutes show in the wallet from the server.
    unawaited(WalletService.instance.load(user));
    return booking;
  }
}
