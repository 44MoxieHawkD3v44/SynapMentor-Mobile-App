import 'package:flutter/material.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/explore_service.dart';
import '../services/solver_service.dart';
import '../services/wallet_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import '../widgets/liquid_nav_bar.dart';
import 'booking_sheet.dart';
import 'pick_solver_sheet.dart';
import 'solver_details_screen.dart';

enum _View { discover, podcasts, favorites }

enum _Sort {
  relevant('Most Relevant'),
  rating('Highest Rated'),
  rate('Lowest Rate'),
  sessions('Most Sessions');

  const _Sort(this.label);
  final String label;
}

class _Filters {
  const _Filters({
    this.category,
    this.subcategory,
    this.minRating,
    this.availableNow = false,
    this.languages = const {},
    this.prices = const {},
  });

  final String? category;
  final String? subcategory;
  final double? minRating;
  final bool availableNow;
  final Set<String> languages;

  /// Prices per session minute, in paise.
  final Set<int> prices;

  int get activeCount => [
    category != null,
    subcategory != null,
    minRating != null,
    availableNow,
    languages.isNotEmpty,
    prices.isNotEmpty,
  ].where((a) => a).length;

  bool matches(Solver s) =>
      (category == null || s.category == category) &&
      (subcategory == null || s.subcategories.contains(subcategory)) &&
      (minRating == null || s.rating >= minRating!) &&
      (!availableNow || s.availableNow) &&
      (languages.isEmpty || s.languages.any(languages.contains)) &&
      (prices.isEmpty || prices.contains(s.pricePaise));
}

/// Seeker Explore tab: every solver, searchable and filterable, with
/// favorites, podcasts and "Pick a Solver for Me".
class ExploreTab extends StatefulWidget {
  const ExploreTab({super.key, required this.user, required this.onViewBookings});

  final AppUser user;
  final VoidCallback onViewBookings;

  @override
  State<ExploreTab> createState() => _ExploreTabState();
}

class _ExploreTabState extends State<ExploreTab> {
  final _explore = ExploreService.instance;
  final _search = TextEditingController();

  _View _view = _View.discover;
  _Sort _sort = _Sort.relevant;
  _Filters _filters = const _Filters();

