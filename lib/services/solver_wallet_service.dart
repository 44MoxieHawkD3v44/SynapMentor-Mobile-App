import 'package:flutter/foundation.dart';

import '../api/solver_wallet_api.dart';
import 'auth_service.dart';
import 'solver_service.dart';
import 'wallet_service.dart' show solverShare;

enum EntryKind {
  sessionEarning('Session Earning'),
  withdrawal('Withdrawal'),
  reversal('Withdrawal Reversal');

  const EntryKind(this.label);
  final String label;
}

/// One line of the solver's wallet ledger.
class WalletEntry {
  WalletEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.minutes,
    required this.at,
    this.seeker,
    this.sessionMinutes,
    this.anonymous = false,
    this.withdrawalId,
  });

  final String id;
  final EntryKind kind;
  final String title;

  /// Positive for credits, negative for debits.
  final int minutes;
  final DateTime at;
  final String? seeker;

  /// How long the session ran. Anonymous sessions earn
  /// [ExploreService.anonymousMultiplier] times this.
  final int? sessionMinutes;
  final bool anonymous;
  final String? withdrawalId;

  /// Wallet balance right after this entry.
  int balanceAfter = 0;

  /// The server's status for the entry: on_hold, available or withdrawn.
  String? apiStatus;
}

enum PayoutType {
  upi('UPI'),
  bank('Bank Account');

  const PayoutType(this.label);
  final String label;
}

/// Where withdrawals are paid.
class PayoutMethod {
  PayoutMethod({
    required this.id,
    required this.type,
    required this.holderName,
    required this.displayName,
    this.upiId,
    this.accountNumber,
    this.ifsc,
    this.bankName,
  });

  final String id;
  final PayoutType type;
  final String holderName;
  final String displayName;
  final String? upiId;
  final String? accountNumber;
  final String? ifsc;
  final String? bankName;
  bool isDefault = false;

  /// e.g. "SBI · ****7896" or "UPI · name@bank".
  String get summary => type == PayoutType.upi
      ? 'UPI · $upiId'
      : '${bankName ?? 'Bank'} · ****${accountNumber!.substring(accountNumber!.length - 4)}';
}

enum WithdrawalStatus {
  pending('Pending'),
  completed('Completed'),
  rejected('Rejected');

  const WithdrawalStatus(this.label);
  final String label;
}

class Withdrawal {
  Withdrawal({
    required this.id,
    required this.minutes,
    required this.ratePerMinute,
    required this.requestedAt,
    required this.method,
  });

  final String id;
  final int minutes;

  /// The solver's price in ₹ per minute when they asked.
  final int ratePerMinute;
  final DateTime requestedAt;

  /// Snapshot of where it's paid.
  final String method;
  WithdrawalStatus status = WithdrawalStatus.pending;
  String? rejectionReason;
  DateTime? paidAt;
  String? utr;

  /// The amounts the server priced, when it did.
  int? apiGross;
  int? apiNet;

  int get grossAmount => apiGross ?? minutes * ratePerMinute;
  int get fee => grossAmount - netAmount;

  /// 70% goes to the solver; 30% is the platform fee.
  int get netAmount => apiNet ?? (grossAmount * solverShare).round();
}

/// A file the solver exported, kept so it can be downloaded again.
class ExportRecord {
  const ExportRecord({required this.fileName, required this.createdAt, required this.bytes, required this.mimeType});

  final String fileName;
  final DateTime createdAt;
  final Uint8List bytes;
  final String mimeType;
}

/// The solver's wallet: Synap Minutes earned from sessions, withdrawals to
/// money and payout methods from the solver wallet API, plus exports.
class SolverWalletService extends ChangeNotifier {
  static final SolverWalletService instance = SolverWalletService();

  // ---- API -----------------------------------------------------------------------

  /// Users whose wallet came from the API.
  final _remote = <String>{};
  final _summary = <String, Map<String, dynamic>>{};

  /// Why the wallet couldn't be loaded, if it couldn't.
  String? loadError;

  bool isRemote(AppUser user) => _remote.contains(user.email);

  /// Money and payout changes need the wallet from the API.
  static const _notLoaded = AuthException('Your wallet couldn\'t be loaded. Please try again.');

  static int _int(Object? v) => v is num ? v.round() : 0;

