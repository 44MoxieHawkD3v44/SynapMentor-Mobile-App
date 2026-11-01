import 'package:flutter/material.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/countries.dart' show UserZone;
import '../services/explore_service.dart';
import '../services/session_service.dart';
import '../services/solver_service.dart';
import '../services/wallet_service.dart' show solverShare;
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import 'booking_sheet.dart';
import 'bookings_tab.dart' show BookingBadge, ChatLogSheet, DetailRow, RescheduleSheet;
import 'session_screen.dart';

enum _Tab {
  active('Active'),
  upcoming('Upcoming'),
  cancelled('Cancelled'),
  podcasts('Podcasts'),
  completed('Completed');

  const _Tab(this.label);
  final String label;
}

/// Where a booking stands for the solver.
enum _Stage {
  active('Active'),
  upcoming('Upcoming'),
  cancelled('Cancelled'),
  completed('Completed');

  const _Stage(this.label);
  final String label;
}

_Stage _stageOf(Booking b) {
  if (b.cancellation != null) return _Stage.cancelled;
  return switch (SessionService.instance.phaseOf(b)) {
    SessionPhase.live => _Stage.active,
    SessionPhase.upcoming => _Stage.upcoming,
    SessionPhase.completed => _Stage.completed,
  };
}

/// Solver Bookings: every session seekers booked in the solver's available
/// slots, split into Active, Upcoming, Cancelled, Podcasts and Completed.
class SolverBookingsTab extends StatefulWidget {
  const SolverBookingsTab({super.key, required this.user});

  final AppUser user;

  @override
  State<SolverBookingsTab> createState() => _SolverBookingsTabState();
}

class _SolverBookingsTabState extends State<SolverBookingsTab> {
  _Tab _tab = _Tab.active;
  _Stage _podcastStage = _Stage.upcoming;
  String? _notice;
  String? _error;

  AppUser get _user => widget.user;

  Future<void> _choosePodcastStage() async {
    final picked = await showGlassPicker(
      context,
      title: 'Show podcasts',
      options: _Stage.values,
      label: (s) => s.label,
      selected: _podcastStage,
    );
    if (picked != null) setState(() => _podcastStage = picked);
  }

