import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/wallet_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/coupon_ticket.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/wallet_card.dart';
import '../widgets/glass_coverflow.dart';
import '../widgets/glass_select.dart';
import 'booking_sheet.dart';
import 'support_screen.dart';

enum PaymentsTab {
  overview('Overview'),
  packs('Minute Packs'),
  wallet('Wallet'),
  transactions('Transactions'),
  subscriptions('Subscriptions');

  const PaymentsTab(this.label);
  final String label;
}

/// Synap Wallet: minutes balance, minute packs, subscriptions and the full
/// transaction history. Money only appears for pack and subscription payments;
/// everything else is in Synap Minutes.
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({
    super.key,
    required this.user,
    required this.onContactSupport,
    this.initialTab = PaymentsTab.overview,
  });

  final AppUser user;
  final VoidCallback onContactSupport;
  final PaymentsTab initialTab;

  /// Opens Payments on [tab], with Support one tap away.
  static Future<void> open(BuildContext context, AppUser user, {PaymentsTab tab = PaymentsTab.overview}) =>
      Navigator.of(context).push(
        glassRoute(
          PaymentsScreen(
            user: user,
            initialTab: tab,
            onContactSupport: () => Navigator.of(context).push(glassRoute(SupportScreen(user: user))),
          ),
        ),
      );

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  final _wallet = WalletService.instance;
  final _search = TextEditingController();
  late PaymentsTab _tab = widget.initialTab;
  TransactionType? _typeFilter;
  bool _exporting = false;
  String? _notice;
  NoticeTone _noticeTone = NoticeTone.success;

  AppUser get _user => widget.user;

  @override
  void initState() {
    super.initState();
    _wallet.load(_user);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    setState(() {
      _exporting = true;
      _notice = null;
    });
    try {
      final now = DateTime.now();
      final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final csv = await _wallet.exportFullCsv(_user);
      final saved = await FilePicker.saveFile(
        fileName: 'synap_transactions_$stamp.csv',
        bytes: utf8.encode(csv),
        mimeType: 'text/csv',
        dialogTitle: 'Save transaction history',
      );
      if (saved != null && mounted) {
        setState(() {
          _notice = 'Transaction history saved.';
          _noticeTone = NoticeTone.success;
        });
      }
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _notice = e.message;
          _noticeTone = NoticeTone.error;
        });
      }
    } on PlatformException {
      if (mounted) {
        setState(() {
          _notice = 'Couldn\'t save the file. Please try again.';
          _noticeTone = NoticeTone.error;
        });
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _buyPack(MinutePack pack) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => _CheckoutSheet(user: _user, pack: pack),
  );

  Future<void> _subscribe(SubscriptionPlan plan) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => _CheckoutSheet(user: _user, plan: plan),
  );

  void _showTransaction(WalletTransaction t) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => _TransactionSheet(transaction: t, onContactSupport: widget.onContactSupport),
    );
  }

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
                    child: Text('PAYMENTS', textAlign: TextAlign.center, style: AppText.heading.copyWith(fontSize: 20)),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: _wallet,
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
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final tab in PaymentsTab.values) ...[
                                    GlassChip(
                                      label: tab.label,
                                      selected: _tab == tab,
                                      onTap: () => setState(() {
                                        _tab = tab;
                                        _notice = null;
                                      }),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                ],
                              ),
                            ),
                            gap14,
                            InlineNotice(message: _notice, tone: _noticeTone),
                            InlineNotice(message: _wallet.loadError, tone: NoticeTone.error),
                            StepSwitcher(
                              child: KeyedSubtree(key: ValueKey(_tab), child: _buildTab()),
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

  Widget _buildTab() => switch (_tab) {
    PaymentsTab.overview => _buildOverview(),
    PaymentsTab.packs => _buildPacks(),
    PaymentsTab.wallet => _buildWallet(),
    PaymentsTab.transactions => _buildTransactions(),
    PaymentsTab.subscriptions => _buildSubscriptions(),
  };

  // ---- Overview ------------------------------------------------------------------

  Widget _buildOverview() {
    final recent = _wallet.transactions(_user).take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.account_balance_wallet_outlined,
                value: '${_wallet.balance(_user)} min',
                label: 'Minutes Balance',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.schedule_rounded,
                value: '${_wallet.minutesSpent(_user)} min',
                label: 'Total Minutes Spent',
              ),
            ),
          ],
        ),
        gap24,
        const Text('Quick Actions', style: _heading),
        gap14,
        Row(
          children: [
            Expanded(
              child: GlassPillButton(
                label: 'Add Minutes',
                icon: Icons.add_rounded,
                onPressed: () => setState(() => _tab = PaymentsTab.packs),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GlassPillButton(
                label: 'Export Data',
                icon: Icons.download_rounded,
                loading: _exporting,
                onPressed: _export,
              ),
            ),
          ],
        ),
        gap24,
        _SectionHeader(title: 'Recent Transactions', onViewAll: () => setState(() => _tab = PaymentsTab.transactions)),
        gap14,
        for (final t in recent) ...[
          _TransactionTile(transaction: t, onView: () => _showTransaction(t)),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  // ---- Minute packs ----------------------------------------------------------------

  Widget _buildPacks() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Available Minute Packs', style: _heading),
        const SizedBox(height: 4),
        Text(
          'Sessions are booked with Synap Minutes. Choose a pack based on your requirement.',
          style: AppText.caption,
        ),
        gap14,
        if (WalletService.packs.isEmpty)
          GlassWell(
            radius: 22,
            padding: const EdgeInsets.all(20),
            child: Text('No minute packs available right now.', style: AppText.body, textAlign: TextAlign.center),
          ),
        GlassStackCarousel(
          height: 330,
          itemCount: WalletService.packs.length,
          itemBuilder: (context, i, focused) {
            final pack = WalletService.packs[i];
            // Dark translucent glass (as on the streak reward tiles). The front card
            // frosts the blurred neighbours behind it; its rim brightens when focused.
            return GlassWell(
              radius: 26,
              active: focused,
              floating: true,
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              child: Column(
                children: [
                  const GlassIconBadge(icon: Icons.schedule_rounded, size: 60),
                  gap14,
                  Text(
                    pack.name,
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                  const SizedBox(height: 6),
                  _IconLine(Icons.schedule_rounded, '${pack.minutes} minutes'),
                  if (pack.bonusMinutes > 0)
                    _IconLine(Icons.card_giftcard_outlined, '+ ${pack.bonusMinutes} bonus minutes'),
                  const Spacer(),
                  Text(
                    formatMoney(pack.pricePaise),
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                  Text('+ $gstLabel', style: AppText.caption.copyWith(fontSize: 11.5)),
                  gap14,
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryPillButton(label: 'Buy Now', onPressed: () => _buyPack(pack)),
                  ),
                ],
              ),
            );
          },
        ),
        gap24,
        if (WalletService.coupons.isNotEmpty) ...[
          const Text('Available Coupons', style: _heading),
          const SizedBox(height: 4),
          Text('Tap a coupon to copy its code, then apply it at checkout.', style: AppText.caption),
          gap14,
          for (final c in WalletService.coupons) ...[
            CouponTicket(
              code: c.code,
              bonusMinutes: c.bonusMinutes,
              appliesTo: c.appliesToLabel,
              footer:
                  'Enter this code at checkout on a ${c.forPacks ? 'minute pack' : 'subscription'}.'
                  '${c.expiresAt == null ? '' : ' Valid until ${formatDay(c.expiresAt!).substring(5)}.'}',
              onTap: () => _copyCoupon(c),
            ),
            gap14,
          ],
        ] else
          Text(
            'Have a coupon? Apply it at checkout. Coupons add bonus minutes to your wallet.',
            style: AppText.caption,
            textAlign: TextAlign.center,
          ),
      ],
    );
  }

  Future<void> _copyCoupon(Coupon c) async {
    await Clipboard.setData(ClipboardData(text: c.code));
    if (!mounted) return;
    setState(() {
      _notice = '${c.code} copied. Paste it in Coupon Code at checkout.';
      _noticeTone = NoticeTone.success;
    });
  }

  // ---- Wallet ------------------------------------------------------------------------

  Widget _buildWallet() {
    final activity = _wallet.transactions(_user).where((t) => t.type != TransactionType.subscription).take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WalletCard(holder: _user.name, balanceLabel: 'Minutes Balance', balance: '${_wallet.balance(_user)} min'),
        gap14,
        PrimaryPillButton(label: 'Add Minutes', onPressed: () => setState(() => _tab = PaymentsTab.packs)),
        gap24,
        _SectionHeader(
          title: 'Recent Wallet Activity',
          onViewAll: () => setState(() => _tab = PaymentsTab.transactions),
        ),
        gap14,
        for (final t in activity) ...[
          _TransactionTile(transaction: t, onView: () => _showTransaction(t)),
          const SizedBox(height: 10),
        ],
        gap8,
        _RefundNote(onContactSupport: widget.onContactSupport),
      ],
    );
  }

  // ---- Transactions ------------------------------------------------------------------

  Widget _buildTransactions() {
    final query = _search.text.trim().toLowerCase();
    final list = _wallet.transactions(_user).where((t) {
      if (_typeFilter != null && t.type != _typeFilter) return false;
      return query.isEmpty || t.title.toLowerCase().contains(query) || t.detail.toLowerCase().contains(query);
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              flex: 3,
              child: GlassTextField(
                controller: _search,
                hint: 'Search transactions',
                icon: Icons.search_rounded,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: GlassSelectField(
                value: _typeFilter?.label ?? 'All Types',
                hint: 'All Types',
                onTap: () async {
                  const all = 'All Types';
                  final picked = await showGlassPicker<String>(
                    context,
                    title: 'Transaction Type',
                    options: [all, for (final t in TransactionType.values) t.label],
                    label: (l) => l,
                    selected: _typeFilter?.label ?? all,
                  );
                  if (picked == null || !mounted) return; // dismissed
                  setState(() => _typeFilter = TransactionType.values.where((t) => t.label == picked).firstOrNull);
                },
              ),
            ),
          ],
        ),
        gap14,
        Align(
          alignment: Alignment.centerRight,
          child: SmallPillButton(label: _exporting ? 'Exporting…' : 'Export CSV', onPressed: _export),
        ),
        gap14,
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Text('No transactions match your search.', style: AppText.body, textAlign: TextAlign.center),
          )
        else
          for (final t in list) ...[
            _TransactionTile(transaction: t, onView: () => _showTransaction(t)),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  // ---- Subscriptions -----------------------------------------------------------------

  Widget _buildSubscriptions() {
    final current = _wallet.subscription(_user);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Your Subscription', style: _heading)),
            if (current != null) const _StatusBadge('Active'),
          ],
        ),
        gap14,
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(16),
          child: current == null
              ? Row(
                  children: [
                    const GlassIconBadge(icon: Icons.workspace_premium_outlined, size: 48),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'No active subscription. Subscribe to a plan to access content.',
                        style: AppText.body,
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    const GlassIconBadge(icon: Icons.workspace_premium_outlined, size: 48),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(current.plan.name, style: _heading),
                          const SizedBox(height: 2),
                          Text('${formatMoney(current.plan.pricePaise)} / month + GST', style: AppText.caption),
                          Text(
                            'Expires ${formatDay(current.expiresAt)} (${current.daysLeft} days left)',
                            style: AppText.caption,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        gap24,
        const Text('Available Plans', style: _heading),
        const SizedBox(height: 4),
        Text('Choose a plan to unlock more of the platform.', style: AppText.caption),
        gap14,
        if (WalletService.plans.isEmpty)
          GlassWell(
            radius: 22,
            padding: const EdgeInsets.all(20),
            child: Text('No plans available right now.', style: AppText.body, textAlign: TextAlign.center),
          ),
        // Same layered-glass carousel and card treatment as the Minute Packs.
        GlassStackCarousel(
          height: 388,
          itemCount: WalletService.plans.length,
          itemBuilder: (context, i, focused) {
            final plan = WalletService.plans[i];
            return _PlanCard(
              plan: plan,
              focused: focused,
              current: current?.plan.id == plan.id,
              onSubscribe: () => _subscribe(plan),
            );
          },
        ),
      ],
    );
  }

  static const _heading = TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: Colors.white);
}