  /// Loads the balance, earnings ledger, withdrawals and payout methods.
  Future<void> load(AppUser user) async {
    if (user.role != UserRole.solver) return;
    try {
      final results = await Future.wait([
        SolverWalletApi.summary(),
        SolverWalletApi.history(),
        SolverWalletApi.withdrawals(),
        SolverWalletApi.methods(),
      ]);
      final summary = results[0] as Map<String, dynamic>;
      _summary[user.email] = summary;
      if (summary['min_withdrawal_minutes'] is num) minWithdrawal = _int(summary['min_withdrawal_minutes']);
      _entries[user.email] = [for (final e in (results[1] as List<Map<String, dynamic>>).reversed) _entryFrom(e)];
      _withdrawals[user.email] = [for (final w in results[2] as List<Map<String, dynamic>>) _withdrawalFrom(w)];
      _methods[user.email] = [for (final m in results[3] as List<Map<String, dynamic>>) _methodFrom(m)];
      _remote.add(user.email);
      loadError = null;
    } on AuthException catch (e) {
      loadError = e.message;
    }
    notifyListeners();
  }

  WalletEntry _entryFrom(Map<String, dynamic> e) {
    final type = '${e['txn_type']}'.toUpperCase();
    final minutes = e['minutes_delta'] is int ? e['minutes_delta'] as int : _int(e['amount_delta']);
    final kind = type.contains('REVERS') || type.contains('REFUND')
        ? EntryKind.reversal
        : type.contains('WITHDRAW') || minutes < 0
        ? EntryKind.withdrawal
        : EntryKind.sessionEarning;
    final seeker = (e['seeker_name'] as String?)?.trim();
    return WalletEntry(
        id: '${e['id']}',
        kind: kind,
        title: (e['session_title'] as String?)?.trim().isNotEmpty == true
            ? (e['session_title'] as String).trim()
            : kind.label,
        minutes: minutes,
        at: (DateTime.tryParse('${e['created_at']}') ?? DateTime.now()).toLocal(),
        seeker: seeker == null || seeker.isEmpty ? null : seeker,
        sessionMinutes: e['duration_minutes'] as int?,
      )
      ..balanceAfter = _int(e['balance_after'])
      ..apiStatus = e['status'] as String?;
  }

  Withdrawal _withdrawalFrom(Map<String, dynamic> w) {
    final minutes = _int(w['minutes_equivalent']);
    final net = _int(w['amount']);
    // The platform keeps its fee from the gross; the request stores the net.
    final gross = (net / solverShare).round();
    final details = w['payment_details'] is Map ? w['payment_details'] as Map : const {};
    return Withdrawal(
        id: '${w['id']}',
        minutes: minutes,
        ratePerMinute: minutes > 0 ? (gross / minutes).round() : 0,
        requestedAt: (DateTime.tryParse('${w['created_at']}') ?? DateTime.now()).toLocal(),
        method: '${details['display_name'] ?? w['payment_method'] ?? 'Payout method'}',
      )
      ..apiNet = net
      ..apiGross = gross
      ..status = switch (w['status']) {
        'completed' => WithdrawalStatus.completed,
        'rejected' => WithdrawalStatus.rejected,
        _ => WithdrawalStatus.pending,
      }
      ..rejectionReason = w['rejection_reason'] as String?
      ..paidAt = DateTime.tryParse('${w['completed_at'] ?? w['processed_at']}')?.toLocal();
  }

  PayoutMethod _methodFrom(Map<String, dynamic> m) {
    final d = m['details'] is Map ? Map<String, dynamic>.from(m['details'] as Map) : const <String, dynamic>{};
    final upi = m['method_type'] == 'upi';
    final display = m['display_name'] as String? ?? '';
    return PayoutMethod(
      id: '${m['id']}',
      type: upi ? PayoutType.upi : PayoutType.bank,
      holderName: d['account_holder_name'] as String? ?? display,
      displayName: display,
      upiId: d['upi_id'] as String?,
      accountNumber: d['account_number'] as String?,
      ifsc: d['ifsc'] as String?,
      bankName: d['bank_name'] as String?,
    )..isDefault = m['is_default'] == true;
  }

