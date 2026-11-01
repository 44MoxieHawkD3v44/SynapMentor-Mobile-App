import 'api_client.dart';

/// The solver's wallet (Postman: Solver App > Wallet): earned Synap Minutes,
/// the earnings ledger, payout methods and withdrawals.
abstract final class SolverWalletApi {
  static ApiClient get _api => ApiClient.instance;

  /// GET /solver/wallet: available, pending and lifetime minutes, and the
  /// minimum withdrawal.
  static Future<Map<String, dynamic>> summary() async => _map(await _api.get('/solver/wallet/'));

  /// GET /solver/wallet/history: the latest [max] ledger rows, newest first.
  static Future<List<Map<String, dynamic>>> history({int max = 300}) async {
    final all = <Map<String, dynamic>>[];
    String? cursor;
    while (all.length < max) {
      final data = _map(await _api.get('/solver/wallet/history', query: {'limit': 100, 'cursor': ?cursor}));
      all.addAll(_list(data['items']));
      cursor = data['next_cursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    return all;
  }

  /// GET /solver/wallet/withdrawals (latest 50).
  static Future<List<Map<String, dynamic>>> withdrawals() async => _list(await _api.get('/solver/wallet/withdrawals'));

  /// GET /solver/wallet/payment-methods (details come back masked).
  static Future<List<Map<String, dynamic>>> methods() async => _list(await _api.get('/solver/wallet/payment-methods'));

  /// POST /solver/wallet/payment-methods. [type] is `upi` or `bank_account`.
  static Future<Map<String, dynamic>> addMethod({
    required String type,
    required String displayName,
    required Map<String, dynamic> details,
    required bool makeDefault,
  }) async => _map(
    await _api.post(
      '/solver/wallet/payment-methods',
      data: {'method_type': type, 'display_name': displayName, 'details': details, 'is_default': makeDefault},
    ),
  );

  /// PATCH /solver/wallet/payment-methods/:id. [details] are merged over the
  /// stored ones.
  static Future<Map<String, dynamic>> updateMethod(
    String id, {
    String? displayName,
    Map<String, dynamic>? details,
    bool? makeDefault,
  }) async => _map(
    await _api.patch(
      '/solver/wallet/payment-methods/$id',
      data: {
        'display_name': ?displayName,
        if (details != null && details.isNotEmpty) 'details': details,
        'is_default': ?makeDefault,
      },
    ),
  );

  /// DELETE /solver/wallet/payment-methods/:id.
  static Future<void> removeMethod(String id) => _api.delete('/solver/wallet/payment-methods/$id');

  /// POST /solver/wallet/withdraw/initiate: a 2-minute priced quote
  /// (`{quote, destination}`), paid to [methodId] or the default method.
  static Future<Map<String, dynamic>> quote(int minutes, {String? methodId}) async => _map(
    await _api.post(
      '/solver/wallet/withdraw/initiate',
      data: {'minutes_requested': minutes, 'payment_method_id': ?methodId},
    ),
  );

  /// POST /solver/wallet/withdraw/confirm: records the request and takes the
  /// minutes out of the wallet.
  static Future<void> confirm(String quoteId) =>
      _api.post('/solver/wallet/withdraw/confirm', data: {'quote_id': quoteId}, idempotent: true);

  static List<Map<String, dynamic>> _list(Object? data) => [
    if (data is List)
      for (final item in data) _map(item),
  ];

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
