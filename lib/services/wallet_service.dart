import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';

import '../api/payments_api.dart';

import 'auth_service.dart';
import 'countries.dart';

/// Share of a completed session's minutes paid to the solver; the rest is the
/// platform fee.
const solverShare = 0.70;

/// The currency a seeker sees prices in: their profile country's, converted
/// from INR at the server's display rate.
class DisplayCurrency {
  const DisplayCurrency(this.code, this.symbol, this.rate);

  static const inr = DisplayCurrency('INR', '₹', 1);

  final String code;
  final String symbol;

  /// Units of [code] per rupee.
  final double rate;

  bool get isInr => code == 'INR';
}

/// Money is kept in paise (INR) so amounts stay exact; it's shown in the
/// seeker's currency.
String formatMoney(int paise) {
  final currency = WalletService.instance.currency;
  final cents = currency.isInr ? paise : (paise * currency.rate).round();
  final whole = cents ~/ 100;
  final fraction = cents % 100;
  final digits = whole.toString();
  final buffer = StringBuffer();
  if (digits.length <= 3) {
    buffer.write(digits);
  } else if (currency.isInr) {
    // Indian grouping: last three digits, then pairs (12,34,567).
    final head = digits.substring(0, digits.length - 3);
    for (var i = 0; i < head.length; i++) {
      if (i > 0 && (head.length - i) % 2 == 0) buffer.write(',');
      buffer.write(head[i]);
    }
    buffer.write(',${digits.substring(digits.length - 3)}');
  } else {
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
  }
  return '${currency.symbol}$buffer${fraction == 0 ? '' : '.${fraction.toString().padLeft(2, '0')}'}';
}

/// GST on [paise] at the server's rate ([WalletService.gstPercent]), or null
/// while the server hasn't sent one.
int? gstOn(int paise) {
  final percent = WalletService.instance.gstPercent;
  return percent == null ? null : (paise * percent / 100).round();
}

/// "18% GST" at the server's rate, or just "GST" while it isn't known.
String get gstLabel {
  final percent = WalletService.instance.gstPercent;
  if (percent == null) return 'GST';
  return '${percent == percent.roundToDouble() ? percent.toStringAsFixed(0) : '$percent'}% GST';
}

class MinutePack {
  const MinutePack(this.id, this.name, this.minutes, this.bonusMinutes, this.pricePaise, {this.priceInclTaxPaise});

  final String id;
  final String name;
  final int minutes;
  final int bonusMinutes;

  /// Before GST.
  final int pricePaise;

  /// With GST, as the server works it out.
  final int? priceInclTaxPaise;

  int get totalMinutes => minutes + bonusMinutes;
}

class SubscriptionPlan {
  const SubscriptionPlan(this.id, this.name, this.pricePaise, this.features, {this.originalPricePaise});

  final String id;
  final String name;

  /// Per month, before GST.
  final int pricePaise;

  /// Set when the plan is on a limited offer.
  final int? originalPricePaise;
  final List<String> features;

  int? get discountPercent =>
      originalPricePaise == null ? null : ((1 - pricePaise / originalPricePaise!) * 100).round();
}

class Subscription {
  const Subscription(this.plan, this.startedAt, this.expiresAt);

  final SubscriptionPlan plan;
  final DateTime startedAt;
  final DateTime expiresAt;

  bool get active => DateTime.now().isBefore(expiresAt);

  int get daysLeft => expiresAt.difference(DateTime.now()).inDays.clamp(0, 9999);
}

enum TransactionType {
  purchase('Minutes Purchased', 'MINUTE_PURCHASE'),
  couponBonus('Coupon Bonus', 'COUPON_BONUS'),
  booking('Session Booking', 'BOOKING_FREEZE'),
  refund('Refunded Minutes', 'REFUND'),
  subscription('Subscription Purchase', 'SUBSCRIPTION'),
  rewardConversion('Points Converted', 'POINTS_CONVERSION');

  const TransactionType(this.label, this.code);
  final String label;
  final String code;
}