  /// The payout details for the API, leaving out values shown masked.
  static Map<String, dynamic> _details({
    required PayoutType type,
    required String holderName,
    String? upiId,
    String? accountNumber,
    String? ifsc,
    String? bankName,
    PayoutMethod? old,
  }) {
    bool changed(String? value, String? before) =>
        value != null && value.trim().isNotEmpty && !value.contains('*') && value.trim() != before;
    return type == PayoutType.upi
        ? {if (changed(upiId, old?.upiId)) 'upi_id': upiId!.trim()}
        : {
            if (changed(accountNumber, old?.accountNumber)) 'account_number': accountNumber!.trim(),
            if (changed(ifsc, old?.ifsc)) 'ifsc': ifsc!.trim().toUpperCase(),
            if (changed(holderName, old?.holderName)) 'account_holder_name': holderName.trim(),
            if (changed(bankName, old?.bankName)) 'bank_name': bankName!.trim(),
          };
  }

  /// Configured by the admin; not fixed in the app.
  static int minWithdrawal = 1600;

  /// Withdrawals reach the bank within this long.
  static const payoutDays = 7;

  final _entries = <String, List<WalletEntry>>{};
  final _withdrawals = <String, List<Withdrawal>>{};
  final _methods = <String, List<PayoutMethod>>{};
  final _exports = <String, List<ExportRecord>>{};

  // ---- Ledger ----------------------------------------------------------------------

  List<WalletEntry> _ledger(AppUser user) => _entries.putIfAbsent(user.email, () => []);

  /// Replaces the solver's ledger, withdrawals and payment methods with what
  /// the API returned.
  void setAccount(
    AppUser user, {
    List<WalletEntry>? entries,
    List<Withdrawal>? withdrawals,
    List<PayoutMethod>? methods,
  }) {
    if (entries != null) _entries[user.email] = [...entries];
    if (withdrawals != null) _withdrawals[user.email] = [...withdrawals];
    if (methods != null) _methods[user.email] = [...methods];
    _recompute(_ledger(user));
    notifyListeners();
  }

  /// Newest first.
  List<WalletEntry> entries(AppUser user) => _ledger(user).reversed.toList();

  int balance(AppUser user) {
    final summary = _summary[user.email];
    if (summary != null) return _int(summary['available_minutes']);
    return _ledger(user).lastOrNull?.balanceAfter ?? 0;
  }

  /// Everything earned from sessions, before withdrawals.
  int totalEarned(AppUser user) {
    final summary = _summary[user.email];
    if (summary != null) return _int(summary['total_earned_minutes']);
    return _ledger(user).where((e) => e.kind == EntryKind.sessionEarning).fold(0, (sum, e) => sum + e.minutes);
  }

  int pendingWithdrawal(AppUser user) => _summary[user.email] != null
      ? _int(_summary[user.email]!['pending_minutes'])
      : withdrawals(user).where((w) => w.status == WithdrawalStatus.pending).fold(0, (sum, w) => sum + w.minutes);

  /// Session earnings, newest first.
  List<WalletEntry> sessionEarnings(AppUser user) =>
      entries(user).where((e) => e.kind == EntryKind.sessionEarning).toList();

  /// The solver's price in ₹ per minute: their current pricing tier.
  int ratePerMinute(AppUser user) => SolverService.instance.rateOf(SolverService.instance.statsFor(user));

  void _recompute(List<WalletEntry> ledger) {
    ledger.sort((a, b) => a.at.compareTo(b.at));
    var running = 0;
    for (final e in ledger) {
      running += e.minutes;
      e.balanceAfter = running;
    }
  }

  // ---- Withdrawals ---------------------------------------------------------------------

  /// Newest first.
  List<Withdrawal> withdrawals(AppUser user) {
    _ledger(user); // seeds withdrawals too
    return _withdrawals.putIfAbsent(user.email, () => []);
  }

  Withdrawal? withdrawalById(AppUser user, String id) => withdrawals(user).where((w) => w.id == id).firstOrNull;

