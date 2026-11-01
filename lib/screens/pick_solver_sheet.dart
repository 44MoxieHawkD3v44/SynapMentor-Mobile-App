import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/explore_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import 'booking_sheet.dart';

/// The match from "Pick a Solver for Me", plus what the seeker described.
typedef SolverMatch = ({Solver solver, BookingPrefill prefill});

/// "Pick a Solver for Me": the seeker describes the need and picks a time; the
/// service assigns the best available solver.
Future<SolverMatch?> showPickSolverSheet(BuildContext context, {required AppUser user}) {
  return showModalBottomSheet<SolverMatch>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => _PickSolverSheet(user: user),
  );
}

class _PickSolverSheet extends StatefulWidget {
  const _PickSolverSheet({required this.user});

  final AppUser user;

  @override
  State<_PickSolverSheet> createState() => _PickSolverSheetState();
}

class _PickSolverSheetState extends State<_PickSolverSheet> {
  static const _firstHour = 7;
  static const _lastHour = 23;

  final _explore = ExploreService.instance;
  late final _zone = ExploreService.userZone(widget.user);
  final _title = TextEditingController();
  final _details = TextEditingController();

  late DateTime _date = _today;
  DateTime? _slot; // UTC
  String? _category;
  String? _subcategory;

  bool _searching = false;
  bool _searched = false;
  Solver? _match;
  final _errors = <String, String?>{};

