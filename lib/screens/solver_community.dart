import 'package:flutter/material.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/community_logo.dart';
import 'booking_sheet.dart';
import 'community_manage.dart';
import 'community_screen.dart';

enum _View { communities, requests }

/// The solver's own communities and their requests to create new ones. Shown
/// as the "My Community" tab in Community; the rest of Community is the same
/// as for seekers.
class SolverMyCommunity extends StatefulWidget {
  const SolverMyCommunity({super.key, required this.user, required this.onSetPseudoName});

  final AppUser user;

  /// Communities are anonymous: opens the pseudo-name sheet.
  final Future<void> Function() onSetPseudoName;

  @override
  State<SolverMyCommunity> createState() => _SolverMyCommunityState();
}

class _SolverMyCommunityState extends State<SolverMyCommunity> {
  final _service = CommunityService.instance;
  _View _view = _View.communities;
  String? _notice;

  AppUser get _user => widget.user;

  Future<T?> _sheet<T>(Widget sheet) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => sheet,
  );

  Future<void> _request() async {
    final request = await _sheet<CommunityRequest>(_RequestSheet(user: _user));
    if (request != null && mounted) {
      setState(() {
        _view = _View.requests;
        _notice = '"${request.name}" was sent for admin review. We\'ll email you the decision.';
      });
    }
  }

  void _open(Community c) => Navigator.of(context).push(glassRoute(CommunityScreen(user: _user, community: c)));

  @override
  Widget build(BuildContext context) {
    final pseudo = _user.profile.pseudoName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Your pseudo name: ', style: AppText.caption.copyWith(fontSize: 13)),
            if (pseudo != null)
              Text(
                pseudo,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white),
              )
            else
              UnderlineLink(label: 'Set one', bold: true, onTap: widget.onSetPseudoName),
          ],
        ),
        gap14,
        Row(
          children: [
            for (final v in _View.values) ...[
              if (v != _View.values.first) const SizedBox(width: 8),
              Expanded(
                child: GlassOption(
                  height: 44,
                  radius: 14,
                  selected: _view == v,
                  onTap: () => setState(() {
                    _view = v;
                    _notice = null;
                  }),
                  child: Text(
                    v == _View.communities ? 'My Communities' : 'My Requests',
                    style: AppText.label.copyWith(fontSize: 13.5, fontWeight: _view == v ? FontWeight.w700 : null),
                  ),
                ),
              ),
            ],
          ],
        ),
        gap14,
        InlineNotice(message: _notice, tone: NoticeTone.success),
        StepSwitcher(
          child: KeyedSubtree(key: ValueKey(_view), child: _view == _View.communities ? _communities() : _requests()),
        ),
      ],
    );
  }

  Widget _communities() {
    final owned = _service.ownedAll(_user);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('My Communities (${owned.length})', style: _heading)),
            SmallPillButton(label: '+ Request New', primary: true, onPressed: _request),
          ],
        ),
        gap14,
        if (owned.isEmpty)
          GlassPanel(
            radius: 22,
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const GlassIconBadge(icon: Icons.groups_outlined, size: 64),
                gap14,
                Text(
                  'You don\'t run a community yet. Request one and it\'s created once the admin approves it.',
                  style: AppText.body,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else
          for (final c in owned)
            _OwnedCard(
              user: _user,
              community: c,
              onOpen: () => _open(c),
              onManage: () => showCommunityManage(context, _user, c),
            ),
      ],
    );
  }

  Widget _requests() {
    final list = _service.requests(_user);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('My Community Requests', style: _heading)),
            GlassIconButton(icon: Icons.refresh_rounded, tooltip: 'Refresh', onPressed: () => setState(() {})),
          ],
        ),
        gap14,
        Align(
          alignment: Alignment.centerRight,
          child: SmallPillButton(label: '+ Request New Community', primary: true, onPressed: _request),
        ),
        gap14,
        if (list.isEmpty)
          GlassPanel(
            radius: 22,
            padding: const EdgeInsets.all(20),
            child: Text('No requests yet.', style: AppText.body, textAlign: TextAlign.center),
          )
        else
          for (final r in list)
            _RequestCard(request: r, onOpen: r.communityId == null ? null : () => _open(_service.byId(r.communityId!))),
      ],
    );
  }

  static const _heading = TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: Colors.white);
}

// ---- Cards ----------------------------------------------------------------------------

class _OwnedCard extends StatelessWidget {
  const _OwnedCard({required this.user, required this.community, required this.onOpen, required this.onManage});

