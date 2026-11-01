import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/explore_service.dart';
import '../services/solver_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import 'booking_sheet.dart';

enum _Tab { about, skills, problems }

/// Everything a seeker checks before booking: skills, problems solved,
/// ratings, availability (in the seeker's timezone), location and rate.
class SolverDetailsScreen extends StatefulWidget {
  const SolverDetailsScreen({
    super.key,
    required this.user,
    required this.solver,
    required this.onViewBookings,
    this.bookingType,
  });

  final AppUser user;
  final Solver solver;
  final VoidCallback onViewBookings;

  /// The booking type to use, when it was chosen before (Podcasts).
  final BookingType? bookingType;

  @override
  State<SolverDetailsScreen> createState() => _SolverDetailsScreenState();
}

class _SolverDetailsScreenState extends State<SolverDetailsScreen> {
  final _explore = ExploreService.instance;
  late final _zone = ExploreService.userZone(widget.user);
  _Tab _tab = _Tab.about;
  bool _showSchedule = false;

  /// The latest copy, with its solve stories once they load.
  Solver get _solver => _explore.allSolvers.where((s) => s.id == widget.solver.id).firstOrNull ?? widget.solver;

  /// The next 7 days, as dates on the seeker's clock.
  late final List<DateTime> _week = () {
    final now = DateTime.now().toUtc().add(_zone.offset);
    return [for (var i = 0; i < 7; i++) DateTime.utc(now.year, now.month, now.day + i)];
  }();

  @override
  void initState() {
    super.initState();
    _explore.loadStories(widget.solver).then((_) {
      if (mounted) setState(() {});
    }, onError: (Object _) {});
    // The real free time for the week, as booking offers it.
    _explore.loadSlots(widget.solver, _week, _zone, refresh: true);
  }

