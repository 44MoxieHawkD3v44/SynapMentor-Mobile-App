import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/chat_extras.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/true_colors.dart';
import '../widgets/community_logo.dart';
import 'booking_sheet.dart';
import 'community_manage.dart';

/// An emoji in its own colours, light mode included.
Widget _emoji(String emoji, double size) => TrueColors(
  child: Text(emoji, style: TextStyle(fontSize: size)),
);

/// A joined community: discussions (threads) and their chats. Wide screens
/// show both side by side; phones show the list, then the chosen thread.
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key, required this.user, required this.community});

  final AppUser user;
  final Community community;

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  final _service = CommunityService.instance;

  /// Null on phones means the discussion list is showing.
  Discussion? _open;

  Community get _c => widget.community;

  String? _loadError;

  @override
  void initState() {
    super.initState();
    _service.loadThreads(widget.user, _c).catchError((Object e) {
      if (mounted) setState(() => _loadError = e is AuthException ? e.message : 'Couldn\'t load the discussions.');
    });
  }

  Future<T?> _sheet<T>(Widget sheet) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => sheet,
  );

  Future<void> _newDiscussion() async {
    final created = await _sheet<Discussion>(_NewDiscussionSheet(user: widget.user, community: _c));
    if (created != null && mounted) setState(() => _open = created);
  }

  bool get _owner => _service.isOwner(widget.user, _c);

  void _manage() => showCommunityManage(context, widget.user, _c);

  /// Owner moderation for one thread: pin, lock or delete.
  Future<void> _moderate(Discussion d) async {
    final action = await _sheet<String>(_ModerateSheet(discussion: d));
    if (action == null || !mounted) return;
    try {
      switch (action) {
        case 'pin':
          await _service.togglePin(widget.user, _c, d);
        case 'lock':
          await _service.toggleLock(widget.user, _c, d);
        case 'delete':
          await _service.deleteDiscussion(widget.user, _c, d);
          if (mounted && _open?.id == d.id) setState(() => _open = null);
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _loadError = e.message);
    }
  }

  Future<void> _settings() async {
    final left = await _sheet<bool>(_SettingsSheet(user: widget.user, community: _c));
    if (left == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final open = _open ?? (wide ? _c.discussions.firstOrNull : null);
    final onModerate = _owner ? _moderate : null;
    return PopScope(
      canPop: wide || _open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _open = null);
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: ListenableBuilder(
            listenable: _service,
            builder: (context, _) => Column(
              children: [
                _Header(
                  community: _c,
                  members: _service.memberCount(widget.user, _c),
                  subtitle: !wide && open != null ? open.title : null,
                  onBack: () =>
                      !wide && _open != null ? setState(() => _open = null) : Navigator.of(context).maybePop(),
                  onSettings: _owner ? _manage : _settings,
                  owner: _owner,
                  onNewDiscussion: _newDiscussion,
                ),
                if (_loadError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: InlineNotice(message: _loadError, tone: NoticeTone.error),
                  ),
                Expanded(
                  child: wide
                      ? Row(
                          children: [
                            SizedBox(
                              width: 300,
                              child: _DiscussionList(
                                community: _c,
                                selected: open,
                                onSelect: (d) => setState(() => _open = d),
                                onAdd: _newDiscussion,
                                onModerate: onModerate,
                              ),
                            ),
                            Expanded(
                              child: open == null
                                  ? const SizedBox.shrink()
                                  : _Thread(key: ValueKey(open.id), user: widget.user, community: _c, discussion: open),
                            ),
                          ],
                        )
                      : StepSwitcher(
                          child: open == null
                              ? KeyedSubtree(
                                  key: const ValueKey('list'),
                                  child: _DiscussionList(
                                    community: _c,
                                    onSelect: (d) => setState(() => _open = d),
                                    onAdd: _newDiscussion,
                                    onModerate: onModerate,
                                  ),
                                )
                              : _Thread(key: ValueKey(open.id), user: widget.user, community: _c, discussion: open),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.community,
    required this.members,
    required this.onBack,
    required this.onSettings,
    required this.onNewDiscussion,
    this.subtitle,
    this.owner = false,
  });

  final Community community;

  /// Owners get Manage in place of Settings.
  final bool owner;
  final int members;
  final String? subtitle;
  final VoidCallback onBack;
  final VoidCallback onSettings;
  final VoidCallback onNewDiscussion;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          GlassIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: onBack),
          const SizedBox(width: 10),
          CommunityLogo(community: community, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  community.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                Text(
                  subtitle ?? '$members members',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          GlassIconButton(
            icon: owner ? Icons.admin_panel_settings_outlined : Icons.settings_outlined,
            tooltip: owner ? 'Manage community' : 'Community settings',
            onPressed: onSettings,
          ),
          const SizedBox(width: 8),
          GlassIconButton(icon: Icons.add_comment_outlined, tooltip: 'New Discussion', onPressed: onNewDiscussion),
        ],
      ),
    );
  }
}

class _DiscussionList extends StatelessWidget {
  const _DiscussionList({
    required this.community,
    required this.onSelect,
    required this.onAdd,
    this.selected,
    this.onModerate,
  });

  final Community community;
  final Discussion? selected;
  final ValueChanged<Discussion> onSelect;
  final VoidCallback onAdd;

  /// Set for the owner: pin, lock or delete a thread.
  final ValueChanged<Discussion>? onModerate;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Discussions',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ),
            GlassIconButton(icon: Icons.add_rounded, tooltip: 'New Discussion', onPressed: onAdd),
          ],
        ),
        gap14,
        for (final d in CommunityService.instance.discussionsOf(community))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GlassOption(
              height: 76,
              radius: 18,
              selected: selected?.id == d.id,
              onTap: () => onSelect(d),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Icon(
                      d.general
                          ? Icons.forum_outlined
                          : d.pinned
                          ? Icons.push_pin_outlined
                          : Icons.tag_rounded,
                      size: 20,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            d.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            d.general
                                ? 'Main community chat · ${d.messages.length} messages'
                                : '${d.locked ? 'Locked · ' : ''}${d.author} · ${formatDay(d.createdAt)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                    if (d.locked) ...[
                      const Icon(Icons.lock_outline_rounded, size: 16, color: Colors.white),
                      const SizedBox(width: 4),
                    ],
                    if (onModerate != null && !d.general)
                      IconButton(
                        tooltip: 'Moderate thread',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => onModerate!(d),
                        icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
                      )
                    else
                      const Icon(Icons.chevron_right_rounded, color: Colors.white),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A discussion's chat: messages with reactions and mentions, file sharing,
/// and @-mention suggestions while typing.
class _Thread extends StatefulWidget {
  const _Thread({super.key, required this.user, required this.community, required this.discussion});

  final AppUser user;
  final Community community;
  final Discussion discussion;

  @override
  State<_Thread> createState() => _ThreadState();
}

class _ThreadState extends State<_Thread> {
  static final _mentionAtEnd = RegExp(r'@(\w*)$');

  final _input = TextEditingController();
  final _scroll = ScrollController();
  String? _mentionQuery;
  String? _error;

  /// The message being replied to, shown above the composer.
  CommunityMessage? _replyTo;

  CommunityService get _service => CommunityService.instance;

  List<String> get _people {
    final me = widget.user.profile.pseudoName;
    return {
      ...widget.community.members,
      for (final d in widget.community.discussions)
        for (final m in d.messages) m.author,
    }.where((p) => p != me).toList()..sort();
  }

  /// New messages arrive by refreshing while the thread is open.
  Timer? _refresh;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
    _service.openThread = (user: widget.user, discussion: widget.discussion);
    _refresh = Timer.periodic(const Duration(seconds: 10), (_) => _load(quiet: true));
  }

  Future<void> _load({bool quiet = false}) async {
    try {
      final atBottom = !_scroll.hasClients || _scroll.position.extentAfter < 40;
      await _service.loadMessages(widget.user, widget.discussion);
      if (atBottom) _toBottom();
    } on AuthException catch (e) {
      if (mounted && !quiet) setState(() => _error = e.message);
    }
  }

  @override
  void dispose() {
    if (_service.openThread?.discussion == widget.discussion) _service.openThread = null;
    _refresh?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _react(CommunityMessage m, Reaction r) async {
    try {
      await _service.toggleReaction(widget.user, m, r);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _onChanged(String text) {
    final match = _mentionAtEnd.firstMatch(text);
    setState(() => _mentionQuery = match?.group(1));
  }

  void _insertMention(String name) {
    final text = _input.text.replaceFirst(_mentionAtEnd, '@$name ');
    _input
      ..text = text
      ..selection = TextSelection.collapsed(offset: text.length);
    setState(() => _mentionQuery = null);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _service.send(widget.user, widget.discussion, text, replyTo: _replyTo, c: widget.community);
      _input.clear();
      if (mounted) {
        setState(() {
          _mentionQuery = null;
          _replyTo = null;
        });
      }
      _toBottom();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attach() async {
    final file = await FilePicker.pickFile();
    if (file == null || !mounted) return;
    final bytes = await file.length();
    if (!mounted) return;
    if (bytes == null || bytes > 10 * 1024 * 1024) {
      setState(() => _error = 'Files can be up to 10 MB.');
      return;
    }
    setState(() {
      _error = null;
      _sending = true;
    });
    try {
      await _service.send(
        widget.user,
        widget.discussion,
        'Shared a file',
        fileName: file.name,
        filePath: file.path,
        c: widget.community,
      );
      _toBottom();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  });

  Future<void> _pickReaction(CommunityMessage m) async {
    final picked = await showModalBottomSheet<Reaction>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => FlowSheetFrame(
        title: 'React',
        body: OptionGrid(
          columns: 5,
          spacing: 8,
          children: [
            for (final r in Reaction.all)
              Semantics(
                label: r.name,
                child: Tooltip(
                  message: r.name,
                  child: GlassOption(
                    height: 52,
                    selected: m.reactions[r]?.contains(widget.user.profile.pseudoName) ?? false,
                    onTap: () => Navigator.of(context).pop(r),
                    child: _emoji(r.emoji, 24),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await _react(m, picked);
  }

  /// Who wrote a quoted message, if it's among the loaded ones.
  String? _authorOf(String? id) {
    if (id == null) return null;
    final m = widget.discussion.messages.where((x) => x.id == id).firstOrNull;
    if (m == null) return null;
    return m.author == widget.user.profile.pseudoName ? 'You' : m.author;
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.discussion;
    final me = widget.user.profile.pseudoName;
    final query = _mentionQuery?.toLowerCase();
    final suggestions = query == null
        ? const <String>[]
        : _people.where((p) => p.toLowerCase().startsWith(query)).take(5).toList();
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            children: [
              if (!d.general)
                GlassWell(
                  radius: 16,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.title,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                      const SizedBox(height: 4),
                      Text(d.description, style: AppText.caption.copyWith(color: AppColors.white(0.85))),
                      const SizedBox(height: 4),
                      Text(
                        'Started by ${d.author} · ${formatDay(d.createdAt)}',
                        style: AppText.caption.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              gap14,
              if (d.messages.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Text(
                    'No messages yet. Start the conversation.',
                    style: AppText.body,
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final m in d.messages)
                SwipeToReply(
                  onReply: () => setState(() => _replyTo = m),
                  child: _MessageBubble(
                    message: m,
                    mine: m.author == me,
                    me: me,
                    quotedAuthor: _authorOf(m.quotedId),
                    onReact: () => _pickReaction(m),
                    onToggle: (r) => _react(m, r),
                  ),
                ),
            ],
          ),
        ),
        if (suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassWell(
              radius: 16,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  for (final p in suggestions)
                    ListTile(
                      dense: true,
                      leading: GlassAvatar(initials: p[0].toUpperCase(), size: 30),
                      title: Text('@$p', style: AppText.label.copyWith(fontSize: 13.5)),
                      onTap: () => _insertMention(p),
                    ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FlashError(_error, onHidden: () => setState(() => _error = null)),
              if (_replyTo case final r?)
                ReplyComposerBar(
                  author: r.author == me ? 'yourself' : r.author,
                  text: r.fileName != null && r.text == 'Shared a file' ? r.fileName! : r.text,
                  onCancel: () => setState(() => _replyTo = null),
                ),
              if (d.locked && !_service.isOwner(widget.user, widget.community))
                const InlineNotice(message: 'This thread is locked by the community owner. You can still read it.')
              else
                Row(
                  children: [
                    GlassIconButton(icon: Icons.attach_file_rounded, tooltip: 'Share a file', onPressed: _attach),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GlassTextField(
                        controller: _input,
                        hint: 'Type a message. Use @ to mention',
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.send,
                        onChanged: _onChanged,
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GlassIconButton(icon: Icons.send_rounded, tooltip: 'Send', onPressed: _send),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.me,
    required this.onReact,
    required this.onToggle,
    this.quotedAuthor,
  });

  final CommunityMessage message;
  final bool mine;
  final String? me;

  /// Who wrote the message this one replies to, when known.
  final String? quotedAuthor;
  final VoidCallback onReact;
  final ValueChanged<Reaction> onToggle;

  static final _mention = RegExp(r'@\w+');

  /// Mentions render bold so they stand out.
  List<TextSpan> _spans(String text) {
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _mention.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(
        TextSpan(
          text: m.group(0),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
            decorationColor: Colors.white,
          ),
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final m = message;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              GlassWell(
                radius: 16,
                fillTop: mine ? 0.08 : 0,
                fillBottom: mine ? 0.05 : 0,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${mine ? 'You' : m.author} · ${formatDay(m.sentAt)}, ${formatClock(m.sentAt)}',
                      style: AppText.caption.copyWith(fontSize: 11),
                    ),
                    const SizedBox(height: 4),
                    if (m.quotedText != null && m.quotedText!.isNotEmpty)
                      QuotedReply(author: quotedAuthor, text: m.quotedText!),
                    if (m.fileName != null)
                      AttachmentPreview(
                        name: m.fileName!,
                        url: m.fileUrl,
                        localPath: m.localPath,
                        contentType: m.fileType,
                      ),
                    if (m.fileName == null || m.text != 'Shared a file')
                      Text.rich(
                        TextSpan(children: _spans(m.text)),
                        style: const TextStyle(fontSize: 14, height: 1.4, color: Colors.white),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final entry in m.reactions.entries)
                    Semantics(
                      button: true,
                      label: '${entry.key.name} ${entry.value.length}',
                      excludeSemantics: true,
                      child: GestureDetector(
                        onTap: () => onToggle(entry.key),
                        child: GlassWell(
                          radius: 12,
                          active: entry.value.contains(me),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _emoji(entry.key.emoji, 13),
                              const SizedBox(width: 4),
                              Text('${entry.value.length}', style: const TextStyle(fontSize: 12, color: Colors.white)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Semantics(
                    button: true,
                    label: 'Add reaction',
                    excludeSemantics: true,
                    child: GestureDetector(
                      onTap: onReact,
                      child: GlassWell(
                        radius: 12,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        child: const Icon(Icons.add_reaction_outlined, size: 15, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Owner actions for a thread. Pops 'pin', 'lock' or 'delete'.
class _ModerateSheet extends StatefulWidget {
  const _ModerateSheet({required this.discussion});

  final Discussion discussion;

  @override
  State<_ModerateSheet> createState() => _ModerateSheetState();
}

class _ModerateSheetState extends State<_ModerateSheet> {
  bool _confirmDelete = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.discussion;
    Widget option(IconData icon, String label, String note, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassOption(
        height: 60,
        radius: 16,
        selected: false,
        onTap: value == 'delete' && !_confirmDelete
            ? () => setState(() => _confirmDelete = true)
            : () => Navigator.of(context).pop(value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: AppText.label.copyWith(fontSize: 14)),
                    Text(note, style: AppText.caption.copyWith(fontSize: 11.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return FlowSheetFrame(
      title: d.title,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          option(
            Icons.push_pin_outlined,
            d.pinned ? 'Unpin Thread' : 'Pin Thread',
            d.pinned ? 'Return it to the normal order' : 'Keep it at the top, after General',
            'pin',
          ),
          option(
            d.locked ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
            d.locked ? 'Unlock Thread' : 'Lock Thread',
            d.locked ? 'Members can post again' : 'Members can read but not post',
            'lock',
          ),
          if (_confirmDelete)
            const InlineNotice(
              message: 'Delete this thread and all its messages? This can\'t be undone.',
              tone: NoticeTone.error,
            ),
          option(
            Icons.delete_outline_rounded,
            _confirmDelete ? 'Tap again to delete' : 'Delete Thread',
            'Removes it for everyone',
            'delete',
          ),
        ],
      ),
    );
  }
}

class _NewDiscussionSheet extends StatefulWidget {
  const _NewDiscussionSheet({required this.user, required this.community});

  final AppUser user;
  final Community community;

  @override
  State<_NewDiscussionSheet> createState() => _NewDiscussionSheetState();
}

class _NewDiscussionSheetState extends State<_NewDiscussionSheet> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  bool _saving = false;
  final _errors = <String, String?>{};
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _error = null;
      _errors
        ..['title'] = _title.text.trim().length < 5 ? 'Use at least 5 characters.' : null
        ..['description'] = _description.text.trim().length < 10 ? 'Use at least 10 characters.' : null;
    });
    if (_errors.values.any((e) => e != null)) return;
    setState(() => _saving = true);
    try {
      final d = await CommunityService.instance.createDiscussion(
        widget.user,
        widget.community,
        _title.text,
        _description.text,
      );
      if (mounted) Navigator.of(context).pop(d);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'New Discussion',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Starting a new discussion in ${widget.community.name}. '
            'Separate threads keep different topics easy to follow.',
            style: AppText.caption,
          ),
          gap14,
          InlineNotice(message: _error, tone: NoticeTone.error),
          const Text('Title (min 5 chars)', style: _label),
          gap8,
          GlassTextField(
            controller: _title,
            hint: 'What would you like to discuss?',
            textCapitalization: TextCapitalization.sentences,
            errorText: _errors['title'],
            onChanged: (_) => setState(() => _errors['title'] = null),
          ),
          gap14,
          const Text('Description (min 10 chars)', style: _label),
          gap8,
          GlassTextField(
            controller: _description,
            hint: 'Describe your discussion topic in detail',
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            errorText: _errors['description'],
            onChanged: (_) => setState(() => _errors['description'] = null),
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
            child: PrimaryPillButton(label: 'Create', loading: _saving, onPressed: _create),
          ),
        ],
      ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

/// Notification toggle and leaving. Pops `true` if the user left.
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.user, required this.community});

  final AppUser user;
  final Community community;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  bool _confirmLeave = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final service = CommunityService.instance;
    final on = service.notificationsOn(widget.user, widget.community);
    return FlowSheetFrame(
      title: 'Community Settings',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassWell(
            radius: 18,
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
            child: MergeSemantics(
              child: Row(
                children: [
                  const Icon(Icons.notifications_none_rounded, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Notifications', style: AppText.label.copyWith(fontWeight: FontWeight.w600)),
                        Text(
                          'Updates and activity in ${widget.community.name}',
                          style: AppText.caption.copyWith(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: on,
                    onChanged: (v) => setState(() => service.setNotifications(widget.user, widget.community, v)),
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
            ),
          ),
          gap14,
          InlineNotice(message: _error, tone: NoticeTone.error),
          if (_confirmLeave)
            InlineNotice(
              message: 'Leave ${widget.community.name}? You can join again anytime.',
              tone: NoticeTone.error,
              persistent: true,
            ),
        ],
      ),
      footer: _confirmLeave
          ? Row(
              children: [
                Expanded(
                  child: GlassPillButton(label: 'Stay', onPressed: () => setState(() => _confirmLeave = false)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PrimaryPillButton(
                    label: 'Leave Community',
                    onPressed: () async {
                      try {
                        await service.leave(widget.user, widget.community);
                        if (context.mounted) Navigator.of(context).pop(true);
                      } on AuthException catch (e) {
                        if (mounted) setState(() => _error = e.message);
                      }
                    },
                  ),
                ),
              ],
            )
          : GlassPillButton(label: 'Leave Community', onPressed: () => setState(() => _confirmLeave = true)),
    );
  }
}
