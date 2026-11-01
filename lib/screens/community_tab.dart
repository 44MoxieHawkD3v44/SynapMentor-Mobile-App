import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import '../widgets/liquid_nav_bar.dart';
import '../widgets/community_logo.dart';
import '../widgets/event_artwork.dart';
import 'booking_sheet.dart';
import 'community_manage.dart';
import 'community_screen.dart';
import 'solver_community.dart';

enum _Tab {
  mine('My Community'),
  joined('Joined'),
  all('All'),
  events('Events'),
  workshops('Workshops'),
  conferences('Conferences');

  const _Tab(this.label);
  final String label;
}

/// Communities: joined and public communities, plus community events. Solvers
/// also get My Community, for the communities they run and their requests.
class CommunityTab extends StatefulWidget {
  const CommunityTab({super.key, required this.user});

  final AppUser user;

  @override
  State<CommunityTab> createState() => _CommunityTabState();
}

class _CommunityTabState extends State<CommunityTab> {
  final _communities = CommunityService.instance;
  final _search = TextEditingController();

  late _Tab _tab = _solver ? _Tab.mine : _Tab.joined;
  String? _domain;
  final _topics = <String>{};
  EventType? _eventType;
  bool _registeredOnly = false;
  String? _notice;
  NoticeTone _tone = NoticeTone.success;

  AppUser get _user => widget.user;

  bool get _solver => widget.user.role == UserRole.solver;

  /// Seekers don't run communities, so they don't see My Community.
  List<_Tab> get _tabs => _solver ? _Tab.values : _Tab.values.where((t) => t != _Tab.mine).toList();

