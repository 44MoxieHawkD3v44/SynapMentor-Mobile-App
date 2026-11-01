import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/explore_service.dart';
import '../services/export_files.dart';
import '../services/solver_wallet_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/wallet_card.dart';
import '../widgets/glass_select.dart';
import 'booking_sheet.dart';
import 'bookings_tab.dart' show DetailRow;

enum _Tab {
  wallet('Wallet', Icons.account_balance_wallet_outlined),
  methods('Methods', Icons.credit_card_outlined),
  history('History', Icons.history_rounded),
  withdraw('Withdraw', Icons.payments_outlined),
  export('Export', Icons.file_download_outlined);

  const _Tab(this.label, this.icon);
  final String label;
  final IconData icon;
}

enum _HistoryFilter {
  all('All Transactions'),
  earnings('Session Earnings'),
  withdrawals('Withdrawals'),
  reversals('Reversals');

  const _HistoryFilter(this.label);
  final String label;

  bool matches(WalletEntry e) => switch (this) {
    all => true,
    earnings => e.kind == EntryKind.sessionEarning,
    withdrawals => e.kind == EntryKind.withdrawal,
    reversals => e.kind == EntryKind.reversal,
  };
}

enum _ExportType {
  all('All Transactions'),
  earnings('Session Earnings Only'),
  withdrawals('Withdrawals Only'),
  methods('Payment Methods');

  const _ExportType(this.label);
  final String label;
}

String _stamp(DateTime t) => '${formatDay(t)}, ${formatClock(t)}';

Future<T?> _sheet<T>(BuildContext context, Widget sheet) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: 0.35),
  builder: (_) => sheet,
);

/// Solver Payments: Synap Minutes earned from sessions, withdrawals to money,
/// payout methods, history and exports. Opens on [initialHistory] when the
/// dashboard's "View Detailed Earnings" is used.
class SolverPaymentsTab extends StatefulWidget {
  const SolverPaymentsTab({super.key, required this.user});

  final AppUser user;

  /// Bumped by the dashboard's "View Detailed Earnings" to open History.
  static final openHistory = ValueNotifier<int>(0);

  @override
  State<SolverPaymentsTab> createState() => _SolverPaymentsTabState();
}

class _SolverPaymentsTabState extends State<SolverPaymentsTab> {
  final _wallet = SolverWalletService.instance;
  final _search = TextEditingController();
  final _minutes = TextEditingController();
  _Tab _tab = _Tab.wallet;
  _HistoryFilter _filter = _HistoryFilter.all;
  String? _notice;
  NoticeTone _tone = NoticeTone.success;
  bool _requesting = false;
  String? _minutesError;

  // Export
  DateTime? _from;
  DateTime? _to;
  _ExportType _exportType = _ExportType.all;
  bool _exporting = false;

  AppUser get _user => widget.user;

  @override
  void initState() {
    super.initState();
    SolverPaymentsTab.openHistory.addListener(_showHistory);
    _wallet.load(_user).then((_) {
      final error = _wallet.loadError;
      if (mounted && error != null) _say(error, NoticeTone.error);
    });
  }

  void _showHistory() {
    if (mounted) {
      setState(() {
        _tab = _Tab.history;
        _filter = _HistoryFilter.earnings;
        _notice = null;
      });
    }
  }

  @override
  void dispose() {
    SolverPaymentsTab.openHistory.removeListener(_showHistory);
    _search.dispose();
    _minutes.dispose();
    super.dispose();
  }

