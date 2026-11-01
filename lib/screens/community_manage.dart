import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/community_logo.dart';
import '../widgets/event_artwork.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import 'booking_sheet.dart';

Future<T?> _sheet<T>(BuildContext context, Widget sheet) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: 0.35),
  builder: (_) => sheet,
);

/// The date and time pickers in the app's colours.
ThemeData _pickerTheme(BuildContext context) => Theme.of(context).copyWith(
  colorScheme: const ColorScheme.dark(
    primary: Colors.white,
    onPrimary: AppColors.primary,
    surface: AppColors.primary,
    onSurface: Colors.white,
  ),
  dialogTheme: const DialogThemeData(backgroundColor: AppColors.primary),
);

/// Opens the owner's tools for [community].
Future<void> showCommunityManage(BuildContext context, AppUser owner, Community community) =>
    _sheet<void>(context, CommunityManageSheet(owner: owner, community: community));

enum _Section {
  overview('Overview'),
  invite('Invite'),
  members('Members'),
  events('Events'),
  moderate('Moderate');

  const _Section(this.label);
  final String label;
}

/// Everything the owner runs: activity, the invite code and link, members
/// (kick or ban), community events and moderation.
class CommunityManageSheet extends StatefulWidget {
  const CommunityManageSheet({super.key, required this.owner, required this.community});

  final AppUser owner;
  final Community community;

  @override
  State<CommunityManageSheet> createState() => _CommunityManageSheetState();
}

class _CommunityManageSheetState extends State<CommunityManageSheet> {
  final _service = CommunityService.instance;
  _Section _section = _Section.overview;
  String? _notice;

  Community get _c => widget.community;

  void _say(String text) => setState(() => _notice = text);

  @override
  void initState() {
    super.initState();
    // Member ids, bans and the invite code come from the server.
    _service
        .prepareOwnerTools(widget.owner, _c)
        .then(
          (_) {
            if (mounted) setState(() {});
          },
          onError: (Object e) {
            if (mounted) _say(e is AuthException ? e.message : 'Couldn\'t load your community tools.');
          },
        );
  }

  /// Runs an owner action and reports a failure.
  Future<bool> _run(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on AuthException catch (e) {
      if (mounted) _say(e.message);
      return false;
    }
  }

  Future<void> _copy(String value, String what) async {
    await Clipboard.setData(ClipboardData(text: value));
    _say('$what copied.');
  }

  Future<void> _remove(String member, {required bool ban}) async {
    final confirmed = await _sheet<bool>(
      context,
      _Confirm(
        title: ban ? 'Ban $member?' : 'Kick $member?',
        message: ban
            ? 'They\'ll be removed and can\'t join ${_c.name} again unless you unban them.'
            : 'They\'ll be removed from ${_c.name}. They can join again later.',
        label: ban ? 'Ban' : 'Kick',
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!await _run(() => _service.removeMember(widget.owner, _c, member, ban: ban)) || !mounted) return;
    _say(ban ? '$member was banned.' : '$member was removed.');
  }

  bool _uploadingLogo = false;

  static const _logoTypes = ['png', 'jpg', 'jpeg', 'webp', 'gif'];
  static const _maxLogo = 2 * 1024 * 1024;

  /// Uploads the community's logo, or replaces it.
  Future<void> _pickLogo() async {
    if (_uploadingLogo) return;
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: _logoTypes);
    if (file == null || !mounted) return;
    final extension = (file.extension ?? file.name.split('.').last).toLowerCase();
    final bytes = await file.length();
    if (!mounted) return;
    final path = file.path;
    final problem = !_logoTypes.contains(extension)
        ? 'Choose a PNG, JPG, WebP or GIF picture.'
        : bytes != null && bytes > _maxLogo
        ? 'The logo must be under 2 MB. Choose a smaller picture.'
        : path == null
        ? 'Couldn\'t read that picture. Try another one.'
        : null;
    if (problem != null) return _say(problem);
    final hadLogo = _c.logoUrl != null;
    setState(() => _uploadingLogo = true);
    final ok = await _run(() => _service.uploadLogo(widget.owner, _c, path: path!, fileName: file.name));
    if (!mounted) return;
    setState(() => _uploadingLogo = false);
    if (ok) _say(hadLogo ? 'Logo updated.' : 'Logo added. Members see it on your community.');
  }

  Future<void> _createEvent() async {
    final event = await _sheet<CommunityEvent>(context, _EventFormSheet(owner: widget.owner, community: _c));
    final artworkError = _service.lastArtworkError;
    if (event != null && mounted && artworkError != null) {
      return _say('"${event.title}" created. $artworkError You can add it from Events.');
    }
    if (event != null && mounted) _say('"${event.title}" created. Members can register from Events.');
  }