  @override
  void initState() {
    super.initState();
    _communities.load(_user).catchError((Object e) {
      if (mounted) _say(e is AuthException ? e.message : 'Couldn\'t load communities.', NoticeTone.error);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _say(String message, [NoticeTone tone = NoticeTone.success]) => setState(() {
    _notice = message;
    _tone = tone;
  });

  Future<T?> _sheet<T>(Widget sheet) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => sheet,
  );

  // ---- Joining -----------------------------------------------------------------

  /// Pseudo name first (it's the user's only identity in communities), then
  /// the rules, then membership.
  Future<void> _join(Community c) async {
    if (_user.profile.pseudoName == null) {
      final set = await _sheet<bool>(_PseudoNameSheet(user: _user));
      if (set != true || !mounted) return;
    }
    final joined = await _sheet<bool>(_RulesSheet(user: _user, community: c, joining: true));
    if (joined == true && mounted) {
      _say('You joined ${c.name} as ${_user.profile.pseudoName}.');
      setState(() => _tab = _Tab.joined);
    }
  }

  Future<void> _joinViaCode() async {
    final community = await _sheet<Community>(const _InviteCodeSheet());
    if (community == null || !mounted) return;
    if (_communities.isMember(_user, community)) {
      _say('You\'re already a member of ${community.name}.', NoticeTone.info);
      return;
    }
    await _join(community);
  }

  Future<void> _leave(Community c) async {
    final confirmed = await _sheet<bool>(
      _ConfirmSheet(
        title: 'Leave ${c.name}?',
        message: 'You\'ll stop receiving its updates. You can join again anytime.',
        confirmLabel: 'Leave',
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _communities.leave(_user, c);
      _say('You left ${c.name}.');
    } on AuthException catch (e) {
      _say(e.message, NoticeTone.error);
    }
  }

  void _open(Community c) => Navigator.of(context).push(glassRoute(CommunityScreen(user: _user, community: c)));

  void _details(Community c) =>
      _sheet<void>(_CommunityDetailsSheet(user: _user, community: c, onJoin: () => _join(c), onOpen: () => _open(c)));

  void _rules(Community c) => _sheet<void>(_RulesSheet(user: _user, community: c, joining: false));

  Future<void> _filter() async {
    final result = await _sheet<(String?, Set<String>)>(_FilterSheet(domain: _domain, topics: _topics));
    if (result != null) {
      setState(() {
        _domain = result.$1;
        _topics
          ..clear()
          ..addAll(result.$2);
      });
    }
  }

  // ---- Events ------------------------------------------------------------------

  Future<void> _toggleRegistration(CommunityEvent e) async {
    try {
      if (_communities.isRegistered(_user, e)) {
        await _communities.cancelRegistration(_user, e);
        _say('Registration for "${e.title}" cancelled.');
      } else {
        // Registering shares the user's name and email with the host.
        final agreed = await _sheet<bool>(
          _ConfirmSheet(
            title: 'Register for "${e.title}"?',
            message: 'Registering shares your name and email with the event host.',
            confirmLabel: 'Register',
          ),
        );
        if (agreed != true || !mounted) return;
        await _communities.register(_user, e);
        _say('You\'re registered for "${e.title}".');
      }
    } on AuthException catch (err) {
      _say(err.message, NoticeTone.error);
    }
  }

  void _eventDetails(CommunityEvent e) =>
      _sheet<void>(_EventDetailsSheet(user: _user, event: e, onToggle: () => _toggleRegistration(e)));

  Future<void> _chooseEventType() async {
    const all = 'All Types';
    final picked = await showGlassPicker<String>(
      context,
      title: 'Event Type',
      options: [all, for (final t in EventType.values) t.label],
      label: (l) => l,
      selected: _eventType?.label ?? all,
    );
    if (picked == null) return;
    setState(() => _eventType = EventType.values.where((t) => t.label == picked).firstOrNull);
  }

  // ---- Layout ------------------------------------------------------------------

  bool _matches(Community c) {
    final q = _search.text.trim().toLowerCase();
    if (_domain != null && c.domain != _domain) return false;
    if (_topics.isNotEmpty && !c.topics.any(_topics.contains)) return false;
    if (q.isEmpty) return true;
    return [
      c.name,
      c.tagline,
      c.about,
      c.domain,
      ...c.topics,
      ...c.technologies,
    ].any((f) => f.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _communities,
      builder: (context, _) => ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(16, 8, 16, LiquidNavBar.clearance + MediaQuery.paddingOf(context).bottom),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Community',
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
                        ),
                      ),
                      SmallPillButton(label: 'Join via Invite Code', onPressed: _joinViaCode),
                    ],
                  ),
                  gap14,
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final tab in _tabs) ...[
                          GlassChip(
                            label: tab.label,
                            selected: _tab == tab,
                            onTap: () => setState(() {
                              _tab = tab;
                              _notice = null;
                            }),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                  gap14,
                  InlineNotice(message: _notice, tone: _tone),
                  StepSwitcher(
                    child: KeyedSubtree(key: ValueKey(_tab), child: _buildTab()),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTab() {
    switch (_tab) {
      case _Tab.mine:
        return SolverMyCommunity(
          user: _user,
          onSetPseudoName: () async {
            await _sheet<bool>(_PseudoNameSheet(user: _user));
            if (mounted) setState(() {});
          },
        );
      case _Tab.joined:
      case _Tab.all:
        final source = _tab == _Tab.joined ? _communities.joined(_user) : _communities.publicCommunities;
        final list = source.where(_matches).toList();
        final filters = (_domain == null ? 0 : 1) + _topics.length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: GlassTextField(
                    controller: _search,
                    hint: 'Search communities, topics or domains',
                    icon: Icons.search_rounded,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    GlassIconButton(
                      icon: Icons.filter_list_rounded,
                      tooltip: 'Filter by domain and topics',
                      onPressed: _filter,
                    ),
                    if (filters > 0)
                      Positioned(
                        right: -2,
                        top: -2,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                          child: Text(
                            '$filters',
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.primary),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            gap14,
            Text(
              _tab == _Tab.joined ? 'Your Communities (${list.length})' : 'All Communities (${list.length})',
              style: _heading,
            ),
            gap14,
            if (list.isEmpty)
              _Empty(
                _tab == _Tab.joined && source.isEmpty
                    ? 'You haven\'t joined any communities yet. Browse All to find one.'
                    : 'No communities match your search.',
              )
            else
              for (final c in list) _communityCard(c),
          ],
        );
      case _Tab.events:
        final list = _communities.events
            .where(
              (e) =>
                  (_eventType == null || e.type == _eventType) &&
                  (!_registeredOnly || _communities.isRegistered(_user, e)),
            )
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Community Events (${list.length})', style: _heading)),
                _Dropdown(label: _eventType?.label ?? 'All Types', onTap: _chooseEventType),
                const SizedBox(width: 8),
                _Dropdown(
                  label: _registeredOnly ? 'Registered' : 'All Events',
                  onTap: () => setState(() => _registeredOnly = !_registeredOnly),
                ),
              ],
            ),
            gap14,
            if (list.isEmpty) const _Empty('No events here yet.') else for (final e in list) _eventCard(e),
          ],
        );
      case _Tab.workshops:
      case _Tab.conferences:
        final type = _tab == _Tab.workshops ? EventType.workshop : EventType.conference;
        final list = _communities.events.where((e) => e.type == type).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Upcoming ${type.label}s (${list.length})', style: _heading),
            gap14,
            if (list.isEmpty)
              _Empty('No ${type.label.toLowerCase()}s scheduled.')
            else
              for (final e in list) _eventCard(e),
          ],
        );
    }
  }

  Widget _communityCard(Community c) {
    final member = _communities.isMember(_user, c);
    final owner = _communities.isOwner(_user, c);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassWell(
        radius: 20,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CommunityLogo(community: c, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            c.name,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                          if (owner) const _Badge('Owner'),
                          if (c.featured) const _Badge('Featured'),
                          if (c.private) const _Badge('Private'),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(Icons.group_outlined, size: 14, color: AppColors.white(0.8)),
                          const SizedBox(width: 4),
                          Text(
                            '${_communities.memberCount(_user, c)} members',
                            style: AppText.caption.copyWith(fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            gap8,
            _Badge(c.tagline),
            gap8,
            Text(
              c.about,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: AppColors.white(0.85)),
            ),
            gap14,
            Row(
              children: [
                Expanded(
                  child: member
                      ? SmallPillButton(label: 'View', primary: true, onPressed: () => _open(c))
                      : SmallPillButton(label: 'Join', primary: true, onPressed: () => _join(c)),
                ),
                const SizedBox(width: 8),
                if (!member) ...[
                  Expanded(
                    child: SmallPillButton(label: 'View Details', onPressed: () => _details(c)),
                  ),
                  const SizedBox(width: 8),
                ],
                // Members have no View Details button, so this opens the full
                // details (rules included) for them.
                GlassIconButton(
                  icon: Icons.info_outline_rounded,
                  tooltip: member ? 'Community details' : 'Community rules',
                  onPressed: () => member ? _details(c) : _rules(c),
                ),
                if (owner) ...[
                  const SizedBox(width: 8),
                  SmallPillButton(label: 'Manage', onPressed: () => showCommunityManage(context, _user, c)),
                ] else if (member) ...[
                  const SizedBox(width: 8),
                  SmallPillButton(label: 'Leave', onPressed: () => _leave(c)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _eventCard(CommunityEvent e) {
    final registered = _communities.isRegistered(_user, e);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassWell(
        radius: 20,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EventCoverBanner(event: e),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox.square(dimension: 40, child: GlassIconBadge(icon: Icons.event_outlined, size: 40)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.title,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                      Text(_communities.hostOf(e), style: AppText.caption.copyWith(fontSize: 12)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [_Badge(e.typeLabel), const SizedBox(height: 4), _Badge(e.mode.label)],
                ),
              ],
            ),
            gap8,
            _EventTimes(event: e),
            gap8,
            Text(
              e.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: AppColors.white(0.85)),
            ),
            gap8,
            Text(
              e.registrationOpen
                  ? '${e.registered} registered · Registration closes ${formatDay(e.registrationEnds)}'
                  : '${e.registered} registered · Registration closed',
              style: AppText.caption.copyWith(fontSize: 11.5),
            ),
            gap14,
            Row(
              children: [
                Expanded(
                  child: !e.registrationOpen
                      ? Opacity(
                          opacity: 0.5,
                          child: SmallPillButton(
                            label: registered ? 'Registered' : 'Registration Closed',
                            onPressed: () {},
                          ),
                        )
                      : SmallPillButton(
                          label: registered ? 'Cancel Registration' : 'Register',
                          primary: !registered,
                          onPressed: () => _toggleRegistration(e),
                        ),
                ),
                const SizedBox(width: 8),
                SmallPillButton(label: 'View Details', onPressed: () => _eventDetails(e)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const _heading = TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: Colors.white);
}

// ---- Pieces ------------------------------------------------------------------------

class _EventTimes extends StatelessWidget {
  const _EventTimes({required this.event});

  final CommunityEvent event;

  @override
  Widget build(BuildContext context) {
    final style = AppText.caption.copyWith(fontSize: 12, color: AppColors.white(0.85));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.calendar_today_outlined, size: 13, color: AppColors.white(0.85)),
            const SizedBox(width: 6),
            Flexible(child: Text('${formatDay(event.start)}, ${formatClock(event.start)}', style: style)),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Icon(Icons.flag_outlined, size: 13, color: AppColors.white(0.85)),
            const SizedBox(width: 6),
            Flexible(child: Text('Ends ${formatDay(event.end)}, ${formatClock(event.end)}', style: style)),
          ],
        ),
      ],
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
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
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
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: const TextStyle(fontSize: 12, color: Colors.white)),
                const Icon(Icons.keyboard_arrow_down_rounded, size: 17, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 22,
      padding: const EdgeInsets.all(20),
      child: Text(text, style: AppText.body, textAlign: TextAlign.center),
    );
  }
}

// ---- Sheets --------------------------------------------------------------------------

class _CommunityDetailsSheet extends StatelessWidget {
  const _CommunityDetailsSheet({
    required this.user,
    required this.community,
    required this.onJoin,
    required this.onOpen,
  });

  final AppUser user;
  final Community community;
  final VoidCallback onJoin;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = community;
    final service = CommunityService.instance;
    final member = service.isMember(user, c);
    return FlowSheetFrame(
      title: c.name,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CommunityLogo(community: c, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${service.memberCount(user, c)} members · ${c.domain}', style: AppText.caption),
                    const SizedBox(height: 6),
                    _Badge(c.tagline),
                  ],
                ),
              ),
            ],
          ),
          gap24,
          const Text('About', style: _label),
          gap8,
          Text(c.about, style: AppText.body),
          gap14,
          const Text('Scope', style: _label),
          gap8,
          Text(c.scope, style: AppText.body),
          gap14,
          const Text('Technologies', style: _label),
          gap8,
          Wrap(spacing: 6, runSpacing: 6, children: [for (final t in c.technologies) _Badge(t)]),
          gap14,
          const Text('Rules', style: _label),
          gap8,
          _RulesList(c.rules),
        ],
      ),
      footer: member
          ? PrimaryPillButton(
              label: 'Open Community',
              onPressed: () {
                Navigator.of(context).pop();
                onOpen();
              },
            )
          : PrimaryPillButton(
              label: 'Join',
              onPressed: () {
                Navigator.of(context).pop();
                onJoin();
              },
            ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

/// A community's rules, numbered, or "No Rules Yet" when it has none.
class _RulesList extends StatelessWidget {
  const _RulesList(this.rules);

  final List<String> rules;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final r in rules)
        if (r.trim().isNotEmpty) r.trim(),
    ];
    return GlassWell(
      radius: 18,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, rule) in shown.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text('${i + 1}. $rule', style: AppText.body),
            ),
          if (shown.isEmpty) Text('No Rules Yet', style: AppText.body),
        ],
      ),
    );
  }
}

