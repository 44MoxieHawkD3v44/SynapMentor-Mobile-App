import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/explore_service.dart';
import '../services/session_service.dart';
import '../services/todo_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import 'booking_sheet.dart';
import 'bookings_tab.dart' show DetailRow;

extension on TaskView {
  String get label => switch (this) {
    TaskView.all => 'All',
    TaskView.today => 'Today',
    TaskView.upcoming => 'Upcoming',
    TaskView.completed => 'Completed',
    TaskView.overdue => 'Overdue',
  };
}

class _Filters {
  const _Filters({this.status, this.priority, this.category});

  final TaskStatus? status;
  final TaskPriority? priority;
  final String? category;

  int get count => [status, priority, category].where((f) => f != null).length;

  bool matches(Task t) =>
      (status == null || t.status == status) &&
      (priority == null || t.priority == priority) &&
      (category == null || t.category == category);
}

String _due(DateTime t) => '${formatDay(t)}, ${formatClock(t)}';

Future<T?> _sheet<T>(BuildContext context, Widget sheet) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: 0.35),
  builder: (_) => sheet,
);

/// My Tasks as a calendar: a collapsible month grid with a month strip, then
/// a Day, Week or Month schedule showing tasks and booked sessions at their
/// times, plus a List view with Today, Upcoming, Completed and Overdue.
/// Tapping (or hovering) an item shows its details card.
class TodoScreen extends StatefulWidget {
  const TodoScreen({super.key, required this.user});

  final AppUser user;

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Height of one hour in the Day and Week schedules.
const _hour = 60.0;

DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
String _weekdayShort(DateTime d) => _weekdays[d.weekday - 1];
String _dateLabel(DateTime d) => '${_weekdayShort(d)}, ${d.day} ${_months[d.month - 1]} ${d.year}';

enum _Mode { day, week, month, list }

/// Something on the calendar: a task, or a booked session.
class _Event {
  _Event({required this.title, required this.start, required this.end, this.task, this.booking, this.withWhom});

  final String title;
  final DateTime start;
  final DateTime end;
  final Task? task;
  final Booking? booking;

  /// For sessions: the solver (seeker view) or seeker (solver view).
  final String? withWhom;

  bool get isSession => booking != null;
  bool get done => task?.completed ?? false;
  bool get overdue => task?.overdue ?? false;
  String get timeRange => '${formatClock(start)} – ${formatClock(end)}';
}

class _TodoScreenState extends State<TodoScreen> {
  final _service = TodoService.instance;
  final _search = TextEditingController();
  final _timeScroll = ScrollController();
  _Filters _filters = const _Filters();
  String? _notice;
  Timer? _reminders;

  _Mode _mode = _Mode.day;

  /// The month grid at the top; closing it gives the schedule the screen.
  bool _expanded = true;
  bool _searching = false;
  late DateTime _selected = _dayOf(DateTime.now());
  late DateTime _month = DateTime(_selected.year, _selected.month);

  /// List mode: null lists the selected day; otherwise one of the views.
  TaskView? _view;

  AppUser get _user => widget.user;

  @override
  void initState() {
    super.initState();
    _service.load(_user).catchError((Object e) {
      if (mounted) setState(() => _notice = e is AuthException ? e.message : 'Couldn\'t load your tasks.');
    });
    // The backend runs this on a schedule; here it runs while the screen is open.
    _service.sendReminders(_user);
    _reminders = Timer.periodic(const Duration(seconds: 30), (_) => _service.sendReminders(_user));
    _autoScroll();
  }

  @override
  void dispose() {
    _reminders?.cancel();
    _search.dispose();
    _timeScroll.dispose();
    super.dispose();
  }

  // ---- Data ------------------------------------------------------------------------

  bool _matchesSearch(String text) {
    final q = _search.text.trim().toLowerCase();
    return q.isEmpty || text.toLowerCase().contains(q);
  }

  bool _taskMatches(Task t) =>
      _filters.matches(t) && _matchesSearch([t.title, t.description, t.category, ...t.tags].join(' '));

  /// Tasks plus the user's booked sessions (not cancelled).
  List<_Event> _events() {
    // Repeating tasks also show on each day they repeat on around the month
    // in view; every repeat opens the same task.
    final from = DateTime(_month.year, _month.month - 1, 20);
    final to = DateTime(_month.year, _month.month + 1, 12);
    final events = <_Event>[
      for (final t in _service.tasks(_user))
        if (_taskMatches(t)) ...[
          _Event(
            title: t.title,
            start: t.due,
            end: t.due.add(Duration(minutes: t.minutes)),
            task: t,
          ),
          if (t.repeat != TaskRepeat.none && !t.completed)
            for (var d = from; d.isBefore(to); d = DateTime(d.year, d.month, d.day + 1))
              if (!_sameDay(d, t.due) && t.occursOn(d))
                _Event(
                  title: t.title,
                  start: DateTime(d.year, d.month, d.day, t.due.hour, t.due.minute),
                  end: DateTime(d.year, d.month, d.day, t.due.hour, t.due.minute).add(Duration(minutes: t.minutes)),
                  task: t,
                ),
        ],
    ];
    // Sessions follow the status filter only when it isn't set.
    if (_filters.count == 0) {
      final solver = _user.role == UserRole.solver;
      final bookings = solver
          ? ExploreService.instance.bookingsForSolver(_user)
          : ExploreService.instance.bookingsFor(_user);
      for (final b in bookings.where((b) => b.cancellation == null)) {
        if (_service.hasSessionTask(_user, b.id)) continue; // already on the list as a task
        final start = b.start.toLocal();
        final minutes = b.minutes + SessionService.instance.stateOf(b).extraMinutes;
        final who = solver ? b.seekerLabel : b.solver.name;
        if (!_matchesSearch('${b.title} $who')) continue;
        events.add(
          _Event(
            title: b.title,
            start: start,
            end: start.add(Duration(minutes: minutes)),
            booking: b,
            withWhom: who,
          ),
        );
      }
    }
    return events..sort((a, b) => a.start.compareTo(b.start));
  }

  // ---- Actions -----------------------------------------------------------------------

  Future<void> _create() async {
    final created = await _sheet<Task>(context, _TaskFormSheet(user: _user, initialDate: _selected));
    if (created != null && mounted) {
      setState(() {
        _notice = '"${created.title}" added.';
        _select(_dayOf(created.due));
      });
      _autoScroll();
    }
  }

