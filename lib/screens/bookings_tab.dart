import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../core/navigation.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/countries.dart' show UserZone;
import '../services/explore_service.dart';
import '../services/session_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/chat_extras.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import '../widgets/liquid_nav_bar.dart';
import 'booking_sheet.dart';
import 'session_screen.dart';

enum _Tab {
  upcoming('Upcoming', Icons.event_outlined),
  live('Live', Icons.sensors_rounded),
  podcast('Podcast', Icons.mic_none_rounded),
  history('History', Icons.history_rounded),
  chat('Chat', Icons.chat_bubble_outline_rounded);

  const _Tab(this.label, this.icon);
  final String label;
  final IconData icon;
}

enum _ModeFilter {
  all('All Sessions'),
  meet('Meet Sessions'),
  chat('Chat Sessions');

  const _ModeFilter(this.label);
  final String label;

  bool matches(Booking b) => switch (this) {
    all => true,
    meet => b.mode == SessionMode.meet,
    chat => b.mode == SessionMode.chat,
  };
}

/// Seeker Bookings: upcoming and live sessions, podcasts, and the history and
/// chat logs of past sessions.
class BookingsTab extends StatefulWidget {
  const BookingsTab({super.key, required this.user});

  final AppUser user;

  @override
  State<BookingsTab> createState() => _BookingsTabState();
}

class _BookingsTabState extends State<BookingsTab> {
  final _sessions = SessionService.instance;
  final _explore = ExploreService.instance;
  _Tab _tab = _Tab.upcoming;
  _ModeFilter _filter = _ModeFilter.all;
  String? _notice;

  AppUser get _user => widget.user;

  @override
  void initState() {
    super.initState();
    _explore.loadBookings(_user).catchError((Object e) {
      if (mounted) setState(() => _notice = e is AuthException ? e.message : 'Couldn\'t load your bookings.');
    });
  }

  UserZone get _userZone => ExploreService.userZone(_user);

  String _when(Booking b) {
    final wall = _userZone.wall(b.start);
    return '${formatDay(wall)} · ${formatClock(wall)}';
  }