  /// The server says whether it can still be edited (not started, completed
  /// or cancelled) before the form opens.
  Future<void> _editEvent(CommunityEvent e) async {
    String? blocked;
    final ok = await _run(() async => blocked = await _service.eventEditBlocked(e));
    if (!ok || !mounted) return;
    if (blocked != null) return _say(blocked!);
    final saved = await _sheet<CommunityEvent>(context, _EventFormSheet(owner: widget.owner, community: _c, event: e));
    if (saved != null && mounted) _say('"${saved.title}" updated. Members are told it changed.');
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Manage ${_c.name}',
      body: ListenableBuilder(
        listenable: _service,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final s in _Section.values) ...[
                    GlassChip(
                      label: s.label,
                      selected: _section == s,
                      onTap: () => setState(() {
                        _section = s;
                        _notice = null;
                      }),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            gap14,
            InlineNotice(message: _notice, tone: NoticeTone.success),
            StepSwitcher(
              child: KeyedSubtree(
                key: ValueKey(_section),
                child: switch (_section) {
                  _Section.overview => _overview(),
                  _Section.invite => _invite(),
                  _Section.members => _members(),
                  _Section.events => _events(),
                  _Section.moderate => _ModerationPanel(owner: widget.owner, community: _c),
                },
              ),
            ),
          ],
        ),
      ),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }

  Widget _overview() {
    final stats = _service.statsOf(widget.owner, _c);
    final latest = [
      for (final d in _c.discussions)
        for (final m in d.messages) (d, m),
    ]..sort((a, b) => b.$2.sentAt.compareTo(a.$2.sentAt));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CommunityLogo(community: _c, size: 56),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Community logo', style: _label),
                    const SizedBox(height: 2),
                    Text('PNG, JPG, WebP or GIF, up to 2 MB.', style: AppText.caption.copyWith(fontSize: 11.5)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _uploadingLogo
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                      ),
                    )
                  : SmallPillButton(label: _c.logoUrl == null ? 'Upload' : 'Change', onPressed: _pickLogo),
            ],
          ),
        ),
        gap14,
        OptionGrid(
          columns: 3,
          spacing: 8,
          children: [
            _Stat('Members', '${stats.members}', Icons.group_outlined),
            _Stat('Threads', '${stats.discussions}', Icons.forum_outlined),
            _Stat('Messages', '${stats.messages}', Icons.chat_bubble_outline_rounded),
          ],
        ),
        gap8,
        OptionGrid(
          columns: 2,
          spacing: 8,
          children: [
            _Stat('Events', '${stats.events}', Icons.event_outlined),
            _Stat('Registrations', '${stats.registrations}', Icons.how_to_reg_outlined),
          ],
        ),
        gap14,
        const Text('Recent activity', style: _label),
        gap8,
        if (latest.isEmpty)
          Text('No messages yet. Share your invite code to bring members in.', style: AppText.caption)
        else
          GlassWell(
            radius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              children: [
                for (final (d, m) in latest.take(5))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GlassAvatar(initials: m.author[0].toUpperCase(), size: 30),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${m.author} in ${d.title}', style: AppText.caption.copyWith(fontSize: 11.5)),
                              Text(
                                m.fileName ?? m.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.label.copyWith(fontSize: 13.5),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _invite() {
    final code = _service.inviteCodeOf(_c);
    final link = _service.inviteLink(_c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Anyone with the code or link can join ${_c.name} directly, even if it isn\'t listed publicly.',
          style: AppText.caption,
        ),
        gap14,
        const Text('Invite code', style: _label),
        gap8,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  code,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3,
                    color: Colors.white,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy code',
                onPressed: () => _copy(code, 'Invite code'),
                icon: const Icon(Icons.copy_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
        gap14,
        const Text('Community link', style: _label),
        gap8,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Expanded(child: Text(link, style: AppText.label.copyWith(fontSize: 13.5))),
              IconButton(
                tooltip: 'Copy link',
                onPressed: () => _copy(link, 'Community link'),
                icon: const Icon(Icons.copy_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
        gap14,
        GlassPillButton(
          label: 'Generate New Code',
          icon: Icons.refresh_rounded,
          onPressed: () async {
            if (!await _run(() => _service.renewInvite(widget.owner, _c)) || !mounted) return;
            _say('New invite code created. The old code and link no longer work.');
          },
        ),
      ],
    );
  }

  Widget _members() {
    final members = List.of(_c.members)..sort();
    final banned = _c.banned.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${_service.memberCount(widget.owner, _c)} members, including you. Members appear by pseudo name.',
          style: AppText.caption,
        ),
        gap14,
        if (members.isEmpty)
          Text('No other members yet.', style: AppText.body, textAlign: TextAlign.center)
        else
          for (final m in members)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassWell(
                radius: 16,
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(
                  children: [
                    GlassAvatar(initials: m[0].toUpperCase(), size: 34),
                    const SizedBox(width: 10),
                    Expanded(child: Text(m, style: AppText.label.copyWith(fontSize: 14))),
                    SmallPillButton(label: 'Kick', onPressed: () => _remove(m, ban: false)),
                    const SizedBox(width: 6),
                    SmallPillButton(label: 'Ban', onPressed: () => _remove(m, ban: true)),
                  ],
                ),
              ),
            ),
        if (banned.isNotEmpty) ...[
          gap14,
          const Text('Banned', style: _label),
          gap8,
          for (final m in banned)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassWell(
                radius: 16,
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.block_rounded, size: 20, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(child: Text(m, style: AppText.label.copyWith(fontSize: 14))),
                    SmallPillButton(
                      label: 'Unban',
                      onPressed: () async {
                        if (!await _run(() => _service.unban(widget.owner, _c, m)) || !mounted) return;
                        _say('$m can join again.');
                      },
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// Events whose artwork is being uploaded.
  final _uploadingArtwork = <String>{};

  Future<void> _changeArtwork(CommunityEvent e, {required bool cover}) async {
    final file = await pickEventArtwork(onError: _say);
    if (file == null || !mounted) return;
    setState(() => _uploadingArtwork.add(e.id));
    final ok = await _run(
      () => _service.uploadEventArtwork(widget.owner, _c, e, cover: cover, path: file.path, fileName: file.name),
    );
    if (!mounted) return;
    setState(() => _uploadingArtwork.remove(e.id));
    if (ok) _say(cover ? 'Cover image updated.' : 'Poster updated.');
  }

  Widget _events() {
    final events = _service.eventsOf(_c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PrimaryPillButton(label: 'Create Event', onPressed: _createEvent),
        gap8,
        Text(
          'After registration closes, the list of registered members is emailed to you.',
          style: AppText.caption.copyWith(fontSize: 12),
          textAlign: TextAlign.center,
        ),
        gap14,
        if (events.isEmpty)
          Text('No events yet.', style: AppText.body, textAlign: TextAlign.center)
        else
          for (final e in events)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GlassWell(
                radius: 18,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    EventCoverBanner(event: e),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            e.title,
                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                        ),
                        _Badge(e.typeLabel),
                        const SizedBox(width: 6),
                        _Badge(e.mode.label),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('${formatDay(e.start)} · ${formatClock(e.start)}', style: AppText.caption),
                    Text(
                      '${e.registered}${e.memberLimit == null ? '' : ' / ${e.memberLimit}'} registered · '
                      '${e.registrationNotStarted
                          ? 'Registration opens ${formatDay(e.registrationStarts!)}'
                          : e.registrationOpen
                          ? 'Registration open until ${formatDay(e.registrationEnds)}'
                          : 'Registration closed'}',
                      style: AppText.caption.copyWith(fontSize: 12),
                    ),
                    // Artwork can change until the event ends.
                    if (DateTime.now().isBefore(e.end)) ...[
                      gap8,
                      _uploadingArtwork.contains(e.id)
                          ? Text('Uploading…', style: AppText.caption.copyWith(fontSize: 12))
                          : Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                // Details can change any number of times until it starts.
                                if (DateTime.now().isBefore(e.start))
                                  SmallPillButton(label: 'Edit', primary: true, onPressed: () => _editEvent(e)),
                                SmallPillButton(
                                  label: e.coverUrl == null ? 'Add cover' : 'Change cover',
                                  onPressed: () => _changeArtwork(e, cover: true),
                                ),
                                SmallPillButton(
                                  label: e.posterUrl == null ? 'Add poster' : 'Change poster',
                                  onPressed: () => _changeArtwork(e, cover: false),
                                ),
                              ],
                            ),
                    ],
                  ],
                ),
              ),
            ),
      ],
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

