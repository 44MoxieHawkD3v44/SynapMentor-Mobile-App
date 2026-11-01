import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/explore_service.dart';
import '../services/solver_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import 'booking_sheet.dart';

const _heading = TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white);
const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);

Future<T?> _sheet<T>(BuildContext context, Widget sheet) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: 0.35),
  builder: (_) => sheet,
);

class _Chip extends StatelessWidget {
  const _Chip(this.text, {this.onRemove});

  final String text;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      padding: EdgeInsets.fromLTRB(12, 6, onRemove == null ? 12 : 4, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: const TextStyle(fontSize: 13, color: Colors.white)),
          if (onRemove != null)
            InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close_rounded, size: 15, color: AppColors.white(0.85), semanticLabel: 'Remove $text'),
              ),
            ),
        ],
      ),
    );
  }
}

// ---- Pricing tier ----------------------------------------------------------------------

/// Current Pricing: a tier slider (locked tiers can't be selected) and the
/// pricing levels with progress toward the next one. Tier rules come from
/// the admin panel.
class PricingTierCard extends StatelessWidget {
  const PricingTierCard({super.key, required this.user, this.embedded = false});

  final AppUser user;

  /// Leave out the panel and title, for use inside a collapsible card.
  final bool embedded;

  static int _multiplier(PricingTier t) {
    final base = SolverService.tiers.first.rate;
    return base <= 0 ? 1 : t.rate ~/ base;
  }

  @override
  Widget build(BuildContext context) {
    final service = SolverService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final tiers = SolverService.tiers;
        if (tiers.isEmpty) {
          final empty = Text('Pricing tiers will show here once they\'re available.', style: AppText.body);
          return embedded ? empty : GlassPanel(radius: 24, padding: const EdgeInsets.all(16), child: empty);
        }
        // Works for every solver; new ones start on the base tier.
        final stats = service.statsFor(user);
        final rate = service.rateOf(stats);
        final active = tiers.firstWhere((t) => t.rate == rate, orElse: () => tiers.first);
        final activeIndex = tiers.indexOf(active);
        final next = tiers.where((t) => !service.unlocked(stats, t)).firstOrNull;
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InlineNotice(message: service.saveError, tone: NoticeTone.error),
            if (!embedded) ...[const Text('Current Pricing', style: _heading), gap14],
            Row(
              children: [
                const Expanded(child: Text('Select Price Tier', style: _label)),
                Text(
                  '${service.priceLabel(user, active)} (${_multiplier(active)}×)',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ],
            ),
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: Colors.white,
                inactiveTrackColor: AppColors.white(0.14),
                thumbColor: Colors.white,
                activeTickMarkColor: AppColors.primary,
                inactiveTickMarkColor: AppColors.white(0.35),
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Slider(
                value: activeIndex.toDouble(),
                max: (tiers.length - 1).toDouble(),
                divisions: tiers.length > 1 ? tiers.length - 1 : null,
                semanticFormatterCallback: (v) => service.priceLabel(user, tiers[v.round()]),
                // Moves while dragging and saves once on release. Locked
                // tiers can't be picked; the thumb stays put.
                onChanged: (v) {
                  final tier = tiers[v.round()];
                  if (service.unlocked(stats, tier)) service.previewRate(stats, tier.rate);
                },
                onChangeEnd: (v) {
                  final tier = tiers[v.round()];
                  if (service.unlocked(stats, tier)) service.selectRate(stats, tier.rate);
                },
              ),
            ),
            Row(
              children: [
                for (final (i, t) in tiers.indexed) ...[
                  if (i > 0) const Spacer(),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!service.unlocked(stats, t)) ...[
                        Icon(Icons.lock_outline_rounded, size: 11, color: AppColors.white(0.6)),
                        const SizedBox(width: 2),
                      ],
                      Text(
                        service.priceOf(user, t),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: t == active ? FontWeight.w700 : FontWeight.w400,
                          color: AppColors.white(service.unlocked(stats, t) ? 1 : 0.6),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            gap8,
            Row(
              children: [
                Icon(Icons.lock_outline_rounded, size: 13, color: AppColors.white(0.72)),
                const SizedBox(width: 6),
                Expanded(
                  // The server says exactly what the next tier still needs.
                  child: Text(
                    next != null && service.lockReason != null
                        ? '${service.lockReason} New rates apply to new bookings.'
                        : 'Earn your credibility badge to unlock higher rates. New rates apply to new bookings.',
                    style: AppText.caption.copyWith(fontSize: 11.5),
                  ),
                ),
              ],
            ),
            gap24,
            const Text('Pricing Levels', style: _label),
            gap8,
            OptionGrid(
              columns: 2,
              spacing: 10,
              children: [
                for (final t in tiers)
                  _TierCard(
                    rate: service.priceLabel(user, t),
                    multiplier: _multiplier(t),
                    active: t == active,
                    unlocked: service.unlocked(stats, t),
                    isNext: t == next,
                    stats: stats,
                    tier: t,
                    onSelect: () => service.selectRate(stats, t.rate),
                  ),
              ],
            ),
          ],
        );
        // Inside a collapsible card the card supplies the panel and title.
        return embedded ? content : GlassPanel(radius: 24, padding: const EdgeInsets.all(16), child: content);
      },
    );
  }
}