// ---- Checkout -------------------------------------------------------------------------

enum _CheckoutStep { confirm, method, success }

/// Confirm → payment method → success, for a minute pack or a subscription.
class _CheckoutSheet extends StatefulWidget {
  const _CheckoutSheet({required this.user, this.pack, this.plan})
    : assert((pack == null) != (plan == null), 'Checkout needs exactly one of pack or plan.');

  final AppUser user;
  final MinutePack? pack;
  final SubscriptionPlan? plan;

  @override
  State<_CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends State<_CheckoutSheet> {
  final _wallet = WalletService.instance;
  final _couponField = TextEditingController();

  _CheckoutStep _step = _CheckoutStep.confirm;
  PaymentMethod _method = PaymentMethod.upi;
  Coupon? _coupon;
  bool _checkingCoupon = false;
  bool _paying = false;
  String? _couponError;
  String? _error;

  MinutePack? get _pack => widget.pack;
  SubscriptionPlan? get _plan => widget.plan;
  int get _price => _pack?.pricePaise ?? _plan!.pricePaise;

  /// GST from the server: the pack's own tax-inclusive price, otherwise its
  /// rate. Null when the server sent neither; it's then added at checkout.
  int? get _gst {
    final inclusive = _pack?.priceInclTaxPaise;
    return inclusive != null ? inclusive - _price : gstOn(_price);
  }

  int get _total => _price + (_gst ?? 0);
  int get _minutesReceived => (_pack?.totalMinutes ?? 0) + (_coupon?.bonusMinutes ?? 0);

  @override
  void dispose() {
    _couponField.dispose();
    super.dispose();
  }

  /// Coupons the user can still use on a minute pack.
  List<Coupon> get _packCoupons => [
    for (final c in WalletService.coupons)
      if (c.forPacks && (c.expiresAt == null || c.expiresAt!.isAfter(DateTime.now()))) c,
  ];

  Future<void> _applyCoupon() async {
    final code = _couponField.text.trim();
    if (code.isEmpty) {
      setState(() => _couponError = 'Enter a coupon code.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _checkingCoupon = true;
      _couponError = null;
    });
    try {
      final coupon = await _wallet.checkCoupon(widget.user, code);
      if (mounted) setState(() => _coupon = coupon);
    } on AuthException catch (e) {
      if (mounted) setState(() => _couponError = e.message);
    } finally {
      if (mounted) setState(() => _checkingCoupon = false);
    }
  }

  Future<void> _pay() async {
    setState(() {
      _paying = true;
      _error = null;
    });
    try {
      if (_pack != null) {
        await _wallet.buyPack(widget.user, _pack!, _method, coupon: _coupon);
      } else {
        await _wallet.subscribe(widget.user, _plan!, _method);
      }
      if (mounted) setState(() => _step = _CheckoutStep.success);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: switch (_step) {
        _CheckoutStep.confirm => 'Confirm Purchase',
        _CheckoutStep.method => 'Payment Method',
        _CheckoutStep.success => 'Payment Successful',
      },
      onBack: _step == _CheckoutStep.method && !_paying ? () => setState(() => _step = _CheckoutStep.confirm) : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          StepSwitcher(
            child: KeyedSubtree(
              key: ValueKey(_step),
              child: switch (_step) {
                _CheckoutStep.confirm => _buildConfirm(),
                _CheckoutStep.method => _buildMethod(),
                _CheckoutStep.success => _buildSuccess(),
              },
            ),
          ),
        ],
      ),
      footer: switch (_step) {
        _CheckoutStep.confirm => Row(
          children: [
            Expanded(
              child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PrimaryPillButton(
                label: 'Proceed to Payment',
                onPressed: () => setState(() => _step = _CheckoutStep.method),
              ),
            ),
          ],
        ),
        _CheckoutStep.method => PrimaryPillButton(
          label: 'Pay ${formatMoney(_total)}',
          loading: _paying,
          onPressed: _pay,
        ),
        _CheckoutStep.success => PrimaryPillButton(label: 'Done', onPressed: () => Navigator.of(context).pop()),
      },
    );
  }

  Widget _buildConfirm() {
    final pack = _pack;
    final plan = _plan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              GlassIconBadge(icon: pack != null ? Icons.schedule_rounded : Icons.workspace_premium_outlined, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pack?.name ?? plan!.name,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                    if (pack != null) ...[
                      _IconLine(Icons.schedule_rounded, '${pack.minutes} minutes'),
                      if (pack.bonusMinutes > 0)
                        _IconLine(Icons.card_giftcard_outlined, '+ ${pack.bonusMinutes} bonus minutes'),
                    ] else
                      Text('Monthly subscription · 30 days', style: AppText.caption),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (pack != null) ...[
          gap14,
          const Text('Coupon Code', style: _label),
          gap8,
          if (_coupon == null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: GlassTextField(
                    controller: _couponField,
                    hint: 'Enter coupon',
                    icon: Icons.local_offer_outlined,
                    textCapitalization: TextCapitalization.characters,
                    errorText: _couponError,
                    onChanged: (_) {
                      if (_couponError != null) setState(() => _couponError = null);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: _checkingCoupon
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          ),
                        )
                      : SmallPillButton(label: 'Apply', onPressed: _applyCoupon),
                ),
              ],
            )
          else
            GlassWell(
              radius: 16,
              active: true,
              padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
              child: Row(
                children: [
                  const Icon(Icons.local_offer_outlined, size: 18, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${_coupon!.code} · +${_coupon!.bonusMinutes} bonus minutes',
                      style: AppText.label.copyWith(fontSize: 13.5),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove coupon',
                    onPressed: () => setState(() {
                      _coupon = null;
                      _couponField.clear();
                    }),
                    icon: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
                  ),
                ],
              ),
            ),
          if (_coupon == null && _packCoupons.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Available coupons · tap to apply', style: AppText.caption.copyWith(fontSize: 12)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _packCoupons)
                  GlassChip(
                    label: '${c.code} · +${c.bonusMinutes} min',
                    selected: _couponField.text.trim().toUpperCase() == c.code.toUpperCase(),
                    onTap: _checkingCoupon
                        ? () {}
                        : () {
                            _couponField.text = c.code;
                            _applyCoupon();
                          },
                  ),
              ],
            ),
          ],
        ],
        gap14,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              _Row('Price', formatMoney(_price)),
              _Row(gstLabel, _gst == null ? 'Added at checkout' : formatMoney(_gst!)),
              Container(height: 1, color: AppColors.white(0.12)),
              _Row(_gst == null ? 'Total before GST' : 'Total Payable', formatMoney(_total), bold: true),
            ],
          ),
        ),
        gap14,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                pack != null ? Icons.card_giftcard_outlined : Icons.lock_open_rounded,
                size: 26,
                color: Colors.white,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('You will receive', style: AppText.caption),
                    Text(
                      pack != null ? '$_minutesReceived Synap Minutes' : plan!.features.join(' · '),
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                    if (pack != null)
                      Text(
                        [
                          '${pack.minutes} minutes',
                          if (pack.bonusMinutes > 0) '${pack.bonusMinutes} bonus',
                          if (_coupon != null) '${_coupon!.bonusMinutes} coupon bonus',
                        ].join(' + '),
                        style: AppText.caption.copyWith(fontSize: 12),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMethod() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Select a payment method', style: AppText.caption),
        gap14,
        for (final method in PaymentMethod.values) ...[
          GlassOption(
            height: 64,
            radius: 18,
            selected: _method == method,
            onTap: _paying ? null : () => setState(() => _method = method),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(
                    switch (method) {
                      PaymentMethod.upi => Icons.qr_code_2_rounded,
                      PaymentMethod.card => Icons.credit_card_rounded,
                      PaymentMethod.netBanking => Icons.account_balance_outlined,
                    },
                    size: 24,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          method.label,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                        ),
                        Text(method.subtitle, style: AppText.caption.copyWith(fontSize: 12)),
                      ],
                    ),
                  ),
                  Icon(
                    _method == method ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        gap8,
        Text(
          _gst == null
              ? 'GST is added to ${formatMoney(_total)} at checkout.'
              : 'Total ${formatMoney(_total)} includes ${formatMoney(_gst!)} GST.',
          style: AppText.caption,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildSuccess() {
    final pack = _pack;
    final subscription = _wallet.subscription(widget.user);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: GlassIconBadge(icon: Icons.check_rounded, size: 80)),
        gap14,
        const Text('PAYMENT SUCCESSFUL!', style: AppText.title, textAlign: TextAlign.center),
        gap8,
        if (pack != null) ...[
          Text('You have purchased', style: AppText.body, textAlign: TextAlign.center),
          Text(
            '$_minutesReceived minutes',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
          ),
          gap24,
          GlassWell(
            radius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                _Row('Pack minutes', '${pack.minutes} min'),
                if (pack.bonusMinutes > 0) _Row('Bonus minutes', '+${pack.bonusMinutes} min'),
                if (_coupon != null) _Row('Coupon ${_coupon!.code}', '+${_coupon!.bonusMinutes} min'),
                Container(height: 1, color: AppColors.white(0.12)),
                _Row('New Wallet Balance', '${_wallet.balance(widget.user)} minutes', bold: true),
              ],
            ),
          ),
        ] else
          Text(
            subscription == null
                ? 'Your subscription is active.'
                : '${subscription.plan.name} is active until ${formatDay(subscription.expiresAt)}.',
            style: AppText.body,
            textAlign: TextAlign.center,
          ),
      ],
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