/// Event name, description, type, mode, event and registration windows, link
/// or venue, and member limit. Creates an event, or edits [event] (filled in
/// from it). Pops the created or saved event.
class _EventFormSheet extends StatefulWidget {
  const _EventFormSheet({required this.owner, required this.community, this.event});

  final AppUser owner;
  final Community community;

  /// The event being edited; null when creating one.
  final CommunityEvent? event;

  @override
  State<_EventFormSheet> createState() => _EventFormSheetState();
}

class _EventFormSheetState extends State<_EventFormSheet> {
  late final CommunityEvent? _editing = widget.event;
  late final _title = TextEditingController(text: _editing?.title);
  late final _description = TextEditingController(text: _editing?.description);
  late final _link = TextEditingController(text: _editing?.link);
  late final _location = TextEditingController(text: _editing?.location);
  late final _limit = TextEditingController(text: _editing?.memberLimit?.toString());
  late final _typeOther = TextEditingController(text: _editing?.typeOther);
  late EventType _type = _editing?.type ?? EventType.workshop;
  late EventMode _mode = _editing?.mode ?? EventMode.online;
  late final _times = <String, DateTime?>{
    'start': _editing?.start,
    'end': _editing?.end,
    'regStart': _editing?.registrationStarts,
    'regEnd': _editing?.registrationEnds,
  };
  bool _saving = false;
  String? _error;