  Future<T?> _sheet<T>(Widget sheet) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => sheet,
  );

  void _join(Booking b) => Navigator.of(context).push(glassRoute(SessionScreen(user: _user, booking: b)));

  Future<void> _reschedule(Booking b) async {
    final moved = await _sheet<Booking>(RescheduleSheet(user: _user, booking: b));
    if (moved != null && mounted) {
      final wall = _userZone.wall(moved.start);
      setState(() => _notice = '"${moved.title}" moved to ${formatDay(wall)} at ${formatClock(wall)}.');
    }
  }

  void _details(Booking b) => _sheet<void>(_DetailsSheet(user: _user, booking: b));

  void _chatLog(Booking b) => _sheet<void>(ChatLogSheet(booking: b));

  Future<void> _chooseFilter() async {
    final picked = await showGlassPicker(
      context,
      title: 'Show',
      options: _ModeFilter.values,
      label: (f) => f.label,
      selected: _filter,
    );
    if (picked != null) setState(() => _filter = picked);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_sessions, _explore]),
      builder: (context, _) {
        final all = _explore.bookingsFor(_user);
        return ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, LiquidNavBar.clearance + MediaQuery.paddingOf(context).bottom),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Session Management',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    gap14,
                    Row(
                      children: [
                        for (final tab in _Tab.values) ...[
                          if (tab != _Tab.values.first) const SizedBox(width: 6),
                          Expanded(
                            child: GlassOption(
                              height: 62,
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
                                    child: Text(tab.label, style: AppText.label.copyWith(fontSize: 12)),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    gap14,
                    InlineNotice(message: _notice, tone: NoticeTone.success),
                    StepSwitcher(
                      child: KeyedSubtree(key: ValueKey(_tab), child: _buildTab(all)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTab(List<Booking> all) {
    SessionPhase phase(Booking b) => _sessions.phaseOf(b);
    switch (_tab) {
      case _Tab.upcoming:
        final list = all.where((b) => phase(b) == SessionPhase.upcoming).toList();
        return _Section(
          title: 'Upcoming Sessions (${list.length})',
          empty: 'No upcoming sessions. Book one from Explore.',
          children: [for (final b in list) _upcomingCard(b)],
        );
      case _Tab.live:
        // Sessions that haven't gone live yet stay under Upcoming.
        final live = all.where((b) => phase(b) == SessionPhase.live).toList();
        return _Section(
          title: 'Live Sessions (${live.length})',
          empty: 'No live sessions. Sessions go live 5 minutes before they start.',
          children: [for (final b in live) _liveCard(b)],
        );
      case _Tab.podcast:
        final list = all.where((b) => b.type == BookingType.podcast).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const InlineNotice(message: 'Podcast sessions are recorded and stored securely after compression.'),
            _Section(
              title: 'Podcasts (${list.length})',
              empty: 'No podcast bookings yet. Look for solvers under Explore → Podcasts.',
              children: [
                for (final b in list)
                  switch (phase(b)) {
                    SessionPhase.live => _liveCard(b),
                    SessionPhase.upcoming => _upcomingCard(b),
                    SessionPhase.completed => _historyCard(b),
                  },
              ],
            ),
          ],
        );
      case _Tab.history:
        final list = all.where((b) => phase(b) == SessionPhase.completed && _filter.matches(b)).toList().reversed;
        return _Section(
          title: 'Booking History',
          trailing: _FilterButton(label: _filter.label, onTap: _chooseFilter),
          empty: 'No completed sessions yet.',
          children: [for (final b in list) _historyCard(b)],
        );
      case _Tab.chat:
        final list = all
            .where(
              (b) =>
                  phase(b) != SessionPhase.upcoming && _filter.matches(b) && _sessions.stateOf(b).messages.isNotEmpty,
            )
            .toList()
            .reversed;
        return _Section(
          title: 'Chat History',
          trailing: _FilterButton(label: _filter.label, onTap: _chooseFilter),
          empty: 'No session chats yet.',
          children: [
            for (final b in list)
              _SessionCard(
                booking: b,
                when: _when(b),
                badge: phase(b) == SessionPhase.live ? 'Live' : 'Completed',
                onTap: () => _chatLog(b),
                trailingIcon: Icons.chevron_right_rounded,
              ),
          ],
        );
    }
  }

  Widget _upcomingCard(Booking b) {
    final canReschedule = _sessions.canReschedule(b);
    return _SessionCard(
      booking: b,
      when: _when(b),
      footnote: canReschedule ? null : 'Rescheduling closes 1 hour before the session.',
      actions: [
        SmallPillButton(label: 'Reschedule', onPressed: canReschedule ? () => _reschedule(b) : () {}),
        SmallPillButton(label: 'View Details', onPressed: () => _details(b)),
      ],
      dimFirstAction: !canReschedule,
    );
  }

  Widget _liveCard(Booking b) {
    return _SessionCard(
      booking: b,
      when: _when(b),
      badge: 'LIVE',
      description: b.description,
      actions: [
        SmallPillButton(label: 'Join Now', primary: true, onPressed: () => _join(b)),
        SmallPillButton(label: 'Session Details', onPressed: () => _details(b)),
      ],
    );
  }

  Widget _historyCard(Booking b) {
    final review = _sessions.stateOf(b).review;
    return _SessionCard(
      booking: b,
      when: _when(b),
      badge: 'Completed',
      footnote: review == null ? 'Review pending' : 'You rated ${review.rating}/5',
      actions: [SmallPillButton(label: 'View Details', onPressed: () => _details(b))],
    );
  }
}

// ---- Cards -------------------------------------------------------------------------

String sessionTypeLabel(Booking b) => switch (b.type) {
  BookingType.podcast => 'Podcast',
  BookingType.anonymous => b.mode == SessionMode.chat ? 'Anonymous · Chat' : 'Anonymous · Meeting',
  BookingType.normal => b.mode == SessionMode.chat ? 'Chat' : 'Meeting',
};

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.booking,
    required this.when,
    this.badge,
    this.description,
    this.footnote,
    this.actions = const [],
    this.dimFirstAction = false,
    this.onTap,
    this.trailingIcon,
  });

  final Booking booking;
  final String when;
  final String? badge;
  final String? description;
  final String? footnote;
  final List<Widget> actions;
  final bool dimFirstAction;
  final VoidCallback? onTap;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final content = Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassAvatar(
                initials: b.solver.initials,
                size: 44,
                photoUrl: ExploreService.instance.solverPhoto(b.solver),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(child: Text('with ${b.solver.name}', style: AppText.caption)),
                        const SizedBox(width: 8),
                        const Icon(Icons.star_rounded, size: 14, color: Colors.white),
                        const SizedBox(width: 2),
                        Text(b.solver.ratingLabel, style: AppText.caption.copyWith(color: Colors.white)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (badge != null) ...[BookingBadge(badge!), const SizedBox(height: 4)],
                  BookingBadge(sessionTypeLabel(b)),
                ],
              ),
              if (trailingIcon != null) Icon(trailingIcon, color: Colors.white),
            ],
          ),
          if (description != null) ...[
            gap8,
            Text(description!, style: AppText.caption.copyWith(color: AppColors.white(0.85))),
          ],
          gap8,
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [_Meta(Icons.calendar_today_outlined, when), _Meta(Icons.timelapse_rounded, '${b.minutes} min')],
          ),
          if (footnote != null) ...[
            const SizedBox(height: 6),
            Text(footnote!, style: AppText.caption.copyWith(fontSize: 11.5)),
          ],
          if (actions.isNotEmpty) ...[
            gap14,
            Row(
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Opacity(opacity: i == 0 && dimFirstAction ? 0.45 : 1, child: actions[i]),
                ],
              ],
            ),
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassWell(
        radius: 20,
        child: onTap == null
            ? content
            : Material(
                type: MaterialType.transparency,
                child: InkWell(borderRadius: BorderRadius.circular(20), onTap: onTap, child: content),
              ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.empty, this.trailing});

  final String title;
  final List<Widget> children;
  final String? empty;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ),
            ?trailing,
          ],
        ),
        gap14,
        if (children.isEmpty && empty != null)
          GlassPanel(
            radius: 22,
            padding: const EdgeInsets.all(20),
            child: Text(empty!, style: AppText.body, textAlign: TextAlign.center),
          )
        else
          ...children,
      ],
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.label, required this.onTap});

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
            padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: const TextStyle(fontSize: 12.5, color: Colors.white)),
                const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class BookingBadge extends StatelessWidget {
  const BookingBadge(this.text, {super.key});

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

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.white(0.85)),
        const SizedBox(width: 5),
        Text(text, style: AppText.caption.copyWith(fontSize: 12, color: AppColors.white(0.85))),
      ],
    );
  }
}