enum PaymentMethod {
  upi('UPI', 'Pay using any UPI app'),
  card('Credit / Debit Card', 'Visa, MasterCard, RuPay'),
  netBanking('Net Banking', 'All major banks supported');

  const PaymentMethod(this.label, this.subtitle);
  final String label;
  final String subtitle;
}

class WalletTransaction {
  const WalletTransaction({
    required this.id,
    required this.type,
    required this.title,
    required this.detail,
    required this.date,
    this.minutes = 0,
    this.amountPaidPaise,
    this.status = 'Completed',
    this.balanceAfter,
  });

  final String id;
  final TransactionType type;
  final String title;
  final String detail;
  final DateTime date;

  /// Signed: credits are positive, bookings negative.
  final int minutes;

  /// Money paid, including GST. Only set for minute packs and subscriptions.
  final int? amountPaidPaise;
  final String status;

  /// The wallet's minutes right after this, when the ledger has it.
  final int? balanceAfter;

  /// "Credit", "Debit", or null when no minutes moved.
  String? get direction => minutes > 0 ? 'Credit' : (minutes < 0 ? 'Debit' : null);

  WalletTransaction withBalance(int? balance) => WalletTransaction(
    id: id,
    type: type,
    title: title,
    detail: detail,
    date: date,
    minutes: minutes,
    amountPaidPaise: amountPaidPaise,
    status: status,
    balanceAfter: balance,
  );
}

class Coupon {
  const Coupon(this.code, this.bonusMinutes, this.description, {this.appliesTo = 'minute_packs', this.expiresAt});

  final String code;
  final int bonusMinutes;
  final String description;

  /// What it can be used on: `minute_packs` or `subscription_plans` (or
  /// both).
  final String appliesTo;
  final DateTime? expiresAt;

  bool get forPacks => !appliesTo.contains('subscription') || appliesTo.contains('all');
  bool get forPlans => appliesTo.contains('subscription') || appliesTo.contains('all');

  /// E.g. "Minute Packs" or "Subscriptions".
  String get appliesToLabel => switch ((forPacks, forPlans)) {
    (true, true) => 'Minute Packs & Subscriptions',
    (false, true) => 'Subscriptions',
    _ => 'Minute Packs',
  };
}

/// The seeker's wallet, payments and subscription. Packs, plans, the balance
/// and the history come from the payments API, and purchases are paid through
/// Razorpay and confirmed by the server.
class WalletService extends ChangeNotifier {
  static final WalletService instance = WalletService();

  // ---- API (seekers) -------------------------------------------------------------

  /// Users whose wallet came from the API; purchases for them go to Razorpay.
  final _remote = <String>{};

  /// The server's balance and minutes spent, per user.
  final _apiBalance = <String, int>{};
  final _apiSpent = <String, int>{};

  /// Why part of the payments couldn't be loaded, if it couldn't.
  String? loadError;

  /// Coupons and payments need the wallet from the API.
  static const _notLoaded = AuthException('Your wallet couldn\'t be loaded. Please try again.');

  static int _paise(Object? rupees) => rupees is num ? (rupees * 100).round() : 0;

  /// The GST percentage the server charges on packs and subscriptions (its
  /// `tax_percentage`), or null until it has loaded or when the server's tax
  /// setting couldn't be read.
  double? gstPercent;

  /// What prices are shown in. INR until the seeker's currency has loaded,
  /// and INR again when the server has no rate for it.
  DisplayCurrency currency = DisplayCurrency.inr;

  /// Whether the server balance for [user] has been loaded.
  bool isLoaded(AppUser user) => _apiBalance.containsKey(user.email);

  /// The profile country's currency, with the server's display rate.
  Future<void> _loadCurrency(AppUser user) async {
    final country = Countries.byName(user.profile.countryName);
    if (country == null || country.currencyCode == 'INR') {
      currency = DisplayCurrency.inr;
      return;
    }
    try {
      final r = await PaymentsApi.fxRate(country.currencyCode);
      final rate = r['rate'];
      currency = rate is num && rate > 0
          ? DisplayCurrency(country.currencyCode, country.currencySymbol, rate.toDouble())
          : DisplayCurrency.inr;
    } on AuthException {
      currency = DisplayCurrency.inr;
    }
  }