// ---- Transaction details ----------------------------------------------------------------

class _TransactionSheet extends StatelessWidget {
  const _TransactionSheet({required this.transaction, required this.onContactSupport});

  final WalletTransaction transaction;
  final VoidCallback onContactSupport;

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final booking = t.type == TransactionType.booking;
    return FlowSheetFrame(
      title: 'Transaction Details',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassWell(
            radius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                _Row('Minutes', t.minutes == 0 ? '—' : _signedMinutes(t.minutes)),
                _Row('Status', t.status),
                _Row('Date', '${formatDay(t.date)}, ${formatClock(t.date)}'),
                _Row('Type', t.type.label),
                _Row('Direction', t.direction ?? '—'),
                _Row('Balance After', t.balanceAfter == null ? '—' : '${t.balanceAfter} min'),
              ],
            ),
          ),
          if (booking) ...[
            gap14,
            _RefundNote(
              onContactSupport: () {
                Navigator.of(context).pop();
                onContactSupport();
              },
            ),
          ],
        ],
      ),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

String _signedMinutes(int minutes) => '${minutes > 0 ? '+' : ''}$minutes min';

// ---- Pieces ----------------------------------------------------------------------------------

class _TransactionTile extends StatelessWidget {
  const _TransactionTile({required this.transaction, required this.onView});