class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.rate,
    required this.multiplier,
    required this.active,
    required this.unlocked,
    required this.isNext,
    required this.stats,
    required this.tier,
    required this.onSelect,
  });

  final String rate;
  final int multiplier;
  final bool active;
  final bool unlocked;

  /// The first locked tier shows its requirements; later ones just "Locked".
  final bool isNext;
  final SolverStats stats;
  final PricingTier tier;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final service = SolverService.instance;
    final dim = AppColors.white(unlocked ? 1 : 0.6);
    final row = AppText.caption.copyWith(fontSize: 11.5, color: AppColors.white(0.7));
    Widget stat(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: row)),
          Text(value, style: row.copyWith(color: Colors.white)),
        ],
      ),
    );
    final progress = service.progressTo(stats, tier);
    return Semantics(
      button: unlocked && !active,
      selected: active,
      child: GlassWell(
        radius: 18,
        active: active,
        fillTop: active ? 0.08 : 0,
        fillBottom: active ? 0.04 : 0,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: unlocked && !active ? onSelect : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                height: 132,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              rate,
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: dim),
                            ),
                          ),
                        ),
                        if (active)
                          GlassWell(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            child: Text('Active', style: AppText.caption.copyWith(fontSize: 10.5, color: Colors.white)),
                          )
                        else if (!unlocked)
                          Icon(Icons.lock_outline_rounded, size: 15, color: AppColors.white(0.6)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('Multiplier $multiplier×', style: row),
                    if (!unlocked && isNext) ...[
                      stat('Sessions', '${stats.sessions}/${tier.minSessions}'),
                      stat('Unique Seekers', '${stats.uniqueSeekers}/${tier.minUniqueSeekers}'),
                      stat(
                        'Feedback',
                        '${SolverService.feedbackPercent(stats.rating)}%/${SolverService.feedbackPercent(tier.minRating)}%',
                      ),
                      const Spacer(),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: AppColors.white(0.14),
                          valueColor: const AlwaysStoppedAnimation(Colors.white),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${(progress * 100).round()}% to unlock',
                        textAlign: TextAlign.center,
                        style: row.copyWith(fontSize: 10.5),
                      ),
                    ] else if (!unlocked) ...[
                      const SizedBox(height: 4),
                      Text('Locked', style: row),
                    ] else if (!active) ...[
                      const Spacer(),
                      Text('Tap to switch', style: row),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Expertise ---------------------------------------------------------------------------

/// Skills and projects come from Skill Verification and can't be edited here;
/// languages can.
class SolverExpertiseTab extends StatefulWidget {
  const SolverExpertiseTab({super.key, required this.user});

  final AppUser user;

  @override
  State<SolverExpertiseTab> createState() => _SolverExpertiseTabState();
}

class _SolverExpertiseTabState extends State<SolverExpertiseTab> {
  final _service = SolverService.instance;

  AppUser get user => widget.user;

  @override
  void initState() {
    super.initState();
    _service.loadExpertise(user);
  }

  Future<void> _addLanguage(BuildContext context) async {
    final current = _service.languages(user);
    final options = SolverService.languageOptions.where((l) => !current.contains(l)).toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (context) => _LanguageSheet(options: options, current: current),
    );
    if (picked != null) _service.setLanguages(user, [...current, picked]);
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final languages = service.languages(user);
        final profile = service.profileFor(user);
        final expertise = service.expertiseOf(user);
        final skills = expertise?.skills ?? profile?.skills ?? const <String>[];
        final focusAreas = expertise?.focusAreas ?? const <String>[];
        final projects = expertise?.projects ?? profile?.problemsSolved ?? const <ProblemSolved>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InlineNotice(message: service.saveError ?? service.expertiseError, tone: NoticeTone.error),
            GlassPanel(
              radius: 24,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('Skills & Expertise', style: _heading)),
                      GlassWell(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.lock_outline_rounded, size: 12, color: Colors.white),
                            const SizedBox(width: 4),
                            Text(
                              'From verification',
                              style: AppText.caption.copyWith(fontSize: 11, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Your skills and projects come from Skill Verification and can\'t be edited here. Seekers see them on your profile.',
                    style: AppText.caption,
                  ),
                  gap14,
                  const Text('Technical Skills', style: _label),
                  gap8,
                  if (skills.isEmpty)
                    Text('Your skills appear here after Skill Verification.', style: AppText.caption)
                  else
                    Wrap(spacing: 8, runSpacing: 8, children: [for (final s in skills) _Chip(s)]),
                  if (focusAreas.isNotEmpty) ...[
                    gap24,
                    const Text('Expertise', style: _label),
                    gap8,
                    Wrap(spacing: 8, runSpacing: 8, children: [for (final f in focusAreas) _Chip(f)]),
                  ],
                  gap24,
                  Row(
                    children: [
                      const Expanded(child: Text('Languages', style: _label)),
                      SmallPillButton(label: '+ Add', onPressed: () => _addLanguage(context)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('Seekers can find and book you by language.', style: AppText.caption.copyWith(fontSize: 12)),
                  gap8,
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final l in languages)
                        _Chip(
                          l,
                          onRemove: languages.length > 1
                              ? () => service.setLanguages(user, [...languages]..remove(l))
                              : null,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            gap14,
            GlassPanel(
              radius: 24,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Recent Projects', style: _heading),
                  gap14,
                  if (projects.isEmpty)
                    Text('Projects from Skill Verification appear here.', style: AppText.body)
                  else
                    for (final p in projects)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: GlassWell(
                          radius: 18,
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'PROBLEM STATEMENT',
                                style: AppText.caption.copyWith(fontSize: 11, letterSpacing: 1),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                p.problem,
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                              ),
                              if (p.solution.isNotEmpty) ...[
                                gap8,
                                Text('SOLUTION', style: AppText.caption.copyWith(fontSize: 11, letterSpacing: 1)),
                                const SizedBox(height: 2),
                                Text(p.solution, style: AppText.caption.copyWith(color: AppColors.white(0.85))),
                              ],
                            ],
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Pick a listed language, or type one that isn't listed.
class _LanguageSheet extends StatefulWidget {
  const _LanguageSheet({required this.options, required this.current});

  final List<String> options;
  final List<String> current;

  @override
  State<_LanguageSheet> createState() => _LanguageSheetState();
}

class _LanguageSheetState extends State<_LanguageSheet> {
  final _custom = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _addCustom() {
    final name = _custom.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final taken = widget.current.any((l) => l.toLowerCase() == name.toLowerCase());
    if (name.length < 2) return setState(() => _error = 'Enter a language.');
    if (taken) return setState(() => _error = 'You\'ve already added $name.');
    Navigator.of(context).pop(name[0].toUpperCase() + name.substring(1));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: FlowSheetFrame(
        title: 'Add a Language',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: GlassTextField(
                    controller: _custom,
                    hint: 'Type a language',
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r"[\p{L}\p{M} ()'-]", unicode: true)),
                      LengthLimitingTextInputFormatter(40),
                    ],
                    errorText: _error,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _addCustom(),
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: GlassIconButton(icon: Icons.add_rounded, tooltip: 'Add language', onPressed: _addCustom),
                ),
              ],
            ),
            if (widget.options.isNotEmpty) ...[
              gap14,
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final l in widget.options)
                    GlassChip(label: l, selected: false, onTap: () => Navigator.of(context).pop(l)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---- Availability --------------------------------------------------------------------------

/// Weekly schedule and a 60-day calendar with per-date edits. Slots can't
/// overlap: taken times are greyed out when adding or editing.
class SolverAvailabilityTab extends StatefulWidget {
  const SolverAvailabilityTab({super.key, required this.user});

  final AppUser user;

  @override
  State<SolverAvailabilityTab> createState() => _SolverAvailabilityTabState();
}

class _SolverAvailabilityTabState extends State<SolverAvailabilityTab> {
  static const _weekdays = [7, 1, 2, 3, 4, 5, 6]; // Sunday first

  final _service = SolverService.instance;
  bool _calendar = false;
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  late DateTime _selected = _today;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    // The schedule seekers book into is kept on the server.
    _service.loadBookingSetup(widget.user).catchError((Object e) {
      if (mounted) setState(() => _error = e is AuthException ? e.message : null);
    });
  }

  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Future<void> _pickSlot({
    required List<TimeSlot> taken,
    required ValueChanged<TimeSlot> onPicked,
    TimeSlot? initial,
  }) async {
    final slot = await _sheet<TimeSlot>(context, _SlotSheet(taken: taken, initial: initial));
    if (slot == null) return;
    try {
      onPicked(slot);
      setState(() => _error = null);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final zone = ExploreService.userZone(widget.user);
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final schedule = _service.scheduleOf(widget.user);
        final changed = _service.availabilityChanged(widget.user);
        final hours = schedule.weeklyMinutes / 60;
        final hoursLabel = hours == hours.roundToDouble() ? hours.toStringAsFixed(0) : hours.toStringAsFixed(1);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassPanel(
              radius: 24,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const GlassIconBadge(icon: Icons.schedule_rounded, size: 46),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Availability Schedule', style: _heading),
                            Text('${zone.label} · ${hoursLabel}h / week', style: AppText.caption),
                          ],
                        ),
                      ),
                    ],
                  ),
                  gap14,
                  Row(
                    children: [
                      Expanded(
                        child: GlassOption(
                          height: 44,
                          radius: 22,
                          selected: !_calendar,
                          onTap: () => setState(() => _calendar = false),
                          child: Text('Schedule', style: AppText.label.copyWith(fontSize: 14)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GlassOption(
                          height: 44,
                          radius: 22,
                          selected: _calendar,
                          onTap: () => setState(() => _calendar = true),
                          child: Text('Calendar', style: AppText.label.copyWith(fontSize: 14)),
                        ),
                      ),
                    ],
                  ),
                  gap14,
                  Row(
                    children: [
                      Expanded(
                        child: Text('Seekers can book up to', style: AppText.caption.copyWith(color: Colors.white)),
                      ),
                      for (final days in const [14, 30, 45, 60]) ...[
                        const SizedBox(width: 6),
                        GlassChip(
                          label: '${days}d',
                          selected: schedule.windowDays == days,
                          onTap: () => _service.setWindowDays(widget.user, days),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            gap14,
            InlineNotice(message: _error ?? _service.saveError, tone: NoticeTone.error),
            StepSwitcher(
              child: KeyedSubtree(
                key: ValueKey(_calendar),
                child: _calendar ? _buildCalendar(schedule) : _buildWeekly(schedule),
              ),
            ),
            gap14,
            GlassPanel(
              radius: 22,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const GlassIconBadge(icon: Icons.timelapse_rounded, size: 46),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Total Weekly Hours', style: AppText.caption),
                      Text(
                        '${hoursLabel}h / week',
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            gap24,
            InlineNotice(message: changed ? null : _success, tone: NoticeTone.success),
            if (changed) ...[
              Text(
                'You have unsaved changes.',
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: Colors.white),
              ),
              gap8,
            ],
            PrimaryPillButton(
              label: 'Save Availability',
              loading: _service.savingAvailability,
              onPressed: changed ? _save : null,
            ),
          ],
        );
      },
    );
  }

  Future<void> _save() async {
    setState(() => _error = null);
    final saved = await _service.saveAvailability(widget.user);
    if (saved && mounted) setState(() => _success = 'Availability saved.');
  }

  Widget _buildWeekly(SolverSchedule schedule) {
    return GlassPanel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Weekly Schedule', style: _heading),
          Text('Set your recurring availability for each day.', style: AppText.caption),
          gap14,
          for (final day in _weekdays) _dayRow(day, schedule.weekly[day] ?? const []),
        ],
      ),
    );
  }

  Widget _dayRow(int weekday, List<TimeSlot> slots) {
    final name = weekdayName(weekday);
    final hours = slots.fold(0, (s, t) => s + t.minutes) / 60;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassWell(
        radius: 18,
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox.square(
              dimension: 36,
              child: GlassWell(
                radius: 12,
                active: slots.isNotEmpty,
                child: Center(
                  child: Text(
                    name[0],
                    style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: _label.copyWith(fontSize: 14)),
                  Text(
                    slots.isEmpty
                        ? 'Unavailable'
                        : '${slots.length} slot${slots.length == 1 ? '' : 's'} · ${hours == hours.roundToDouble() ? hours.toStringAsFixed(0) : hours.toStringAsFixed(1)}h',
                    style: AppText.caption.copyWith(fontSize: 11.5),
                  ),
                  if (slots.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final s in slots)
                          _Chip('$s', onRemove: () => _service.removeWeeklySlot(widget.user, weekday, s)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: 'Add a slot on $name',
              onPressed: () =>
                  _pickSlot(taken: slots, onPicked: (slot) => _service.addWeeklySlot(widget.user, weekday, slot)),
              icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendar(SolverSchedule schedule) {
    final today = _today;
    final last = today.add(Duration(days: schedule.windowDays - 1));
    final first = DateTime(_month.year, _month.month);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leading = first.weekday % 7; // Sunday first
    final canPrev = first.isAfter(DateTime(today.year, today.month));
    final canNext = DateTime(_month.year, _month.month + 1).isBefore(last.add(const Duration(days: 1)));
    final slots = schedule.slotsOn(_selected);
    final overridden = schedule.overrides.containsKey(_selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Previous month',
                    onPressed: canPrev ? () => setState(() => _month = DateTime(_month.year, _month.month - 1)) : null,
                    icon: Icon(Icons.chevron_left_rounded, color: AppColors.white(canPrev ? 1 : 0.3)),
                  ),
                  Expanded(
                    child: Text(
                      '${const ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][_month.month - 1]} ${_month.year}',
                      textAlign: TextAlign.center,
                      style: _label,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next month',
                    onPressed: canNext ? () => setState(() => _month = DateTime(_month.year, _month.month + 1)) : null,
                    icon: Icon(Icons.chevron_right_rounded, color: AppColors.white(canNext ? 1 : 0.3)),
                  ),
                ],
              ),
              gap8,
              Row(
                children: [
                  for (final d in const ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'])
                    Expanded(
                      child: Text(d, textAlign: TextAlign.center, style: AppText.caption.copyWith(fontSize: 11)),
                    ),
                ],
              ),
              gap8,
              OptionGrid(
                columns: 7,
                spacing: 6,
                children: [
                  for (var i = 0; i < leading; i++) const SizedBox(height: 42),
                  for (var d = 1; d <= daysInMonth; d++)
                    Builder(
                      builder: (context) {
                        final date = DateTime(_month.year, _month.month, d);
                        final inWindow = !date.isBefore(today) && !date.isAfter(last);
                        final has = schedule.slotsOn(date).isNotEmpty;
                        return GlassOption(
                          height: 42,
                          radius: 12,
                          selected: date == _selected,
                          onTap: inWindow ? () => setState(() => _selected = date) : null,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('$d', style: const TextStyle(fontSize: 13, color: Colors.white)),
                              Container(
                                width: 4,
                                height: 4,
                                margin: const EdgeInsets.only(top: 2),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: has && inWindow ? Colors.white : Colors.transparent,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                ],
              ),
              gap8,
              Text(
                'You can set availability up to ${schedule.windowDays} days ahead.',
                style: AppText.caption.copyWith(fontSize: 11.5),
              ),
            ],
          ),
        ),
        gap14,
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: formatDay(_selected), style: _label),
                          if (overridden) TextSpan(text: '  · edited', style: AppText.caption),
                        ],
                      ),
                    ),
                  ),
                  SmallPillButton(
                    label: '+ Add Slot',
                    onPressed: () => _pickSlot(
                      taken: slots,
                      onPicked: (slot) => _service.editDate(widget.user, _selected, slot: slot),
                    ),
                  ),
                ],
              ),
              gap14,
              if (slots.isEmpty)
                Text('Unavailable on this day.', style: AppText.body, textAlign: TextAlign.center)
              else
                for (final s in slots)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: GlassWell(
                      radius: 16,
                      padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                      child: Row(
                        children: [
                          Expanded(child: Text('$s', style: AppText.label.copyWith(fontSize: 14))),
                          GlassWell(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            child: Text('Active', style: AppText.caption.copyWith(fontSize: 11, color: Colors.white)),
                          ),
                          IconButton(
                            tooltip: 'Edit slot',
                            onPressed: () => _pickSlot(
                              taken: [...slots]..remove(s),
                              initial: s,
                              onPicked: (slot) => _service.editDate(widget.user, _selected, old: s, slot: slot),
                            ),
                            icon: const Icon(Icons.edit_outlined, size: 19, color: Colors.white),
                          ),
                          IconButton(
                            tooltip: 'Remove slot on this day',
                            onPressed: () => _service.editDate(widget.user, _selected, old: s),
                            icon: Icon(Icons.delete_outline_rounded, size: 19, color: AppColors.error),
                          ),
                        ],
                      ),
                    ),
                  ),
              if (overridden)
                Align(
                  alignment: Alignment.centerRight,
                  child: UnderlineLink(
                    label: 'Reset to weekly schedule',
                    onTap: () => _service.resetDate(widget.user, _selected),
                  ),
                ),
              Text('Changes here apply to this date only.', style: AppText.caption.copyWith(fontSize: 11.5)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Pick a start, then an end. Times inside existing slots are greyed out and
/// can't be chosen, and the end can't run into the next slot.
class _SlotSheet extends StatefulWidget {
  const _SlotSheet({required this.taken, this.initial});

  final List<TimeSlot> taken;
  final TimeSlot? initial;

  @override
  State<_SlotSheet> createState() => _SlotSheetState();
}

class _SlotSheetState extends State<_SlotSheet> {
  static const _step = SolverService.slotStep;
  late int? _start = widget.initial?.start;
  late int? _end = widget.initial?.end;

  /// Start times show until one is picked; then they close and only the
  /// end times for that start show.
  late bool _pickingStart = widget.initial == null;

  bool _startTaken(int m) => widget.taken.any((t) => m >= t.start && m < t.end);

  /// The latest end for [start]: the next slot's start, or midnight.
  int _maxEnd(int start) =>
      widget.taken.where((t) => t.start >= start + _step).fold(24 * 60, (max, t) => t.start < max ? t.start : max);

  @override
  Widget build(BuildContext context) {
    final start = _start;
    return FlowSheetFrame(
      title: widget.initial == null ? 'Add Time Slot' : 'Edit Time Slot',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _pickingStart
                ? 'Pick a start time. Times already in another slot are greyed out.'
                : 'Now pick an end time. Only times before your next slot are shown.',
            style: AppText.caption,
          ),
          gap14,
          if (_pickingStart || start == null) ...[
            const Text('Start time', style: _label),
            gap8,
            OptionGrid(
              columns: 4,
              spacing: 6,
              children: [
                for (var m = 0; m < 24 * 60; m += _step)
                  _TimeOption(
                    label: TimeSlot.label(m),
                    selected: _start == m,
                    onTap: _startTaken(m)
                        ? null
                        : () => setState(() {
                            _start = m;
                            _pickingStart = false;
                            if (_end != null && (_end! <= m || _end! > _maxEnd(m))) _end = null;
                          }),
                  ),
              ],
            ),
          ] else ...[
            GlassWell(
              radius: 16,
              active: true,
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
              child: Row(
                children: [
                  const Icon(Icons.schedule_rounded, size: 18, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Start time: ${TimeSlot.label(start)}', style: AppText.label.copyWith(fontSize: 14)),
                  ),
                  SmallPillButton(label: 'Change', onPressed: () => setState(() => _pickingStart = true)),
                ],
              ),
            ),
            gap24,
            const Text('End time', style: _label),
            gap8,
            OptionGrid(
              columns: 4,
              spacing: 6,
              children: [
                for (var m = start + _step; m <= _maxEnd(start); m += _step)
                  _TimeOption(label: TimeSlot.label(m), selected: _end == m, onTap: () => setState(() => _end = m)),
              ],
            ),
          ],
        ],
      ),
      footer: PrimaryPillButton(
        label: _start == null || _end == null ? 'Pick a start and end time' : 'Save ${TimeSlot(_start!, _end!)}',
        onPressed: _start == null || _end == null ? null : () => Navigator.of(context).pop(TimeSlot(_start!, _end!)),
      ),
    );
  }
}