  DateTime get _today {
    final now = DateTime.now().toUtc().add(_zone.offset);
    return DateTime.utc(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _title.dispose();
    _details.dispose();
    super.dispose();
  }

  /// Start times on [_date] (UTC) every 10 minutes, from 7 AM to 11 PM
  /// local; today they begin at the earliest bookable time, as in booking.
  List<DateTime> get _times {
    final earliest = ExploreService.earliestBookingStart();
    final from = _zone.toUtc(_date.add(const Duration(hours: _firstHour)));
    final until = _zone.toUtc(_date.add(const Duration(hours: _lastHour)));
    return [
      for (var t = from.isBefore(earliest) ? earliest : from; t.isBefore(until); t = t.add(ExploreService.slotStep)) t,
    ];
  }

  Future<void> _selectCategory() async {
    final picked = await showGlassPicker(
      context,
      title: 'Category',
      options: _explore.categories.keys.toList(),
      label: (c) => c,
      selected: _category,
    );
    if (picked != null && picked != _category) {
      setState(() {
        _category = picked;
        _subcategory = null;
        _errors['category'] = null;
      });
    }
  }

  Future<void> _selectSubcategory() async {
    final category = _category;
    if (category == null) {
      setState(() => _errors['subcategory'] = 'Select a category first.');
      return;
    }
    final picked = await showGlassPicker(
      context,
      title: 'Subcategory',
      options: _explore.categories[category]!,
      label: (s) => s,
      selected: _subcategory,
    );
    if (picked != null) {
      setState(() {
        _subcategory = picked;
        _errors['subcategory'] = null;
      });
    }
  }

  Future<void> _find() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _errors
        ..['time'] = _slot == null ? 'Pick a time.' : null
        ..['category'] = _category == null ? 'Select a category.' : null
        ..['subcategory'] = _subcategory == null ? 'Select a subcategory.' : null
        ..['title'] = _title.text.trim().isEmpty ? 'Add a title.' : null
        ..['details'] = _details.text.trim().isEmpty ? 'Describe what you need.' : null;
    });
    if (_errors.values.any((e) => e != null)) return;
    setState(() => _searching = true);
    final match = await _explore.pickSolver(category: _category!, subcategory: _subcategory!, slot: _slot!);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searched = true;
      _match = match;
    });
  }

  void _book() {
    Navigator.of(context).pop<SolverMatch>((
      solver: _match!,
      prefill: BookingPrefill(slot: _slot!, title: _title.text.trim(), description: _details.text.trim()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final match = _match;
    return FlowSheetFrame(
      title: 'Pick a Solver for Me',
      onBack: _searched ? () => setState(() => _searched = false) : null,
      body: StepSwitcher(
        child: KeyedSubtree(
          key: ValueKey(_searched),
          child: !_searched ? _buildForm() : (match == null ? _buildNoMatch() : _buildMatch(match)),
        ),
      ),
      footer: !_searched
          ? PrimaryPillButton(label: 'Find My Solver', loading: _searching, onPressed: _find)
          : match == null
          ? GlassPillButton(label: 'Change Details', onPressed: () => setState(() => _searched = false))
          : PrimaryPillButton(label: 'Book with ${match.name}', onPressed: _book),
    );
  }

  Widget _buildForm() {
    final days = [for (var i = 0; i < 7; i++) _today.add(Duration(days: i))];
    final times = _times;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Tell us what you need and when. We\'ll assign an available solver who fits.', style: AppText.body),
        gap24,
        const Text('When', style: _label),
        gap8,
        SizedBox(
          height: 58,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: days.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => SizedBox(
              width: 62,
              child: GlassOption(
                height: 58,
                selected: days[i] == _date,
                onTap: () => setState(() {
                  _date = days[i];
                  _slot = null;
                }),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(i == 0 ? 'Today' : weekdayShort(days[i]), style: AppText.caption.copyWith(fontSize: 11)),
                    Text(
                      '${days[i].day}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        gap8,
        SizedBox(
          height: 44,
          child: times.isEmpty
              ? Center(child: Text('No times left today. Pick another day.', style: AppText.caption))
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: times.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => SizedBox(
                    width: 90,
                    child: GlassOption(
                      height: 44,
                      selected: times[i] == _slot,
                      onTap: () => setState(() {
                        _slot = times[i];
                        _errors['time'] = null;
                      }),
                      child: Text(formatClock(_zone.wall(times[i])), style: AppText.label.copyWith(fontSize: 13)),
                    ),
                  ),
                ),
        ),
        FieldError(_errors['time']),
        gap8,
        Text('Times are shown in ${_zone.label}.', style: AppText.caption.copyWith(fontSize: 11.5)),
        gap24,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Category *', style: _label),
                  gap8,
                  GlassSelectField(
                    value: _category,
                    hint: 'Select',
                    errorText: _errors['category'],
                    onTap: _selectCategory,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Subcategory *', style: _label),
                  gap8,
                  GlassSelectField(
                    value: _subcategory,
                    hint: 'Select',
                    errorText: _errors['subcategory'],
                    onTap: _selectSubcategory,
                  ),
                ],
              ),
            ),
          ],
        ),
        gap14,
        const Text('Title *', style: _label),
        gap8,
        GlassTextField(
          controller: _title,
          hint: 'e.g. Fix slow database queries',
          textCapitalization: TextCapitalization.sentences,
          errorText: _errors['title'],
          onChanged: (_) => setState(() => _errors['title'] = null),
        ),
        gap14,
        const Text('Description *', style: _label),
        gap8,
        GlassTextField(
          controller: _details,
          hint: 'What\'s the problem and what have you tried?',
          maxLines: 5,
          textCapitalization: TextCapitalization.sentences,
          errorText: _errors['details'],
          onChanged: (_) => setState(() => _errors['details'] = null),
        ),
      ],
    );
  }

  Widget _buildMatch(Solver solver) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('WE FOUND YOUR SOLVER', style: AppText.title, textAlign: TextAlign.center),
        gap8,
        Text(
          'Available ${formatDay(_date)} at ${formatClock(_zone.wall(_slot!))}.',
          style: AppText.body,
          textAlign: TextAlign.center,
        ),
        gap24,
        GlassWell(
          radius: 22,
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              GlassAvatar(initials: solver.initials, size: 56, photoUrl: ExploreService.instance.solverPhoto(solver)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      solver.name,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                    Text(solver.headline, style: AppText.caption),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded, size: 16, color: Colors.white),
                        const SizedBox(width: 4),
                        Text(
                          '${solver.ratingLabel} · ${solver.priceLabel}',
                          style: AppText.caption.copyWith(color: Colors.white),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        gap14,
        Text(
          'Your title and description carry over. You\'ll choose the booking type and duration next.',
          style: AppText.caption,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildNoMatch() {
    return Column(
      children: [
        const GlassIconBadge(icon: Icons.search_off_rounded, size: 72),
        gap24,
        const Text('NO SOLVER AVAILABLE', style: AppText.title, textAlign: TextAlign.center),
        gap8,
        Text(
          'No $_subcategory solver is free at that time. Try another time or subcategory.',
          style: AppText.body,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}