  /// The currency to charge in, when it isn't INR.
  String? get _orderCurrency => currency.isInr ? null : currency.code;

  /// Creates an order in the seeker's currency, or in INR when the server
  /// won't take that currency.
  Future<Map<String, dynamic>> _order(Future<Map<String, dynamic>> Function(String? currency) create) async {
    final code = _orderCurrency;
    if (code == null) return create(null);
    try {
      return await create(code);
    } on AuthException {
      return create(null);
    }
  }

  /// Loads the packs, plans, coupons, wallet, history and subscription. Each
  /// part loads on its own, so one refusal doesn't hide the rest.
  Future<void> load(AppUser user) async {
    if (user.role != UserRole.seeker) return;
    final errors = <String>[];
    Future<void> part(Future<void> Function() load) async {
      try {
        await load();
      } catch (e) {
        errors.add(e is AuthException ? e.message : 'Couldn\'t load part of your payments.');
      }
    }

    await Future.wait([
      _loadCurrency(user),
      part(() async {
        final list = await PaymentsApi.minutePacks();
        packs
          ..clear()
          ..addAll([
            for (final p in list)
              MinutePack(
                '${p['pack_id']}',
                p['title'] as String? ?? 'Minute Pack',
                p['base_minutes'] is int ? p['base_minutes'] as int : 0,
                p['bonus_minutes'] is int ? p['bonus_minutes'] as int : 0,
                _paise(p['price']),
                priceInclTaxPaise: p['price_incl_tax'] is num ? _paise(p['price_incl_tax']) : null,
              ),
          ]);
        // One tax setting covers packs and subscriptions.
        final percent = list.map((p) => p['tax_percentage']).whereType<num>().firstOrNull;
        gstPercent = percent?.toDouble();
      }),
      part(() async {
        plans
          ..clear()
          ..addAll([
            for (final p in await PaymentsApi.plans())
              if (p['is_active'] != false) _planFrom(p),
          ]);
      }),
      part(() async {
        _coupons
          ..clear()
          ..addAll([
            for (final c in await PaymentsApi.coupons())
              Coupon(
                '${c['code']}',
                c['bonus_minutes'] is int ? c['bonus_minutes'] as int : 0,
                c['title'] as String? ?? '',
                appliesTo: c['applies_to'] as String? ?? 'minute_packs',
                expiresAt: DateTime.tryParse('${c['expires_at'] ?? ''}')?.toLocal(),
              ),
          ]);
      }),
      part(() async {
        final w = await PaymentsApi.wallet();
        _apiBalance[user.email] = w['minutes_balance'] is int ? w['minutes_balance'] as int : 0;
        _apiSpent[user.email] = w['minutes_spent'] is int ? w['minutes_spent'] as int : 0;
      }),
      part(() async {
        final results = await Future.wait([
          PaymentsApi.history(),
          PaymentsApi.walletLedger().catchError((Object _) => <Map<String, dynamic>>[]),
        ]);
        _ledgers[user.email] = _withBalances([for (final t in results[0].reversed) _transactionFrom(t)], results[1]);
      }),
      part(() async {
        final s = await PaymentsApi.subscription();
        final enrollment = s['enrollment'] is Map ? Map<String, dynamic>.from(s['enrollment'] as Map) : null;
        if (s['has_subscription'] != true || enrollment == null) {
          _subscriptions.remove(user.email);
          return;
        }
        final plan =
            plans.where((p) => p.id == enrollment['plan_id']).firstOrNull ??
            SubscriptionPlan('${enrollment['plan_id']}', s['plan_name'] as String? ?? 'Subscription', 0, const []);
        _subscriptions[user.email] = Subscription(
          plan,
          (DateTime.tryParse('${enrollment['starts_at']}') ?? DateTime.now()).toLocal(),
          (DateTime.tryParse('${enrollment['expires_at']}') ?? DateTime.now()).toLocal(),
        );
      }),
    ]);
    _remote.add(user.email);
    loadError = errors.firstOrNull;
    notifyListeners();
  }