/// Shows a community's rules. When [joining], the user must agree before
/// the Agree & Join button works. Pops `true` once joined.
class _RulesSheet extends StatefulWidget {
  const _RulesSheet({required this.user, required this.community, required this.joining});

  final AppUser user;
  final Community community;
  final bool joining;

  @override
  State<_RulesSheet> createState() => _RulesSheetState();
}

class _RulesSheetState extends State<_RulesSheet> {
  bool _agreed = false;
  bool _joining = false;
  String? _error;

  Future<void> _join() async {
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      await CommunityService.instance.join(widget.user, widget.community, acceptedRules: _agreed);
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.community;
    return FlowSheetFrame(
      title: 'Community Rules',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(c.name, style: AppText.label.copyWith(fontWeight: FontWeight.w600)),
          gap14,
          InlineNotice(message: _error, tone: NoticeTone.error),
          _RulesList(c.rules),
          if (widget.joining) ...[
            gap14,
            Row(
              children: [
                GlassCheckbox(value: _agreed, onChanged: (v) => setState(() => _agreed = v)),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _agreed = !_agreed),
                    child: Text(
                      'I have read and agree to abide by these rules.',
                      style: AppText.label.copyWith(fontSize: 13.5),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      footer: widget.joining
          ? Row(
              children: [
                Expanded(
                  child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PrimaryPillButton(label: 'Agree & Join', loading: _joining, onPressed: _agreed ? _join : null),
                ),
              ],
            )
          : GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class _InviteCodeSheet extends StatefulWidget {
  const _InviteCodeSheet();

  @override
  State<_InviteCodeSheet> createState() => _InviteCodeSheetState();
}

class _InviteCodeSheetState extends State<_InviteCodeSheet> {
  final _code = TextEditingController();
  Community? _preview;
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<Community?> _lookup() async {
    if (_code.text.trim().isEmpty) {
      setState(() => _error = 'Enter an invite code.');
      return null;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final c = await CommunityService.instance.findByInviteCode(_code.text);
      if (mounted) setState(() => _preview = c);
      return c;
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
      return null;
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _join() async {
    final c = _preview ?? await _lookup();
    if (c != null && mounted) Navigator.of(context).pop(c);
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return FlowSheetFrame(
      title: 'Join via Invite Code',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Invite Code',
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          gap8,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: GlassTextField(
                  controller: _code,
                  hint: 'Enter code',
                  icon: Icons.vpn_key_outlined,
                  textCapitalization: TextCapitalization.characters,
                  errorText: _error,
                  onChanged: (_) => setState(() {
                    _error = null;
                    _preview = null;
                  }),
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 9),
                child: _checking
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        ),
                      )
                    : SmallPillButton(label: 'Preview', onPressed: _lookup),
              ),
            ],
          ),
          if (preview != null) ...[
            gap14,
            GlassWell(
              radius: 18,
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  CommunityLogo(community: preview, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          preview.name,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                        Text(preview.tagline, style: AppText.caption),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: 'Join', onPressed: _checking ? null : _join),
          ),
        ],
      ),
    );
  }
}

class _PseudoNameSheet extends StatefulWidget {
  const _PseudoNameSheet({required this.user});

  final AppUser user;

  @override
  State<_PseudoNameSheet> createState() => _PseudoNameSheetState();
}

class _PseudoNameSheetState extends State<_PseudoNameSheet> {
  static final _pattern = RegExp(r'^[A-Za-z0-9._-]{3,20}$');
  final _name = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (!_pattern.hasMatch(name)) {
      setState(() => _error = 'Use 3–20 letters, numbers, dots, hyphens or underscores.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AuthService.instance.setPseudoName(name);
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Set Your Pseudo Name',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Communities never show your real identity. Everyone sees your pseudo name instead.',
            style: AppText.body,
          ),
          gap14,
          const InlineNotice(message: 'Important: once set, your pseudo name cannot be changed. Choose carefully!'),
          GlassTextField(
            controller: _name,
            hint: 'Enter a pseudo name',
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9._-]')),
              LengthLimitingTextInputFormatter(20),
            ],
            errorText: _error,
            onChanged: (_) => setState(() => _error = null),
          ),
          gap14,
          Align(
            alignment: Alignment.centerLeft,
            child: SmallPillButton(
              label: 'Auto-generate',
              onPressed: () async {
                try {
                  final name = await AuthService.instance.suggestPseudoName();
                  if (mounted) {
                    setState(() {
                      _name.text = name;
                      _error = null;
                    });
                  }
                } on AuthException catch (e) {
                  if (mounted) setState(() => _error = e.message);
                }
              },
            ),
          ),
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: 'Set & Continue', loading: _saving, onPressed: _save),
          ),
        ],
      ),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.domain, required this.topics});

  final String? domain;
  final Set<String> topics;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late String? _domain = widget.domain;
  late final _topics = {...widget.topics};

  @override
  Widget build(BuildContext context) {
    final service = CommunityService.instance;
    return FlowSheetFrame(
      title: 'Filter Communities',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Domain', style: _label),
          gap8,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final d in service.domains)
                GlassChip(
                  label: d,
                  selected: _domain == d,
                  onTap: () => setState(() => _domain = _domain == d ? null : d),
                ),
            ],
          ),
          gap24,
          const Text('Topics', style: _label),
          gap8,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in service.topics)
                GlassChip(
                  label: t,
                  selected: _topics.contains(t),
                  onTap: () => setState(() => _topics.contains(t) ? _topics.remove(t) : _topics.add(t)),
                ),
            ],
          ),
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Reset', onPressed: () => Navigator.of(context).pop((null, <String>{}))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: 'Apply', onPressed: () => Navigator.of(context).pop((_domain, _topics))),
          ),
        ],
      ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