  final AppUser user;
  final Community community;
  final VoidCallback onOpen;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final c = community;
    final stats = CommunityService.instance.statsOf(user, c);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassWell(
        radius: 20,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CommunityLogo(community: c, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    c.name,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
                const _Badge('Owner'),
              ],
            ),
            gap14,
            _Field('Purpose', c.about),
            gap8,
            _Field('Scope', c.scope),
            gap8,
            const Text('Technologies', style: _label),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final t in c.technologies) _Badge(t)]),
            gap14,
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _Meta(Icons.group_outlined, '${stats.members} members'),
                _Meta(Icons.forum_outlined, '${stats.discussions} threads'),
                _Meta(Icons.event_outlined, '${stats.events} events'),
              ],
            ),
            gap14,
            Row(
              children: [
                Expanded(
                  child: SmallPillButton(label: 'Open Community', primary: true, onPressed: onOpen),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SmallPillButton(label: 'Manage', onPressed: onManage),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const _label = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white);
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request, this.onOpen});

  final CommunityRequest request;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final (icon, message, tone) = switch (r.status) {
      RequestStatus.pending => (
        Icons.hourglass_top_rounded,
        'Under admin review. We\'ll email you the decision.',
        NoticeTone.info,
      ),
      RequestStatus.approved => (
        Icons.check_circle_outline_rounded,
        'Approved - your community is live',
        NoticeTone.success,
      ),
      RequestStatus.rejected => (
        Icons.error_outline_rounded,
        'Rejected: ${r.rejectionReason ?? 'No reason given.'}',
        NoticeTone.error,
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassWell(
        radius: 20,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    r.name,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
                _Badge(r.status.label.toUpperCase()),
              ],
            ),
            gap14,
            _Field('Purpose', r.purpose),
            gap8,
            _Field('Scope', r.scope),
            gap8,
            const Text('Technologies', style: _OwnedCard._label),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final t in r.technologies) _Badge(t)]),
            gap14,
            // InlineNotice brings its own bottom spacing.
            Semantics(
              label: message,
              child: InlineNotice(message: message, tone: tone, persistent: true),
            ),
            Row(
              children: [
                Icon(icon, size: 14, color: AppColors.white(0.7)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Submitted ${formatDay(r.submittedAt)}', style: AppText.caption.copyWith(fontSize: 12)),
                ),
                if (onOpen != null) SmallPillButton(label: 'Open', onPressed: onOpen!),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Request sheet ---------------------------------------------------------------------

class _RequestSheet extends StatefulWidget {
  const _RequestSheet({required this.user});

  final AppUser user;

  @override
  State<_RequestSheet> createState() => _RequestSheetState();
}

class _RequestSheetState extends State<_RequestSheet> {
  final _name = TextEditingController();
  final _purpose = TextEditingController();
  final _scope = TextEditingController();
  final _tech = TextEditingController();
  final _errors = <String, String?>{};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _purpose, _scope, _tech]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _technologies => {
    for (final t in _tech.text.split(','))
      if (t.trim().isNotEmpty) t.trim(),
  }.toList();

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _errors
        ..['name'] = _name.text.trim().length < 3 ? 'Use at least 3 characters.' : null
        ..['purpose'] = _purpose.text.trim().length < 10 ? 'Use at least 10 characters.' : null
        ..['scope'] = _scope.text.trim().length < 10 ? 'Use at least 10 characters.' : null
        ..['tech'] = _technologies.isEmpty ? 'Add at least one technology.' : null;
    });
    if (_errors.values.any((e) => e != null)) return;
    setState(() => _saving = true);
    try {
      final request = await CommunityService.instance.submitRequest(
        widget.user,
        name: _name.text,
        purpose: _purpose.text,
        scope: _scope.text,
        technologies: _technologies,
      );
      if (mounted) Navigator.of(context).pop(request);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Request New Community',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          const Text('Community Name *', style: _label),
          gap8,
          GlassTextField(
            controller: _name,
            hint: 'Enter community name…',
            textCapitalization: TextCapitalization.words,
            errorText: _errors['name'],
            onChanged: (_) => setState(() => _errors['name'] = null),
          ),
          gap14,
          const Text('Purpose *', style: _label),
          gap8,
          GlassTextField(
            controller: _purpose,
            hint: 'What is the purpose of this community?',
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            errorText: _errors['purpose'],
            onChanged: (_) => setState(() => _errors['purpose'] = null),
          ),
          gap14,
          const Text('Scope *', style: _label),
          gap8,
          GlassTextField(
            controller: _scope,
            hint: 'What topics and activities will this community cover?',
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            errorText: _errors['scope'],
            onChanged: (_) => setState(() => _errors['scope'] = null),
          ),
          gap14,
          const Text('Technology *', style: _label),
          gap8,
          GlassTextField(
            controller: _tech,
            hint: 'Enter technologies (comma separated)',
            errorText: _errors['tech'],
            onChanged: (_) => setState(() => _errors['tech'] = null),
          ),
          if (_technologies.isNotEmpty) ...[
            gap8,
            Wrap(spacing: 6, runSpacing: 6, children: [for (final t in _technologies) _Badge(t)]),
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
            child: PrimaryPillButton(label: 'Submit Request', loading: _saving, onPressed: _submit),
          ),
        ],
      ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

// ---- Pieces ---------------------------------------------------------------------------

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: _OwnedCard._label),
        const SizedBox(height: 2),
        Text(value, style: AppText.caption.copyWith(fontSize: 13, color: AppColors.white(0.85))),
      ],
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
        Icon(icon, size: 14, color: AppColors.white(0.8)),
        const SizedBox(width: 4),
        Text(text, style: AppText.caption.copyWith(fontSize: 12)),
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
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.white(0.35)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
      ),
    );
  }
}
