import 'package:flutter/material.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/explore_service.dart';
import '../services/solver_service.dart';
import '../services/kyc_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import 'kyc_screen.dart';
import 'top_up_prompt.dart';

/// Opens the booking flow for [solver]. Resolves to true when the user asks to
/// see their bookings afterwards. A seeker low on minutes is offered a top-up
/// first. With [type] (e.g. from Podcasts), that type is used and the booking
/// starts at choosing the date.
Future<bool?> showBookingSheet(
  BuildContext context, {
  required AppUser user,
  required Solver solver,
  BookingPrefill? prefill,
  BookingType? type,
}) async {
  if (user.role == UserRole.seeker && !await ensureWalletBalance(context, user)) return null;
  if (!context.mounted) return null;
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => _BookingSheet(user: user, solver: solver, prefill: prefill, type: type),
  );
}

/// Bottom-docked glass sheet with a title, optional step indicator, scrolling
/// body and fixed footer. Shared by the booking and pick-a-solver flows.
class FlowSheetFrame extends StatelessWidget {
  const FlowSheetFrame({
    super.key,
    required this.title,
    required this.body,
    this.footer,
    this.stepNumber,
    this.stepLabel,
    this.stepCount = 5,
    this.onBack,
  });

  final String title;
  final Widget body;
  final Widget? footer;
  final int? stepNumber;
  final String? stepLabel;
  final int stepCount;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.9, maxWidth: 560),
          child: GlassPanel(
            radius: 30,
            squareBottom: true,
            blur: 5,
            padding: EdgeInsets.fromLTRB(20, 10, 20, 16 + media.padding.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(color: AppColors.white(0.3), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (onBack != null)
                      IconButton(
                        tooltip: 'Back',
                        onPressed: onBack,
                        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                      ),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                  ],
                ),
                if (stepNumber != null) ...[
                  gap8,
                  Row(
                    children: [
                      SizedBox.square(
                        dimension: 28,
                        child: GlassWell(
                          radius: 14,
                          active: true,
                          fillTop: 0.08,
                          fillBottom: 0.05,
                          child: Center(
                            child: Text(
                              '$stepNumber',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(stepLabel ?? '', style: AppText.label)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: stepNumber! / stepCount),
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, _) => LinearProgressIndicator(
                        value: value,
                        minHeight: 3,
                        backgroundColor: AppColors.white(0.16),
                        valueColor: const AlwaysStoppedAnimation(Colors.white),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Flexible(
                  child: SingleChildScrollView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    child: body,
                  ),
                ),
                if (footer != null) ...[const SizedBox(height: 16), footer!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Selectable glass box used for dates, durations, slots and modes.
class GlassOption extends StatelessWidget {
  const GlassOption({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
    this.height = 48,
    this.radius = 16,
  });

  final bool selected;
  final VoidCallback? onTap;
  final Widget child;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: GlassWell(
          radius: radius,
          height: height,
          active: selected,
          fillTop: selected ? 0.10 : 0,
          fillBottom: selected ? 0.06 : 0,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(radius),
              onTap: onTap,
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lays children out in [columns] equal-width columns.
class OptionGrid extends StatelessWidget {
  const OptionGrid({super.key, required this.children, this.columns = 3, this.spacing = 10});

  final List<Widget> children;
  final int columns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [for (final child in children) SizedBox(width: width, child: child)],
        );
      },
    );
  }
}

enum _Step { type, schedule, slot, details, review, confirm, done }

enum _DayPart {
  morning('Morning'),
  afternoon('Afternoon'),
  evening('Evening');

  const _DayPart(this.label);
  final String label;

  static _DayPart of(DateTime wall) => wall.hour < 12 ? morning : (wall.hour < 17 ? afternoon : evening);
}

class _BookingSheet extends StatefulWidget {
  const _BookingSheet({required this.user, required this.solver, this.prefill, this.type});

  final AppUser user;
  final Solver solver;
  final BookingPrefill? prefill;

  /// Set when the booking type was already chosen; its step is skipped.
  final BookingType? type;

  @override
  State<_BookingSheet> createState() => _BookingSheetState();
}

class _BookingSheetState extends State<_BookingSheet> {
  final _explore = ExploreService.instance;
  late final _zone = ExploreService.userZone(widget.user);
  late final _title = TextEditingController(text: widget.prefill?.title);
  late final _details = TextEditingController(text: widget.prefill?.description);

  late _Step _step = widget.type == null ? _Step.type : _Step.schedule;
  late BookingType? _type = widget.type;
  late DateTime _date = _initialDate();
  int? _minutes;
  DateTime? _slot; // UTC
  late _DayPart _part = _DayPart.morning;
  SessionMode _mode = SessionMode.meet;

  /// The type step is left out when the type was given.
  bool get _typeFixed => widget.type != null;

  /// A given type that needs KYC the seeker hasn't done (the type step locks it).
  bool get _kycBlocked => _typeFixed && (_type?.needsKyc ?? false) && !_kycDone;

  bool _loading = false;
  String? _error;
  String? _titleError;
  String? _detailsError;
  Booking? _booking;

  Solver get _solver => widget.solver;
  bool get _kycDone => !kEnforceVerification || KycService.instance.stateFor(widget.user).completed;

  /// "Now" as a wall-clock time in the user's zone.
  DateTime get _nowWall => DateTime.now().toUtc().add(_zone.offset);

  DateTime _wall(DateTime utc) => _zone.wall(utc);

  /// Today, or the day of a prefilled slot, in the user's zone.
  DateTime _initialDate() {
    final slot = widget.prefill?.slot;
    final wall = slot == null ? _nowWall : _wall(slot);
    return DateTime.utc(wall.year, wall.month, wall.day);
  }

  @override
  void initState() {
    super.initState();
    _explore.addListener(_onSlots);
    _loadSlots();
  }

  /// Each day's slots show as soon as they arrive.
  void _onSlots() {
    if (mounted) setState(() => _step == _Step.slot && _slot == null ? _prepareSlotStep() : null);
  }

  /// The solver's free slots for the week come from the server.
  void _loadSlots() {
    _explore.loadSlots(_solver, _days, _zone, refresh: true).then((_) {
      if (mounted) setState(() => _step == _Step.slot ? _prepareSlotStep() : null);
    });
  }

  @override
  void dispose() {
    _explore.removeListener(_onSlots);
    _title.dispose();
    _details.dispose();
    super.dispose();
  }

  List<DateTime> get _days {
    final today = _nowWall;
    return [for (var i = 0; i < 7; i++) DateTime.utc(today.year, today.month, today.day + i)];
  }

  List<DateTime> _slotsFor(DateTime day) =>
      _explore.openSlots(_solver, day, _minutes ?? _type?.minMinutes ?? 10, _zone.offset);

  int get _cost => ExploreService.walletCost(_solver, _type!, _minutes!);

  void _go(_Step step) => setState(() {
    _step = step;
    _error = null;
    if (step == _Step.slot) _prepareSlotStep();
  });

  /// Keeps a prefilled or earlier choice if it still fits the chosen duration.
  void _prepareSlotStep() {
    final slots = _slotsFor(_date);
    final wanted = _slot ?? widget.prefill?.slot;
    _slot = wanted != null && slots.contains(wanted) ? wanted : null;
    final anchor = _slot ?? slots.firstOrNull;
    if (anchor != null) _part = _DayPart.of(_wall(anchor));
  }

  void _selectType(BookingType type) {
    setState(() {
      _type = type;
      if (_minutes != null && !type.durations.contains(_minutes)) _minutes = null;
      if (type == BookingType.podcast) _mode = SessionMode.meet;
    });
  }

  Future<void> _openKyc() async {
    await Navigator.of(context).push(glassRoute(KycScreen(user: widget.user)));
    if (mounted) setState(() {});
  }

  void _toReview() {
    setState(() {
      _titleError = _title.text.trim().isEmpty ? 'Add a topic for your session.' : null;
    });
    if (_titleError == null) _go(_Step.review);
  }

  /// Not enough minutes for this booking: offers the Minute Packs, then shows
  /// the updated balance.
  Future<void> _topUp() async {
    await showTopUpPrompt(context, widget.user, needed: _cost);
    if (mounted) setState(() {});
  }

  Future<void> _confirm() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final booking = await _explore.book(
        user: widget.user,
        solver: _solver,
        type: _type!,
        mode: _mode,
        start: _slot!,
        minutes: _minutes!,
        title: _title.text.trim(),
        description: _details.text.trim(),
        kycCompleted: _kycDone,
      );
      if (mounted) {
        setState(() => _booking = booking);
        _go(_Step.done);
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---- Frame -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final (number, label) = switch (_step) {
      _Step.type => (1, 'Choose Booking Type'),
      _Step.schedule => (2, 'Select Date & Duration'),
      _Step.slot => (3, 'Select Time Slot'),
      _Step.details => (4, 'Session Details'),
      _Step.review => (5, 'Review Details'),
      _ => (null, null),
    };
    // Without the type step, the steps count from the date.
    final shown = _typeFixed && number != null ? number - 1 : number;
    final back = switch (_step) {
      _Step.schedule when !_typeFixed => _Step.type,
      _Step.slot => _Step.schedule,
      _Step.details => _Step.slot,
      _Step.review => _Step.details,
      _ => null,
    };
    return FlowSheetFrame(
      title: switch (_step) {
        _Step.review => 'Booking Summary',
        _Step.confirm => 'Confirm Booking',
        _Step.done => 'Booking Confirmed',
        _ => 'Book a Session',
      },
      stepNumber: shown,
      stepCount: _typeFixed ? 4 : 5,
      stepLabel: label,
      onBack: back == null ? null : () => _go(back),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          StepSwitcher(
            child: KeyedSubtree(key: ValueKey(_step), child: _buildBody()),
          ),
        ],
      ),
      footer: _buildFooter(),
    );
  }

  Widget _buildFooter() {
    switch (_step) {
      case _Step.type:
        return PrimaryPillButton(label: 'Continue', onPressed: _type == null ? null : () => _go(_Step.schedule));
      case _Step.schedule:
        return PrimaryPillButton(
          label: 'Continue',
          onPressed: _minutes == null || _kycBlocked ? null : () => _go(_Step.slot),
        );
      case _Step.slot:
        return PrimaryPillButton(label: 'Continue', onPressed: _slot == null ? null : () => _go(_Step.details));
      case _Step.details:
        return PrimaryPillButton(label: 'Book Now', onPressed: _toReview);
      case _Step.review:
        // A podcast is booked only with the recording consent.
        final consented = _type != BookingType.podcast || _recordingConsent;
        return PrimaryPillButton(label: 'Confirm & Book', onPressed: consented ? () => _go(_Step.confirm) : null);
      case _Step.confirm:
        final affordable = _cost <= _explore.walletBalance(widget.user);
        return Row(
          children: [
            Expanded(
              child: GlassPillButton(label: 'Cancel', onPressed: _loading ? null : () => _go(_Step.review)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PrimaryPillButton(
                label: 'Confirm & Book',
                loading: _loading,
                onPressed: affordable ? _confirm : _topUp,
              ),
            ),
          ],
        );
      case _Step.done:
        return Row(
          children: [
            Expanded(
              child: GlassPillButton(label: 'View in Bookings', onPressed: () => Navigator.of(context).pop(true)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PrimaryPillButton(label: 'Done', onPressed: () => Navigator.of(context).pop(false)),
            ),
          ],
        );
    }
  }

  Widget _buildBody() => switch (_step) {
    _Step.type => _buildType(),
    _Step.schedule => _buildSchedule(),
    _Step.slot => _buildSlot(),
    _Step.details => _buildDetails(),
    _Step.review => _buildReview(),
    _Step.confirm => _buildConfirm(),
    _Step.done => _buildDone(),
  };

  // ---- Steps -------------------------------------------------------------------

  Widget _buildType() {
    final types = [
      BookingType.normal,
      BookingType.anonymous,
      if (SolverService.instance.podcastEnabled(_solver)) BookingType.podcast,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final type in types) ...[
          _TypeCard(
            type: type,
            selected: _type == type,
            locked: type.needsKyc && !_kycDone,
            onTap: () => _selectType(type),
          ),
          const SizedBox(height: 10),
        ],
        if (!_kycDone)
          Row(
            children: [
              Expanded(
                child: Text(
                  'Normal and podcast bookings need KYC verification. Anonymous booking doesn\'t.',
                  style: AppText.caption,
                ),
              ),
              UnderlineLink(label: 'Verify now', bold: true, onTap: _openKyc),
            ],
          ),
        if (_type == BookingType.podcast) ...[
          gap8,
          const InlineNotice(
            message: 'Podcast sessions are recorded. The solver may publish the recording in Content.',
          ),
        ],
      ],
    );
  }

  Widget _buildSchedule() {
    final type = _type!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The type step, which explains this, was skipped.
        if (_kycBlocked) ...[
          Row(
            children: [
              Expanded(child: Text('${type.label}s need KYC verification.', style: AppText.caption)),
              UnderlineLink(label: 'Verify now', bold: true, onTap: _openKyc),
            ],
          ),
          gap14,
        ],
        if (_typeFixed && type == BookingType.podcast) ...[
          const InlineNotice(
            message: 'Podcast sessions are recorded. The solver may publish the recording in Content.',
          ),
          gap14,
        ],
        const Text('Select Date', style: _sectionTitle),
        gap14,
        SizedBox(
          height: 74,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _days.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final day = _days[i];
              final open = _slotsFor(day).isNotEmpty;
              return SizedBox(
                width: 62,
                child: GlassOption(
                  height: 74,
                  selected: day == _date,
                  onTap: () => setState(() {
                    _date = day;
                    _slot = null;
                  }),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(i == 0 ? 'Today' : weekdayShort(day), style: AppText.caption.copyWith(fontSize: 11.5)),
                      const SizedBox(height: 4),
                      Text(
                        '${day.day}',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: open ? Colors.white : AppColors.white(0.2),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        gap24,
        const Text('Session Duration (minutes)', style: _sectionTitle),
        gap14,
        OptionGrid(
          children: [
            for (final minutes in type.durations)
              GlassOption(
                selected: _minutes == minutes,
                onTap: () => setState(() => _minutes = minutes),
                child: Text('$minutes min', style: AppText.label.copyWith(fontSize: 14)),
              ),
          ],
        ),
        gap14,
        Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 16, color: AppColors.white(0.72)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                type == BookingType.podcast
                    ? 'Minimum 60 minutes for podcast booking.'
                    : 'Minimum 10 minutes for ${type == BookingType.anonymous ? 'anonymous' : 'normal'} booking.',
                style: AppText.caption,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSlot() {
    final slots = _slotsFor(_date);
    final inPart = slots.where((s) => _DayPart.of(_wall(s)) == _part).toList();
    final slot = _slot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OptionGrid(
          spacing: 8,
          children: [
            for (final part in _DayPart.values)
              GlassOption(
                height: 44,
                radius: 22,
                selected: _part == part,
                onTap: () => setState(() => _part = part),
                child: Text(part.label, style: AppText.label.copyWith(fontSize: 13.5)),
              ),
          ],
        ),
        gap14,
        if (slots.isEmpty && _explore.slotsLoading(_solver, _date))
          const _EmptyNote('Loading open slots…')
        else if (slots.isEmpty)
          _EmptyNote('No open slots on ${formatDay(_date)}. Go back and pick another date.')
        else if (inPart.isEmpty)
          _EmptyNote('No ${_part.label.toLowerCase()} slots on this day. Try another time of day.')
        else
          OptionGrid(
            spacing: 8,
            children: [
              for (final s in inPart)
                GlassOption(
                  height: 44,
                  selected: s == slot,
                  onTap: () => setState(() => _slot = s),
                  child: Text(formatClock(_wall(s)), style: AppText.label.copyWith(fontSize: 13.5)),
                ),
            ],
          ),
        gap14,
        if (slot != null)
          GlassWell(
            radius: 16,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.event_available_outlined, size: 18, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${formatDay(_date)} · $_minutes min · ${formatClock(_wall(slot))}',
                    style: AppText.label.copyWith(fontSize: 13.5),
                  ),
                ),
              ],
            ),
          ),
        gap8,
        Text('Times are shown in ${_zone.label}.', style: AppText.caption.copyWith(fontSize: 11.5)),
      ],
    );
  }

  Widget _buildDetails() {
    final podcast = _type == BookingType.podcast;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Session Topic *', style: _sectionTitle),
        gap8,
        GlassTextField(
          controller: _title,
          hint: 'e.g. API design review, Docker issue',
          textCapitalization: TextCapitalization.sentences,
          errorText: _titleError,
          onChanged: (_) {
            if (_titleError != null) setState(() => _titleError = null);
          },
        ),
        gap14,
        const Text('Details (optional)', style: _sectionTitle),
        gap8,
        GlassTextField(
          controller: _details,
          hint: 'Add any context, questions or goals for this session',
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          errorText: _detailsError,
          onChanged: (_) => setState(() => _detailsError = null),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 6, right: 6),
            child: Text('${_details.text.length}/500', style: AppText.caption.copyWith(fontSize: 12)),
          ),
        ),
        gap8,
        const Text('Session Mode', style: _sectionTitle),
        gap8,
        Row(
          children: [
            for (final mode in SessionMode.values) ...[
              if (mode != SessionMode.values.first) const SizedBox(width: 10),
              Expanded(
                child: GlassOption(
                  selected: _mode == mode,
                  onTap: podcast && mode == SessionMode.chat ? null : () => setState(() => _mode = mode),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        mode == SessionMode.meet ? Icons.videocam_outlined : Icons.chat_bubble_outline_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Text(mode.label, style: AppText.label.copyWith(fontSize: 14)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
        gap8,
        Text(
          podcast ? 'Podcasts support Meet only and are recorded.' : 'Prefer not to be on video? Choose Chat instead.',
          style: AppText.caption,
        ),
        gap24,
        _Breakdown(solver: _solver, type: _type!, minutes: _minutes!),
      ],
    );
  }

  /// The seeker agreed that a podcast session is recorded.
  bool _recordingConsent = false;

  Widget _buildReview() {
    final slot = _slot!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              _Row(Icons.person_outline_rounded, 'Solver', _solver.name),
              _Row(Icons.category_outlined, 'Session Type', _type!.label),
              _Row(Icons.calendar_today_outlined, 'Date', formatDay(_date)),
              _Row(Icons.timelapse_rounded, 'Duration', '$_minutes minutes'),
              _Row(Icons.schedule_rounded, 'Time Slot', formatClock(_wall(slot))),
              _Row(Icons.topic_outlined, 'Session Topic', _title.text.trim()),
              _Row(
                _mode == SessionMode.meet ? Icons.videocam_outlined : Icons.chat_bubble_outline_rounded,
                'Session Mode',
                _mode.label,
              ),
            ],
          ),
        ),
        gap14,
        _Breakdown(solver: _solver, type: _type!, minutes: _minutes!),
        if (_type == BookingType.anonymous) ...[
          gap14,
          const InlineNotice(message: 'Your identity stays hidden from the solver for this session.'),
        ],
        if (_type == BookingType.podcast) ...[
          gap14,
          const InlineNotice(message: 'This podcast session will be recorded. The solver may publish it in Content.'),
          gap14,
          GlassConsentRow(
            value: _recordingConsent,
            onChanged: (v) => setState(() => _recordingConsent = v),
            text: 'I understand and agree that this podcast session will be recorded.',
          ),
        ],
      ],
    );
  }

  Widget _buildConfirm() {
    final balance = _explore.walletBalance(widget.user);
    final after = balance - _cost;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: GlassIconBadge(icon: Icons.account_balance_wallet_outlined, size: 72)),
        gap24,
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'This booking will reserve '),
              TextSpan(
                text: '$_cost minutes',
                style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
              ),
              const TextSpan(text: ' from your wallet. Continue?'),
            ],
          ),
          style: AppText.body,
          textAlign: TextAlign.center,
        ),
        gap24,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              _Row(null, 'Current balance', '$balance min'),
              _Row(null, 'After booking', after < 0 ? '—' : '$after min'),
            ],
          ),
        ),
        if (after < 0) ...[
          gap14,
          const InlineNotice(
            message:
                'You don\'t have enough minutes in your wallet. Top up your Synap Wallet or choose a shorter session.',
            tone: NoticeTone.error,
          ),
        ],
      ],
    );
  }

  Widget _buildDone() {
    final booking = _booking!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: GlassIconBadge(icon: Icons.check_rounded, size: 80)),
        gap14,
        const Text('BOOKING CONFIRMED!', style: AppText.title, textAlign: TextAlign.center),
        gap8,
        Text('Your session has been successfully booked.', style: AppText.body, textAlign: TextAlign.center),
        gap24,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              _Row(Icons.person_outline_rounded, 'Solver', booking.solver.name),
              _Row(Icons.calendar_today_outlined, 'Date', formatDay(_date)),
              _Row(Icons.schedule_rounded, 'Time', '${formatClock(_wall(booking.start))} (${booking.minutes} min)'),
              _Row(Icons.videocam_outlined, 'Mode', booking.mode.label),
              _Row(Icons.topic_outlined, 'Topic', booking.title),
              _Row(Icons.account_balance_wallet_outlined, 'Wallet', '${booking.walletMinutes} min reserved'),
            ],
          ),
        ),
      ],
    );
  }

  static const _sectionTitle = TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white);
}