// ---- Sheets --------------------------------------------------------------------------

class _DetailsSheet extends StatelessWidget {
  const _DetailsSheet({required this.user, required this.booking});

  final AppUser user;
  final Booking booking;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final zone = ExploreService.userZone(user);
    final wall = zone.wall(b.start);
    final sessions = SessionService.instance;
    final end = zone.wall(sessions.endOf(b));
    return FlowSheetFrame(
      title: 'Session Details',
      body: GlassWell(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          children: [
            DetailRow('Topic', b.title),
            DetailRow('Details', b.description),
            DetailRow('Solver', b.solver.name),
            DetailRow('Session type', b.type.label),
            DetailRow('Mode', b.mode.label),
            DetailRow('Date', formatDay(wall)),
            DetailRow('Time', '${formatClock(wall)} – ${formatClock(end)}'),
            DetailRow(
              'Duration',
              '${b.minutes} min${sessions.stateOf(b).extraMinutes > 0 ? ' + ${sessions.stateOf(b).extraMinutes} min extension' : ''}',
            ),
            DetailRow('Timezone', zone.labelAt(b.start)),
            DetailRow('Wallet', '${b.walletMinutes} min reserved'),
            if (b.type == BookingType.podcast) const DetailRow('Recording', 'This session is recorded'),
          ],
        ),
      ),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class DetailRow extends StatelessWidget {
  const DetailRow(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.caption.copyWith(fontSize: 13, color: AppColors.white(0.75))),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// A past session's chat, read-only.
/// A session's chat history (Meet or Chat), loaded from the server.
class ChatLogSheet extends StatefulWidget {
  const ChatLogSheet({super.key, required this.booking, this.asSolver = false});

  final Booking booking;
  final bool asSolver;

  @override
  State<ChatLogSheet> createState() => _ChatLogSheetState();
}

class _ChatLogSheetState extends State<ChatLogSheet> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    SessionService.instance
        .loadChatHistory(widget.booking)
        .catchError((Object e) {
          if (mounted) setState(() => _error = e is AuthException ? e.message : 'The chat couldn\'t be loaded.');
        })
        .whenComplete(() {
          if (mounted) setState(() => _loading = false);
        });
  }

  @override
  Widget build(BuildContext context) {
    final booking = widget.booking;
    final asSolver = widget.asSolver;
    return FlowSheetFrame(
      title: booking.title,
      body: ListenableBuilder(
        listenable: SessionService.instance,
        builder: (context, _) {
          final messages = SessionService.instance.stateOf(booking).messages;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Chat with ${asSolver ? booking.seekerLabel : booking.solver.name}', style: AppText.caption),
              gap14,
              InlineNotice(message: _error, tone: NoticeTone.error, persistent: true),
              if (messages.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: _loading
                        ? const SizedBox.square(
                            dimension: 28,
                            child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                          )
                        : Text('No messages in this session.', style: AppText.caption),
                  ),
                ),
              for (final m in messages)
                ChatBubble(
                  message: m,
                  otherName: asSolver ? booking.seekerLabel : booking.solver.name,
                  seekerView: !asSolver,
                ),
            ],
          );
        },
      ),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

/// Picks a new open slot. Seekers and solvers both reschedule here, up to
/// 1 hour before the session.
class RescheduleSheet extends StatefulWidget {
  const RescheduleSheet({super.key, required this.user, required this.booking});