  /// Optional artwork, uploaded once the event is created.
  ({String path, String name})? _cover;
  ({String path, String name})? _poster;

  Future<void> _pickArtwork({required bool cover}) async {
    final file = await pickEventArtwork(onError: (message) => setState(() => _error = message));
    if (file == null || !mounted) return;
    setState(() {
      _error = null;
      cover ? _cover = file : _poster = file;
    });
  }

  /// A picker for the cover or poster, with a preview once chosen.
  Widget _artworkField({required bool cover}) {
    final file = cover ? _cover : _poster;
    final title = cover ? 'Cover image (optional)' : 'Poster (optional)';
    final hint = cover
        ? 'A wide banner for event cards, e.g. 1600×700'
        : 'A portrait flyer shown in full in the details, e.g. 1080×1350';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: _label),
        gap8,
        if (file == null)
          GlassSelectField(
            value: null,
            hint: hint,
            trailingIcon: Icons.add_photo_alternate_outlined,
            onTap: () => _pickArtwork(cover: cover),
          )
        else ...[
          Center(
            child: SizedBox(
              width: cover ? double.infinity : 160,
              child: ArtworkPreview(path: file.path, aspectRatio: cover ? 16 / 7 : 4 / 5),
            ),
          ),
          gap8,
          Row(
            children: [
              Expanded(
                child: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(fontSize: 12),
                ),
              ),
              SmallPillButton(
                label: 'Change',
                onPressed: () => _pickArtwork(cover: cover),
              ),
              const SizedBox(width: 6),
              SmallPillButton(label: 'Remove', onPressed: () => setState(() => cover ? _cover = null : _poster = null)),
            ],
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    for (final c in [_title, _description, _link, _location, _limit, _typeOther]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick(String key) async {
    final now = DateTime.now();
    final current = _times[key];
    final date = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      builder: (context, child) => Theme(data: _pickerTheme(context), child: child!),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: current == null ? const TimeOfDay(hour: 10, minute: 0) : TimeOfDay.fromDateTime(current),
      builder: (context, child) => Theme(data: _pickerTheme(context), child: child!),
    );
    if (time == null || !mounted) return;
    setState(() {
      _times[key] = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      _error = null;
    });
  }

  Future<void> _create() async {
    final missing = _times.values.any((t) => t == null);
    final limitText = _limit.text.trim();
    final limit = limitText.isEmpty ? null : int.tryParse(limitText);
    if (_type == EventType.other && _typeOther.text.trim().length < 2) {
      setState(() => _error = 'Enter the type of event.');
      return;
    }
    if (missing) {
      setState(() => _error = 'Choose the event and registration dates and times.');
      return;
    }
    if (limitText.isNotEmpty && limit == null) {
      setState(() => _error = 'Enter the member limit as a number.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final service = CommunityService.instance;
      final editing = _editing;
      final event = editing != null
          ? await service.updateEvent(
              widget.owner,
              widget.community,
              editing,
              type: _type,
              typeOther: _type == EventType.other ? _typeOther.text : null,
              mode: _mode,
              title: _title.text,
              description: _description.text,
              start: _times['start']!,
              end: _times['end']!,
              registrationStarts: _times['regStart']!,
              registrationEnds: _times['regEnd']!,
              link: _link.text,
              location: _mode == EventMode.online ? null : _location.text,
              memberLimit: limit,
            )
          : await service.createEvent(
              widget.owner,
              widget.community,
              type: _type,
              typeOther: _type == EventType.other ? _typeOther.text : null,
              mode: _mode,
              title: _title.text,
              description: _description.text,
              start: _times['start']!,
              end: _times['end']!,
              registrationStarts: _times['regStart']!,
              registrationEnds: _times['regEnd']!,
              link: _link.text,
              location: _mode == EventMode.online ? null : _location.text,
              memberLimit: limit,
              cover: _cover,
              poster: _poster,
            );
      if (mounted) Navigator.of(context).pop(event);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget when(String label, String key) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: AppText.caption.copyWith(fontSize: 12)),
          const SizedBox(height: 6),
          GlassSelectField(
            value: _times[key] == null ? null : '${formatDay(_times[key]!)}\n${formatClock(_times[key]!)}',
            hint: 'Select',
            onTap: () => _pick(key),
          ),
        ],
      ),
    );
    return FlowSheetFrame(
      title: _editing == null ? 'Create Event' : 'Edit Event',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          const Text('Event name *', style: _label),
          gap8,
          GlassTextField(
            controller: _title,
            hint: 'e.g. Go Concurrency Workshop',
            textCapitalization: TextCapitalization.words,
          ),
          gap14,
          const Text('Description *', style: _label),
          gap8,
          GlassTextField(
            controller: _description,
            hint: 'What will members learn or do?',
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
          ),
          gap14,
          const Text('Event type *', style: _label),
          gap8,
          GlassSelectField(
            value: _type.label,
            hint: 'Select type',
            onTap: () async {
              final picked = await showGlassPicker(
                context,
                title: 'Event Type',
                options: EventType.values,
                label: (t) => t.label,
                selected: _type,
              );
              if (picked != null) setState(() => _type = picked);
            },
          ),
          if (_type == EventType.other) ...[
            gap8,
            GlassTextField(
              controller: _typeOther,
              hint: 'Enter the type of event, e.g. Bootcamp',
              textCapitalization: TextCapitalization.words,
              inputFormatters: [LengthLimitingTextInputFormatter(50)],
            ),
          ],
          gap14,
          const Text('Format *', style: _label),
          gap8,
          OptionGrid(
            columns: 3,
            spacing: 8,
            children: [
              for (final m in EventMode.values)
                GlassOption(
                  height: 44,
                  selected: _mode == m,
                  onTap: () => setState(() => _mode = m),
                  child: Text(m.label, style: AppText.label.copyWith(fontSize: 13.5)),
                ),
            ],
          ),
          gap14,
          const Text('Event time *', style: _label),
          gap8,
          Row(children: [when('Starts', 'start'), const SizedBox(width: 10), when('Ends', 'end')]),
          gap14,
          const Text('Registration *', style: _label),
          gap8,
          Row(children: [when('Opens', 'regStart'), const SizedBox(width: 10), when('Closes', 'regEnd')]),
          // Every event can have a link: required to join online and hybrid
          // ones, optional (e.g. a registration or info page) for offline ones.
          gap14,
          Text(_mode == EventMode.offline ? 'Event link (optional)' : 'Event link *', style: _label),
          gap8,
          GlassTextField(
            controller: _link,
            hint: _mode == EventMode.offline ? 'https:// (registration or info page)' : 'https://',
            icon: Icons.link_rounded,
            keyboardType: TextInputType.url,
          ),
          if (_mode != EventMode.online) ...[
            gap14,
            const Text('Venue *', style: _label),
            gap8,
            GlassTextField(
              controller: _location,
              hint: 'Where is it happening?',
              icon: Icons.place_outlined,
              textCapitalization: TextCapitalization.words,
            ),
          ],
          gap14,
          const Text('Member limit (optional)', style: _label),
          gap8,
          GlassTextField(
            controller: _limit,
            hint: 'No limit',
            icon: Icons.group_outlined,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          // When editing, the cover and poster change from the event's card.
          if (_editing == null) ...[gap14, _artworkField(cover: true), gap14, _artworkField(cover: false)],
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
              label: _editing == null ? 'Create Event' : 'Save Changes',
              loading: _saving,
              onPressed: _create,
            ),
          ),
        ],
      ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