  /// Asks for [minutes] to be paid out. The minutes leave the wallet now and
  /// come back if the admin rejects the request.
  Future<Withdrawal> requestWithdrawal(AppUser user, int minutes) async {
    if (minutes < minWithdrawal) throw AuthException('The minimum withdrawal is $minWithdrawal minutes.');
    if (minutes > balance(user)) throw const AuthException('That\'s more than your available minutes.');
    final method = defaultMethod(user);
    if (method == null) throw const AuthException('Add a payment method to receive your withdrawal.');
    if (isRemote(user)) {
      // The server prices a short-lived quote, then records the request.
      final data = await SolverWalletApi.quote(minutes, methodId: method.id);
      final quote = data['quote'] is Map ? Map<String, dynamic>.from(data['quote'] as Map) : const <String, dynamic>{};
      final quoteId = quote['id'] as String?;
      if (quoteId == null) throw const AuthException('The withdrawal couldn\'t be priced. Please try again.');
      await SolverWalletApi.confirm(quoteId);
      final withdrawal =
          Withdrawal(
              id: quoteId,
              minutes: minutes,
              ratePerMinute: (_int(quote['gross_inr']) / minutes).round(),
              requestedAt: DateTime.now(),
              method: method.summary,
            )
            ..apiGross = _int(quote['gross_inr'])
            ..apiNet = _int(quote['net_inr']);
      await load(user);
      return withdrawal;
    }
    throw _notLoaded;
  }

  /// How a withdrawal entry reads in history.
  String entryStatus(AppUser user, WalletEntry e) => switch (e.apiStatus) {
    'on_hold' => 'On Hold',
    'available' => 'Available',
    'withdrawn' => 'Withdrawn',
    _ => _localStatus(user, e),
  };

  String _localStatus(AppUser user, WalletEntry e) => switch (e.kind) {
    EntryKind.sessionEarning => 'Available',
    EntryKind.reversal => 'Returned',
    EntryKind.withdrawal => switch (withdrawalById(user, e.withdrawalId ?? '')?.status) {
      WithdrawalStatus.completed => 'Withdrawn',
      WithdrawalStatus.rejected => 'Rejected',
      _ => 'Pending',
    },
  };

  // ---- Payment methods -------------------------------------------------------------------

  List<PayoutMethod> methods(AppUser user) {
    _ledger(user);
    return _methods.putIfAbsent(user.email, () => []);
  }

  PayoutMethod? defaultMethod(AppUser user) =>
      methods(user).where((m) => m.isDefault).firstOrNull ?? methods(user).firstOrNull;

  static final _upi = RegExp(r'^[a-zA-Z0-9._-]{2,}@[a-zA-Z]{2,}$');
  static final _ifsc = RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$');
  static final _name = RegExp(r"^[a-zA-Z][a-zA-Z .'-]{1,49}$");

  /// Field checks shared by the form and the service.
  static String? checkUpi(String v) =>
      _upi.hasMatch(v.trim()) ? null : 'Use the format name@bank, e.g. alice@hdfcbank.';
  static String? checkAccount(String v) => RegExp(r'^\d{9,18}$').hasMatch(v.trim()) ? null : 'Enter 9 to 18 digits.';
  static String? checkIfsc(String v) =>
      _ifsc.hasMatch(v.trim().toUpperCase()) ? null : 'Use 11 characters: 4 letters, 0, then 6 letters or digits.';
  static String? checkBankName(String v) =>
      RegExp(r'^[a-zA-Z][a-zA-Z .&-]{1,49}$').hasMatch(v.trim()) ? null : 'Use letters only, no digits.';
  static String? checkHolder(String v) => _name.hasMatch(v.trim()) ? null : 'Enter the full name as per bank records.';

