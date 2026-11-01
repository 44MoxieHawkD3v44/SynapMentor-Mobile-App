import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/support_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/chat_extras.dart' show SecureAttachment;
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import 'booking_sheet.dart';

enum _Tab { raise, report, history }

/// Support in one screen: FAQs with ticket raising, content reports, and the
/// chat history with the admin team. Opening a ticket shows its conversation
/// in place.
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key, required this.user});

  final AppUser user;

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  final _support = SupportService.instance;
  final _faqSearch = TextEditingController();
  final _reply = TextEditingController();

  _Tab _tab = _Tab.raise;
  TicketKind _historyKind = TicketKind.ticket;
  String? _faqCategory;
  final _openFaqs = <String>{};
  SupportTicket? _thread;
  String? _notice;
  bool _sending = false;
  String? _replyError;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _support.load(widget.user).catchError(_showLoadError);
  }

  void _showLoadError(Object e) {
    if (mounted) setState(() => _loadError = e is AuthException ? e.message : 'Couldn\'t load support.');
  }

  /// While a ticket waits for the admin, its thread is checked for a reply.
  Timer? _replyCheck;

  void _openThread(SupportTicket t) {
    setState(() {
      _thread = t;
      _notice = null;
      _replyError = null;
    });
    _support.loadThread(t).catchError(_showLoadError);
    _replyCheck?.cancel();
    _replyCheck = Timer.periodic(const Duration(seconds: 15), (_) {
      final open = _thread;
      if (open != null && open.userMessagesInARow > 0 && open.status.acceptsReplies) {
        _support.loadThread(open).catchError((Object _) {});
      }
    });
  }

  @override
  void dispose() {
    _replyCheck?.cancel();
    _faqSearch.dispose();
    _reply.dispose();
    super.dispose();
  }

  Future<void> _openForm(TicketKind kind) async {
    final ticket = await showModalBottomSheet<SupportTicket>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => _TicketFormSheet(user: widget.user, kind: kind),
    );
    if (ticket == null || !mounted) return;
    setState(() {
      _tab = _Tab.history;
      _historyKind = kind;
      _notice = '${ticket.id} submitted. You\'ll get an email when the admin responds, and can follow it here.';
    });
  }

  /// A file picked for the chat, sent with the next Send.
  Attachment? _pendingFile;

  Future<void> _pickReplyFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: SupportService.attachmentExtensions,
    );
    if (file == null || !mounted) return;
    final bytes = await file.length();
    if (!mounted) return;
    final ext = file.extension?.toLowerCase();
    setState(() {
      if (ext == null || !SupportService.attachmentExtensions.contains(ext)) {
        _replyError = 'Attach a JPG, PNG, WebP or PDF file.';
      } else if (bytes == null || bytes > SupportService.maxAttachmentBytes) {
        _replyError = 'That file is over 5 MB. Choose a smaller one.';
      } else if (file.path == null) {
        _replyError = 'Couldn\'t read that file. Try another one.';
      } else {
        _pendingFile = Attachment(file.name, bytes, file.path);
        _replyError = null;
      }
    });
  }

  /// Sends the picked file, then the message if there is one.
  Future<void> _sendReply() async {
    final text = _reply.text.trim();
    final thread = _thread;
    final file = _pendingFile;
    if ((text.isEmpty && file == null) || thread == null) return;
    setState(() {
      _sending = true;
      _replyError = null;
    });
    try {
      if (file != null) {
        await _support.sendFile(thread, file);
        if (mounted) setState(() => _pendingFile = null);
      }
      if (text.isNotEmpty) {
        await _support.reply(thread, text);
        _reply.clear();
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _replyError = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _closeThread() => setState(() {
    _replyCheck?.cancel();
    _thread = null;
    _reply.clear();
    _replyError = null;
    _pendingFile = null;
  });

  @override
  Widget build(BuildContext context) {
    final thread = _thread;
    return PopScope(
      canPop: thread == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeThread();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: ListenableBuilder(
            listenable: _support,
            builder: (context, _) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      GlassIconButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: 'Back',
                        onPressed: thread != null ? _closeThread : () => Navigator.of(context).maybePop(),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              thread?.id ?? 'SUPPORT',
                              textAlign: TextAlign.center,
                              style: AppText.heading.copyWith(fontSize: 20),
                            ),
                            if (thread != null) ...[const SizedBox(height: 4), _Badge(thread.status.label)],
                          ],
                        ),
                      ),
                      const SizedBox(width: 44),
                    ],
                  ),
                ),
                Expanded(child: thread == null ? _buildHome() : _buildThread(thread)),
                if (thread != null) _buildReplyBar(thread),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Home --------------------------------------------------------------------

  Widget _buildHome() {
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    for (final (tab, icon, label) in const [
                      (_Tab.raise, Icons.confirmation_number_outlined, 'Raise Ticket'),
                      (_Tab.report, Icons.report_gmailerrorred_outlined, 'Report Content'),
                      (_Tab.history, Icons.forum_outlined, 'Chat History'),
                    ]) ...[
                      if (tab != _Tab.raise) const SizedBox(width: 10),
                      Expanded(
                        child: GlassOption(
                          height: 76,
                          radius: 18,
                          selected: _tab == tab,
                          onTap: () => setState(() {
                            _tab = tab;
                            _notice = null;
                          }),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(icon, size: 22, color: Colors.white),
                              const SizedBox(height: 6),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(label, style: AppText.label.copyWith(fontSize: 13)),
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
                InlineNotice(message: _loadError, tone: NoticeTone.error),
                StepSwitcher(
                  child: KeyedSubtree(
                    key: ValueKey(_tab),
                    child: switch (_tab) {
                      _Tab.raise => _buildRaise(),
                      _Tab.report => _buildReport(),
                      _Tab.history => _buildHistory(),
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRaise() {
    final query = _faqSearch.text.trim().toLowerCase();
    final faqs = SupportService.faqs.where((f) {
      if (_faqCategory != null && f.category != _faqCategory) return false;
      return query.isEmpty || f.question.toLowerCase().contains(query) || f.answer.toLowerCase().contains(query);
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SupportEmail(),
        gap14,
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Heading(
                icon: Icons.confirmation_number_outlined,
                title: 'Raise a Ticket',
                subtitle: 'Check if your question is answered below, or raise a new ticket.',
              ),
              gap14,
              const _Guidelines(title: 'Ticket Guidelines', lines: SupportService.ticketGuidelines, collapsible: true),
              gap14,
              PrimaryPillButton(label: 'Raise a Ticket', onPressed: () => _openForm(TicketKind.ticket)),
              gap14,
              GlassTextField(
                controller: _faqSearch,
                hint: 'Search frequently asked questions',
                icon: Icons.search_rounded,
                onChanged: (_) => setState(() {}),
              ),
              gap14,
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  GlassChip(
                    label: 'All',
                    selected: _faqCategory == null,
                    onTap: () => setState(() => _faqCategory = null),
                  ),
                  for (final c in SupportService.faqCategories)
                    GlassChip(label: c, selected: _faqCategory == c, onTap: () => setState(() => _faqCategory = c)),
                ],
              ),
            ],
          ),
        ),
        gap14,
        if (faqs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text('No questions match your search.', style: AppText.body, textAlign: TextAlign.center),
          )
        else
          for (final faq in faqs) ...[
            _FaqCard(
              faq: faq,
              expanded: _openFaqs.contains(faq.question),
              onToggle: () => setState(() {
                if (!_openFaqs.remove(faq.question)) _openFaqs.add(faq.question);
              }),
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _buildReport() {
    return GlassPanel(
      radius: 24,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Heading(
            icon: Icons.report_gmailerrorred_outlined,
            title: 'Report Content',
            subtitle: 'Found content that is abusive, duplicated or breaks our content policies? Let us know.',
          ),
          gap14,
          const _Guidelines(
            title: 'Reporting Guidelines',
            lines: SupportService.reportingGuidelines,
            collapsible: true,
          ),
          gap24,
          PrimaryPillButton(label: 'Report Content', onPressed: () => _openForm(TicketKind.report)),
        ],
      ),
    );
  }

  Widget _buildHistory() {
    final tickets = _support.ticketsFor(widget.user, _historyKind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Heading(
                icon: Icons.history_rounded,
                title: 'Support History',
                subtitle: 'View your past support conversations and reports.',
              ),
              gap14,
              Row(
                children: [
                  GlassChip(
                    label: 'Ticket History',
                    selected: _historyKind == TicketKind.ticket,
                    onTap: () => setState(() => _historyKind = TicketKind.ticket),
                  ),
                  const SizedBox(width: 8),
                  GlassChip(
                    label: 'Report History',
                    selected: _historyKind == TicketKind.report,
                    onTap: () => setState(() => _historyKind = TicketKind.report),
                  ),
                ],
              ),
            ],
          ),
        ),
        gap14,
        if (tickets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              _historyKind == TicketKind.ticket
                  ? 'You haven\'t raised any tickets yet.'
                  : 'You haven\'t reported any content yet.',
              style: AppText.body,
              textAlign: TextAlign.center,
            ),
          )
        else
          for (final t in tickets) ...[_TicketTile(ticket: t, onTap: () => _openThread(t)), const SizedBox(height: 10)],
      ],
    );
  }

  // ---- Thread ------------------------------------------------------------------

  Widget _buildThread(SupportTicket t) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GlassPanel(
                  radius: 22,
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      GlassIconBadge(
                        icon: t.kind == TicketKind.ticket
                            ? Icons.confirmation_number_outlined
                            : Icons.report_gmailerrorred_outlined,
                        size: 46,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Badge(t.category),
                            const SizedBox(height: 6),
                            Text(
                              t.subject,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                            ),
                            Text('${formatDay(t.createdAt)}, ${formatClock(t.createdAt)}', style: AppText.caption),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                gap24,
                _Bubble(
                  fromAdmin: false,
                  text: t.description,
                  sentAt: t.createdAt,
                  extras: [for (final link in t.links) (Icons.link_rounded, link)],
                ),
                for (final item in _conversation(t))
                  switch (item) {
                    (final SupportMessage m, _) => _Bubble(fromAdmin: m.fromAdmin, text: m.text, sentAt: m.sentAt),
                    (_, final Attachment a) => _Bubble(
                      fromAdmin: a.fromAdmin,
                      text: '',
                      sentAt: a.sentAt ?? t.createdAt,
                      attachment: a,
                    ),
                    _ => const SizedBox.shrink(),
                  },
                if (!t.status.acceptsReplies) ...[
                  gap14,
                  const InlineNotice(
                    message: 'This ticket was marked Resolved and the chat is closed. Raise a new ticket if you need more help.',
                    tone: NoticeTone.success,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReplyBar(SupportTicket t) {
    if (!t.status.acceptsReplies || !t.threadLoaded) return const SizedBox.shrink();
    if (t.awaitingAdmin) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: GlassWell(
            radius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.hourglass_top_rounded, size: 18, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'You\'ve sent ${SupportTicket.maxUserMessagesInARow} messages. Waiting for the support team to '
                    'reply. You can send more once they do.',
                    style: AppText.caption.copyWith(color: AppColors.white(0.85)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final pending = _pendingFile;
    final canAttach = t.attachments.length < SupportService.maxTicketFiles;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pending != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _RemovableRow(
                  icon: Icons.attach_file_rounded,
                  text: pending.name,
                  onRemove: () => setState(() => _pendingFile = null),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5, right: 10),
                  child: GlassIconButton(
                    icon: Icons.attach_file_rounded,
                    tooltip: canAttach ? 'Attach a file' : 'This ticket has the maximum of 6 files',
                    onPressed: canAttach && !_sending ? _pickReplyFile : () {},
                  ),
                ),
                Expanded(
                  child: GlassTextField(
                    controller: _reply,
                    hint: pending == null ? 'Type your reply' : 'Add a message (optional)',
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    errorText: _replyError,
                    onSubmitted: (_) => _sendReply(),
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: _sending
                      ? const SizedBox.square(
                          dimension: 44,
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          ),
                        )
                      : GlassIconButton(icon: Icons.send_rounded, tooltip: 'Send', onPressed: _sendReply),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The ticket's messages and files, oldest first.
  static List<(SupportMessage?, Attachment?)> _conversation(SupportTicket t) {
    final items = <(DateTime, SupportMessage?, Attachment?)>[
      for (final m in t.messages) (m.sentAt, m, null),
      for (final a in t.attachments) (a.sentAt ?? t.createdAt, null, a),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, m, a) in items) (m, a)];
  }
}

// ---- New ticket / report sheet ------------------------------------------------------

class _TicketFormSheet extends StatefulWidget {
  const _TicketFormSheet({required this.user, required this.kind});

  final AppUser user;
  final TicketKind kind;

  @override
  State<_TicketFormSheet> createState() => _TicketFormSheetState();
}

class _TicketFormSheetState extends State<_TicketFormSheet> {
  final _subject = TextEditingController();
  final _description = TextEditingController();
  final _link = TextEditingController();
  final _customCategory = TextEditingController();

  String? _category;

  bool get _isOther => _category == SupportService.otherCategory;
  final _links = <String>[];
  final _attachments = <Attachment>[];
  bool _submitting = false;
  String? _error;
  final _errors = <String, String?>{};

  bool get _isReport => widget.kind == TicketKind.report;

  @override
  void dispose() {
    _subject.dispose();
    _description.dispose();
    _link.dispose();
    _customCategory.dispose();
    super.dispose();
  }

  Future<void> _selectCategory() async {
    final picked = await showGlassPicker(
      context,
      title: 'Category',
      options: _isReport ? SupportService.reportCategories : SupportService.ticketCategories,
      label: (c) => c,
      selected: _category,
    );
    if (picked != null) {
      setState(() {
        _category = picked;
        _errors['category'] = null;
      });
    }
  }

  void _addLink() {
    final text = _link.text.trim();
    final uri = Uri.tryParse(text);
    final valid = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
    setState(() {
      if (!valid) {
        _errors['link'] = 'Enter a full link starting with https://';
      } else if (_links.contains(text)) {
        _errors['link'] = 'You\'ve already added this link.';
      } else {
        _links.add(text);
        _link.clear();
        _errors['link'] = null;
      }
    });
  }

  Future<void> _pickAttachments() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: SupportService.attachmentExtensions,
    );
    if (files.isEmpty || !mounted) return;
    final skipped = <String>[];
    for (final file in files) {
      if (_attachments.length >= SupportService.maxAttachments) {
        skipped.add('${file.name} (limit of ${SupportService.maxAttachments} files)');
        continue;
      }
      final ext = file.extension?.toLowerCase();
      final bytes = await file.length();
      if (ext == null || !SupportService.attachmentExtensions.contains(ext)) {
        skipped.add('${file.name} (unsupported type)');
      } else if (bytes == null || bytes > SupportService.maxAttachmentBytes) {
        skipped.add('${file.name} (over 5 MB)');
      } else {
        _attachments.add(Attachment(file.name, bytes, file.path));
      }
    }
    if (!mounted) return;
    setState(() => _errors['attachments'] = skipped.isEmpty ? null : 'Skipped: ${skipped.join(', ')}.');
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _errors
        ..['category'] = _category == null ? 'Select a category.' : null
        ..['customCategory'] = _isOther && _customCategory.text.trim().length < 2 ? 'Enter your category.' : null
        ..['subject'] = _subject.text.trim().length < 5 ? 'Use at least 5 characters.' : null
        ..['description'] = _description.text.trim().length < 10 ? 'Use at least 10 characters.' : null;
    });
    if (_errors['category'] != null ||
        _errors['customCategory'] != null ||
        _errors['subject'] != null ||
        _errors['description'] != null) {
      return;
    }
    setState(() => _submitting = true);
    try {
      final ticket = await SupportService.instance.create(
        user: widget.user,
        kind: widget.kind,
        category: _category!,
        customCategory: _isOther ? _customCategory.text : null,
        subject: _subject.text,
        description: _description.text,
        links: List.of(_links),
        attachments: List.of(_attachments),
      );
      if (mounted) Navigator.of(context).pop(ticket);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: _isReport ? 'Report Content' : 'Create Support Ticket',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          const Text('Category *', style: _label),
          gap8,
          GlassSelectField(
            value: _category,
            hint: 'Select a category',
            errorText: _errors['category'],
            onTap: _selectCategory,
          ),
          if (_isOther) ...[
            gap8,
            GlassTextField(
              controller: _customCategory,
              hint: 'Enter your category',
              textCapitalization: TextCapitalization.words,
              errorText: _errors['customCategory'],
              onChanged: (_) {
                if (_errors['customCategory'] != null) setState(() => _errors['customCategory'] = null);
              },
            ),
          ],
          gap14,
          const Text('Subject *', style: _label),
          gap8,
          GlassTextField(
            controller: _subject,
            hint: 'Brief summary (min 5 characters)',
            textCapitalization: TextCapitalization.sentences,
            errorText: _errors['subject'],
            onChanged: (_) {
              if (_errors['subject'] != null) setState(() => _errors['subject'] = null);
            },
          ),
          gap14,
          const Text('Description *', style: _label),
          gap8,
          GlassTextField(
            controller: _description,
            hint: 'Describe the ${_isReport ? 'issue' : 'problem'} in detail (min 10 characters)',
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            errorText: _errors['description'],
            onChanged: (_) {
              if (_errors['description'] != null) setState(() => _errors['description'] = null);
            },
          ),
          if (_isReport) ...[
            gap14,
            const Text('Related Links (optional)', style: _label),
            gap8,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: GlassTextField(
                    controller: _link,
                    hint: 'https://example.com/…',
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    errorText: _errors['link'],
                    onSubmitted: (_) => _addLink(),
                    onChanged: (_) {
                      if (_errors['link'] != null) setState(() => _errors['link'] = null);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: GlassIconButton(icon: Icons.add_rounded, tooltip: 'Add link', onPressed: _addLink),
                ),
              ],
            ),
            for (final link in _links)
              _RemovableRow(icon: Icons.link_rounded, text: link, onRemove: () => setState(() => _links.remove(link))),
          ],
          gap14,
          const Text('Attachments (optional)', style: _label),
          const SizedBox(height: 4),
          Text('JPG, PNG, WebP or PDF. Max 5 MB each, up to 5 files.', style: AppText.caption.copyWith(fontSize: 12)),
          gap8,
          GlassWell(
            radius: 18,
            error: _errors['attachments'] != null,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: _attachments.length >= SupportService.maxAttachments ? null : _pickAttachments,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.upload_file_outlined, size: 20, color: Colors.white),
                      const SizedBox(width: 8),
                      Text(
                        _attachments.length >= SupportService.maxAttachments
                            ? 'File limit reached'
                            : 'Tap to upload (JPG, PNG, WebP, PDF)',
                        style: AppText.label.copyWith(fontSize: 13.5),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          FieldError(_errors['attachments']),
          for (final file in _attachments)
            _RemovableRow(
              icon: Icons.attach_file_rounded,
              text: '${file.name} · ${(file.bytes / 1024).ceil()} KB',
              onRemove: () => setState(() => _attachments.remove(file)),
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
              label: _isReport ? 'Submit Report' : 'Submit Ticket',
              loading: _submitting,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

// ---- Pieces ---------------------------------------------------------------------------

class _Heading extends StatelessWidget {
  const _Heading({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GlassIconBadge(icon: icon, size: 48),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              const SizedBox(height: 2),
              Text(subtitle, style: AppText.caption),
            ],
          ),
        ),
      ],
    );
  }
}