  final AppUser user;
  final Booking booking;

  @override
  State<RescheduleSheet> createState() => RescheduleSheetState();
}

class RescheduleSheetState extends State<RescheduleSheet> {
  late final _zone = ExploreService.userZone(widget.user);
  late DateTime _date = _today;
  DateTime? _slot;
  bool _saving = false;
  String? _error;

  DateTime get _today {
    final now = DateTime.now().toUtc().add(_zone.offset);
    return DateTime.utc(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    // The solver's free slots for the week come from the server.
    ExploreService.instance
        .loadSlots(
          widget.booking.solver,
          [for (var i = 0; i < 7; i++) _today.add(Duration(days: i))],
          _zone,
          refresh: true,
        )
        .then((_) {
          if (mounted) setState(() {});
        });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final moved = await ExploreService.instance.reschedule(widget.booking, _slot!);
      if (mounted) Navigator.of(context).pop(moved);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _asSolver => widget.user.role == UserRole.solver;

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    final days = [for (var i = 0; i < 7; i++) _today.add(Duration(days: i))];
    final slots = ExploreService.instance
        .openSlots(b.solver, _date, b.minutes, _zone.offset, ignoreBookingId: b.id)
        .where((s) => s != b.start)
        .toList();
    final current = _zone.wall(b.start);
    return FlowSheetFrame(
      title: 'Reschedule Session',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          GlassWell(
            radius: 18,
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                GlassAvatar(
                  initials: _asSolver ? b.seekerInitials : b.solver.initials,
                  size: 42,
                  photoUrl: SessionService.instance.peerPhoto(b),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b.title,
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                      Text(
                        'with ${_asSolver ? b.seekerLabel : b.solver.name} · ${b.minutes} min',
                        style: AppText.caption,
                      ),
                      Text('Now: ${formatDay(current)}, ${formatClock(current)}', style: AppText.caption),
                    ],
                  ),
                ),
              ],
            ),
          ),
          gap14,
          InlineNotice(
            message: _asSolver
                ? 'Can\'t attend? Reschedule at least 1 hour before the session. The seeker is notified of the new time.'
                : 'You can reschedule up to 1 hour before the session. Sessions can\'t be cancelled.',
          ),
          const Text('Select New Date', style: _label),
          gap8,
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: days.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => SizedBox(
                width: 60,
                child: GlassOption(
                  height: 64,
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
          gap14,
          const Text('Available Time Slots', style: _label),
          gap8,
          if (slots.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                'No open slots on this day. Try another date.',
                style: AppText.body,
                textAlign: TextAlign.center,
              ),
            )
          else
            OptionGrid(
              spacing: 8,
              children: [
                for (final s in slots)
                  GlassOption(
                    height: 44,
                    selected: s == _slot,
                    onTap: () => setState(() => _slot = s),
                    child: Text(formatClock(_zone.wall(s)), style: AppText.label.copyWith(fontSize: 13.5)),
                  ),
              ],
            ),
          gap8,
          Text('Times are shown in ${_zone.label}.', style: AppText.caption.copyWith(fontSize: 11.5)),
        ],
      ),
      footer: PrimaryPillButton(label: 'Reschedule Session', loading: _saving, onPressed: _slot == null ? null : _save),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

/// A chat message bubble, shared by the live chat and chat history.
class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.message, required this.otherName, this.seekerView = true, this.replyTo});

  final ChatMessage message;

  /// The message this one replies to, when it's in the chat.
  final ChatMessage? replyTo;

  /// The other person in the chat.
  final String otherName;

  /// Whether the reader is the seeker (their messages are "You").
  final bool seekerView;

  @override
  Widget build(BuildContext context) {
    final mine = message.fromSeeker == seekerView;
    if (message.system) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GlassWell(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(message.text, style: AppText.caption.copyWith(fontSize: 12, color: Colors.white)),
          ),
        ),
      );
    }
    final quoted = replyTo;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GlassWell(
            radius: 16,
            fillTop: mine ? 0.08 : 0,
            fillBottom: mine ? 0.05 : 0,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${mine ? 'You' : otherName} · ${formatClock(message.sentAt.toLocal())}',
                  style: AppText.caption.copyWith(fontSize: 11),
                ),
                const SizedBox(height: 4),
                if (quoted != null)
                  QuotedReply(
                    author: quoted.fromSeeker == seekerView ? 'You' : otherName,
                    text: quoted.fileName ?? quoted.text,
                  ),
                if (message.fileName != null)
                  SecureAttachment(
                    name: message.fileName!,
                    url: message.fileUrl,
                    localPath: message.localPath,
                    download: ApiClient.instance.download,
                  )
                else
                  Text(message.text, style: const TextStyle(fontSize: 14, height: 1.4, color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