  Future<PayoutMethod> addMethod(
    AppUser user, {
    required PayoutType type,
    required String holderName,
    required String displayName,
    required bool makeDefault,
    String? upiId,
    String? accountNumber,
    String? ifsc,
    String? bankName,
  }) async {
    final problem = type == PayoutType.upi
        ? checkUpi(upiId ?? '') ?? checkHolder(holderName)
        : checkAccount(accountNumber ?? '') ??
              checkIfsc(ifsc ?? '') ??
              checkBankName(bankName ?? '') ??
              checkHolder(holderName);
    if (problem != null) throw AuthException(problem);
    final duplicate = methods(user).any(
      (m) => type == PayoutType.upi
          ? m.upiId?.toLowerCase() == upiId!.trim().toLowerCase()
          : m.accountNumber == accountNumber!.trim(),
    );
    if (duplicate) throw const AuthException('You\'ve already added this payment method.');
    final name = displayName.trim().isEmpty ? (type == PayoutType.upi ? 'UPI' : bankName!.trim()) : displayName.trim();
    if (isRemote(user)) {
      final created = _methodFrom(
        await SolverWalletApi.addMethod(
          type: type == PayoutType.upi ? 'upi' : 'bank_account',
          displayName: name,
          details: _details(
            type: type,
            holderName: holderName,
            upiId: upiId,
            accountNumber: accountNumber,
            ifsc: ifsc,
            bankName: bankName,
          ),
          makeDefault: makeDefault || methods(user).isEmpty,
        ),
      );
      if (created.isDefault) {
        for (final m in methods(user)) {
          m.isDefault = false;
        }
      }
      methods(user).add(created);
      notifyListeners();
      return created;
    }
    throw _notLoaded;
  }

  /// Saves changes to [old], keeping its place in the list. On the server the
  /// details are shown masked, so only fields the solver changed are checked
  /// and sent.
  Future<PayoutMethod> updateMethod(
    AppUser user,
    PayoutMethod old, {
    required PayoutType type,
    required String holderName,
    required String displayName,
    required bool makeDefault,
    String? upiId,
    String? accountNumber,
    String? ifsc,
    String? bankName,
  }) async {
    final name = displayName.trim().isEmpty
        ? (type == PayoutType.upi ? 'UPI' : (bankName ?? '').trim())
        : displayName.trim();
    if (isRemote(user)) {
      if (type != old.type) {
        throw const AuthException('To switch between UPI and bank, add a new payment method instead.');
      }
      final details = _details(
        type: type,
        holderName: holderName,
        upiId: upiId,
        accountNumber: accountNumber,
        ifsc: ifsc,
        bankName: bankName,
        old: old,
      );
      final problem = [
        if (details['upi_id'] case final String v) checkUpi(v),
        if (details['account_number'] case final String v) checkAccount(v),
        if (details['ifsc'] case final String v) checkIfsc(v),
        if (details['bank_name'] case final String v) checkBankName(v),
        if (details['account_holder_name'] case final String v) checkHolder(v),
      ].nonNulls.firstOrNull;
      if (problem != null) throw AuthException(problem);
      final updated = _methodFrom(
        await SolverWalletApi.updateMethod(
          old.id,
          displayName: name != old.displayName && name.length >= 3 ? name : null,
          details: details,
          makeDefault: makeDefault && !old.isDefault ? true : null,
        ),
      );
      final list = methods(user);
      if (updated.isDefault) {
        for (final m in list) {
          m.isDefault = false;
        }
      }
      list[list.indexOf(old)] = updated;
      notifyListeners();
      return updated;
    }
    throw _notLoaded;
  }

  Future<void> setDefault(AppUser user, PayoutMethod method) async {
    if (!isRemote(user)) throw _notLoaded;
    await SolverWalletApi.updateMethod(method.id, makeDefault: true);
    for (final m in methods(user)) {
      m.isDefault = m == method;
    }
    notifyListeners();
  }

  /// The server makes the newest remaining method the default if needed.
  Future<void> removeMethod(AppUser user, PayoutMethod method) async {
    if (!isRemote(user)) throw _notLoaded;
    await SolverWalletApi.removeMethod(method.id);
    await load(user);
  }

  // ---- Exports ---------------------------------------------------------------------------

  List<ExportRecord> exports(AppUser user) => _exports.putIfAbsent(user.email, () => []);

  void recordExport(AppUser user, ExportRecord record) {
    exports(user).insert(0, record);
    notifyListeners();
  }
}

/// ₹ amounts with Indian digit grouping, e.g. 1,25,000.
String formatInr(int amount) {
  final digits = amount.abs().toString();
  if (digits.length <= 3) return '${amount < 0 ? '-' : ''}$digits';
  final head = digits.substring(0, digits.length - 3);
  final tail = digits.substring(digits.length - 3);
  final groups = <String>[];
  for (var i = head.length; i > 0; i -= 2) {
    groups.insert(0, head.substring(i - 2 < 0 ? 0 : i - 2, i));
  }
  return '${amount < 0 ? '-' : ''}${groups.join(',')},$tail';
}