// ---- Moderation ------------------------------------------------------------------------

enum _ModTab {
  members('Members'),
  bans('Bans'),
  threads('Threads'),
  rules('Rules'),
  activity('Activity');

  const _ModTab(this.label);
  final String label;
}

/// The owner's moderation tools: kick or ban members, lift bans, pin, lock
/// or delete threads, set the rules and read the activity log.
class _ModerationPanel extends StatefulWidget {
  const _ModerationPanel({required this.owner, required this.community});

  final AppUser owner;
  final Community community;

  @override
  State<_ModerationPanel> createState() => _ModerationPanelState();
}

class _ModerationPanelState extends State<_ModerationPanel> {
  final _service = CommunityService.instance;
  late final _rules = TextEditingController(text: _c.rules.join('\n'));
  _ModTab _tab = _ModTab.members;
  bool _loading = true;
  bool _savingRules = false;
  String? _notice;
  String? _error;

  Community get _c => widget.community;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _rules.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    try {
      await _service.loadModeration(widget.owner, _c);
      if (mounted) setState(() => _error = null);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn\'t load the moderation tools. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _say(String text) => setState(() {
    _notice = text;
    _error = null;
  });

  /// Runs an owner action, reports a failure and refreshes the log.
  Future<bool> _run(Future<void> Function() action) async {
    try {
      await action();
      _refreshActivity();
      return true;
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
      return false;
    }
  }

  /// The activity log picks up the action in the background.
  void _refreshActivity() => _service.loadModeration(widget.owner, _c).catchError((Object _) {});

  Future<void> _remove(String member, {required bool ban}) async {
    final done = await _sheet<bool>(
      context,
      _RemoveMemberSheet(owner: widget.owner, community: _c, member: member, ban: ban),
    );
    if (done != true || !mounted) return;
    _refreshActivity();
    _say(ban ? '$member was banned.' : '$member was removed.');
  }

  Future<void> _unban(CommunityBan ban) async {
    final confirmed = await _sheet<bool>(
      context,
      _Confirm(
        title: 'Unban ${ban.member}?',
        message: '${ban.member} will be able to join ${_c.name} again.',
        label: 'Unban',
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!await _run(() => _service.unban(widget.owner, _c, ban.member)) || !mounted) return;
    _say('${ban.member} can join again.');
  }

  Future<void> _deleteThread(Discussion d) async {
    final done = await _sheet<bool>(context, _DeleteThreadSheet(owner: widget.owner, community: _c, discussion: d));
    if (done != true || !mounted) return;
    _refreshActivity();
    _say('"${d.title}" was deleted.');
  }

  Future<void> _saveRules() async {
    setState(() => _savingRules = true);
    final ok = await _run(() => _service.setRules(widget.owner, _c, _rules.text.split('\n')));
    if (!mounted) return;
    setState(() => _savingRules = false);
    if (ok) {
      _rules.text = _c.rules.join('\n');
      _say(_c.rules.isEmpty ? 'Rules cleared.' : 'Rules updated. Members see them right away.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final t in _ModTab.values) ...[
                _SubTab(
                  label: t == _ModTab.bans && _c.bans.isNotEmpty ? '${t.label} (${_c.bans.length})' : t.label,
                  selected: _tab == t,
                  onTap: () => setState(() {
                    _tab = t;
                    _notice = null;
                    _error = null;
                  }),
                ),
                const SizedBox(width: 6),
              ],
            ],
          ),
        ),
        gap14,
        InlineNotice(message: _error, tone: NoticeTone.error),
        InlineNotice(message: _notice, tone: NoticeTone.success),
        if (_loading && _tab != _ModTab.rules)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
              ),
            ),
          )
        else
          switch (_tab) {
            _ModTab.members => _members(),
            _ModTab.bans => _bans(),
            _ModTab.threads => _threads(),
            _ModTab.rules => _rulesEditor(),
            _ModTab.activity => _activity(),
          },
      ],
    );
  }

  Widget _members() {
    final members = List.of(_c.members)..sort();
    if (members.isEmpty) return _empty('No other members yet.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Kicked members can join again. Banned members can\'t until the ban ends or you lift it.',
          style: AppText.caption,
        ),
        gap14,
        for (final m in members)
          _Tile(
            leading: GlassAvatar(initials: m[0].toUpperCase(), size: 34),
            title: m,
            actions: [
              SmallPillButton(label: 'Kick', onPressed: () => _remove(m, ban: false)),
              SmallPillButton(label: 'Ban', onPressed: () => _remove(m, ban: true)),
            ],
          ),
      ],
    );
  }

  Widget _bans() {
    final bans = _c.bans.isNotEmpty
        ? _c.bans
        : [for (final m in _c.banned) CommunityBan(userId: m, member: m, reason: '', bannedAt: DateTime.now())];
    if (bans.isEmpty) return _empty('No one is banned.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in bans)
          _Tile(
            leading: const Icon(Icons.block_rounded, size: 22, color: Colors.white),
            title: b.member,
            lines: [
              if (b.reason.isNotEmpty) 'Reason: ${b.reason}',
              b.permanent
                  ? 'Permanent ban'
                  : b.ended
                  ? 'Ban ended ${formatDay(b.expiresAt!)}'
                  : 'Banned until ${formatDay(b.expiresAt!)} · ${formatClock(b.expiresAt!)}',
              if (_c.bans.isNotEmpty)
                'Banned ${relativeTime(b.bannedAt)}${b.bannedBy == null ? '' : ' by ${b.bannedBy}'}',
            ],
            actions: [SmallPillButton(label: 'Unban', onPressed: () => _unban(b))],
          ),
      ],
    );
  }

  Widget _threads() {
    final threads = _service.discussionsOf(_c);
    if (threads.isEmpty) return _empty('No threads yet.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Pinned threads show first. Locked threads accept no new messages, except yours.', style: AppText.caption),
        gap14,
        for (final d in threads)
          _Tile(
            leading: Icon(
              d.general ? Icons.forum_rounded : (d.locked ? Icons.lock_outline_rounded : Icons.forum_outlined),
              size: 22,
              color: Colors.white,
            ),
            title: d.title,
            badges: [if (d.general) 'General', if (d.pinned) 'Pinned', if (d.locked) 'Locked'],
            lines: [if (d.description.trim().isNotEmpty) d.description.trim(), 'Started ${relativeTime(d.createdAt)}'],
            actions: [
              if (!d.general)
                SmallPillButton(
                  label: d.pinned ? 'Unpin' : 'Pin',
                  onPressed: () async {
                    final pinned = !d.pinned;
                    if (!await _run(() => _service.togglePin(widget.owner, _c, d)) || !mounted) return;
                    _say(pinned ? '"${d.title}" is pinned.' : '"${d.title}" is unpinned.');
                  },
                ),
              SmallPillButton(
                label: d.locked ? 'Unlock' : 'Lock',
                onPressed: () async {
                  final locked = !d.locked;
                  if (!await _run(() => _service.toggleLock(widget.owner, _c, d)) || !mounted) return;
                  _say(locked ? '"${d.title}" is locked.' : '"${d.title}" is open again.');
                },
              ),
              if (!d.general) SmallPillButton(label: 'Delete', onPressed: () => _deleteThread(d)),
            ],
          ),
      ],
    );
  }

  Widget _rulesEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Members accept these rules when they join. Write one rule per line; leave it empty to clear them.',
          style: AppText.caption,
        ),
        gap14,
        GlassTextField(
          controller: _rules,
          hint: 'Be respectful\nStay on topic\nNo spam',
          maxLines: 8,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: [LengthLimitingTextInputFormatter(5000)],
        ),
        gap14,
        PrimaryPillButton(label: 'Save Rules', loading: _savingRules, onPressed: _saveRules),
      ],
    );
  }

  Widget _activity() {
    final log = _c.activity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: SmallPillButton(label: 'Refresh', onPressed: _load),
        ),
        gap8,
        if (log.isEmpty)
          _empty('No activity yet.')
        else
          for (final a in log)
            _Tile(
              leading: const Icon(Icons.history_rounded, size: 22, color: Colors.white),
              title: a.label,
              lines: [
                if (a.member != null) 'Member: ${a.member}',
                if (a.performer != null) 'By: ${a.performer}',
                if (a.note != null) a.note!,
                relativeTime(a.at),
              ],
            ),
      ],
    );
  }

  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(text, style: AppText.body, textAlign: TextAlign.center),
  );
}