  Future<void> _setPodcasts(bool enabled) async {
    try {
      await SolverService.instance.setPodcastEnabled(_user, enabled);
      if (mounted) setState(() => _error = null);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  void initState() {
    super.initState();
    // Booked sessions and the podcast setting come from the server.
    ExploreService.instance
        .loadSolverBookings(_user)
        // Then the reviews on completed sessions, for View Review.
        .then((_) => SessionService.instance.loadSolverReviews(_user).catchError((Object _) {}))
        .catchError((Object e) {
          if (mounted) setState(() => _error = e is AuthException ? e.message : 'Couldn\'t load your bookings.');
        });
    SolverService.instance.loadBookingSetup(_user).catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([SessionService.instance, ExploreService.instance, SolverService.instance]),
      builder: (context, _) {
        final all = ExploreService.instance.bookingsForSolver(_user);
        final sessions = all.where((b) => b.type != BookingType.podcast).toList();
        final podcasts = all.where((b) => b.type == BookingType.podcast).toList();
        List<Booking> inStage(List<Booking> list, _Stage stage) {
          final found = list.where((b) => _stageOf(b) == stage).toList();
          // Newest first for history; soonest first for what's coming.
          return stage == _Stage.cancelled || stage == _Stage.completed ? found.reversed.toList() : found;
        }

        final count = {
          _Tab.active: inStage(sessions, _Stage.active).length,
          _Tab.upcoming: inStage(sessions, _Stage.upcoming).length,
          _Tab.cancelled: inStage(sessions, _Stage.cancelled).length,
          _Tab.podcasts: podcasts
              .where((b) => _stageOf(b) != _Stage.cancelled && _stageOf(b) != _Stage.completed)
              .length,
          _Tab.completed: inStage(sessions, _Stage.completed).length,
        };
        return ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Bookings',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    gap14,
                    // Scrolls sideways so each tab keeps a readable size.
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final tab in _Tab.values) ...[
                            GlassChip(
                              label: '${tab.label} ${count[tab]}',
                              selected: _tab == tab,
                              onTap: () => setState(() {
                                _tab = tab;
                                _notice = null;
                                _error = null;
                              }),
                            ),
                            const SizedBox(width: 8),
                          ],
                        ],
                      ),
                    ),
                    gap14,
                    InlineNotice(message: _notice, tone: NoticeTone.success),
                    InlineNotice(message: _error, tone: NoticeTone.error),
                    StepSwitcher(
                      child: KeyedSubtree(
                        key: ValueKey(_tab),
                        child: switch (_tab) {
                          _Tab.active => _panel('Active Sessions', _Stage.active, inStage(sessions, _Stage.active)),
                          _Tab.upcoming => _panel(
                            'Upcoming Sessions',
                            _Stage.upcoming,
                            inStage(sessions, _Stage.upcoming),
                          ),
                          _Tab.cancelled => _panel(
                            'Cancelled Sessions',
                            _Stage.cancelled,
                            inStage(sessions, _Stage.cancelled),
                          ),
                          _Tab.podcasts => _podcastPanel(inStage(podcasts, _podcastStage)),
                          _Tab.completed => _panel(
                            'Completed Sessions',
                            _Stage.completed,
                            inStage(sessions, _Stage.completed),
                          ),
                        },
                      ),
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

  Widget _panel(String title, _Stage stage, List<Booking> list, {bool podcast = false, Widget? trailing}) {
    return GlassPanel(
      radius: 26,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 0, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          if (list.isEmpty)
            _EmptyState(stage: stage, podcast: podcast)
          else
            for (final (i, b) in list.indexed) ...[
              if (i > 0) const SizedBox(height: 12),
              SolverBookingCard(user: _user, booking: b, onNotice: (text) => setState(() => _notice = text)),
            ],
        ],
      ),
    );
  }

  Widget _podcastPanel(List<Booking> list) {
    final enabled = SolverService.instance.podcastEnabled(ExploreService.instance.ownSolver(_user));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text('Accepting podcasts', style: AppText.caption.copyWith(color: Colors.white)),
            const SizedBox(width: 6),
            Switch(
              value: enabled,
              onChanged: _setPodcasts,
              thumbColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.white(0.8),
              ),
              trackColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? Colors.white : AppColors.white(0.14),
              ),
              trackOutlineColor: WidgetStateProperty.all(AppColors.white(0.3)),
            ),
          ],
        ),
        gap8,
        if (!enabled) ...[
          const InlineNotice(message: 'Podcast bookings are off. Seekers can\'t book new podcasts with you.'),
        ],
        _panel(
          'Podcasts',
          _podcastStage,
          list,
          podcast: true,
          trailing: _DropdownButton(label: _podcastStage.label, onTap: _choosePodcastStage),
        ),
      ],
    );
  }
}

// ---- Card ---------------------------------------------------------------------------

/// One booking as the solver sees it, with the actions for its stage.
class SolverBookingCard extends StatelessWidget {
  const SolverBookingCard({super.key, required this.user, required this.booking, this.onNotice});

  final AppUser user;
  final Booking booking;

  /// Confirmation text after an action, e.g. a reschedule.
  final ValueChanged<String>? onNotice;