  @override
  void initState() {
    super.initState();
    _explore.load(widget.user);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Solver> get _results {
    final query = _search.text.trim().toLowerCase();
    final favorites = _explore.favoritesOf(widget.user);
    final list = _explore.solvers.where((s) {
      if (_view == _View.podcasts && !SolverService.instance.podcastEnabled(s)) return false;
      if (_view == _View.favorites && !favorites.contains(s.id)) return false;
      if (!_filters.matches(s)) return false;
      if (query.isEmpty) return true;
      return [
        s.name,
        s.headline,
        s.category,
        ...s.subcategories,
        ...s.skills,
        ...s.problemsSolved.map((p) => p.problem),
      ].any((field) => field.toLowerCase().contains(query));
    }).toList();
    switch (_sort) {
      case _Sort.relevant:
        list.sort((a, b) => (b.availableNow ? 1 : 0).compareTo(a.availableNow ? 1 : 0));
      case _Sort.rating:
        list.sort((a, b) => b.rating.compareTo(a.rating));
      case _Sort.rate:
        // Solvers without a price from the server go last.
        list.sort((a, b) => (a.pricePaise ?? 1 << 31).compareTo(b.pricePaise ?? 1 << 31));
      case _Sort.sessions:
        list.sort((a, b) => b.sessions.compareTo(a.sessions));
    }
    return list;
  }

  /// From Podcasts, the booking is a podcast booking straight away.
  BookingType? get _bookingType => _view == _View.podcasts ? BookingType.podcast : null;

  Future<void> _book(Solver solver, {BookingPrefill? prefill}) async {
    final viewBookings = await showBookingSheet(
      context,
      user: widget.user,
      solver: solver,
      prefill: prefill,
      type: prefill == null ? _bookingType : null,
    );
    if (viewBookings == true) widget.onViewBookings();
  }

  void _openDetails(Solver solver) {
    Navigator.of(context).push(
      glassRoute(
        SolverDetailsScreen(
          user: widget.user,
          solver: solver,
          onViewBookings: widget.onViewBookings,
          bookingType: _bookingType,
        ),
      ),
    );
  }

  Future<void> _pickForMe() async {
    final match = await showPickSolverSheet(context, user: widget.user);
    if (match != null && mounted) await _book(match.solver, prefill: match.prefill);
  }

  Future<void> _chooseSort() async {
    final picked = await showGlassPicker(
      context,
      title: 'Sort By',
      options: _Sort.values,
      label: (s) => s.label,
      selected: _sort,
    );
    if (picked != null) setState(() => _sort = picked);
  }

  Future<void> _openFilters() async {
    final picked = await showModalBottomSheet<_Filters>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => _FilterSheet(initial: _filters),
    );
    if (picked != null) setState(() => _filters = picked);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _explore,
      builder: (context, _) {
        final results = _results;
        final online = _explore.solvers.where((s) => s.availableNow).length;
        final favoriteCount = _explore.favoritesOf(widget.user).length;
        return ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, LiquidNavBar.clearance + MediaQuery.paddingOf(context).bottom),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Explore',
                      style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    const SizedBox(height: 4),
                    Text('${_explore.solvers.length} solvers available · $online online now', style: AppText.caption),
                    gap14,
                    GlassTextField(
                      controller: _search,
                      hint: 'Search by name, skill, expertise or topic',
                      icon: Icons.search_rounded,
                      textInputAction: TextInputAction.search,
                      onChanged: (_) => setState(() {}),
                    ),
                    gap14,
                    _PickForMeCard(onTap: _pickForMe),
                    gap14,
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          GlassChip(
                            label: 'Discover Solvers',
                            selected: _view == _View.discover,
                            onTap: () => setState(() => _view = _View.discover),
                          ),
                          const SizedBox(width: 8),
                          GlassChip(
                            label: 'Podcasts',
                            selected: _view == _View.podcasts,
                            onTap: () => setState(() => _view = _View.podcasts),
                          ),
                          const SizedBox(width: 8),
                          GlassChip(
                            label: 'Favorites ($favoriteCount)',
                            selected: _view == _View.favorites,
                            onTap: () => setState(() => _view = _View.favorites),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _ToolbarButton(
                          icon: Icons.tune_rounded,
                          label: _filters.activeCount == 0 ? 'Filters' : 'Filters (${_filters.activeCount})',
                          onTap: _openFilters,
                        ),
                        const Spacer(),
                        _ToolbarButton(icon: Icons.swap_vert_rounded, label: _sort.label, onTap: _chooseSort),
                      ],
                    ),
                    if (_view == _View.podcasts) ...[
                      gap14,
                      const InlineNotice(
                        message:
                            'Podcast sessions are Meet only, at least 60 minutes, and recorded. '
                            'Solvers may publish them in Content.',
                      ),
                    ],
                    gap14,
                    if (results.isEmpty)
                      _EmptyState(
                        view: _view,
                        onReset: () => setState(() {
                          _filters = const _Filters();
                          _search.clear();
                        }),
                      )
                    else
                      for (final solver in results) ...[
                        SolverCard(
                          solver: solver,
                          favorite: _explore.isFavorite(widget.user, solver),
                          onFavorite: () => _explore.toggleFavorite(widget.user, solver),
                          onBook: () => _book(solver),
                          onView: () => _openDetails(solver),
                        ),
                        const SizedBox(height: 12),
                      ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PickForMeCard extends StatelessWidget {
  const _PickForMeCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 20,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const GlassIconBadge(icon: Icons.auto_fix_high_outlined, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Pick a Solver for Me',
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                      const SizedBox(height: 2),
                      Text('Not sure who to book? Describe your need and we\'ll assign one.', style: AppText.caption),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: Colors.white),
                const SizedBox(width: 6),
                Text(label, style: const TextStyle(fontSize: 13, color: Colors.white)),
                const SizedBox(width: 2),
                const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A solver in a list: profile summary, skills, rating, location, rate and
/// availability, with favorite, Book Now and View. Also used on Home.
class SolverCard extends StatelessWidget {
  const SolverCard({
    super.key,
    required this.solver,
    required this.favorite,
    required this.onFavorite,
    required this.onBook,
    required this.onView,
  });

  final Solver solver;
  final bool favorite;
  final VoidCallback onFavorite;
  final VoidCallback onBook;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassAvatar(initials: solver.initials, size: 52, photoUrl: ExploreService.instance.solverPhoto(solver)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            solver.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.verified_outlined, size: 16, color: Colors.white, semanticLabel: 'Verified'),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      solver.about,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(color: AppColors.white(0.82)),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: favorite ? 'Remove from favorites' : 'Add to favorites',
                onPressed: onFavorite,
                icon: Icon(favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final skill in solver.skills.take(3)) _Tag(skill),
                    if (solver.skills.length > 3) _Tag('+${solver.skills.length - 3}'),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  children: [
                    _Meta(Icons.star_rounded, '${solver.ratingLabel} · ${solver.sessions} sessions', bold: true),
                    _Meta(Icons.location_on_outlined, solver.location),
                    _Meta(Icons.toll_outlined, solver.priceLabel),
                    _Meta(
                      solver.availableNow ? Icons.circle : Icons.circle_outlined,
                      solver.availableNow ? 'Available now' : 'Scheduled only',
                      iconSize: 9,
                    ),
                  ],
                ),
                gap14,
                Row(
                  children: [
                    Expanded(
                      child: PrimaryPillButton(label: 'Book Now', onPressed: onBook),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 96,
                      child: GlassPillButton(label: 'View', onPressed: onView),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.view, required this.onReset});

  final _View view;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final favorites = view == _View.favorites;
    return GlassPanel(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: Column(
        children: [
          GlassIconBadge(icon: favorites ? Icons.favorite_border_rounded : Icons.search_off_rounded, size: 64),
          gap14,
          Text(
            favorites
                ? 'No favorites yet. Tap the heart on a solver to save them here.'
                : 'No solvers match your search.',
            style: AppText.body,
            textAlign: TextAlign.center,
          ),
          if (!favorites) ...[gap14, SmallPillButton(label: 'Clear search & filters', onPressed: onReset)],
        ],
      ),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.initial});

  final _Filters initial;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  final _explore = ExploreService.instance;
  late String? _category = widget.initial.category;
  late String? _subcategory = widget.initial.subcategory;
  late double? _minRating = widget.initial.minRating;
  late bool _availableNow = widget.initial.availableNow;
  late final _languages = {...widget.initial.languages};
  late final _prices = {...widget.initial.prices};

  @override
  Widget build(BuildContext context) {
    final subcategories = _category == null ? const <String>[] : _explore.categories[_category]!;
    return FlowSheetFrame(
      title: 'Filters',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section('Category', [
            for (final c in _explore.categories.keys)
              GlassChip(
                label: c,
                selected: _category == c,
                onTap: () => setState(() {
                  _category = _category == c ? null : c;
                  _subcategory = null;
                }),
              ),
          ]),
          if (subcategories.isNotEmpty)
            _section('Subcategory', [
              for (final s in subcategories)
                GlassChip(
                  label: s,
                  selected: _subcategory == s,
                  onTap: () => setState(() => _subcategory = _subcategory == s ? null : s),
                ),
            ]),
          _section('Rating', [
            for (final (label, value) in const [('Any', null), ('4.5+', 4.5), ('4.8+', 4.8)])
              GlassChip(label: label, selected: _minRating == value, onTap: () => setState(() => _minRating = value)),
          ]),
          _section('Availability', [
            GlassChip(label: 'Any time', selected: !_availableNow, onTap: () => setState(() => _availableNow = false)),
            GlassChip(
              label: 'Available now',
              selected: _availableNow,
              onTap: () => setState(() => _availableNow = true),
            ),
          ]),
          _section('Languages', [
            for (final l in _explore.languages)
              GlassChip(
                label: l,
                selected: _languages.contains(l),
                onTap: () => setState(() => _languages.contains(l) ? _languages.remove(l) : _languages.add(l)),
              ),
          ]),
          _section('Price per minute', [
            for (final p in _explore.priceTiers)
              GlassChip(
                label: '${formatMoney(p)}/min',
                selected: _prices.contains(p),
                onTap: () => setState(() => _prices.contains(p) ? _prices.remove(p) : _prices.add(p)),
              ),
          ]),
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Reset', onPressed: () => Navigator.of(context).pop(const _Filters())),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(
              label: 'Apply',
              onPressed: () => Navigator.of(context).pop(
                _Filters(
                  category: _category,
                  subcategory: _subcategory,
                  minRating: _minRating,
                  availableNow: _availableNow,
                  languages: _languages,
                  prices: _prices,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> chips) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          gap8,
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.white(0.3)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white)),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text, {this.bold = false, this.iconSize = 15});

  final IconData icon;
  final String text;
  final bool bold;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: iconSize, color: AppColors.white(0.85)),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            color: AppColors.white(0.85),
          ),
        ),
      ],
    );
  }
}