  final WalletTransaction transaction;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final icon = switch (t.type) {
      TransactionType.purchase => Icons.add_rounded,
      TransactionType.couponBonus => Icons.card_giftcard_outlined,
      TransactionType.booking => Icons.north_east_rounded,
      TransactionType.refund => Icons.replay_rounded,
      TransactionType.subscription => Icons.workspace_premium_outlined,
      TransactionType.rewardConversion => Icons.redeem_outlined,
    };
    final amount = t.amountPaidPaise != null && t.minutes == 0
        ? formatMoney(t.amountPaidPaise!)
        : _signedMinutes(t.minutes);
    return GlassWell(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 42,
            child: GlassWell(radius: 12, child: Icon(icon, size: 20, color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                const SizedBox(height: 2),
                Text('${t.type.label} — ${formatDay(t.date)}', style: AppText.caption.copyWith(fontSize: 11.5)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                amount,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              const SizedBox(height: 4),
              _StatusBadge(t.status),
            ],
          ),
          IconButton(
            tooltip: 'View details',
            onPressed: onView,
            icon: const Icon(Icons.visibility_outlined, size: 20, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.icon, required this.value, required this.label});

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 22,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GlassIconBadge(icon: icon, size: 44),
          gap14,
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
            ),
          ),
          Text(label, style: AppText.caption),
        ],
      ),
    );
  }
}

