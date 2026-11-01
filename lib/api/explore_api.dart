import 'api_client.dart';

/// Explore and bookings for seekers (Postman: Seeker App > Solvers, Solver
/// Categories, Explore, Solver Availability, Bookings; Shared > Booking
/// Config): the solver directory, favourites, free slots and bookings.
abstract final class ExploreApi {
  static ApiClient get _api => ApiClient.instance;

  /// GET /public/solvers/search: every bookable solver, best rated first.
  static Future<List<Map<String, dynamic>>> solvers({int max = 200}) async {
    final all = <Map<String, dynamic>>[];
    for (var page = 1; all.length < max; page++) {
      final data = _map(await _api.get('/public/solvers/search', query: {'page': page, 'limit': 50}));
      final batch = _list(data['solvers']);
      all.addAll(batch);
      final total = _map(data['pagination'])['total'];
      if (batch.length < 50 || (total is int && all.length >= total)) break;
    }
    return all;
  }

  /// GET /public/solver-categories: skill → focus areas held by bookable
  /// solvers.
  static Future<Map<String, List<String>>> categories() async {
    final list = _map(await _api.get('/public/solver-categories'))['categories'];
    return {
      if (list is List)
        for (final c in list)
          if (c is Map && c['name'] is String)
            c['name'] as String: [for (final s in c['sub_categories'] as List? ?? const []) '$s'],
    };
  }

  /// GET /public/solvers/:id/solve-stories: problems the solver solved.
  static Future<List<Map<String, dynamic>>> solveStories(String solverId) async =>
      _list(await _api.get('/public/solvers/$solverId/solve-stories'));

  /// GET /public/booking-config: e.g. the anonymous minutes multiplier.
  static Future<Map<String, dynamic>> bookingConfig() async => _map(await _api.get('/public/booking-config'));

  /// GET /seeker/explore/favorites: the favourite solvers' ids.
  static Future<List<String>> favorites() async {
    final data = _map(await _api.get('/seeker/explore/favorites/', query: {'limit': 50}));
    return [for (final s in _list(data['solvers'])) '${s['solver_id']}'];
  }

  /// Adds or removes a favourite solver.
  static Future<void> setFavorite(String solverId, {required bool favorite}) =>
      favorite ? _api.post('/seeker/explore/favorites/$solverId') : _api.delete('/seeker/explore/favorites/$solverId');

  /// GET /seeker/solver-availability/slots: the solver's free ranges on
  /// [date] (YYYY-MM-DD) in the seeker's timezone, as `HH:MM` pairs.
  static Future<List<({String start, String end})>> freeRanges(String solverId, String date) async {
    final data = _map(
      await _api.get('/seeker/solver-availability/slots', query: {'solver_id': solverId, 'date': date}),
    );
    return [
      for (final s in _list(data['available_slots']))
        if (s['start_time'] is String && s['end_time'] is String)
          (start: s['start_time'] as String, end: s['end_time'] as String),
    ];
  }

  /// GET /seeker/solver-availability/match-solver: a random bookable solver
  /// verified in the skill / focus area.
  static Future<String?> matchSolver({required String category, required String subcategory}) async =>
      _map(
            await _api.get(
              '/seeker/solver-availability/match-solver',
              query: {'category': category, 'sub_category': subcategory},
            ),
          )['solver_id']
          as String?;

  /// GET /seeker/bookings: the seeker's bookings, every page.
  static Future<List<Map<String, dynamic>>> bookings() async {
    final all = <Map<String, dynamic>>[];
    for (var page = 1; page <= 10; page++) {
      final batch = _list(await _api.get('/seeker/bookings/', query: {'page': page, 'limit': 100}));
      all.addAll(batch);
      if (batch.length < 100) break;
    }
    return all;
  }

  /// GET /seeker/bookings/:id: one booking, including its newest extension
  /// request (`extension_status`, `extension_remaining_seconds`,
  /// `extension_extra_minutes`) and `price_multiplier`.
  static Future<Map<String, dynamic>> bookingDetail(String bookingId) async =>
      _map(await _api.get('/seeker/bookings/$bookingId'));

  /// POST /seeker/bookings: books a session; the wallet minutes are frozen.
  static Future<Map<String, dynamic>> book(Map<String, dynamic> booking) async =>
      _map(await _api.post('/seeker/bookings/', data: booking));

  /// POST /seeker/bookings/:id/reschedule.
  static Future<Map<String, dynamic>> reschedule(String bookingId, DateTime newStart) async => _map(
    await _api.post(
      '/seeker/bookings/$bookingId/reschedule',
      data: {'new_scheduled_start_time': newStart.toUtc().toIso8601String()},
    ),
  );

  static List<Map<String, dynamic>> _list(Object? data) => [
    if (data is List)
      for (final item in data) _map(item),
  ];

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