  void _say(String text, [NoticeTone tone = NoticeTone.success]) => setState(() {
    _notice = text;
    _tone = tone;
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
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
                  const Text(
                    'Payments',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                  gap14,
                  Row(
                    children: [
                      for (final tab in _Tab.values) ...[
                        if (tab != _Tab.values.first) const SizedBox(width: 6),
                        Expanded(
                          child: GlassOption(
                            height: 60,
                            radius: 16,
                            selected: _tab == tab,
                            onTap: () => setState(() {
                              _tab = tab;
                              _notice = null;
                            }),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(tab.icon, size: 19, color: Colors.white),
                                const SizedBox(height: 4),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(tab.label, style: AppText.label.copyWith(fontSize: 11.5)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  gap14,
                  InlineNotice(message: _notice, tone: _tone),
                  StepSwitcher(
                    child: KeyedSubtree(
                      key: ValueKey(_tab),
                      child: switch (_tab) {
                        _Tab.wallet => _buildWallet(),
                        _Tab.methods => _buildMethods(),
                        _Tab.history => _buildHistory(),
                        _Tab.withdraw => _buildWithdraw(),
                        _Tab.export => _buildExport(),
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Wallet --------------------------------------------------------------------------

  Widget _buildWallet() {
    final balance = _wallet.balance(_user);
    final rate = _wallet.ratePerMinute(_user);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WalletCard(
          holder: _user.name,
          balanceLabel: 'Synap Minutes',
          balance: '$balance min',
          caption: '≈ ₹${formatInr(balance * rate)} before the platform fee',
          trailing: '₹$rate/min',
        ),
        gap24,
        const Text('Wallet Overview', style: _heading),
        gap14,
        GlassWell(
          radius: 20,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(
            children: [
              _OverviewRow(Icons.savings_outlined, 'Total Minutes Earned', '${_wallet.totalEarned(_user)} min'),
              Container(height: 1, color: AppColors.white(0.1)),
              _OverviewRow(Icons.account_balance_wallet_outlined, 'Available for Withdrawal', '$balance min'),
              Container(height: 1, color: AppColors.white(0.1)),
              _OverviewRow(Icons.schedule_rounded, 'Pending Withdrawal', '${_wallet.pendingWithdrawal(_user)} min'),
            ],
          ),
        ),
        gap14,
        InlineNotice(
          message:
              'Minutes will be credited to your wallet after the session is completed and both reviews are '
              'submitted. Anonymous sessions earn ${ExploreService.anonymousLabel} minutes.',
        ),
      ],
    );
  }

  // ---- Methods --------------------------------------------------------------------------

  Widget _buildMethods() {
    final methods = _wallet.methods(_user);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Payment Methods', style: _heading)),
            SmallPillButton(label: '+ Add Method', onPressed: _addMethod),
          ],
        ),
        gap14,
        if (methods.isEmpty)
          _EmptyPanel(
            icon: Icons.credit_card_outlined,
            text: 'Add a UPI ID or bank account to receive your withdrawals.',
          )
        else
          for (final m in methods)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GlassWell(
                radius: 18,
                padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
                child: Row(
                  children: [
                    GlassIconBadge(
                      icon: m.type == PayoutType.upi ? Icons.qr_code_2_rounded : Icons.account_balance_outlined,
                      size: 44,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.displayName,
                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                          Text(
                            m.type == PayoutType.upi
                                ? 'UPI · ${m.upiId}'
                                : 'Bank · ****${m.accountNumber!.substring(m.accountNumber!.length - 4)}',
                            style: AppText.caption.copyWith(fontSize: 12),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            children: [if (m.isDefault) const _Badge('Default'), const _Badge('Active')],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'More',
                      onPressed: () => _methodMenu(m),
                      icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _addMethod() async {
    final added = await _sheet<PayoutMethod>(context, _AddMethodSheet(user: _user));
    if (added != null && mounted) _say('${added.displayName} added.');
  }

  Future<void> _methodMenu(PayoutMethod m) async {
    final options = [
      (Icons.visibility_outlined, 'View', 'view'),
      (Icons.edit_outlined, 'Edit', 'edit'),
      if (!m.isDefault) (Icons.star_outline_rounded, 'Set as Default', 'default'),
      (Icons.delete_outline_rounded, 'Remove', 'remove'),
    ];
    final choice = await _sheet<String>(
      context,
      FlowSheetFrame(
        title: m.displayName,
        body: Builder(
          builder: (sheetContext) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (icon, label, value) in options)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GlassOption(
                    height: 54,
                    radius: 16,
                    selected: false,
                    onTap: () => Navigator.of(sheetContext).pop(value),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          Icon(icon, color: Colors.white),
                          const SizedBox(width: 12),
                          Text(label, style: AppText.label.copyWith(fontSize: 14)),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'view':
        await _sheet<void>(context, _MethodDetailsSheet(method: m));
      case 'edit':
        final updated = await _sheet<PayoutMethod>(context, _AddMethodSheet(user: _user, existing: m));
        if (updated != null && mounted) _say('${updated.displayName} updated.');
      case 'default':
        try {
          await _wallet.setDefault(_user, m);
          if (mounted) _say('${m.displayName} is now your default payment method.');
        } on AuthException catch (e) {
          if (mounted) _say(e.message, NoticeTone.error);
        }
      case 'remove':
        try {
          await _wallet.removeMethod(_user, m);
          if (mounted) _say('${m.displayName} removed.');
        } on AuthException catch (e) {
          if (mounted) _say(e.message, NoticeTone.error);
        }
    }
  }

  // ---- History --------------------------------------------------------------------------

  Widget _buildHistory() {
    final q = _search.text.trim().toLowerCase();
    final list = _wallet
        .entries(_user)
        .where(
          (e) =>
              _filter.matches(e) &&
              (q.isEmpty || '${e.title} ${e.seeker ?? ''} ${e.kind.label}'.toLowerCase().contains(q)),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: GlassTextField(
                controller: _search,
                hint: 'Search transactions…',
                icon: Icons.search_rounded,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            _Dropdown(
              label: _filter == _HistoryFilter.all ? 'All' : _filter.label,
              onTap: () async {
                final picked = await showGlassPicker(
                  context,
                  title: 'Show',
                  options: _HistoryFilter.values,
                  label: (f) => f.label,
                  selected: _filter,
                );
                if (picked != null) setState(() => _filter = picked);
              },
            ),
          ],
        ),
        gap14,
        if (list.isEmpty)
          const _EmptyPanel(icon: Icons.receipt_long_outlined, text: 'No transactions match.')
        else
          for (final e in list)
            _EntryTile(
              entry: e,
              status: _wallet.entryStatus(_user, e),
              onTap: () => _sheet<void>(context, _EntrySheet(user: _user, entry: e)),
            ),
      ],
    );
  }

  // ---- Withdraw --------------------------------------------------------------------------

  Widget _buildWithdraw() {
    final balance = _wallet.balance(_user);
    final rate = _wallet.ratePerMinute(_user);
    final min = SolverWalletService.minWithdrawal;
    final minutes = int.tryParse(_minutes.text.trim());
    final canRequest = balance >= min;
    final history = _wallet.withdrawals(_user);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Withdraw Earnings', style: _heading),
        gap14,
        GlassWell(
          radius: 20,
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const GlassIconBadge(icon: Icons.account_balance_wallet_outlined, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Available Minutes', style: AppText.caption),
                    Text(
                      '$balance min',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    Text(
                      '≈ ₹${formatInr(balance * rate)} before platform fee',
                      style: AppText.caption.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        gap14,
        const Text('Minutes to Withdraw', style: _label),
        gap8,
        GlassTextField(
          controller: _minutes,
          hint: 'Enter minutes (min: $min)',
          icon: Icons.timelapse_rounded,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          errorText: _minutesError,
          onChanged: (_) => setState(() => _minutesError = null),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: UnderlineLink(
            label: 'Withdraw all ($balance min)',
            onTap: () => setState(() {
              _minutes.text = '$balance';
              _minutesError = null;
            }),
          ),
        ),
        gap8,
        if (minutes != null && minutes > 0) ...[_Estimate(minutes: minutes, rate: rate), gap14],
        PrimaryPillButton(
          label: 'Request Withdrawal',
          loading: _requesting,
          onPressed: canRequest ? _requestWithdrawal : null,
        ),
        gap14,
        InlineNotice(
          message:
              'Minimum withdrawal: $min minutes. The amount is credited to your payment method within '
              '${SolverWalletService.payoutDays} days, and you\'ll get an email once it\'s paid.',
        ),
        gap14,
        const Text('Withdrawal History', style: _heading),
        gap14,
        if (history.isEmpty)
          const _EmptyPanel(icon: Icons.payments_outlined, text: 'No withdrawals yet.')
        else
          for (final w in history) _WithdrawalCard(withdrawal: w),
      ],
    );
  }

  Future<void> _requestWithdrawal() async {
    final minutes = int.tryParse(_minutes.text.trim());
    final min = SolverWalletService.minWithdrawal;
    final balance = _wallet.balance(_user);
    setState(() {
      _minutesError = minutes == null
          ? 'Enter the minutes to withdraw.'
          : minutes < min
          ? 'The minimum withdrawal is $min minutes.'
          : minutes > balance
          ? 'You have $balance minutes available.'
          : null;
    });
    if (_minutesError != null) return;
    setState(() => _requesting = true);
    try {
      final w = await _wallet.requestWithdrawal(_user, minutes!);
      if (!mounted) return;
      _minutes.clear();
      _say(
        'Withdrawal of ${w.minutes} min requested. ₹${formatInr(w.netAmount)} will reach ${w.method} within '
        '${SolverWalletService.payoutDays} days.',
      );
    } on AuthException catch (e) {
      if (mounted) _say(e.message, NoticeTone.error);
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  // ---- Export ----------------------------------------------------------------------------

  Widget _buildExport() {
    final records = _wallet.exports(_user);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassPanel(
          radius: 22,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Export Payment Data', style: _heading),
              gap14,
              const Text('Date Range', style: _label),
              gap8,
              Row(
                children: [
                  Expanded(
                    child: GlassSelectField(
                      value: _from == null ? null : formatDay(_from!),
                      hint: 'From',
                      trailingIcon: Icons.calendar_today_outlined,
                      onTap: () => _pickDate(true),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text('–', style: AppText.body),
                  ),
                  Expanded(
                    child: GlassSelectField(
                      value: _to == null ? null : formatDay(_to!),
                      hint: 'To',
                      trailingIcon: Icons.calendar_today_outlined,
                      onTap: () => _pickDate(false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text('Leave empty to include everything.', style: AppText.caption.copyWith(fontSize: 11.5)),
              gap14,
              const Text('Data Type', style: _label),
              gap8,
              for (final t in _ExportType.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _exportType = t),
                    child: Row(
                      children: [
                        GlassCheckbox(value: _exportType == t, onChanged: (_) => setState(() => _exportType = t)),
                        const SizedBox(width: 10),
                        Text(t.label, style: AppText.label.copyWith(fontSize: 13.5)),
                      ],
                    ),
                  ),
                ),
              gap14,
              Row(
                children: [
                  Expanded(
                    child: GlassPillButton(
                      label: 'Export PDF',
                      icon: Icons.picture_as_pdf_outlined,
                      loading: _exporting,
                      onPressed: _exporting ? null : () => _export(pdf: true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GlassPillButton(
                      label: 'Export Excel',
                      icon: Icons.table_chart_outlined,
                      loading: _exporting,
                      onPressed: _exporting ? null : () => _export(pdf: false),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        gap14,
        GlassPanel(
          radius: 22,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Recent Exports', style: _heading),
              gap8,
              if (records.isEmpty)
                Text('No exports yet - files you export will appear here for re-download.', style: AppText.caption)
              else
                for (final r in records)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: GlassWell(
                      radius: 14,
                      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                      child: Row(
                        children: [
                          Icon(
                            r.fileName.endsWith('.pdf') ? Icons.picture_as_pdf_outlined : Icons.table_chart_outlined,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(r.fileName, style: AppText.label.copyWith(fontSize: 13)),
                                Text(_stamp(r.createdAt), style: AppText.caption.copyWith(fontSize: 11.5)),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Download again',
                            onPressed: () => _save(r),
                            icon: const Icon(Icons.file_download_outlined, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  ThemeData _pickerTheme(BuildContext context) => Theme.of(context).copyWith(
    colorScheme: const ColorScheme.dark(
      primary: Colors.white,
      onPrimary: AppColors.primary,
      surface: AppColors.primary,
      onSurface: Colors.white,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: AppColors.primary),
  );

  Future<void> _pickDate(bool from) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (from ? _from : _to) ?? now,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      builder: (context, child) => Theme(data: _pickerTheme(context), child: child!),
    );
    if (picked != null) setState(() => from ? _from = picked : _to = picked);
  }

  List<ExportTable> _tables() {
    final from = _from;
    final to = _to == null ? null : DateTime(_to!.year, _to!.month, _to!.day, 23, 59, 59);
    bool inRange(DateTime t) => (from == null || !t.isBefore(from)) && (to == null || !t.isAfter(to));
    final entries = _wallet.entries(_user).where((e) => inRange(e.at)).toList();
    ExportTable ledger(String title, Iterable<WalletEntry> list) => ExportTable(
      title: title,
      headers: const ['Date', 'Type', 'Details', 'Minutes', 'Balance', 'Status'],
      rows: [
        for (final e in list)
          [
            _stamp(e.at),
            e.kind.label,
            e.kind == EntryKind.sessionEarning
                ? '${e.title} (${e.seeker}, ${e.sessionMinutes} min${e.anonymous ? ', ${ExploreService.anonymousLabel}' : ''})'
                : e.title,
            '${e.minutes}',
            '${e.balanceAfter}',
            _wallet.entryStatus(_user, e),
          ],
      ],
    );
    final withdrawals = ExportTable(
      title: 'Withdrawals',
      headers: const ['Requested', 'Minutes', 'Rate', 'Gross', 'Fee (30%)', 'You receive (70%)', 'Status', 'Reference'],
      rows: [
        for (final w in _wallet.withdrawals(_user).where((w) => inRange(w.requestedAt)))
          [
            _stamp(w.requestedAt),
            '${w.minutes}',
            '₹${w.ratePerMinute}/min',
            '₹${formatInr(w.grossAmount)}',
            '₹${formatInr(w.fee)}',
            '₹${formatInr(w.netAmount)}',
            w.status.label,
            w.utr ?? w.rejectionReason ?? '',
          ],
      ],
    );
    final methods = ExportTable(
      title: 'Payment Methods',
      headers: const ['Name', 'Type', 'Details', 'Account holder', 'Default'],
      rows: [
        for (final m in _wallet.methods(_user))
          [m.displayName, m.type.label, m.summary, m.holderName, m.isDefault ? 'Yes' : 'No'],
      ],
    );
    return switch (_exportType) {
      _ExportType.all => [ledger('All Transactions', entries), withdrawals],
      _ExportType.earnings => [ledger('Session Earnings', entries.where((e) => e.kind == EntryKind.sessionEarning))],
      _ExportType.withdrawals => [withdrawals],
      _ExportType.methods => [methods],
    };
  }

  Future<void> _export({required bool pdf}) async {
    if (_from != null && _to != null && _to!.isBefore(_from!)) {
      _say('The end date must be after the start date.', NoticeTone.error);
      return;
    }
    setState(() => _exporting = true);
    final now = DateTime.now();
    final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final range = _from == null && _to == null
        ? 'All dates'
        : '${_from == null ? 'Start' : formatDay(_from!)} to ${_to == null ? 'today' : formatDay(_to!)}';
    final tables = _tables();
    final record = ExportRecord(
      fileName: 'synap_payments_${_exportType.name}_$stamp.${pdf ? 'pdf' : 'xls'}',
      createdAt: now,
      bytes: pdf
          ? buildPdf('Synap Mentor - Payment Data', [
              _user.name,
              '${_exportType.label} · $range',
              'Exported ${_stamp(now)}',
            ], tables)
          : buildExcel(tables),
      mimeType: pdf ? 'application/pdf' : 'application/vnd.ms-excel',
    );
    final saved = await _save(record);
    if (saved) _wallet.recordExport(_user, record);
    if (mounted) setState(() => _exporting = false);
  }

  Future<bool> _save(ExportRecord r) async {
    try {
      final path = await FilePicker.saveFile(
        fileName: r.fileName,
        bytes: r.bytes,
        mimeType: r.mimeType,
        dialogTitle: 'Save payment data',
      );
      if (path == null) return false;
      _say('${r.fileName} saved.');
      return true;
    } on PlatformException {
      _say('Couldn\'t save the file. Please try again.', NoticeTone.error);
      return false;
    }
  }

  static const _heading = TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white);
  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

// ---- Pieces ------------------------------------------------------------------------------

class _OverviewRow extends StatelessWidget {
  const _OverviewRow(this.icon, this.label, this.value);

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          GlassIconBadge(icon: icon, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.caption.copyWith(fontSize: 12.5)),
                Text(
                  value,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Minutes × price, then 30% platform fee and the solver's 70%.
class _Estimate extends StatelessWidget {
  const _Estimate({required this.minutes, required this.rate});

  final int minutes;
  final int rate;

  @override
  Widget build(BuildContext context) {
    final gross = minutes * rate;
    final net = (gross * 0.70).round();
    final fee = gross - net;
    final row = AppText.label.copyWith(fontSize: 13.5);
    return GlassWell(
      radius: 18,
      active: true,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Estimated Amount Calculation', style: AppText.caption.copyWith(color: Colors.white)),
          gap8,
          Row(
            children: [
              Expanded(child: Text('$minutes min × ₹$rate/min', style: row)),
              Text('₹${formatInr(gross)}', style: row),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: Text('Platform Fee (30%)', style: AppText.caption.copyWith(fontSize: 13))),
              Text('- ₹${formatInr(fee)}', style: AppText.caption.copyWith(fontSize: 13)),
            ],
          ),
          Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 8), color: AppColors.white(0.14)),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'You will receive (70%)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ),
              Text(
                '₹${formatInr(net)}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.status, required this.onTap});

  final WalletEntry entry;
  final String status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final credit = e.minutes > 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassWell(
        radius: 18,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GlassIconBadge(icon: credit ? Icons.south_west_rounded : Icons.north_east_rounded, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.kind == EntryKind.sessionEarning ? e.title : e.kind.label.toUpperCase(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                        const SizedBox(height: 2),
                        Text(_stamp(e.at), style: AppText.caption.copyWith(fontSize: 12)),
                        if (e.sessionMinutes != null)
                          Text(
                            '${e.sessionMinutes} min session${e.anonymous ? ' · ${ExploreService.anonymousLabel} anonymous' : ''}',
                            style: AppText.caption.copyWith(fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${credit ? '+' : ''}${e.minutes} min',
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                      Text('Bal: ${e.balanceAfter} min', style: AppText.caption.copyWith(fontSize: 11.5)),
                      const SizedBox(height: 4),
                      _Badge(status),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EntrySheet extends StatelessWidget {
  const _EntrySheet({required this.user, required this.entry});

  final AppUser user;
  final WalletEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final wallet = SolverWalletService.instance;
    final w = e.withdrawalId == null ? null : wallet.withdrawalById(user, e.withdrawalId!);
    return FlowSheetFrame(
      title: e.kind == EntryKind.sessionEarning ? e.title : e.kind.label,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(e.kind.label.toUpperCase(), style: AppText.caption.copyWith(fontSize: 12)),
          gap14,
          GlassWell(
            radius: 18,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('MINUTES', style: AppText.caption.copyWith(fontSize: 11.5)),
                Text(
                  '${e.minutes > 0 ? '+' : ''}${e.minutes}',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ],
            ),
          ),
          gap14,
          GlassWell(
            radius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                DetailRow('Status', wallet.entryStatus(user, e)),
                DetailRow('Date', _stamp(e.at)),
                DetailRow('Type', e.kind.label),
                DetailRow('Direction', e.minutes > 0 ? 'Credit' : 'Debit'),
                if (e.kind == EntryKind.sessionEarning) ...[
                  DetailRow('Session', e.title),
                  DetailRow('Seeker', e.seeker ?? ''),
                  DetailRow('Session length', '${e.sessionMinutes} min'),
                  if (e.anonymous) DetailRow('Anonymous booking', '${ExploreService.anonymousLabel} minutes'),
                ],
                if (w != null) ...[
                  DetailRow('Request', w.id),
                  DetailRow('Paid to', w.method),
                  DetailRow('You receive', '₹${formatInr(w.netAmount)}'),
                  if (w.utr != null) DetailRow('Reference', w.utr!),
                  if (w.rejectionReason != null) DetailRow('Reason', w.rejectionReason!),
                ],
                DetailRow('Balance after', '${e.balanceAfter} min'),
              ],
            ),
          ),
        ],
      ),
      footer: PrimaryPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class _WithdrawalCard extends StatelessWidget {
  const _WithdrawalCard({required this.withdrawal});

  final Withdrawal withdrawal;

  @override
  Widget build(BuildContext context) {
    final w = withdrawal;
    final meta = AppText.caption.copyWith(fontSize: 12);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassWell(
        radius: 18,
        error: w.status == WithdrawalStatus.rejected,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${w.minutes} minutes - ₹${formatInr(w.netAmount)}',
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                      Text('${w.method} (after platform fee)', style: meta),
                      Text(
                        'Requested: ${formatDay(w.requestedAt)}'
                        '${w.paidAt == null ? '' : '  |  Paid: ${formatDay(w.paidAt!)}'}',
                        style: meta,
                      ),
                      if (w.utr != null) Text(w.utr!, style: meta.copyWith(color: Colors.white)),
                    ],
                  ),
                ),
                _Badge(w.status.label),
              ],
            ),
            if (w.status == WithdrawalStatus.rejected) ...[
              gap8,
              Text(w.rejectionReason ?? '', style: AppText.caption.copyWith(fontSize: 12, color: AppColors.error)),
              Text('The ${w.minutes} minutes have been returned to your wallet.', style: meta),
            ],
            if (w.status == WithdrawalStatus.pending) ...[
              gap8,
              Text('Arrives within ${SolverWalletService.payoutDays} days of the request.', style: meta),
            ],
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

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

class _Dropdown extends StatelessWidget {
  const _Dropdown({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      height: 54,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 22,
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          GlassIconBadge(icon: icon, size: 60),
          gap14,
          Text(text, style: AppText.body, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

// ---- Add method ----------------------------------------------------------------------------

/// A saved payment method's details.
class _MethodDetailsSheet extends StatelessWidget {
  const _MethodDetailsSheet({required this.method});

  final PayoutMethod method;

  @override
  Widget build(BuildContext context) {
    final m = method;
    return FlowSheetFrame(
      title: m.displayName,
      body: GlassWell(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          children: [
            DetailRow('Type', m.type.label),
            if (m.type == PayoutType.upi)
              DetailRow('UPI ID', m.upiId!)
            else ...[
              DetailRow('Bank', m.bankName!),
              DetailRow('Account', '****${m.accountNumber!.substring(m.accountNumber!.length - 4)}'),
              DetailRow('IFSC', m.ifsc!),
            ],
            DetailRow('Account holder', m.holderName),
            DetailRow('Default', m.isDefault ? 'Yes' : 'No'),
            const DetailRow('Status', 'Active'),
          ],
        ),
      ),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class _AddMethodSheet extends StatefulWidget {
  const _AddMethodSheet({required this.user, this.existing});

  final AppUser user;

  /// Set when editing a saved method.
  final PayoutMethod? existing;

  @override
  State<_AddMethodSheet> createState() => _AddMethodSheetState();
}

class _AddMethodSheetState extends State<_AddMethodSheet> {
  late final _upi = TextEditingController(text: widget.existing?.upiId);
  late final _account = TextEditingController(text: widget.existing?.accountNumber);
  late final _ifsc = TextEditingController(text: widget.existing?.ifsc);
  late final _bank = TextEditingController(text: widget.existing?.bankName);
  late final _holder = TextEditingController(text: widget.existing?.holderName);
  late final _display = TextEditingController(text: widget.existing?.displayName);
  late PayoutType _type = widget.existing?.type ?? PayoutType.upi;
  late bool _default = widget.existing?.isDefault ?? false;
  bool _saving = false;
  final _errors = <String, String?>{};
  String? _error;

  @override
  void dispose() {
    for (final c in [_upi, _account, _ifsc, _bank, _holder, _display]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final upi = _type == PayoutType.upi;
    setState(() {
      _error = null;
      _errors
        ..clear()
        ..addAll({
          if (upi) 'upi': SolverWalletService.checkUpi(_upi.text),
          if (!upi) 'account': SolverWalletService.checkAccount(_account.text),
          if (!upi) 'ifsc': SolverWalletService.checkIfsc(_ifsc.text),
          if (!upi) 'bank': SolverWalletService.checkBankName(_bank.text),
          'holder': SolverWalletService.checkHolder(_holder.text),
        });
    });
    if (_errors.values.any((e) => e != null)) return;
    setState(() => _saving = true);
    try {
      final wallet = SolverWalletService.instance;
      final existing = widget.existing;
      final method = existing == null
          ? await wallet.addMethod(
              widget.user,
              type: _type,
              holderName: _holder.text,
              displayName: _display.text,
              makeDefault: _default,
              upiId: upi ? _upi.text : null,
              accountNumber: upi ? null : _account.text,
              ifsc: upi ? null : _ifsc.text,
              bankName: upi ? null : _bank.text,
            )
          : await wallet.updateMethod(
              widget.user,
              existing,
              type: _type,
              holderName: _holder.text,
              displayName: _display.text,
              makeDefault: _default,
              upiId: upi ? _upi.text : null,
              accountNumber: upi ? null : _account.text,
              ifsc: upi ? null : _ifsc.text,
              bankName: upi ? null : _bank.text,
            );
      if (mounted) Navigator.of(context).pop(method);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    String label,
    TextEditingController c,
    String key,
    String hint, {
    String? help,
    TextInputType? keyboard,
    List<TextInputFormatter>? formatters,
    TextCapitalization caps = TextCapitalization.none,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: _SolverPaymentsTabState._label),
          gap8,
          GlassTextField(
            controller: c,
            hint: hint,
            keyboardType: keyboard,
            inputFormatters: formatters,
            textCapitalization: caps,
            errorText: _errors[key],
            onChanged: (_) => setState(() => _errors[key] = null),
          ),
          if (help != null && _errors[key] == null) ...[
            const SizedBox(height: 4),
            Text(help, style: AppText.caption.copyWith(fontSize: 11.5)),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final upi = _type == PayoutType.upi;
    return FlowSheetFrame(
      title: widget.existing == null ? 'Add Payment Method' : 'Edit Payment Method',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          const Text('Payment Type', style: _SolverPaymentsTabState._label),
          gap8,
          GlassSelectField(
            value: _type.label,
            hint: 'Select type',
            onTap: () async {
              final picked = await showGlassPicker(
                context,
                title: 'Payment Type',
                options: PayoutType.values,
                label: (t) => t.label,
                selected: _type,
              );
              if (picked != null) {
                setState(() {
                  _type = picked;
                  _errors.clear();
                });
              }
            },
          ),
          gap14,
          if (upi)
            _field(
              'UPI ID',
              _upi,
              'upi',
              'name@bank',
              help: 'Format name@bank, e.g. alice@hdfcbank (${_upi.text.length}/64)',
              keyboard: TextInputType.emailAddress,
              formatters: [LengthLimitingTextInputFormatter(64)],
            )
          else ...[
            _field(
              'Account Number',
              _account,
              'account',
              '9-18 digits',
              help: 'Digits only, ${_account.text.length}/18 entered',
              keyboard: TextInputType.number,
              formatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(18)],
            ),
            _field(
              'IFSC Code',
              _ifsc,
              'ifsc',
              'HDFC0000123',
              help: '11 characters: 4 letters, 0, then 6 letters or digits',
              caps: TextCapitalization.characters,
              formatters: [LengthLimitingTextInputFormatter(11)],
            ),
            _field(
              'Bank Name',
              _bank,
              'bank',
              'HDFC Bank',
              help: 'Letters only, no digits',
              caps: TextCapitalization.words,
            ),
          ],
          _field(
            'Account Holder Name',
            _holder,
            'holder',
            'Full name as per bank records',
            help: 'Must match the name on the ${upi ? 'UPI' : 'bank'} account (${_holder.text.length}/50)',
            caps: TextCapitalization.words,
            formatters: [LengthLimitingTextInputFormatter(50)],
          ),
          _field(
            'Display Name',
            _display,
            'display',
            upi ? 'Personal UPI' : 'HDFC Savings',
            help: 'Your label for this destination (${_display.text.length}/50)',
            caps: TextCapitalization.words,
            formatters: [LengthLimitingTextInputFormatter(50)],
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _default = !_default),
            child: Row(
              children: [
                GlassCheckbox(value: _default, onChanged: (v) => setState(() => _default = v)),
                const SizedBox(width: 10),
                Text('Set as default payment method', style: AppText.label.copyWith(fontSize: 13.5)),
              ],
            ),
          ),
        ],
      ),
      footer: PrimaryPillButton(
        label: widget.existing == null ? 'Add Method' : 'Save Changes',
        loading: _saving,
        onPressed: _save,
      ),
    );
  }
}