  /// A plan as the app shows it: the monthly price, with the launch discount
  /// as an offer, and its benefits as features.
  SubscriptionPlan _planFrom(Map<String, dynamic> p) {
    final monthly = _paise(p['monthly_price'] ?? p['price']);
    final discount = p['launch_discount_pct'] is int ? p['launch_discount_pct'] as int : 0;
    final free = p['free_session_minutes'] is int ? p['free_session_minutes'] as int : 0;
    final access = '${p['content_access_level'] ?? ''}'.replaceAll('_', ' ').trim();
    final labs = p['premium_labs_limit'];
    final multiplier = p['reward_multiplier'];
    return SubscriptionPlan(
      '${p['id']}',
      p['name'] as String? ?? 'Plan',
      discount > 0 ? (monthly * (100 - discount) / 100).round() : monthly,
      [
        if ((p['description'] as String?)?.trim().isNotEmpty == true) (p['description'] as String).trim(),
        if (access.isNotEmpty) '${access[0].toUpperCase()}${access.substring(1)} content access',
        if (free > 0) '$free free session minutes',
        if (p['premium_labs_enabled'] == true) labs is int ? '$labs premium labs' : 'Premium labs',
        if (p['early_access'] == true) 'Early access to new features',
        if (multiplier is num && multiplier > 1) '${multiplier}x reward points',
      ],
      originalPricePaise: discount > 0 ? monthly : null,
    );
  }

  /// Adds the balance after each entry from the wallet ledger: the ledger
  /// row with the same minutes, recorded within a couple of minutes of it.
  static List<WalletTransaction> _withBalances(List<WalletTransaction> list, List<Map<String, dynamic>> ledger) {
    final rows = [
      for (final r in ledger)
        (
          minutes: r['minutes_delta'] is int ? r['minutes_delta'] as int : 0,
          at: DateTime.tryParse('${r['created_at']}')?.toLocal(),
          balance: r['minutes_balance_after'] is int ? r['minutes_balance_after'] as int : null,
        ),
    ];
    final used = <int>{};
    return [
      for (final t in list)
        t.withBalance(() {
          for (var i = 0; i < rows.length; i++) {
            final r = rows[i];
            final at = r.at;
            if (used.contains(i) || at == null || r.minutes != t.minutes) continue;
            if (at.difference(t.date).abs() > const Duration(minutes: 2)) continue;
            used.add(i);
            return r.balance;
          }
          return null;
        }()),
    ];
  }

  WalletTransaction _transactionFrom(Map<String, dynamic> t) {
    final type = '${t['type']}'.toUpperCase();
    final minutes = t['minutes'] is int ? t['minutes'] as int : 0;
    final amount = _paise(t['amount']);
    final description = t['description'] as String? ?? '';
    final kind = switch (type) {
      'PURCHASE' => minutes == 0 ? TransactionType.subscription : TransactionType.purchase,
      'TOPUP' => TransactionType.purchase,
      'BOOKING_DEBIT' || 'BOOKING_FREEZE' => TransactionType.booking,
      'BOOKING_UNFREEZE' || 'REFUND' => TransactionType.refund,
      'REWARD_CONVERT' => TransactionType.rewardConversion,
      _ => minutes >= 0 ? TransactionType.refund : TransactionType.booking,
    };
    final status = '${t['status'] ?? 'completed'}';
    final booking = t['booking_title'] as String?;
    return WalletTransaction(
      id: '${t['id']}',
      type: kind,
      title: booking?.isNotEmpty == true ? booking! : (description.isNotEmpty ? description : kind.label),
      detail: [
        if (booking?.isNotEmpty == true && description.isNotEmpty) description,
        if (t['is_extension'] == true) 'Session extension',
        if (kind == TransactionType.purchase && minutes > 0) '$minutes minutes',
      ].join(' · '),
      date: (DateTime.tryParse('${t['created_at']}') ?? DateTime.now()).toLocal(),
      minutes: kind == TransactionType.subscription ? 0 : minutes,
      amountPaidPaise: type == 'PURCHASE' && amount > 0 ? amount : null,
      status: status.isEmpty ? 'Completed' : '${status[0].toUpperCase()}${status.substring(1)}',
    );
  }

