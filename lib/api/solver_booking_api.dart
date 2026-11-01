import 'api_client.dart';

/// The solver's side of bookings (Postman: Solver App > Bookings,
/// Availability, Booking Links): booked sessions, cancelling, the weekly
/// schedule seekers book into, podcast bookings and custom booking links.
abstract final class SolverBookingApi {
  static ApiClient get _api => ApiClient.instance;

  /// GET /solver/bookings: every booking, newest first.
  static Future<List<Map<String, dynamic>>> bookings() async {
    final all = <Map<String, dynamic>>[];
    for (var page = 1; page <= 10; page++) {
      final batch = _list(await _api.get('/solver/bookings/', query: {'page': page, 'limit': 100}));
      all.addAll(batch);
      if (batch.length < 100) break;
    }
    return all;
  }

  /// POST /solver/bookings/:id/cancel: cancels with a full refund to the
  /// seeker; allowed until 1 hour before the start.
  static Future<void> cancel(String bookingId, String reason) =>
      _api.post('/solver/bookings/$bookingId/cancel', data: {'reason': reason.trim()});

  /// GET /solver/availability/get?raw=true: the saved windows on [date]
  /// (YYYY-MM-DD) in the solver's timezone, as `HH:MM` pairs.
  static Future<List<({String start, String end})>> savedWindows(String date) async {
    final data = _map(await _api.get('/solver/availability/get', query: {'date': date, 'raw': 'true'}));
    return [
      for (final s in _list(data['available_slots']))
        if (s['start_time'] is String && s['end_time'] is String)
          (start: s['start_time'] as String, end: s['end_time'] as String),
    ];
  }

  /// POST /solver/availability/weekly-schedule: the weekly pattern
  /// (`Sunday`…`Saturday` → `HH:MM-HH:MM`, empty = day off) plus date
  /// overrides, opened for the next [daysForward] days.
  static Future<void> saveWeekly({
    required Map<String, List<String>> weekly,
    required Map<String, List<String>> overrides,
    required String timezone,
    required int daysForward,
  }) => _api.post(
    '/solver/availability/weekly-schedule',
    data: {
      'weekly': weekly,
      'overrides': overrides,
      'timezone': timezone,
      'schedule_type': 'sessions',
      'days_forward': daysForward,
    },
  );

  /// GET /solver/availability/podcast-enabled.
  static Future<bool> podcastEnabled() async =>
      _map(await _api.get('/solver/availability/podcast-enabled'))['accept_podcast_bookings'] == true;

  /// POST /solver/availability/podcast-enabled.
  static Future<void> setPodcastEnabled(bool enabled) =>
      _api.post('/solver/availability/podcast-enabled', data: {'enabled': enabled});

  /// GET /solver/profile/booking-link: the relative public booking path.
  static Future<String?> profileLinkPath() async =>
      _map(await _api.get('/solver/profile/booking-link'))['link'] as String?;

  /// GET /solver/booking-links: custom links, including deactivated ones.
  static Future<List<Map<String, dynamic>>> links() async => _list(await _api.get('/solver/booking-links/'));

  /// POST /solver/booking-links. [price] is ₹5, 10, 15 or 20 per minute, not
  /// above the solver's own rate.
  static Future<Map<String, dynamic>> createLink({
    required String title,
    required int durationMinutes,
    required int price,
  }) async => _map(
    await _api.post(
      '/solver/booking-links/',
      data: {'title': title.trim(), 'duration_minutes': durationMinutes, 'custom_price': price},
    ),
  );

  /// DELETE /solver/booking-links/:id.
  static Future<void> deleteLink(String id) => _api.delete('/solver/booking-links/$id');

  static List<Map<String, dynamic>> _list(Object? data) => [
    if (data is List)
      for (final item in data) _map(item),
  ];

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