/// Kicks [member] with an optional reason, or bans them with a reason and an
/// optional end date (permanent when blank). Pops true once done.
class _RemoveMemberSheet extends StatefulWidget {
  const _RemoveMemberSheet({required this.owner, required this.community, required this.member, required this.ban});

  final AppUser owner;
  final Community community;
  final String member;
  final bool ban;

  @override
  State<_RemoveMemberSheet> createState() => _RemoveMemberSheetState();
}

class _RemoveMemberSheetState extends State<_RemoveMemberSheet> {
  final _reason = TextEditingController();
  DateTime? _until;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pickEnd() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _until ?? now.add(const Duration(days: 7)),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5),
      builder: (context, child) => Theme(data: _pickerTheme(context), child: child!),
    );
    if (date == null || !mounted) return;
    // The ban lasts through the chosen day.
    setState(() {
      _until = DateTime(date.year, date.month, date.day, 23, 59);
      _error = null;
    });
  }

  Future<void> _submit() async {
    final reason = _reason.text.trim();
    if (widget.ban && reason.length < 5) {
      setState(() => _error = 'Give a reason for the ban (at least 5 characters).');
      return;
    }
    if (!widget.ban && reason.isNotEmpty && reason.length < 5) {
      setState(() => _error = 'The reason needs at least 5 characters, or leave it blank.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await CommunityService.instance.removeMember(
        widget.owner,
        widget.community,
        widget.member,
        ban: widget.ban,
        reason: reason,
        until: widget.ban ? _until : null,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ban = widget.ban;
    final name = widget.community.name;
    return FlowSheetFrame(
      title: ban ? 'Ban ${widget.member}' : 'Kick ${widget.member}',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          Text(
            ban
                ? 'They\'ll be removed and can\'t join $name again until the ban ends or you unban them.'
                : 'They\'ll be removed from $name. They can join again later.',
            style: AppText.body,
          ),
          gap14,
          Text(ban ? 'Reason *' : 'Reason (optional)', style: _label),
          gap8,
          GlassTextField(
            controller: _reason,
            hint: ban ? 'Why are you banning them?' : 'Why are you removing them?',
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            inputFormatters: [LengthLimitingTextInputFormatter(500)],
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          if (ban) ...[
            gap14,
            const Text('Ban ends (optional)', style: _label),
            gap8,
            Row(
              children: [
                Expanded(
                  child: GlassSelectField(
                    value: _until == null ? null : formatDay(_until!),
                    hint: 'Permanent',
                    trailingIcon: Icons.event_outlined,
                    onTap: _pickEnd,
                  ),
                ),
                if (_until != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Make permanent',
                    onPressed: () => setState(() => _until = null),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ],
            ),
            gap8,
            Text(
              _until == null
                  ? 'Leave the date blank for a permanent ban.'
                  : 'They can join again after ${formatDay(_until!)}.',
              style: AppText.caption.copyWith(fontSize: 12),
            ),
          ],
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: ban ? 'Ban' : 'Kick', loading: _saving, onPressed: _submit),
          ),
        ],
      ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

/// Deletes a thread for good, with an optional reason. Pops true once done.
class _DeleteThreadSheet extends StatefulWidget {
  const _DeleteThreadSheet({required this.owner, required this.community, required this.discussion});

  final AppUser owner;
  final Community community;
  final Discussion discussion;

  @override
  State<_DeleteThreadSheet> createState() => _DeleteThreadSheetState();
}

class _DeleteThreadSheetState extends State<_DeleteThreadSheet> {
  final _reason = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await CommunityService.instance.deleteDiscussion(
        widget.owner,
        widget.community,
        widget.discussion,
        reason: _reason.text,
      );
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
      title: 'Delete thread?',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          Text(
            '"${widget.discussion.title}" and its messages will be removed for everyone. This can\'t be undone.',
            style: AppText.body,
          ),
          gap14,
          const Text(
            'Reason (optional)',
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          gap8,
          GlassTextField(
            controller: _reason,
            hint: 'At least 10 characters',
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            inputFormatters: [LengthLimitingTextInputFormatter(500)],
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
            child: PrimaryPillButton(label: 'Delete', loading: _saving, onPressed: _submit),
          ),
        ],
      ),
    );
  }
}