  Future<T?> _sheet<T>(BuildContext context, Widget sheet) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => sheet,
  );

  Future<void> _reschedule(BuildContext context, UserZone zone) async {
    // The server lets solvers cancel a booked session (with a full refund to
    // the seeker), not move it.
    if (ExploreService.instance.isSolverBooking(booking)) {
      final cancelled = await _sheet<Booking>(context, _CancelSheet(user: user, booking: booking));
      if (cancelled != null) onNotice?.call('"${cancelled.title}" was cancelled. The seeker gets a full refund.');
      return;
    }
    final moved = await _sheet<Booking>(context, RescheduleSheet(user: user, booking: booking));
    if (moved != null) {
      final wall = zone.wall(moved.start);
      onNotice?.call('"${moved.title}" moved to ${formatDay(wall)} at ${formatClock(wall)}. The seeker was notified.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final sessions = SessionService.instance;
    final state = sessions.stateOf(b);
    final stage = _stageOf(b);
    final zone = ExploreService.userZone(user);
    final start = zone.wall(b.start);
    final end = zone.wall(sessions.endOf(b));
    final anonymous = b.type == BookingType.anonymous;
    final modeLabel = switch (b) {
      Booking(type: BookingType.podcast) => 'Podcast Session',
      Booking(mode: SessionMode.chat) => 'Chat Session',
      _ => 'Video Session',
    };
    final started = sessions.hasStarted(b);
    final status = switch (stage) {
      _Stage.active => started ? 'Live' : 'Starting soon',
      _Stage.upcoming => 'Scheduled',
      _Stage.cancelled => 'Cancelled',
      _Stage.completed => 'Completed',
    };
    final files = state.messages.where((m) => m.fileName != null).length;
    final minutes = b.minutes + state.extraMinutes;

    final lines = <(IconData, String)>[
      ...switch (stage) {
        _Stage.active || _Stage.upcoming => [
          (Icons.calendar_today_outlined, formatDay(start)),
          (Icons.schedule_rounded, '${formatClock(start)} – ${formatClock(end)} · $minutes min'),
          (b.mode == SessionMode.chat ? Icons.chat_bubble_outline_rounded : Icons.videocam_outlined, b.mode.label),
          (Icons.public_rounded, zone.labelAt(b.start)),
        ],
        _Stage.cancelled => [
          (Icons.event_busy_outlined, 'Was scheduled: ${formatDay(start)} at ${formatClock(start)}'),
          (Icons.schedule_rounded, '${b.minutes} min'),
          (Icons.person_outline_rounded, 'Cancelled by: ${b.cancellation!.by}'),
          (Icons.chat_bubble_outline_rounded, 'Reason: ${b.cancellation!.reason}'),
        ],
        _Stage.completed => [
          (Icons.calendar_today_outlined, formatDay(start)),
          (Icons.schedule_rounded, '$minutes min'),
          (Icons.account_balance_wallet_outlined, sessions.payoutStatus(b)),
          if (files > 0) (Icons.attach_file_rounded, 'Session files ($files)'),
        ],
      },
    ];

    return GlassWell(
      radius: 20,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (anonymous)
                const SizedBox.square(
                  dimension: 44,
                  child: GlassWell(
                    radius: 14,
                    child: Icon(Icons.visibility_off_outlined, size: 22, color: Colors.white),
                  ),
                )
              else
                GlassAvatar(initials: b.seekerInitials, size: 44, photoUrl: ExploreService.instance.seekerPhoto(b)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.seekerLabel,
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${anonymous ? 'Anonymous' : 'Seeker'} · $modeLabel',
                      style: AppText.caption.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  BookingBadge(status),
                  if (b.rescheduled && stage != _Stage.completed) ...[
                    const SizedBox(height: 4),
                    const BookingBadge('Rescheduled'),
                  ],
                ],
              ),
            ],
          ),
          gap14,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.menu_book_outlined, size: 17, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  b.title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ),
            ],
          ),
          gap8,
          for (final (icon, text) in lines) _Line(icon, text),
          ..._actions(context, stage, state, zone),
        ],
      ),
    );
  }

  List<Widget> _actions(BuildContext context, _Stage stage, SessionState state, UserZone zone) {
    final b = booking;
    final sessions = SessionService.instance;
    switch (stage) {
      case _Stage.active:
        final verified = state.solverFaceVerified;
        return [
          gap14,
          if (!sessions.hasStarted(b)) ...[
            _Note(
              icon: Icons.hourglass_top_rounded,
              text: 'Starts in ${_mmss(b.start.difference(DateTime.now().toUtc()))}. Verify and wait in the lobby.',
            ),
            gap8,
          ],
          PrimaryPillButton(
            label: verified ? 'Join Now' : 'Verify Face & Join',
            height: 46,
            onPressed: () => Navigator.of(context).push(glassRoute(SessionScreen(user: user, booking: b))),
          ),
          gap8,
          GlassPillButton(
            label: 'Session details',
            icon: Icons.info_outline_rounded,
            height: 46,
            onPressed: () => _sheet<void>(context, _DetailsSheet(user: user, booking: b)),
          ),
        ];
      case _Stage.upcoming:
        final canReschedule = sessions.canReschedule(b);
        return [
          gap14,
          const _Note(icon: Icons.schedule_rounded, text: 'Opens 5 minutes before start'),
          gap8,
          GlassPillButton(
            label: 'Session details',
            icon: Icons.info_outline_rounded,
            height: 46,
            onPressed: () => _sheet<void>(context, _DetailsSheet(user: user, booking: b)),
          ),
          gap8,
          Opacity(
            opacity: canReschedule ? 1 : 0.45,
            child: GlassPillButton(
              label: 'Reschedule',
              icon: Icons.event_repeat_rounded,
              height: 46,
              onPressed: canReschedule ? () => _reschedule(context, zone) : null,
            ),
          ),
          if (!canReschedule) ...[
            const SizedBox(height: 6),
            Text(
              'Rescheduling closes 1 hour before the session.',
              style: AppText.caption.copyWith(fontSize: 11.5),
              textAlign: TextAlign.center,
            ),
          ],
        ];
      case _Stage.cancelled:
        return const [];
      case _Stage.completed:
        // The chat history (Meet or Chat) loads from the server when opened.
        final hasChat = state.messages.isNotEmpty || SessionService.instance.isRemote(b);
        return [
          gap14,
          Row(
            children: [
              if (hasChat) ...[
                SmallPillButton(
                  label: 'Chat',
                  onPressed: () => _sheet<void>(context, ChatLogSheet(booking: b, asSolver: true)),
                ),
                const SizedBox(width: 10),
              ],
              SmallPillButton(
                label: 'View Review',
                onPressed: () => _sheet<void>(context, _ReviewSheet(booking: b)),
              ),
            ],
          ),
        ];
    }
  }
}