/// A subscription plan, laid out like a Minute Pack card: centered badge,
/// name, what's included, price and the action.
class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.current, required this.onSubscribe, this.focused = false});

  final SubscriptionPlan plan;
  final bool current;
  final VoidCallback onSubscribe;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final discount = plan.discountPercent;
    return GlassWell(
      radius: 26,
      active: focused,
      floating: true,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      child: Column(
        children: [
          const GlassIconBadge(icon: Icons.workspace_premium_outlined, size: 60),
          gap14,
          Text(
            plan.name,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: Colors.white),
          ),
          if (discount != null || current) ...[
            const SizedBox(height: 6),
            _StatusBadge(current ? 'Current plan' : 'Limited offer · $discount% off'),
          ],
          const SizedBox(height: 6),
          for (final feature in plan.features) _IconLine(Icons.check_rounded, feature),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatMoney(plan.pricePaise),
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4, left: 4),
                child: Text('/ month', style: AppText.caption),
              ),
            ],
          ),
          if (discount != null)
            Text(
              formatMoney(plan.originalPricePaise!),
              style: AppText.caption.copyWith(
                fontSize: 11.5,
                decoration: TextDecoration.lineThrough,
                decorationColor: AppColors.white(0.72),
              ),
            ),
          Text('+ $gstLabel', style: AppText.caption.copyWith(fontSize: 11.5)),
          gap14,
          SizedBox(
            width: double.infinity,
            child: current
                ? GlassPillButton(label: 'Current Plan', onPressed: null)
                : PrimaryPillButton(label: 'Subscribe', onPressed: onSubscribe),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.onViewAll});

  final String title;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title, style: _PaymentsScreenState._heading)),
        UnderlineLink(label: 'View All', bold: true, onTap: onViewAll),
      ],
    );
  }
}

class _RefundNote extends StatelessWidget {
  const _RefundNote({required this.onContactSupport});

  final VoidCallback onContactSupport;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 18,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.replay_rounded, size: 20, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Solver didn\'t join, or you had a technical issue? Contact Support to request a refund. '
                  'Refunds are credited back as Synap Minutes.',
                  style: AppText.caption.copyWith(color: AppColors.white(0.85)),
                ),
                const SizedBox(height: 4),
                UnderlineLink(label: 'Contact Support', bold: true, onTap: onContactSupport),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IconLine extends StatelessWidget {
  const _IconLine(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.white(0.8)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: AppText.caption.copyWith(color: AppColors.white(0.85))),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.text);

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

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.bold = false});

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.caption.copyWith(fontSize: 13, color: AppColors.white(bold ? 1 : 0.75))),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