class _TypeCard extends StatelessWidget {
  const _TypeCard({required this.type, required this.selected, required this.locked, required this.onTap});

  final BookingType type;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, subtitle) = switch (type) {
      BookingType.normal => (Icons.person_outline_rounded, 'Book with your profile (min 10 minutes).'),
      BookingType.anonymous => (
        Icons.visibility_off_outlined,
        'Stay hidden from the solver (${ExploreService.anonymousLabel} minutes). No KYC needed.',
      ),
      BookingType.podcast => (Icons.mic_none_rounded, 'Book a recorded podcast session (min 60 minutes, Meet only).'),
    };
    return GlassOption(
      height: 92,
      radius: 20,
      selected: selected,
      onTap: locked ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            GlassIconBadge(icon: icon, size: 46),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          type.label,
                          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                      ),
                      if (type == BookingType.anonymous) ...[
                        const SizedBox(width: 8),
                        _Badge(ExploreService.anonymousLabel.replaceAll('×', 'X')),
                      ],
                      if (locked) ...[const SizedBox(width: 8), const _Badge('KYC')],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle, style: AppText.caption.copyWith(fontSize: 12)),
                ],
              ),
            ),
            if (selected) const Icon(Icons.check_circle_rounded, size: 20, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.solver, required this.type, required this.minutes});

  final Solver solver;
  final BookingType type;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    final total = ExploreService.walletCost(solver, type, minutes);
    return GlassWell(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: [
          _Row(null, 'Session length', '$minutes min'),
          _Row(null, 'Solver rate', solver.priceLabel),
          if (type.multiplier > 1) _Row(null, 'Anonymous booking', ExploreService.anonymousLabel),
          Container(height: 1, color: AppColors.white(0.12)),
          _Row(null, 'Total from wallet', '$total min', bold: true),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.icon, this.label, this.value, {this.bold = false});

  final IconData? icon;
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
          if (icon != null) ...[Icon(icon, size: 17, color: AppColors.white(0.8)), const SizedBox(width: 10)],
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

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.white(0.4)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Colors.white),
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Text(text, style: AppText.body, textAlign: TextAlign.center),
    );
  }
}