// ---- Sheets ---------------------------------------------------------------------------

class _DetailsSheet extends StatelessWidget {
  const _DetailsSheet({required this.user, required this.booking});

  final AppUser user;
  final Booking booking;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final sessions = SessionService.instance;
    final zone = ExploreService.userZone(user);
    final start = zone.wall(b.start);
    final end = zone.wall(sessions.endOf(b));
    final extra = sessions.stateOf(b).extraMinutes;
    final value = b.walletMinutes + sessions.stateOf(b).extensionValue;
    return FlowSheetFrame(
      title: 'Session Details',
      body: GlassWell(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          children: [
            DetailRow('Topic', b.title),
            DetailRow('Details', b.description),
            DetailRow('Seeker', b.seekerLabel),
            DetailRow('Session type', b.type.label),
            DetailRow('Mode', b.mode.label),
            DetailRow('Date', formatDay(start)),
            DetailRow('Time', '${formatClock(start)} – ${formatClock(end)}'),
            DetailRow('Duration', '${b.minutes} min${extra > 0 ? ' + $extra min extension' : ''}'),
            DetailRow('Timezone', zone.labelAt(b.start)),
            DetailRow('Your share (70%)', '${(value * solverShare).round()} min'),
          ],
        ),
      ),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class _ReviewSheet extends StatelessWidget {
  const _ReviewSheet({required this.booking});

  final Booking booking;

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Session Review',
      body: ListenableBuilder(listenable: SessionService.instance, builder: (context, _) => _body()),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }

  Widget _body() {
    final b = booking;
    final sessions = SessionService.instance;
    final mine = sessions.stateOf(b).solverReview;
    String stars(int n) => '${'★' * n}${'☆' * (5 - n)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          b.title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
        ),
        Text('with ${b.seekerLabel}', style: AppText.caption),
        gap14,
        const Text('Your review', style: _label),
        gap8,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: mine == null
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text('Not reviewed.', style: AppText.caption),
                )
              : Column(
                  children: [
                    DetailRow('Rating', stars(mine.rating)),
                    DetailRow(
                      'Punctuality',
                      SolverSessionReview.describe(mine.punctuality.label, mine.punctualityOther),
                    ),
                    DetailRow('Engagement', SolverSessionReview.describe(mine.engagement.label, mine.engagementOther)),
                    if (mine.feedback.isNotEmpty) DetailRow('Feedback', mine.feedback),
                  ],
                ),
        ),
        gap14,
        InlineNotice(message: sessions.payoutStatus(b)),
      ],
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

// ---- Pieces ---------------------------------------------------------------------------

class _Line extends StatelessWidget {
  const _Line(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.white(0.85)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: AppText.caption.copyWith(fontSize: 13, color: AppColors.white(0.9))),
          ),
        ],
      ),
    );
  }
}

/// A small inset note, e.g. "Opens 5 minutes before start".
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      child: Row(
        children: [
          Icon(icon, size: 17, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: AppText.caption.copyWith(fontSize: 12.5, color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _DropdownButton extends StatelessWidget {
  const _DropdownButton({required this.label, required this.onTap});

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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.stage, required this.podcast});

  final _Stage stage;
  final bool podcast;

  @override
  Widget build(BuildContext context) {
    final (icon, title, message) = podcast
        ? (
            Icons.mic_none_rounded,
            'No ${stage.label.toLowerCase()} podcasts',
            switch (stage) {
              _Stage.active => 'Podcasts you can join right now will appear here.',
              _Stage.upcoming => 'Podcasts seekers book with you appear here.',
              _Stage.cancelled => 'Cancelled podcasts appear here.',
              _Stage.completed => 'Recorded podcasts appear here.',
            },
          )
        : switch (stage) {
            _Stage.active => (
              Icons.videocam_outlined,
              'No Active Sessions',
              'You don\'t have any live sessions at the moment.',
            ),
            _Stage.upcoming => (
              Icons.event_outlined,
              'No Upcoming Sessions',
              'Sessions seekers book in your available slots appear here.',
            ),
            _Stage.cancelled => (Icons.event_busy_outlined, 'No Cancelled Sessions', 'Nothing has been cancelled.'),
            _Stage.completed => (
              Icons.task_alt_rounded,
              'No Completed Sessions',
              'Sessions you finish appear here with their reviews.',
            ),
          };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36),
      child: Column(
        children: [
          GlassIconBadge(icon: icon, size: 72),
          gap14,
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
          ),
          gap8,
          Text(message, style: AppText.body, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

String _mmss(Duration d) {
  final s = d.inSeconds.clamp(0, 359999);
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Cancels a booked session from the solver's side. The seeker is refunded
/// in full; it's only possible until 1 hour before the start.
class _CancelSheet extends StatefulWidget {
  const _CancelSheet({required this.user, required this.booking});

  final AppUser user;
  final Booking booking;

  @override
  State<_CancelSheet> createState() => _CancelSheetState();
}

class _CancelSheetState extends State<_CancelSheet> {
  final _reason = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _cancel() async {
    if (_reason.text.trim().length < 5) {
      setState(() => _error = 'Tell the seeker why, in a few words.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final cancelled = await ExploreService.instance.cancelForSolver(widget.user, widget.booking, _reason.text);
      if (mounted) Navigator.of(context).pop(cancelled);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Can\'t Attend?',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          Text(
            'Booked sessions can\'t be moved from your side yet. You can cancel "${widget.booking.title}" instead; '
            'the seeker gets a full refund and can book you again.',
            style: AppText.body,
          ),
          gap14,
          GlassTextField(
            controller: _reason,
            hint: 'Reason for the seeker',
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() => _error = null),
          ),
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Keep Session', onPressed: () => Navigator.of(context).pop()),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: 'Cancel Session', loading: _saving, onPressed: _cancel),
          ),
        ],
      ),
    );
  }
}
