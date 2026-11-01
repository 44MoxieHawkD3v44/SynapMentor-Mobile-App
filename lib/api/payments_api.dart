import 'api_client.dart';

/// Seeker payments and wallet (Postman: Seeker App > Payments, Wallet,
/// Subscription Plans): minute packs and subscriptions paid through Razorpay,
/// coupons, the wallet and the payment history.
abstract final class PaymentsApi {
  static ApiClient get _api => ApiClient.instance;

  /// GET /seeker/payments/minute-packs.
  static Future<List<Map<String, dynamic>>> minutePacks() async =>
      _list(await _api.get('/seeker/payments/minute-packs'));

  /// GET /public/subscription-plans.
  static Future<List<Map<String, dynamic>>> plans() async =>
      _list(_map(await _api.get('/public/subscription-plans', query: {'limit': 100}))['plans']);

  /// GET /seeker/payments/subscription: `{has_subscription, enrollment, plan_name, …}`.
  static Future<Map<String, dynamic>> subscription() async => _map(await _api.get('/seeker/payments/subscription'));

  /// GET /seeker/payments/coupons: coupons the seeker can still use.
  static Future<List<Map<String, dynamic>>> coupons() async => _list(await _api.get('/seeker/payments/coupons'));

  /// POST /seeker/payments/apply-coupon. [scope] is `minute_packs` or
  /// `subscription_plans`. Returns `{is_valid, bonus_minutes, message}`.
  static Future<Map<String, dynamic>> checkCoupon(String code, String scope) async =>
      _map(await _api.post('/seeker/payments/apply-coupon', data: {'coupon_code': code.trim(), 'scope': scope}));

  /// GET /public/fx-rates: `{currency, rate, inverse_rate}`, where `rate`
  /// converts INR to [currency] for display.
  static Future<Map<String, dynamic>> fxRate(String currency) async =>
      _map(await _api.get('/public/fx-rates', query: {'currency': currency}));

  /// POST /seeker/payments/buy-minutes: a Razorpay order for a pack, in
  /// [currency] when set.
  static Future<Map<String, dynamic>> buyMinutes(String packId, {String? couponCode, String? currency}) async => _map(
    await _api.post(
      '/seeker/payments/buy-minutes',
      data: {'minute_pack_id': packId, 'coupon_code': ?couponCode, 'currency': ?currency},
      idempotent: true,
    ),
  );

  /// POST /seeker/payments/buy-subscription: a Razorpay order for a plan.
  static Future<Map<String, dynamic>> buySubscription(String planId, {String? couponCode, String? currency}) async =>
      _map(
        await _api.post(
          '/seeker/payments/buy-subscription',
          data: {'plan_id': planId, 'billing_cycle': 'monthly', 'coupon_code': ?couponCode, 'currency': ?currency},
          idempotent: true,
        ),
      );

  /// Confirms a Razorpay payment: credits the minutes or activates the plan.
  static Future<void> verify({
    required String orderId,
    required String paymentId,
    required String signature,
    required bool subscription,
  }) => _api.post(
    subscription ? '/seeker/payments/verify-subscription' : '/seeker/payments/verify',
    data: {'order_id': orderId, 'gateway_payment_id': paymentId, 'gateway_signature': signature},
  );

  /// GET /seeker/wallet: `{minutes_balance, minutes_spent, …}`.
  static Future<Map<String, dynamic>> wallet() async => _map(await _api.get('/seeker/wallet/'));

  /// GET /seeker/payments/history: the latest [limit] purchases and wallet
  /// movements.
  static Future<List<Map<String, dynamic>>> history({int limit = 100}) async =>
      _list(_map(await _api.get('/seeker/payments/history', query: {'limit': limit}))['items']);

  /// GET /seeker/wallet/history: the wallet ledger, newest first, with the
  /// balance after each movement.
  static Future<List<Map<String, dynamic>>> walletLedger() async =>
      _list(_map(await _api.get('/seeker/wallet/history', query: {'limit': 100}))['items']);

  /// GET /seeker/payments/export: the full history, for saving.
  static Future<List<Map<String, dynamic>>> export() async => _list(await _api.get('/seeker/payments/export'));

  static List<Map<String, dynamic>> _list(Object? data) => [
    if (data is List)
      for (final item in data) _map(item),
  ];

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