class _EventDetailsSheet extends StatefulWidget {
  const _EventDetailsSheet({required this.user, required this.event, required this.onToggle});

  final AppUser user;
  final CommunityEvent event;
  final Future<void> Function() onToggle;

  @override
  State<_EventDetailsSheet> createState() => _EventDetailsSheetState();
}

class _EventDetailsSheetState extends State<_EventDetailsSheet> {
  bool _working = false;

  Future<void> _toggle() async {
    setState(() => _working = true);
    await widget.onToggle();
    if (mounted) setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final service = CommunityService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final registered = service.isRegistered(widget.user, e);
        return FlowSheetFrame(
          title: e.title,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EventPoster(event: e),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [_Badge(e.typeLabel), _Badge(e.mode.label), _Badge(service.hostOf(e))],
              ),
              gap14,
              _EventTimes(event: e),
              gap24,
              const Text('About', style: _label),
              gap8,
              Text(e.description, style: AppText.body),
              if (e.link != null) ...[
                gap14,
                const Text('Event Link', style: _label),
                gap8,
                GlassWell(
                  radius: 14,
                  padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(e.link!, style: AppText.caption.copyWith(color: Colors.white)),
                      ),
                      IconButton(
                        tooltip: 'Open link',
                        onPressed: () => launchUrl(Uri.parse(e.link!), mode: LaunchMode.externalApplication),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
              if (e.location != null) ...[
                gap14,
                const Text('Location', style: _label),
                gap8,
                Text(e.location!, style: AppText.body),
              ],
              gap14,
              const Text('Registrations', style: _label),
              gap8,
              Text('${e.registered} registered${registered ? ' (including you)' : ''}', style: AppText.body),
              Text(
                e.registrationOpen
                    ? 'Registration closes ${formatDay(e.registrationEnds)}, ${formatClock(e.registrationEnds)}.'
                    : 'Registration closed on ${formatDay(e.registrationEnds)}.',
                style: AppText.caption,
              ),
            ],
          ),
          footer: !e.registrationOpen
              ? GlassPillButton(label: 'Registration Closed', onPressed: null)
              : registered
              ? GlassPillButton(label: 'Cancel Registration', loading: _working, onPressed: _toggle)
              : PrimaryPillButton(label: 'Register', loading: _working, onPressed: _toggle),
        );
      },
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.title, required this.message, required this.confirmLabel});

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: title,
      body: Text(message, style: AppText.body),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: confirmLabel, onPressed: () => Navigator.of(context).pop(true)),
          ),
        ],
      ),
    );
  }
}