  Future<void> _edit(Task task) async {
    final saved = await _sheet<Task>(context, _TaskFormSheet(user: _user, task: task));
    if (saved != null && mounted) setState(() => _notice = '"${saved.title}" updated.');
  }

  Future<void> _delete(Task task) async {
    final confirmed = await _sheet<bool>(
      context,
      FlowSheetFrame(
        title: 'Delete Task?',
        body: Text('"${task.title}" will be removed permanently.', style: AppText.body),
        footer: Builder(
          builder: (context) => Row(
            children: [
              Expanded(
                child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PrimaryPillButton(label: 'Delete', onPressed: () => Navigator.of(context).pop(true)),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.delete(_user, task);
      if (mounted) setState(() => _notice = '"${task.title}" deleted.');
    } on AuthException catch (e) {
      if (mounted) setState(() => _notice = e.message);
    }
  }

  Future<void> _changeStatus(Task task) async {
    final picked = await showGlassPicker(
      context,
      title: 'Status',
      options: TaskStatus.values,
      label: (s) => s.label,
      selected: task.status,
    );
    if (picked != null) _setStatus(task, picked);
  }

  Future<void> _setStatus(Task task, TaskStatus status) async {
    try {
      await _service.setStatus(_user, task, status);
      if (mounted && status == TaskStatus.completed && task.repeat != TaskRepeat.none) {
        setState(() => _notice = 'Done! The next "${task.title}" is scheduled (${task.repeat.label.toLowerCase()}).');
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _notice = e.message);
    }
  }

  void _details(Task task) => _sheet<void>(
    context,
    _TaskDetailsSheet(
      user: _user,
      task: task,
      onEdit: () => _edit(task),
      onDelete: () => _delete(task),
      onStatus: (s) => _setStatus(task, s),
    ),
  );

  /// The detail card for a calendar item.
  Future<void> _openEvent(_Event e) async {
    final action = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => _EventCard(event: e),
    );
    if (!mounted || action == null || e.task == null) return;
    final t = e.task!;
    if (action.startsWith('status:')) {
      final status = TaskStatus.values.where((s) => 'status:${s.name}' == action).firstOrNull;
      if (status != null && status != t.status) _setStatus(t, status);
      return;
    }
    switch (action) {
      case 'open':
        _details(t);
      case 'toggle':
        _setStatus(t, t.completed ? TaskStatus.todo : TaskStatus.completed);
      case 'edit':
        _edit(t);
    }
  }

  Future<void> _openFilters() async {
    final picked = await _sheet<_Filters>(context, _FilterSheet(initial: _filters));
    if (picked != null) setState(() => _filters = picked);
  }

  Future<void> _chooseView() async {
    const day = 'Selected Day';
    final picked = await showGlassPicker<String>(
      context,
      title: 'Show',
      options: [day, for (final v in TaskView.values) v.label],
      label: (l) =>
          l == day ? l : '$l (${_service.inView(_user, TaskView.values.firstWhere((v) => v.label == l)).length})',
      selected: _view?.label ?? day,
    );
    if (picked == null) return;
    setState(() {
      _view = TaskView.values.where((v) => v.label == picked).firstOrNull;
      _notice = null;
    });
  }

  /// The previous (-1) or next (1) month, keeping the day where it fits.
  void _shiftMonth(int delta) => setState(() {
    final m = DateTime(_month.year, _month.month + delta);
    final day = _selected.day.clamp(1, DateTime(m.year, m.month + 1, 0).day);
    _select(DateTime(m.year, m.month, day));
    _notice = null;
  });

  void _select(DateTime day) {
    _selected = day;
    _month = DateTime(day.year, day.month);
    _view = null;
  }

  void _setMode(_Mode mode) {
    setState(() => _mode = mode);
    _autoScroll();
  }

  /// Day and Week open near the first item of the day (or now, or 8 AM).
  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_timeScroll.hasClients) return;
      final events = _events().where((e) => _sameDay(e.start, _selected)).toList();
      final now = DateTime.now();
      final hour = events.isNotEmpty
          ? events.first.start.hour
          : _sameDay(now, _selected)
          ? now.hour
          : 8;
      final target = ((hour - 1).clamp(0, 23) * _hour).clamp(0.0, _timeScroll.position.maxScrollExtent);
      _timeScroll.animateTo(target, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    });
  }

  // ---- Layout ------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([_service, SessionService.instance, ExploreService.instance]),
          builder: (context, _) {
            final events = _events();
            final busyDays = {for (final e in events) _dayOf(e.start)};
            final now = DateTime.now();
            return Column(
              children: [
                _header(),
                if (_searching)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: GlassTextField(
                      controller: _search,
                      hint: 'Search tasks and sessions…',
                      icon: Icons.search_rounded,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _expanded
                      ? Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: _MonthSwipe(
                                onShift: _shiftMonth,
                                child: _MonthGrid(
                                  month: _month,
                                  selected: _selected,
                                  busyDays: busyDays,
                                  onSelect: (d) {
                                    setState(() {
                                      _select(d);
                                      _notice = null;
                                    });
                                    _autoScroll();
                                  },
                                ),
                              ),
                            ),
                            _MonthStrip(
                              month: _month,
                              onPick: (m) => setState(() {
                                final day = _selected.day.clamp(1, DateTime(m.year, m.month + 1, 0).day);
                                _select(DateTime(m.year, m.month, day));
                              }),
                            ),
                          ],
                        )
                      : const SizedBox(width: double.infinity),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Row(
                    children: [
                      for (final (i, m) in _Mode.values.indexed) ...[
                        if (i > 0) const SizedBox(width: 6),
                        Expanded(
                          child: GlassOption(
                            height: 36,
                            radius: 12,
                            selected: _mode == m,
                            onTap: () => _setMode(m),
                            child: Text(switch (m) {
                              _Mode.day => 'Day',
                              _Mode.week => 'Week',
                              _Mode.month => 'Month',
                              _Mode.list => 'List',
                            }, style: AppText.label.copyWith(fontSize: 13)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: InlineNotice(message: _notice, tone: NoticeTone.success),
                  ),
                Expanded(
                  child: switch (_mode) {
                    _Mode.day => _dayView(events, now),
                    _Mode.week => _weekView(events, now),
                    _Mode.month => _monthView(events),
                    _Mode.list => _listView(events),
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header() {
    final now = DateTime.now();
    final title = _monthNames[_month.month - 1] + (_month.year == now.year ? '' : ' ${_month.year}');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
      child: Row(
        children: [
          GlassIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              button: true,
              label: _expanded ? 'Hide calendar' : 'Show calendar',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _expanded = !_expanded),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: const Icon(Icons.arrow_drop_down_rounded, size: 30, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: _searching ? 'Close search' : 'Search',
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _search.clear();
            }),
            icon: Icon(_searching ? Icons.search_off_rounded : Icons.search_rounded, color: Colors.white),
          ),
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                tooltip: 'Filters',
                onPressed: _openFilters,
                icon: const Icon(Icons.tune_rounded, color: Colors.white),
              ),
              if (_filters.count > 0)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    child: Text(
                      '${_filters.count}',
                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.primary),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 4),
          _AddButton(onTap: _create),
        ],
      ),
    );
  }

  // ---- Day -----------------------------------------------------------------------------

  Widget _dayView(List<_Event> events, DateTime now) {
    final day = events.where((e) => _sameDay(e.start, _selected)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              _DateBadge(day: _selected, today: _sameDay(_selected, now)),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  day.isEmpty
                      ? 'Nothing scheduled. Tap + to add a task.'
                      : '${day.length} item${day.length == 1 ? '' : 's'}'
                            '${day.where((e) => e.isSession).isEmpty ? '' : ' · ${day.where((e) => e.isSession).length} session${day.where((e) => e.isSession).length == 1 ? '' : 's'}'}',
                  style: AppText.caption.copyWith(fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: 'Previous day',
                onPressed: () {
                  setState(() => _select(_selected.subtract(const Duration(days: 1))));
                  _autoScroll();
                },
                icon: const Icon(Icons.chevron_left_rounded, color: Colors.white),
              ),
              IconButton(
                tooltip: 'Next day',
                onPressed: () {
                  setState(() => _select(_selected.add(const Duration(days: 1))));
                  _autoScroll();
                },
                icon: const Icon(Icons.chevron_right_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: _timeScroll,
            padding: EdgeInsets.fromLTRB(8, 4, 12, 24 + MediaQuery.paddingOf(context).bottom),
            child: _TimeGrid(days: [_selected], events: day, now: now, onOpen: _openEvent),
          ),
        ),
      ],
    );
  }

  // ---- Week ----------------------------------------------------------------------------

  Widget _weekView(List<_Event> events, DateTime now) {
    final start = _selected.subtract(Duration(days: _selected.weekday - 1));
    final days = [for (var i = 0; i < 7; i++) DateTime(start.year, start.month, start.day + i)];
    final inWeek = events.where((e) => days.any((d) => _sameDay(d, e.start))).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 12, 6),
          child: Row(
            children: [
              SizedBox(
                width: _TimeGrid.gutter,
                child: IconButton(
                  tooltip: 'Previous week',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _select(_selected.subtract(const Duration(days: 7)))),
                  icon: const Icon(Icons.chevron_left_rounded, color: Colors.white),
                ),
              ),
              for (final d in days)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() => _select(d));
                      _setMode(_Mode.day);
                    },
                    child: Column(
                      children: [
                        Text(_weekdayShort(d)[0], style: AppText.caption.copyWith(fontSize: 11.5)),
                        const SizedBox(height: 4),
                        _DayNumber(day: d, selected: _sameDay(d, _selected), today: _sameDay(d, now), size: 30),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: _timeScroll,
            padding: EdgeInsets.fromLTRB(8, 4, 12, 24 + MediaQuery.paddingOf(context).bottom),
            child: _TimeGrid(days: days, events: inWeek, now: now, onOpen: _openEvent),
          ),
        ),
      ],
    );
  }

  // ---- Month ---------------------------------------------------------------------------

  Widget _monthView(List<_Event> events) {
    final first = DateTime(_month.year, _month.month);
    final lead = first.weekday - 1;
    final count = DateTime(_month.year, _month.month + 1, 0).day;
    final cells = <DateTime?>[
      for (var i = 0; i < lead; i++) null,
      for (var d = 1; d <= count; d++) DateTime(_month.year, _month.month, d),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }
    final now = DateTime.now();
    return _MonthSwipe(
      onShift: _shiftMonth,
      child: ListView(
        padding: EdgeInsets.fromLTRB(10, 0, 10, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          Row(
            children: [
              for (final w in _weekdays)
                Expanded(
                  child: Text(w[0], textAlign: TextAlign.center, style: AppText.caption.copyWith(fontSize: 12)),
                ),
            ],
          ),
          gap8,
          for (var r = 0; r < cells.length; r += 7)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final d in cells.sublist(r, r + 7))
                  Expanded(
                    child: d == null
                        ? const SizedBox(height: 96)
                        : _MonthCell(
                            day: d,
                            selected: _sameDay(d, _selected),
                            today: _sameDay(d, now),
                            events: events.where((e) => _sameDay(e.start, d)).toList(),
                            onDay: () {
                              setState(() => _select(d));
                              _setMode(_Mode.day);
                            },
                            onOpen: _openEvent,
                          ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // ---- List ----------------------------------------------------------------------------

  Widget _listView(List<_Event> events) {
    final searching = _search.text.trim().isNotEmpty;
    final List<Task> list = searching
        ? _service.inView(_user, TaskView.all).where(_taskMatches).toList()
        : _view != null
        ? _service.inView(_user, _view!).where(_taskMatches).toList()
        : (_service.tasks(_user).where((t) => t.occursOn(_selected) && _taskMatches(t)).toList()
            ..sort((a, b) => a.due.compareTo(b.due)));
    final sessions = searching || _view != null
        ? const <_Event>[]
        : events.where((e) => e.isSession && _sameDay(e.start, _selected)).toList();
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 32 + MediaQuery.paddingOf(context).bottom),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                searching
                    ? 'Search Results'
                    : _view != null
                    ? '${_view!.label} Tasks'
                    : _sameDay(_selected, DateTime.now())
                    ? 'Today\'s Tasks'
                    : _dateLabel(_selected),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
              ),
            ),
            if (!searching) _Dropdown(label: _view?.label ?? 'Day', onTap: _chooseView),
          ],
        ),
        gap14,
        for (final s in sessions)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _EventBlock(event: s, height: 64, onOpen: _openEvent),
          ),
        if (list.isEmpty && sessions.isEmpty)
          GlassPanel(
            radius: 22,
            padding: const EdgeInsets.all(22),
            child: Text(
              searching || _filters.count > 0 ? 'No tasks match.' : 'No tasks here. Tap + to add one.',
              style: AppText.body,
              textAlign: TextAlign.center,
            ),
          )
        else
          for (final (i, t) in list.indexed)
            _TimelineRow(
              task: t,
              showDate: searching || _view != null,
              last: i == list.length - 1,
              onTap: () => _details(t),
              onToggle: () => _setStatus(t, t.completed ? TaskStatus.todo : TaskStatus.completed),
              onStatus: () => _changeStatus(t),
              onEdit: () => _edit(t),
              onDelete: () => _delete(t),
            ),
      ],
    );
  }
}