// ---- Pieces ---------------------------------------------------------------------------

/// A smaller tab, for the sections inside Moderate.
class _SubTab extends StatelessWidget {
  const _SubTab({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: selected ? Colors.white : Colors.transparent,
          border: Border.all(color: AppColors.white(selected ? 1 : 0.35)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.primary : Colors.white,
          ),
        ),
      ),
    );
  }
}

/// A member, ban, thread or log entry with its details and actions.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.leading,
    required this.title,
    this.lines = const [],
    this.badges = const [],
    this.actions = const [],
  });

  final Widget leading;
  final String title;
  final List<String> lines;
  final List<String> badges;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassWell(
        radius: 16,
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                leading,
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppText.label.copyWith(fontSize: 14)),
                      if (badges.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Wrap(spacing: 6, runSpacing: 4, children: [for (final b in badges) _Badge(b)]),
                      ],
                      for (final line in lines)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(line, style: AppText.caption.copyWith(fontSize: 12)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 6, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.icon);

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Column(
        children: [
          Icon(icon, size: 18, color: Colors.white),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
          ),
          Text(label, style: AppText.caption.copyWith(fontSize: 11)),
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

class _Confirm extends StatelessWidget {
  const _Confirm({required this.title, required this.message, required this.label});

  final String title;
  final String message;
  final String label;

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
            child: PrimaryPillButton(label: label, onPressed: () => Navigator.of(context).pop(true)),
          ),
        ],
      ),
    );
  }
}