  /// Opens Razorpay for a server order and confirms the payment with the
  /// server. [method] preselects UPI, card or net banking.
  Future<void> _payOrder(
    AppUser user,
    Map<String, dynamic> order,
    PaymentMethod method, {
    required bool subscription,
    required String description,
  }) async {
    final key = order['razorpay_key_id'] as String?;
    final orderId = order['order_id'] as String?;
    if (key == null || key.isEmpty || orderId == null) {
      throw const AuthException('Payments aren\'t available right now. Please try again later.');
    }
    final razorpay = Razorpay();
    final result = Completer<PaymentSuccessResponse>();
    razorpay
      ..on(Razorpay.EVENT_PAYMENT_SUCCESS, (PaymentSuccessResponse r) {
        if (!result.isCompleted) result.complete(r);
      })
      ..on(Razorpay.EVENT_PAYMENT_ERROR, (PaymentFailureResponse r) {
        if (result.isCompleted) return;
        result.completeError(
          AuthException(
            r.code == Razorpay.PAYMENT_CANCELLED
                ? 'Payment cancelled. You haven\'t been charged.'
                : (r.message?.isNotEmpty == true ? r.message! : 'The payment didn\'t go through. Please try again.'),
          ),
        );
      })
      ..on(Razorpay.EVENT_EXTERNAL_WALLET, (ExternalWalletResponse r) {
        if (!result.isCompleted) {
          result.completeError(const AuthException('That wallet isn\'t supported here. Please choose another method.'));
        }
      });
    try {
      razorpay.open({
        'key': key,
        'order_id': order['gateway_order_id'],
        'amount': order['gateway_amount'],
        'currency': order['currency_code'] ?? 'INR',
        'name': 'Synap Mentor',
        'description': description,
        'prefill': {
          'email': user.email,
          if (user.profile.phone.isNotEmpty) 'contact': user.profile.phone,
          'method': switch (method) {
            PaymentMethod.upi => 'upi',
            PaymentMethod.card => 'card',
            PaymentMethod.netBanking => 'netbanking',
          },
        },
        'theme': {'color': '#00001A'},
      });
      final paid = await result.future;
      await PaymentsApi.verify(
        orderId: orderId,
        paymentId: paid.paymentId ?? '',
        signature: paid.signature ?? '',
        subscription: subscription,
      );
    } finally {
      razorpay.clear();
    }
    await load(user);
  }

  // Minute packs, subscription plans and coupons, loaded from the API.
  static final packs = <MinutePack>[];
  static final plans = <SubscriptionPlan>[];
  static final _coupons = <Coupon>[];

  /// Coupons the user can still use, soonest expiry first.
  static List<Coupon> get coupons => List.unmodifiable(_coupons);

  /// Replaces the packs, plans and coupons with what the API returned.
  void setCatalog({List<MinutePack>? packs, List<SubscriptionPlan>? plans, List<Coupon>? coupons}) {
    if (packs != null) {
      WalletService.packs
        ..clear()
        ..addAll(packs);
    }
    if (plans != null) {
      WalletService.plans
        ..clear()
        ..addAll(plans);
    }
    if (coupons != null) {
      _coupons
        ..clear()
        ..addAll(coupons);
    }
    notifyListeners();
  }

  /// Replaces the user's transactions and subscription with what the API returned.
  void setAccount(AppUser user, {List<WalletTransaction>? transactions, Subscription? subscription}) {
    if (transactions != null) _ledgers[user.email] = [...transactions];
    if (subscription != null) _subscriptions[user.email] = subscription;
    notifyListeners();
  }