// ---- Calendar pieces -----------------------------------------------------------------

/// A day number: solid when selected, ringed when it's today.
class _DayNumber extends StatelessWidget {
  const _DayNumber({required this.day, required this.selected, required this.today, this.size = 34});

  final DateTime day;
  final bool selected;
  final bool today;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? Colors.white : Colors.transparent,
        border: today && !selected ? Border.all(color: AppColors.white(0.6)) : null,
      ),
      child: Text(
        '${day.day}',
        style: TextStyle(
          fontSize: size > 32 ? 14.5 : 13,
          fontWeight: selected || today ? FontWeight.w700 : FontWeight.w500,
          color: selected ? AppColors.primary : Colors.white,
        ),
      ),
    );
  }
}

/// The "Fri / 2" badge above the day schedule.
class _DateBadge extends StatelessWidget {
  const _DateBadge({required this.day, required this.today});

  final DateTime day;
  final bool today;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_weekdayShort(day), style: AppText.label.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _DayNumber(day: day, selected: true, today: today, size: 44),
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({required this.month, required this.selected, required this.busyDays, required this.onSelect});

  final DateTime month;
  final DateTime selected;
  final Set<DateTime> busyDays;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month);
    final lead = first.weekday - 1;
    final count = DateTime(month.year, month.month + 1, 0).day;
    final cells = <DateTime?>[
      for (var i = 0; i < lead; i++) null,
      for (var d = 1; d <= count; d++) DateTime(month.year, month.month, d),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }
    final today = _dayOf(DateTime.now());
    return Column(
      children: [
        Row(
          children: [
            for (final (i, w) in _weekdays.indexed)
              Expanded(
                child: Text(
                  w[0],
                  textAlign: TextAlign.center,
                  style: AppText.caption.copyWith(
                    fontSize: 12,
                    color: selected.weekday - 1 == i ? Colors.white : null,
                    fontWeight: selected.weekday - 1 == i ? FontWeight.w700 : null,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var r = 0; r < cells.length; r += 7)
          Row(
            children: [
              for (final d in cells.sublist(r, r + 7))
                Expanded(
                  child: d == null
                      ? const SizedBox(height: 42)
                      : InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () => onSelect(d),
                          child: SizedBox(
                            height: 42,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _DayNumber(day: d, selected: _sameDay(d, selected), today: d == today, size: 32),
                                const SizedBox(height: 2),
                                Container(
                                  width: 4,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: busyDays.contains(d) ? AppColors.white(0.8) : Colors.transparent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Sept · Oct · Nov … with the year between December and January.
/// Swipe left for the next month, right for the previous one.
class _MonthSwipe extends StatelessWidget {
  const _MonthSwipe({required this.onShift, required this.child});

  final ValueChanged<int> onShift;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v.abs() < 250) return;
        onShift(v < 0 ? 1 : -1);
      },
      child: child,
    );
  }
}

class _MonthStrip extends StatelessWidget {
  const _MonthStrip({required this.month, required this.onPick});

  final DateTime month;
  final ValueChanged<DateTime> onPick;

  @override
  Widget build(BuildContext context) {
    final months = [for (var i = -1; i < 13; i++) DateTime(month.year, month.month + i)];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Row(
        children: [
          for (final m in months) ...[
            if (m.month == 1 && m != months.first)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text('${m.year}', style: AppText.label.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            GlassChip(
              label: _months[m.month - 1],
              selected: m.year == month.year && m.month == month.month,
              onTap: () => onPick(m),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// Hours down the left, one column per day, items placed at their times.
/// Overlapping items share the column side by side.
class _TimeGrid extends StatelessWidget {
  const _TimeGrid({required this.days, required this.events, required this.now, required this.onOpen});

  static const gutter = 52.0;

  final List<DateTime> days;
  final List<_Event> events;
  final DateTime now;
  final ValueChanged<_Event> onOpen;

  static String _hourLabel(int h) => h == 0
      ? ''
      : h < 12
      ? '$h AM'
      : h == 12
      ? '12 PM'
      : '${h - 12} PM';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final colWidth = (box.maxWidth - gutter) / days.length;
        final children = <Widget>[
          // Hour rows: a label, then a soft slot per hour.
          for (var h = 0; h < 24; h++) ...[
            Positioned(
              top: h * _hour - 8,
              left: 0,
              width: gutter - 8,
              child: Text(_hourLabel(h), textAlign: TextAlign.right, style: AppText.caption.copyWith(fontSize: 11.5)),
            ),
            Positioned(
              top: h * _hour + 2,
              left: gutter,
              right: 0,
              height: _hour - 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.white(0.035),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.white(0.05)),
                ),
              ),
            ),
          ],
          // Day separators for the week grid.
          if (days.length > 1)
            for (var i = 1; i < days.length; i++)
              Positioned(
                top: 0,
                bottom: 0,
                left: gutter + i * colWidth,
                width: 1,
                child: ColoredBox(color: AppColors.white(0.06)),
              ),
        ];

        for (final (i, day) in days.indexed) {
          final dayEvents = events.where((e) => _sameDay(e.start, day)).toList();
          // Greedy lanes for overlapping items.
          final laneEnds = <DateTime>[];
          final lanes = <_Event, int>{};
          for (final e in dayEvents) {
            var lane = laneEnds.indexWhere((end) => !end.isAfter(e.start));
            if (lane == -1) {
              laneEnds.add(e.end);
              lane = laneEnds.length - 1;
            } else {
              laneEnds[lane] = e.end;
            }
            lanes[e] = lane;
          }
          final laneCount = laneEnds.isEmpty ? 1 : laneEnds.length;
          final laneWidth = colWidth / laneCount;
          for (final e in dayEvents) {
            final startMin = e.start.hour * 60 + e.start.minute;
            final endMin = _sameDay(e.start, e.end) ? e.end.hour * 60 + e.end.minute : 24 * 60;
            final height = ((endMin - startMin) / 60 * _hour - 3).clamp(26.0, 24 * _hour);
            children.add(
              Positioned(
                top: startMin / 60 * _hour + 1.5,
                left: gutter + i * colWidth + lanes[e]! * laneWidth + 2,
                width: laneWidth - 4,
                height: height,
                child: _EventBlock(event: e, height: height, compact: days.length > 1, onOpen: onOpen),
              ),
            );
          }
          // Now line on today.
          if (_sameDay(day, now)) {
            final top = (now.hour * 60 + now.minute) / 60 * _hour;
            children.add(
              Positioned(
                top: top - 4,
                left: gutter + i * colWidth - 4,
                width: colWidth + 4,
                height: 8,
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    ),
                    Expanded(child: Container(height: 1.5, color: Colors.white)),
                  ],
                ),
              ),
            );
          }
        }
        return SizedBox(
          height: 24 * _hour,
          child: Stack(clipBehavior: Clip.none, children: children),
        );
      },
    );
  }
}

/// An item on the calendar: its title (and time when there's room). Hovering
/// shows a quick summary; tapping opens the full card.
class _EventBlock extends StatelessWidget {
  const _EventBlock({required this.event, required this.height, required this.onOpen, this.compact = false});

  final _Event event;
  final double height;
  final bool compact;
  final ValueChanged<_Event> onOpen;

  Widget _blockTitle(_Event e) => Row(
    children: [
      if (!compact) ...[
        Icon(
          e.isSession
              ? Icons.videocam_outlined
              : e.done
              ? Icons.check_box_rounded
              : Icons.check_box_outline_blank_rounded,
          size: 14,
          color: Colors.white,
        ),
        const SizedBox(width: 5),
      ],
      Expanded(
        child: Text(
          e.title,
          maxLines: compact && height > 50 ? 3 : 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: compact ? 10.5 : 13,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            decoration: e.done ? TextDecoration.lineThrough : null,
            decorationColor: Colors.white,
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final e = event;
    final t = e.task;
    final summary = [
      _dateLabel(e.start),
      e.timeRange,
      if (e.isSession) 'Session with ${e.withWhom}' else '${t!.category} · ${t.status.label}',
      if (t != null && t.description.isNotEmpty) t.description,
    ].join('\n');
    return Tooltip(
      richMessage: TextSpan(
        children: [
          TextSpan(
            text: '${e.title}\n',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
          ),
          TextSpan(text: summary),
        ],
      ),
      textStyle: const TextStyle(fontSize: 12, height: 1.45, color: Colors.white),
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.symmetric(horizontal: 24),
      waitDuration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.white(0.3)),
      ),
      child: GlassWell(
        radius: compact ? 8 : 12,
        active: e.isSession,
        error: e.overdue,
        fillTop: e.isSession ? 0.16 : 0.08,
        fillBottom: e.isSession ? 0.10 : 0.04,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(compact ? 8 : 12),
            onTap: () => onOpen(e),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 4 : 10,
                vertical: height < 40 ? 0 : (compact ? 3 : 5),
              ),
              child: Opacity(
                opacity: e.done ? 0.6 : 1,
                child: height < 40
                    ? Align(alignment: Alignment.centerLeft, child: _blockTitle(e))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: height < 40 ? MainAxisAlignment.center : MainAxisAlignment.start,
                        children: [
                          _blockTitle(e),
                          if (!compact && height >= 44)
                            Text(
                              e.isSession ? '${e.timeRange} · ${e.withWhom}' : e.timeRange,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.caption.copyWith(fontSize: 11.5),
                            ),
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

/// One day in the Month schedule, with up to three item titles.
class _MonthCell extends StatelessWidget {
  const _MonthCell({
    required this.day,
    required this.selected,
    required this.today,
    required this.events,
    required this.onDay,
    required this.onOpen,
  });

  final DateTime day;
  final bool selected;
  final bool today;
  final List<_Event> events;
  final VoidCallback onDay;
  final ValueChanged<_Event> onOpen;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDay,
      child: Container(
        height: 96,
        margin: const EdgeInsets.all(1.5),
        padding: const EdgeInsets.fromLTRB(3, 4, 3, 3),
        decoration: BoxDecoration(
          color: AppColors.white(0.03),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.white(0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: _DayNumber(day: day, selected: selected, today: today, size: 24),
            ),
            const SizedBox(height: 3),
            for (final e in events.take(events.length > 3 ? 2 : 3))
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: GestureDetector(
                  onTap: () => onOpen(e),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: AppColors.white(e.isSession ? 0.2 : 0.1),
                      borderRadius: BorderRadius.circular(4),
                      border: e.overdue ? Border.all(color: AppColors.error, width: 0.8) : null,
                    ),
                    child: Text(
                      e.title,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        decoration: e.done ? TextDecoration.lineThrough : null,
                        decorationColor: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            if (events.length > 3)
              Text('+${events.length - 2} more', style: AppText.caption.copyWith(fontSize: 9.5, color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

/// The detail card for a calendar item. Pops 'open', 'toggle' or 'edit' for
/// tasks.
class _EventCard extends StatelessWidget {
  const _EventCard({required this.event});

  final _Event event;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final t = e.task;
    final b = e.booking;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: GlassPanel(
          radius: 26,
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  GlassIconBadge(icon: e.isSession ? Icons.videocam_outlined : Icons.task_alt_rounded, size: 42),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      e.isSession ? 'Scheduled Session' : 'Task · ${t!.category}',
                      style: AppText.caption.copyWith(fontSize: 12.5),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
              gap14,
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      e.title,
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        decoration: e.done ? TextDecoration.lineThrough : null,
                        decorationColor: Colors.white,
                      ),
                    ),
                    gap8,
                    _Line(Icons.calendar_today_outlined, _dateLabel(e.start)),
                    _Line(
                      Icons.schedule_rounded,
                      '${e.timeRange} · ${e.end.difference(e.start).inMinutes} min',
                      color: e.overdue ? AppColors.error : null,
                    ),
                    if (b != null) ...[
                      _Line(Icons.person_outline_rounded, 'With ${e.withWhom}'),
                      _Line(
                        b.mode == SessionMode.chat ? Icons.chat_bubble_outline_rounded : Icons.videocam_outlined,
                        '${b.type.label} · ${b.mode.label}',
                      ),
                      if (b.description.isNotEmpty) ...[gap8, Text(b.description, style: AppText.body)],
                      gap8,
                      Text('Join it from Bookings when it goes live.', style: AppText.caption.copyWith(fontSize: 12)),
                    ],
                    if (t != null) ...[
                      if (t.overdue) _Line(Icons.warning_amber_rounded, 'Overdue', color: AppColors.error),
                      if (t.repeat != TaskRepeat.none) _Line(Icons.repeat_rounded, t.repeat.label),
                      if (t.description.isNotEmpty) ...[gap8, Text(t.description, style: AppText.body)],
                      gap14,
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _Badge(t.priority.label, icon: Icons.priority_high_rounded),
                          for (final tag in t.tags.take(3)) _Badge(tag),
                        ],
                      ),
                      gap14,
                      Text('Status', style: AppText.caption.copyWith(fontSize: 12)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final s in TaskStatus.values)
                            GlassChip(
                              label: s.label,
                              selected: t.status == s,
                              onTap: () => Navigator.of(context).pop('status:${s.name}'),
                            ),
                        ],
                      ),
                      gap14,
                      Row(
                        children: [
                          Expanded(
                            child: GlassPillButton(label: 'Edit', onPressed: () => Navigator.of(context).pop('edit')),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: t.completed
                                ? GlassPillButton(label: 'Reopen', onPressed: () => Navigator.of(context).pop('toggle'))
                                : PrimaryPillButton(
                                    label: 'Complete',
                                    onPressed: () => Navigator.of(context).pop('toggle'),
                                  ),
                          ),
                        ],
                      ),
                      gap8,
                      Center(
                        child: UnderlineLink(
                          label: 'Open full details',
                          onTap: () => Navigator.of(context).pop('open'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.text, {this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color ?? Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: AppText.label.copyWith(fontSize: 13.5, color: color)),
          ),
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'New Task',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: AppColors.shadow(0.2), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: const SizedBox.square(
              dimension: 44,
              child: Icon(Icons.add_rounded, size: 26, color: AppColors.primary),
            ),
          ),
        ),
      ),
    );
  }
}

/// Greeting, this month's count and the three status tiles.
class _Dropdown extends StatelessWidget {
  const _Dropdown({required this.label, required this.onTap});

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
            padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                ),
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

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.icon, this.onTap});

  final String text;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.white(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: Colors.white), const SizedBox(width: 4)],
          Text(
            text,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 2),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 15, color: Colors.white),
          ],
        ],
      ),
    );
    return onTap == null ? badge : GestureDetector(onTap: onTap, child: badge);
  }
}