/// A titled list of guidelines with check marks.
class _Guidelines extends StatefulWidget {
  const _Guidelines({required this.title, required this.lines, this.collapsible = false});

  final String title;
  final List<String> lines;

  /// Shown as a dropdown: the title, opening to the lines.
  final bool collapsible;

  @override
  State<_Guidelines> createState() => _GuidelinesState();
}

class _GuidelinesState extends State<_Guidelines> {
  late bool _open = !widget.collapsible;

  @override
  Widget build(BuildContext context) {
    final title = Text(widget.title, style: AppText.label.copyWith(fontSize: 14, fontWeight: FontWeight.w700));
    final lines = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        for (final line in widget.lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.check_rounded, size: 16, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(line, style: AppText.caption.copyWith(color: AppColors.white(0.85))),
                ),
              ],
            ),
          ),
      ],
    );
    if (!widget.collapsible) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [title, lines]);
    return GlassWell(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.rule_rounded, size: 18, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(child: title),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(padding: const EdgeInsets.only(bottom: 8), child: lines)
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// The support email; tapping it opens the mail app.
class _SupportEmail extends StatelessWidget {
  const _SupportEmail();

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 20,
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => launchUrl(Uri(scheme: 'mailto', path: SupportService.supportEmail)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const GlassIconBadge(icon: Icons.mail_outline_rounded, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Email Support', style: AppText.label.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(SupportService.supportEmail, style: AppText.caption),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: AppColors.white(0.7)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FaqCard extends StatelessWidget {
  const _FaqCard({required this.faq, required this.expanded, required this.onToggle});

  final Faq faq;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 20,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Badge(faq.category),
                          const SizedBox(height: 6),
                          Text(
                            faq.question,
                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: expanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: const Icon(Icons.chevron_right_rounded, color: Colors.white),
                    ),
                  ],
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: expanded
                      ? Padding(
                          padding: const EdgeInsets.only(top: 10, right: 12),
                          child: Text(faq.answer, style: AppText.body),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TicketTile extends StatelessWidget {
  const _TicketTile({required this.ticket, required this.onTap});

  final SupportTicket ticket;
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
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                ticket.kind == TicketKind.ticket
                                    ? Icons.confirmation_number_outlined
                                    : Icons.report_gmailerrorred_outlined,
                                size: 16,
                                color: AppColors.white(0.85),
                              ),
                              const SizedBox(width: 6),
                              Text(ticket.id, style: AppText.caption.copyWith(color: Colors.white)),
                            ],
                          ),
                          _Badge(ticket.category),
                          _Badge(ticket.status.label),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        ticket.subject,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white),
                      ),
                      const SizedBox(height: 2),
                      Text(formatDay(ticket.createdAt), style: AppText.caption),
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

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.fromAdmin,
    required this.text,
    required this.sentAt,
    this.extras = const [],
    this.attachment,
  });

  final bool fromAdmin;
  final String text;
  final DateTime sentAt;
  final List<(IconData, String)> extras;

  /// A file sent in the chat: a picture shows here (tap to view), other
  /// files can be saved.
  final Attachment? attachment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: fromAdmin ? Alignment.centerLeft : Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: GlassWell(
            radius: 18,
            fillTop: fromAdmin ? 0 : 0.08,
            fillBottom: fromAdmin ? 0 : 0.05,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fromAdmin ? 'Admin' : 'You',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                const SizedBox(height: 4),
                if (attachment case final a?)
                  SecureAttachment(name: a.name, url: a.url, localPath: a.path, download: ApiClient.instance.download),
                if (text.isNotEmpty)
                  Text(text, style: const TextStyle(fontSize: 14, height: 1.45, color: Colors.white)),
                for (final (icon, label) in extras)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 14, color: AppColors.white(0.85)),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(label, style: AppText.caption.copyWith(color: AppColors.white(0.85))),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                Text('${formatDay(sentAt)}, ${formatClock(sentAt)}', style: AppText.caption.copyWith(fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RemovableRow extends StatelessWidget {
  const _RemovableRow({required this.icon, required this.text, required this.onRemove});

  final IconData icon;
  final String text;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GlassWell(
        radius: 14,
        padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: Colors.white),
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
            ),
          ],
        ),
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