  final _ledgers = <String, List<WalletTransaction>>{};
  final _subscriptions = <String, Subscription>{};

  // ---- Reads -------------------------------------------------------------------

  /// Newest first.
  List<WalletTransaction> transactions(AppUser user) => List.unmodifiable(_ledger(user).reversed);

  int balance(AppUser user) {
    final api = _apiBalance[user.email];
    return api ?? _ledger(user).fold(0, (sum, t) => sum + t.minutes);
  }

  int minutesSpent(AppUser user) {
    final api = _apiSpent[user.email];
    return api ?? _ledger(user).where((t) => t.minutes < 0).fold(0, (sum, t) => sum - t.minutes);
  }

  Subscription? subscription(AppUser user) {
    final sub = _subscriptions[user.email];
    return sub != null && sub.active ? sub : null;
  }

  // ---- Coupons -----------------------------------------------------------------

  /// Coupons add bonus minutes instead of discounting the price.
  /// [forPlan] checks it for a subscription instead of a minute pack.
  Future<Coupon> checkCoupon(AppUser user, String code, {bool forPlan = false}) async {
    final normalized = code.trim().toUpperCase();
    if (_remote.contains(user.email)) {
      final r = await PaymentsApi.checkCoupon(normalized, forPlan ? 'subscription_plans' : 'minute_packs');
      if (r['is_valid'] != true) {
        throw AuthException(r['message'] as String? ?? 'That coupon code isn\'t valid.');
      }
      final known = _coupons.where((c) => c.code == normalized).firstOrNull;
      return Coupon(normalized, r['bonus_minutes'] is int ? r['bonus_minutes'] as int : 0, known?.description ?? '');
    }
    throw _notLoaded;
  }

  // ---- Payments ----------------------------------------------------------------

  Future<void> buyPack(AppUser user, MinutePack pack, PaymentMethod method, {Coupon? coupon}) async {
    if (_remote.contains(user.email)) {
      final order = await _order((c) => PaymentsApi.buyMinutes(pack.id, couponCode: coupon?.code, currency: c));
      return _payOrder(user, order, method, subscription: false, description: pack.name);
    }
    throw _notLoaded;
  }

  /// Starts (or switches to) [plan] for 30 days from today.
  Future<void> subscribe(AppUser user, SubscriptionPlan plan, PaymentMethod method, {Coupon? coupon}) async {
    if (_remote.contains(user.email)) {
      final order = await _order((c) => PaymentsApi.buySubscription(plan.id, couponCode: coupon?.code, currency: c));
      return _payOrder(user, order, method, subscription: true, description: '${plan.name} subscription');
    }
    throw _notLoaded;
  }

  /// Synap Minutes converted from reward points.
  void creditRewardMinutes(AppUser user, {required int minutes, required int points}) {
    // The server already credited them; show its updated wallet.
    unawaited(load(user));
  }

  /// CSV of the full history from the server, or of what's on the device.
  Future<String> exportFullCsv(AppUser user) async {
    if (!_remote.contains(user.email)) return exportCsv(user);
    final all = [for (final t in await PaymentsApi.export()) _transactionFrom(t)];
    return _csv(all);
  }

  /// CSV of the user's full history, newest first.
  String exportCsv(AppUser user) => _csv(transactions(user));

  String _csv(List<WalletTransaction> list) {
    String cell(String v) => '"${v.replaceAll('"', '""')}"';
    final rows = [
      'Date,Type,Title,Details,Minutes,Amount Paid (${currency.code}),Status',
      for (final t in list)
        [
          t.date.toIso8601String(),
          t.type.code,
          cell(t.title),
          cell(t.detail),
          t.minutes.toString(),
          t.amountPaidPaise == null ? '' : (t.amountPaidPaise! * currency.rate / 100).toStringAsFixed(2),
          t.status,
        ].join(','),
    ];
    return rows.join('\n');
  }

  // ---- Internals ---------------------------------------------------------------

  List<WalletTransaction> _ledger(AppUser user) => _ledgers.putIfAbsent(user.email, () => []);
}