/// One task on the timeline: its time on the left with a dot on the rail,
/// and the task card on the right.
class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.task,
    required this.showDate,
    required this.last,
    required this.onTap,
    required this.onToggle,
    required this.onStatus,
    required this.onEdit,
    required this.onDelete,
  });

  final Task task;

  /// Lists across days show each task's date too.
  final bool showDate;
  final bool last;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onStatus;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = task;
    final end = t.due.add(Duration(minutes: t.minutes));
    final clockText = formatClock(t.due);
    final parts = clockText.split(' ');
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 50,
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showDate)
                    Text(
                      '${t.due.day} ${_months[t.due.month - 1]}',
                      style: AppText.caption.copyWith(fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  Text(
                    parts.first,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  if (parts.length > 1) Text(parts.last, style: AppText.caption.copyWith(fontSize: 11)),
                ],
              ),
            ),
          ),
          SizedBox(
            width: 22,
            child: Column(
              children: [
                const SizedBox(height: 18),
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: t.completed ? Colors.white : Colors.transparent,
                    border: Border.all(color: t.overdue ? AppColors.error : Colors.white, width: 2),
                  ),
                ),
                Expanded(child: Container(width: 1.5, color: last ? Colors.transparent : AppColors.white(0.25))),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GlassWell(
                radius: 20,
                active: t.status == TaskStatus.inProgress,
                error: t.overdue,
                fillTop: t.status == TaskStatus.inProgress ? 0.08 : 0,
                fillBottom: t.status == TaskStatus.inProgress ? 0.04 : 0,
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
                      child: Opacity(
                        opacity: t.completed ? 0.65 : 1,
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
                                        t.bookingId != null ? 'Session · ${t.category}' : t.category,
                                        style: AppText.caption.copyWith(fontSize: 11.5),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        t.title,
                                        style: TextStyle(
                                          fontSize: 15.5,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                          decoration: t.completed ? TextDecoration.lineThrough : null,
                                          decorationColor: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: t.completed ? 'Mark as not done' : 'Mark as complete',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: onToggle,
                                  icon: Icon(
                                    t.completed ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                            if (t.description.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Text(
                                  t.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.caption.copyWith(fontSize: 12.5),
                                ),
                              ),
                            ],
                            Container(
                              height: 1,
                              margin: const EdgeInsets.fromLTRB(0, 10, 8, 8),
                              color: AppColors.white(0.12),
                            ),
                            Row(
                              children: [
                                Icon(
                                  Icons.schedule_rounded,
                                  size: 16,
                                  color: t.overdue ? AppColors.error : Colors.white,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    t.overdue
                                        ? 'Overdue · ${formatClock(t.due)}'
                                        : '${formatClock(t.due)} – ${formatClock(end)}',
                                    style: AppText.caption.copyWith(
                                      fontSize: 12,
                                      color: t.overdue ? AppColors.error : Colors.white,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Edit',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: onEdit,
                                  icon: const Icon(Icons.edit_outlined, size: 18, color: Colors.white),
                                ),
                                IconButton(
                                  tooltip: 'Delete',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: onDelete,
                                  icon: Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.error),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                _Badge(t.status.label, onTap: onStatus),
                                _Badge(t.priority.short),
                                if (t.repeat != TaskRepeat.none) _Badge(t.repeat.label, icon: Icons.repeat_rounded),
                                if (t.bookingId != null) const _Badge('Session', icon: Icons.event_available_outlined),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Sheets --------------------------------------------------------------------------------

class _TaskDetailsSheet extends StatelessWidget {
  const _TaskDetailsSheet({
    required this.user,
    required this.task,
    required this.onEdit,
    required this.onDelete,
    required this.onStatus,
  });

  final AppUser user;
  final Task task;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<TaskStatus> onStatus;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TodoService.instance,
      builder: (context, _) {
        final t = task;
        return FlowSheetFrame(
          title: t.title,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Badge(
                    t.status.label,
                    icon: Icons.flag_outlined,
                    onTap: () async {
                      final picked = await showGlassPicker(
                        context,
                        title: 'Status',
                        options: TaskStatus.values,
                        label: (s) => s.label,
                        selected: t.status,
                      );
                      if (picked != null) onStatus(picked);
                    },
                  ),
                  _Badge(t.priority.label, icon: Icons.priority_high_rounded),
                  _Badge(t.category, icon: Icons.label_outline_rounded),
                  _Badge('${t.minutes}min', icon: Icons.schedule_rounded),
                ],
              ),
              gap14,
              if (t.description.isNotEmpty) ...[
                GlassWell(
                  radius: 16,
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Description', style: AppText.label.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text(t.description, style: AppText.body),
                    ],
                  ),
                ),
                gap14,
              ],
              GlassWell(
                radius: 16,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                child: Column(
                  children: [
                    DetailRow('Due', _due(t.due)),
                    DetailRow('Repeat', t.repeat.label),
                    if (t.overdue) const DetailRow('Status', 'Overdue'),
                  ],
                ),
              ),
              if (t.tags.isNotEmpty) ...[
                gap14,
                Text('Tags', style: AppText.label.copyWith(fontWeight: FontWeight.w600)),
                gap8,
                Wrap(spacing: 6, runSpacing: 6, children: [for (final tag in t.tags) _Badge(tag)]),
              ],
            ],
          ),
          footer: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: GlassPillButton(
                      label: 'Edit',
                      onPressed: () {
                        Navigator.of(context).pop();
                        onEdit();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: t.completed
                        ? GlassPillButton(label: 'Reopen Task', onPressed: () => onStatus(TaskStatus.todo))
                        : PrimaryPillButton(label: 'Mark as Complete', onPressed: () => onStatus(TaskStatus.completed)),
                  ),
                ],
              ),
              gap8,
              Center(
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    onDelete();
                  },
                  icon: Icon(Icons.delete_outline_rounded, color: AppColors.error),
                  label: Text(
                    'Delete Task',
                    style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Create or edit. With no [task] it creates one, and can start from a
/// booked session.
class _TaskFormSheet extends StatefulWidget {
  const _TaskFormSheet({required this.user, this.task, this.initialDate});

  final AppUser user;
  final Task? task;

  /// New tasks start on the day picked in the calendar.
  final DateTime? initialDate;

  @override
  State<_TaskFormSheet> createState() => _TaskFormSheetState();
}

class _TaskFormSheetState extends State<_TaskFormSheet> {
  late final _title = TextEditingController(text: widget.task?.title);
  late final _description = TextEditingController(text: widget.task?.description);
  late final _minutes = TextEditingController(text: '${widget.task?.minutes ?? 30}');
  final _customTag = TextEditingController();

  late DateTime? _date = widget.task?.due ?? widget.initialDate;
  late TimeOfDay? _time = widget.task == null ? null : TimeOfDay.fromDateTime(widget.task!.due);
  late TaskPriority _priority = widget.task?.priority ?? TaskPriority.medium;
  late String _category = widget.task?.category ?? TodoService.categories.firstOrNull ?? '';
  late TaskRepeat _repeat = widget.task?.repeat ?? TaskRepeat.none;
  late final _tags = {...?widget.task?.tags};
  String? _bookingId;
  String? _error;
  bool _saving = false;
  final _errors = <String, String?>{};

  bool get _editing => widget.task != null;

  @override
  void dispose() {
    for (final c in [_title, _description, _minutes, _customTag]) {
      c.dispose();
    }
    super.dispose();
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

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      builder: (context, child) => Theme(data: _pickerTheme(context), child: child!),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        _errors['due'] = null;
      });
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 9, minute: 0),
      builder: (context, child) => Theme(data: _pickerTheme(context), child: child!),
    );
    if (picked != null) {
      setState(() {
        _time = picked;
        _errors['due'] = null;
      });
    }
  }

  Future<T?> _pick<T>(String title, List<T> options, String Function(T) label, T selected) =>
      showGlassPicker(context, title: title, options: options, label: label, selected: selected);

  /// Turns an upcoming session into a reminder task.
  Future<void> _fromSession() async {
    final sessions = SessionService.instance;
    final todo = TodoService.instance;
    final upcoming = ExploreService.instance
        .bookingsFor(widget.user)
        .where((b) => sessions.phaseOf(b) != SessionPhase.completed && !todo.hasSessionTask(widget.user, b.id))
        .toList();
    if (upcoming.isEmpty) {
      setState(() => _error = 'No upcoming sessions to add. Sessions already in your list don\'t show here.');
      return;
    }
    final picked = await showGlassPicker<Booking>(
      context,
      title: 'Add a Session',
      options: upcoming,
      label: (b) => '${b.title} · ${b.solver.name} · ${_due(b.start.toLocal())}',
    );
    if (picked == null) return;
    final start = picked.start.toLocal();
    setState(() {
      _bookingId = picked.id;
      _title.text = 'Session: ${picked.title}';
      _description.text = 'Session with ${picked.solver.name} (${picked.mode.label}). ${picked.description}';
      _date = DateTime(start.year, start.month, start.day);
      _time = TimeOfDay.fromDateTime(start);
      _minutes.text = '${picked.minutes}';
      _category = 'Session';
      _error = null;
    });
  }

  void _addTag() {
    final tag = _customTag.text.trim();
    if (tag.isEmpty) return;
    setState(() {
      _tags.add(tag);
      _customTag.clear();
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final minutes = int.tryParse(_minutes.text.trim());
    setState(() {
      _error = null;
      _errors
        ..['title'] = _title.text.trim().isEmpty ? 'Give the task a title.' : null
        ..['due'] = _date == null || _time == null ? 'Pick a due date and time.' : null
        ..['minutes'] = minutes == null || minutes <= 0 ? 'Enter minutes.' : null;
    });
    if (_errors.values.any((e) => e != null)) return;
    final due = DateTime(_date!.year, _date!.month, _date!.day, _time!.hour, _time!.minute);
    final service = TodoService.instance;
    setState(() => _saving = true);
    try {
      if (_editing) {
        await service.update(
          widget.user,
          widget.task!,
          title: _title.text,
          description: _description.text,
          due: due,
          minutes: minutes!,
          priority: _priority,
          category: _category,
          repeat: _repeat,
          tags: _tags.toList(),
        );
        if (mounted) Navigator.of(context).pop(widget.task);
      } else {
        final task = await service.create(
          widget.user,
          title: _title.text,
          description: _description.text,
          due: due,
          minutes: minutes!,
          priority: _priority,
          category: _category,
          repeat: _repeat,
          tags: _tags.toList(),
          bookingId: _bookingId,
        );
        if (mounted) Navigator.of(context).pop(task);
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget label(String text, [String? counter]) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ),
          if (counter != null) Text(counter, style: AppText.caption.copyWith(fontSize: 12)),
        ],
      ),
    );
    Widget column(List<Widget> children) => Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
    return FlowSheetFrame(
      title: _editing ? 'Edit Task' : 'Create New Task',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          if (!_editing) ...[
            GlassPillButton(
              label: 'Add from my sessions',
              icon: Icons.event_available_outlined,
              onPressed: _fromSession,
            ),
            gap14,
          ],
          label('Title', '${_title.text.length}/255'),
          GlassTextField(
            controller: _title,
            hint: 'What do you need to do?',
            textCapitalization: TextCapitalization.sentences,
            inputFormatters: [LengthLimitingTextInputFormatter(255)],
            errorText: _errors['title'],
            onChanged: (_) => setState(() => _errors['title'] = null),
          ),
          gap14,
          label('Description', '${_description.text.length}/5000'),
          GlassTextField(
            controller: _description,
            hint: 'Add details',
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            inputFormatters: [LengthLimitingTextInputFormatter(5000)],
            onChanged: (_) => setState(() {}),
          ),
          gap14,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              column([
                label('Due Date'),
                GlassSelectField(
                  value: _date == null ? null : formatDay(_date!),
                  hint: 'Pick a date',
                  trailingIcon: Icons.calendar_today_outlined,
                  onTap: _pickDate,
                ),
              ]),
              const SizedBox(width: 10),
              column([
                label('Time'),
                GlassSelectField(
                  value: _time?.format(context),
                  hint: 'Pick a time',
                  trailingIcon: Icons.schedule_rounded,
                  onTap: _pickTime,
                ),
              ]),
            ],
          ),
          FieldError(_errors['due']),
          gap14,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              column([
                label('Est. Minutes'),
                GlassTextField(
                  controller: _minutes,
                  hint: '30',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  errorText: _errors['minutes'],
                  onChanged: (_) => setState(() => _errors['minutes'] = null),
                ),
              ]),
              const SizedBox(width: 10),
              column([
                label('Priority'),
                GlassSelectField(
                  value: _priority.label,
                  hint: 'Priority',
                  onTap: () async {
                    final p = await _pick('Priority', TaskPriority.values, (p) => p.label, _priority);
                    if (p != null) setState(() => _priority = p);
                  },
                ),
              ]),
            ],
          ),
          gap14,
          Row(
            children: [
              column([
                label('Category'),
                GlassSelectField(
                  value: _category,
                  hint: 'Category',
                  onTap: () async {
                    final c = await _pick('Category', TodoService.categories, (c) => c, _category);
                    if (c != null) setState(() => _category = c);
                  },
                ),
              ]),
              const SizedBox(width: 10),
              column([
                label('Repeat'),
                GlassSelectField(
                  value: _repeat.label,
                  hint: 'Repeat',
                  onTap: () async {
                    final r = await _pick('Repeat', TaskRepeat.values, (r) => r.label, _repeat);
                    if (r != null) setState(() => _repeat = r);
                  },
                ),
              ]),
            ],
          ),
          gap14,
          label('Tags'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in {...TodoService.presetTags, ..._tags})
                GlassChip(
                  label: tag,
                  selected: _tags.contains(tag),
                  onTap: () => setState(() => _tags.contains(tag) ? _tags.remove(tag) : _tags.add(tag)),
                ),
            ],
          ),
          gap14,
          Row(
            children: [
              Expanded(
                child: GlassTextField(
                  controller: _customTag,
                  hint: 'Add custom tag',
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addTag(),
                ),
              ),
              const SizedBox(width: 10),
              SmallPillButton(label: 'Add', onPressed: _addTag),
            ],
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
            child: PrimaryPillButton(
              label: _editing ? 'Save Changes' : 'Create Task',
              loading: _saving,
              onPressed: _save,
            ),
          ),
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
  late TaskStatus? _status = widget.initial.status;
  late TaskPriority? _priority = widget.initial.priority;
  late String? _category = widget.initial.category;

  @override
  Widget build(BuildContext context) {
    Widget section(String title, List<Widget> chips) => Padding(
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
    return FlowSheetFrame(
      title: 'Filter Tasks',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section('Status', [
            for (final s in TaskStatus.values)
              GlassChip(
                label: s.label,
                selected: _status == s,
                onTap: () => setState(() => _status = _status == s ? null : s),
              ),
          ]),
          section('Priority', [
            for (final p in TaskPriority.values)
              GlassChip(
                label: p.label,
                selected: _priority == p,
                onTap: () => setState(() => _priority = _priority == p ? null : p),
              ),
          ]),
          section('Category', [
            for (final c in TodoService.categories)
              GlassChip(
                label: c,
                selected: _category == c,
                onTap: () => setState(() => _category = _category == c ? null : c),
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
              onPressed: () =>
                  Navigator.of(context).pop(_Filters(status: _status, priority: _priority, category: _category)),
            ),
          ),
        ],
      ),
    );
  }
}
