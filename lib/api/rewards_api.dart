import 'api_client.dart';

/// Seeker rewards (Postman: Seeker App > Rewards, Referral Code, Referrals,
/// Streaks): points wallet and history, conversion to minutes, referrals and
/// streaks, plus the admin-configured reward values.
abstract final class RewardsApi {
  static ApiClient get _api => ApiClient.instance;

  /// GET /public/rewards/config: `{config_key: integer | [integer]}`.
  static Future<Map<String, dynamic>> config() async => _map(await _api.get('/public/rewards/config'));

  /// GET /seeker/rewards/wallet: available and redeemed points and the rate.
  static Future<Map<String, dynamic>> wallet() async => _map(await _api.get('/seeker/rewards/wallet'));

  /// GET /seeker/rewards/history: the latest [limit] ledger entries.
  static Future<List<Map<String, dynamic>>> history({int limit = 100}) async {
    final recent = _map(await _api.get('/seeker/rewards/history', query: {'limit': limit, 'page': 1}))['recent'];
    return [
      if (recent is List)
        for (final e in recent) _map(e),
    ];
  }

  /// POST /seeker/rewards/convert. Only whole minutes are converted; returns
  /// `{points_deducted, minutes_credited}`.
  static Future<Map<String, dynamic>> convert(int points) async =>
      _map(await _api.post('/seeker/rewards/convert', data: {'points': points}));

  /// POST /seeker/rewards/report-solver. The reward follows admin validation.
  static Future<void> reportSolver({
    required String solverId,
    required String violationType,
    required String details,
    List<String> evidenceUrls = const [],
  }) => _api.post(
    '/seeker/rewards/report-solver',
    data: {
      'solver_public_id': solverId,
      'violation_type': violationType,
      'details': details.trim(),
      if (evidenceUrls.isNotEmpty) 'evidence_urls': evidenceUrls,
    },
  );

  /// GET /seeker/referral-code: `{referral_code, referral_link, usage_count, max_usages}`.
  static Future<Map<String, dynamic>> referralCode() async => _map(await _api.get('/seeker/referral-code'));

  /// GET /seeker/referrals: the people the seeker invited.
  static Future<List<Map<String, dynamic>>> referrals() async {
    final list = _map(await _api.get('/seeker/referrals/'))['referrals'];
    return [
      if (list is List)
        for (final r in list) _map(r),
    ];
  }

  /// GET /seeker/dashboard: `{stats: {streak_count, sessions_completed, ...},
  /// streaks: {week_current, ..., last_activity}, ...}`.
  static Future<Map<String, dynamic>> dashboard() async => _map(await _api.get('/seeker/dashboard'));

  /// GET /seeker/streaks: `{week|month|quarter|year: {current, max}}`.
  static Future<Map<String, dynamic>> streaks() async => _map(await _api.get('/seeker/streaks/'));

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