  Future<void> _book() async {
    final viewBookings = await showBookingSheet(context, user: widget.user, solver: _solver, type: widget.bookingType);
    if (viewBookings == true && mounted) {
      Navigator.of(context).pop();
      widget.onViewBookings();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _explore,
      builder: (context, _) {
        final favorite = _explore.isFavorite(widget.user, _solver);
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
                        child: Text(
                          'SOLVER DETAILS',
                          textAlign: TextAlign.center,
                          style: AppText.heading.copyWith(fontSize: 18),
                        ),
                      ),
                      GlassIconButton(
                        icon: favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        tooltip: favorite ? 'Remove from favorites' : 'Add to favorites',
                        onPressed: () => _explore.toggleFavorite(widget.user, _solver),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildHeader(),
                              const SizedBox(height: 14),
                              _buildTabs(),
                              const SizedBox(height: 14),
                              _buildAvailability(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: PrimaryPillButton(label: 'Book Now', onPressed: _book),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return GlassPanel(
      radius: 28,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GlassAvatar(initials: _solver.initials, size: 72, photoUrl: ExploreService.instance.solverPhoto(_solver)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _solver.name,
                            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.verified_outlined, size: 18, color: Colors.white, semanticLabel: 'Verified'),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(_solver.headline, style: AppText.caption),
                    const SizedBox(height: 8),
                    _Meta(Icons.location_on_outlined, _solver.location),
                    _Meta(Icons.star_rounded, '${_solver.ratingLabel} (${_solver.sessions} sessions)'),
                    _Meta(Icons.toll_outlined, _solver.priceLabel),
                  ],
                ),
              ),
            ],
          ),
          gap14,
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final skill in _solver.skills.take(4)) _Tag(skill),
              if (_solver.skills.length > 4) _Tag('+${_solver.skills.length - 4}'),
              if (SolverService.instance.podcastEnabled(_solver)) const _Tag('Podcasts', icon: Icons.mic_none_rounded),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return GlassPanel(
      radius: 28,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final tab in _Tab.values) ...[
                  GlassChip(
                    label: switch (tab) {
                      _Tab.about => 'About',
                      _Tab.skills => 'Skills',
                      _Tab.problems => 'Problems Solved',
                    },
                    selected: _tab == tab,
                    onTap: () => setState(() => _tab = tab),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          gap14,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: StepSwitcher(
              child: KeyedSubtree(key: ValueKey(_tab), child: _buildTabBody()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBody() {
    switch (_tab) {
      case _Tab.about:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('About Me', style: _heading),
            gap8,
            Text(_solver.about, style: AppText.body),
            gap14,
            _Meta(
              Icons.star_rounded,
              _solver.rating > 0
                  ? 'Rated ${_solver.ratingLabel} by seekers · ${_solver.sessions} sessions'
                  : 'No ratings yet · ${_solver.sessions} sessions',
            ),
            if (_solver.languages.isNotEmpty) _Meta(Icons.translate_rounded, 'Speaks ${_solver.languages.join(', ')}'),
            if (_solver.category.isNotEmpty)
              _Meta(Icons.category_outlined, '${_solver.category} · ${_solver.subcategories.join(', ')}'),
          ],
        );
      case _Tab.skills:
        final verified = _solver.verifiedSkills;
        // Other skills on the profile, beyond the verified ones.
        final others = [
          for (final s in _solver.skills)
            if (!verified.any((v) => v.skill.toLowerCase() == s.toLowerCase())) s,
        ];
        if (verified.isEmpty && others.isEmpty) {
          return Text('Skills appear here once the solver is verified.', style: AppText.caption);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final v in verified) ...[
              GlassWell(
                radius: 18,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.verified_outlined, size: 16, color: Colors.white),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            v.skill,
                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                    if (v.areas.isNotEmpty) ...[
                      gap8,
                      Text('Focus areas', style: AppText.caption.copyWith(fontSize: 11.5)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 8, runSpacing: 8, children: [for (final a in v.areas) _Tag(a)]),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (others.isNotEmpty) ...[
              if (verified.isNotEmpty) Text('Other skills', style: AppText.caption.copyWith(fontSize: 11.5)),
              if (verified.isNotEmpty) const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [for (final s in others) _Tag(s)]),
            ],
          ],
        );
      case _Tab.problems:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final p in _solver.problemsSolved) ...[
              GlassWell(
                radius: 18,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.problem,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'How it was solved: ${p.solution}',
                      style: AppText.caption.copyWith(color: AppColors.white(0.85)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
          ],
        );
    }
  }

  Widget _buildAvailability() {
    final lines = _solver.remote ? _freeLines() : _scheduleLines();
    final loading = _solver.remote && _week.any((d) => _explore.slotsLoading(_solver, d));
    final next = _solver.remote ? _nextFree() : _explore.nextOpenSlot(_solver, _zone.offset);
    final status = _solver.availableNow
        ? 'Available now'
        : next == null
        ? (loading ? 'Checking availability…' : 'No open slots this week')
        : 'Next available: ${formatDay(_zone.wall(next))}, ${formatClock(_zone.wall(next))}';
    return GlassPanel(
      radius: 28,
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Availability', style: _heading)),
              SmallPillButton(
                label: _showSchedule ? 'Hide Schedule' : 'View Schedule',
                onPressed: () => setState(() => _showSchedule = !_showSchedule),
              ),
            ],
          ),
          gap8,
          Row(
            children: [
              Icon(_solver.availableNow ? Icons.circle : Icons.circle_outlined, size: 10, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text(status, style: AppText.label.copyWith(fontSize: 13.5))),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: !_showSchedule
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (lines.isEmpty)
                          Text(
                            loading ? 'Loading the schedule…' : 'No open slots in the next 7 days.',
                            style: AppText.caption,
                          ),
                        for (final line in lines)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                SizedBox(width: 96, child: Text(line.$1, style: AppText.caption)),
                                Expanded(child: Text(line.$2, style: AppText.label.copyWith(fontSize: 13))),
                              ],
                            ),
                          ),
                        gap8,
                        Text('Shown in ${_zone.label}.', style: AppText.caption.copyWith(fontSize: 11.5)),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// The solver's open time for each of the next 7 days, from the server (what
  /// booking offers), on the seeker's clock.
  List<(String, String)> _freeLines() {
    final earliest = DateTime.now().toUtc();
    return [
      for (final (i, day) in _week.indexed)
        if (_explore.freeRangesOn(_solver, day) case final ranges? when ranges.any((r) => r.end.isAfter(earliest)))
          (
            i == 0 ? 'Today' : (i == 1 ? 'Tomorrow' : '${weekdayShort(day)} ${day.day}'),
            [
              for (final r in ranges)
                if (r.end.isAfter(earliest)) '${formatClock(_zone.wall(r.start))} – ${formatClock(_zone.wall(r.end))}',
            ].join(', '),
          ),
    ];
  }

  /// The first open time from the server's ranges this week.
  DateTime? _nextFree() {
    final now = DateTime.now().toUtc();
    for (final day in _week) {
      for (final r in _explore.freeRangesOn(_solver, day) ?? const <({DateTime start, DateTime end})>[]) {
        if (r.end.isAfter(now)) return r.start.isAfter(now) ? r.start : now;
      }
    }
    return _solver.nextAvailableAt;
  }

  /// The solver's weekly windows, converted into the seeker's timezone.
  List<(String, String)> _scheduleLines() {
    final now = DateTime.now().toUtc();
    final shift = _zone.offsetAt(now) - _solver.timezone.offsetAt(now);
    final byDay = <int, List<String>>{};
    for (final w in _solver.availability) {
      // Anchor on a known Monday so weekday arithmetic is exact.
      final start = DateTime.utc(2024, 1, w.weekday, w.startHour).add(shift);
      final end = DateTime.utc(2024, 1, w.weekday, w.endHour).add(shift);
      byDay.putIfAbsent(start.weekday, () => []).add('${formatClock(start)} – ${formatClock(end)}');
    }
    final days = byDay.keys.toList()..sort();
    return [for (final d in days) (weekdayName(d), byDay[d]!.join(', '))];
  }

  static const _heading = TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white);
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: AppColors.white(0.85)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: AppText.caption.copyWith(color: AppColors.white(0.9))),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.white(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: Colors.white), const SizedBox(width: 4)],
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.white)),
        ],
      ),
    );
  }
}