/// A time in the slot picker; the picked one is solid white.
class _TimeOption extends StatelessWidget {
  const _TimeOption({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (!selected) {
      return GlassOption(
        height: 38,
        radius: 12,
        selected: false,
        onTap: onTap,
        child: Text(label, style: const TextStyle(fontSize: 11.5, color: Colors.white)),
      );
    }
    return Semantics(
      selected: true,
      button: true,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
            height: 38,
            child: Center(
              child: Text(
                label,
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.primary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Booking links ----------------------------------------------------------------------------

/// The solver's profile booking link plus custom links to share with seekers.
class SolverBookingLinksTab extends StatefulWidget {
  const SolverBookingLinksTab({super.key, required this.user});

  final AppUser user;

  @override
  State<SolverBookingLinksTab> createState() => _SolverBookingLinksTabState();
}

class _SolverBookingLinksTabState extends State<SolverBookingLinksTab> {
  final _service = SolverService.instance;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _service.loadBookingSetup(widget.user).catchError((Object e) {
      if (mounted && e is AuthException) setState(() => _notice = e.message);
    });
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) setState(() => _notice = 'Link copied.');
  }

  Future<void> _share(String label, String url) => SharePlus.instance.share(
    ShareParams(text: 'Book a session with ${widget.user.name} on Synap Mentor: $url', subject: label),
  );

  Future<void> _create() async {
    final link = await _sheet<BookingLink>(context, _NewLinkSheet(user: widget.user));
    if (link != null && mounted) setState(() => _notice = '"${link.label}" created.');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final links = _service.links(widget.user);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InlineNotice(message: _notice, tone: NoticeTone.success),
            GlassPanel(
              radius: 24,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Profile Booking Link', style: _heading),
                  Text(
                    'Seekers who open this link see your profile and can book you directly.',
                    style: AppText.caption,
                  ),
                  gap14,
                  _LinkRow(
                    label: 'My profile',
                    url: _service.profileLink(widget.user),
                    onCopy: () => _copy(_service.profileLink(widget.user)),
                    onShare: () => _share('My profile', _service.profileLink(widget.user)),
                  ),
                ],
              ),
            ),
            gap14,
            GlassPanel(
              radius: 24,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('My Booking Links', style: _heading)),
                      SmallPillButton(label: '+ Custom Link', onPressed: _create),
                    ],
                  ),
                  gap14,
                  if (links.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Column(
                        children: [
                          const Icon(Icons.link_rounded, size: 40, color: Colors.white),
                          gap8,
                          const Text('No booking links yet', style: _label),
                          const SizedBox(height: 4),
                          Text(
                            'Create custom booking links to share with seekers.',
                            style: AppText.caption,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  else
                    for (final l in links)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _LinkRow(
                          label: l.label,
                          url: l.url,
                          onCopy: () => _copy(l.url),
                          onShare: () => _share(l.label, l.url),
                          onDelete: () async {
                            try {
                              await _service.deleteLink(widget.user, l);
                            } on AuthException catch (e) {
                              if (mounted) setState(() => _notice = e.message);
                            }
                          },
                        ),
                      ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.label, required this.url, required this.onCopy, required this.onShare, this.onDelete});

  final String label;
  final String url;
  final VoidCallback onCopy;
  final VoidCallback onShare;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: Row(
        children: [
          const Icon(Icons.link_rounded, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.label.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
                Text(
                  url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy link',
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded, size: 19, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Share link',
            onPressed: onShare,
            icon: const Icon(Icons.ios_share_rounded, size: 19, color: Colors.white),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: 'Delete link',
              onPressed: onDelete,
              icon: Icon(Icons.delete_outline_rounded, size: 19, color: AppColors.error),
            ),
        ],
      ),
    );
  }
}

class _NewLinkSheet extends StatefulWidget {
  const _NewLinkSheet({required this.user});

  final AppUser user;

  @override
  State<_NewLinkSheet> createState() => _NewLinkSheetState();
}

class _NewLinkSheetState extends State<_NewLinkSheet> {
  final _name = TextEditingController();
  String? _error;
  bool _creating = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final link = await SolverService.instance.createLink(widget.user, _name.text);
      if (mounted) Navigator.of(context).pop(link);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Custom Booking Link',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Name the link so you know where you shared it, e.g. "LinkedIn post".', style: AppText.caption),
          gap14,
          GlassTextField(
            controller: _name,
            hint: 'Link name',
            icon: Icons.link_rounded,
            textCapitalization: TextCapitalization.sentences,
            errorText: _error,
            onSubmitted: (_) => _create(),
            onChanged: (_) => setState(() => _error = null),
          ),
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: 'Create Link', loading: _creating, onPressed: _create),
          ),
        ],
      ),
    );
  }
}
