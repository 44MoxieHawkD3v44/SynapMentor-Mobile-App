import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/session_store.dart';
import '../api/support_api.dart';
import 'auth_service.dart';

enum TicketKind { ticket, report }

enum TicketStatus {
  open('Open'),
  inProgress('In Progress'),
  resolved('Resolved');

  const TicketStatus(this.label);
  final String label;

  /// Resolved tickets are closed; the user can't reply any more.
  bool get acceptsReplies => this != resolved;
}

class Faq {
  const Faq(this.category, this.question, this.answer);

  final String category;
  final String question;
  final String answer;
}

class Attachment {
  const Attachment(this.name, this.bytes, [this.path, this.url, this.sentAt, this.fromAdmin = false, this.contentType]);

  final String name;
  final int bytes;

  /// The file on this device, for uploading. Null for files already sent.
  final String? path;

  /// Where the server keeps it (opened with the user's session).
  final String? url;

  /// When it was added to the ticket, and whether support added it.
  final DateTime? sentAt;
  final bool fromAdmin;
  final String? contentType;
}

class SupportMessage {
  const SupportMessage({required this.fromAdmin, required this.text, required this.sentAt});

  final bool fromAdmin;
  final String text;
  final DateTime sentAt;
}

class SupportTicket {
  SupportTicket({
    required this.id,
    required this.kind,
    required this.category,
    required this.subject,
    required this.description,
    required this.createdAt,
    this.apiId = '',
    this.links = const [],
    this.attachments = const [],
  });

  /// The reference shown to the user, e.g. `TCT-30`.
  final String id;

  /// The ticket's id in the API.
  final String apiId;
  final TicketKind kind;
  final String category;
  final String subject;
  String description;
  final DateTime createdAt;
  List<String> links;
  List<Attachment> attachments;
  TicketStatus status = TicketStatus.open;
  final messages = <SupportMessage>[];

  /// The conversation has been loaded from the server.
  bool threadLoaded = false;

  /// How many messages the user may send in a row before waiting for an
  /// admin reply (the ticket itself counts as the first).
  static const maxUserMessagesInARow = 3;

  /// The user's messages since the admin last replied, the ticket included
  /// when the admin hasn't replied yet.
  int get userMessagesInARow {
    var count = 0;
    for (final m in messages.reversed) {
      if (m.fromAdmin) return count;
      count++;
    }
    // No admin reply yet: the ticket's own description counts too.
    return count + 1;
  }

  /// The user has sent their messages in a row; the next one waits for an
  /// admin reply.
  bool get awaitingAdmin => userMessagesInARow >= maxUserMessagesInARow;
}

/// Help & Support: FAQs, tickets and content reports from the support API.
/// Tickets and reports land in the Admin Panel; the admin's replies arrive
/// here and by email.
class SupportService extends ChangeNotifier {
  static final SupportService instance = SupportService();

  // The labels the forms show and the API's categories behind them.
  static const _ticketCategories = {
    'Technical': 'technical',
    'Account': 'account',
    'Booking': 'booking',
    'Payment': 'payment',
    'Content': 'content',
    'Suspicious Activity': 'suspicious',
    'Other': 'other',
  };
  static const _reportCategories = {
    'Duplicate Content': 'content_duplication',
    'Inappropriate Content': 'content_report',
    'Spam': 'content_report',
    'Copyright Violation': 'content_report',
    'Harassment': 'harassment',
    'Other': 'content_report',
  };

  /// What a loaded ticket's category reads as (several report labels share
  /// one API category).
  static const _categoryLabels = {
    'technical': 'Technical',
    'account': 'Account',
    'booking': 'Booking',
    'payment': 'Payment',
    'content': 'Content',
    'suspicious': 'Suspicious Activity',
    'other': 'Other',
    'content_duplication': 'Duplicate Content',
    'content_report': 'Content Report',
    'harassment': 'Harassment',
  };

  static final ticketCategories = _ticketCategories.keys.toList();
  static final reportCategories = _reportCategories.keys.toList();

  /// The category that lets the user type their own.
  static const otherCategory = 'Other';

  /// Guidelines shown with the ticket and report forms.
  static const ticketGuidelines = [
    'Check the FAQs first; your answer may already be there.',
    'Raise one ticket per issue and pick the closest category.',
    'Use a clear subject and describe what happened, when, and what you expected.',
    'Add screenshots or booking and payment references if you have them.',
    'Never share your password, OTPs or full card details.',
    'Reply in the same ticket; our team responds by email and in Chat History.',
  ];
  static const reportingGuidelines = [
    'Report content that is duplicated, inappropriate, spam, copied or harassing.',
    'Add a link to the exact content and screenshots where you can.',
    'Explain why it breaks our policies; one report per piece of content.',
    'Reports are confidential; the person reported isn\'t told who reported them.',
    'False or repeated reports may limit your account.',
  ];

  static const supportEmail = 'support@synapmentor.com';

  static const attachmentExtensions = ['jpg', 'jpeg', 'png', 'webp', 'pdf'];
  static const maxAttachmentBytes = 5 * 1024 * 1024;

  /// The API accepts up to 6 files per ticket.
  static const maxAttachments = 5;

  /// Frequently asked questions, loaded from the API.
  static final faqs = <Faq>[];

  /// Replaces the FAQs with what the API returned.
  static void setFaqs(List<Faq> list) => faqs
    ..clear()
    ..addAll(list);

  static List<String> get faqCategories => {for (final f in faqs) f.category}.toList();

  final _tickets = <String, List<SupportTicket>>{};

  /// Newest first.
  List<SupportTicket> ticketsFor(AppUser user, TicketKind kind) =>
      _list(user).where((t) => t.kind == kind).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Loads the FAQs and the user's tickets and reports.
  Future<void> load(AppUser user) async {
    final results = await Future.wait([SupportApi.faqs(), SupportApi.tickets(user.role.name)]);
    setFaqs([
      for (final f in results[0])
        Faq(
          _titleCase(f['category'] as String? ?? 'General'),
          f['question'] as String? ?? '',
          f['answer'] as String? ?? '',
        ),
    ]);
    final known = {for (final t in _list(user)) t.apiId: t};
    setTickets(user, [for (final t in results[1]) _merge(known[t['id']], t)]);
  }

  /// Loads a ticket's conversation and files.
  Future<void> loadThread(SupportTicket ticket) async {
    final data = await SupportApi.ticket(_role, ticket.apiId);
    final t = data['ticket'] is Map ? Map<String, dynamic>.from(data['ticket'] as Map) : const <String, dynamic>{};
    ticket
      ..description = t['description'] as String? ?? ticket.description
      ..status = _status(t['status'] as String?)
      ..links = [
        for (final e in t['evidence'] as List? ?? const [])
          if (e is Map && '${e['value']}'.startsWith('http')) '${e['value']}',
      ]
      ..attachments = [
        for (final a in data['attachments'] as List? ?? const [])
          if (a is Map)
            Attachment(
              '${a['file_name'] ?? 'File'}',
              a['file_size'] is int ? a['file_size'] as int : 0,
              null,
              ApiClient.photoLink(a['file_key']),
              _date(a['created_at']),
              a['user_id'] != null && a['user_id'] != SessionStore.instance.userId,
              a['file_type'] as String?,
            ),
      ];
    // The opening message repeats the description, which is shown first.
    final messages = [
      for (final m in data['messages'] as List? ?? const [])
        if (m is Map)
          SupportMessage(
            fromAdmin: m['sender_type'] != 'user',
            text: '${m['message'] ?? ''}',
            sentAt: _date(m['created_at']),
          ),
    ];
    if (messages.isNotEmpty && !messages.first.fromAdmin && messages.first.text.trim() == ticket.description.trim()) {
      messages.removeAt(0);
    }
    ticket.messages
      ..clear()
      ..addAll(messages);
    ticket.threadLoaded = true;
    notifyListeners();
  }

  Future<SupportTicket> create({
    required AppUser user,
    required TicketKind kind,
    required String category,
    required String subject,
    required String description,
    String? customCategory,
    List<String> links = const [],
    List<Attachment> attachments = const [],
  }) async {
    final custom = customCategory?.trim();
    final other = category == otherCategory && custom != null && custom.isNotEmpty;
    if (subject.trim().length < 5) throw const AuthException('The subject needs at least 5 characters.');
    if (description.trim().length < 10) throw const AuthException('The description needs at least 10 characters.');
    final data = kind == TicketKind.ticket
        ? await SupportApi.createTicket(
            user.role.name,
            category: _ticketCategories[category] ?? 'other',
            subject: subject,
            description: description,
            context: other ? 'Category: $custom' : null,
            links: links,
          )
        : await SupportApi.report(
            user.role.name,
            category: _reportCategories[category] ?? 'content_report',
            subject: subject,
            message: description,
            reportType: other ? custom : category,
            links: links,
          );
    final now = DateTime.now();
    final ticket = _merge(null, data, kind: kind, label: other ? custom : category)
      ..links = links
      ..attachments = [for (final a in attachments) Attachment(a.name, a.bytes, a.path, null, now)];
    _list(user).add(ticket);
    notifyListeners();
    // Files go up once the ticket exists. The ticket is already created, so
    // a failed upload is reported without losing it.
    final failed = <String>[];
    for (final file in attachments) {
      final path = file.path;
      if (path == null) continue;
      try {
        await SupportApi.attach(user.role.name, ticket.apiId, path: path, fileName: file.name);
      } catch (_) {
        failed.add(file.name);
      }
    }
    if (failed.isNotEmpty) {
      ticket.attachments = [
        for (final a in ticket.attachments)
          if (!failed.contains(a.name)) a,
      ];
      notifyListeners();
      throw AuthException('${ticket.id} was created, but ${failed.join(', ')} couldn\'t be attached.');
    }
    return ticket;
  }

  /// The API keeps up to this many files on a ticket.
  static const maxTicketFiles = 6;

  /// Adds a file to the ticket's chat (JPG, PNG, WebP or PDF, up to 5 MB).
  Future<void> sendFile(SupportTicket ticket, Attachment file) async {
    if (!ticket.status.acceptsReplies) throw const AuthException('This ticket is resolved and closed.');
    if (ticket.attachments.length >= maxTicketFiles) {
      throw const AuthException('This ticket already has the maximum of 6 files.');
    }
    final path = file.path;
    if (path == null) throw const AuthException('Choose the file again and retry.');
    await SupportApi.attach(_role, ticket.apiId, path: path, fileName: file.name);
    ticket.attachments = [...ticket.attachments, Attachment(file.name, file.bytes, path, null, DateTime.now())];
    notifyListeners();
  }

  Future<void> reply(SupportTicket ticket, String text) async {
    if (!ticket.status.acceptsReplies) throw const AuthException('This ticket is resolved and closed.');
    await SupportApi.reply(_role, ticket.apiId, text);
    ticket.messages.add(SupportMessage(fromAdmin: false, text: text.trim(), sentAt: DateTime.now()));
    notifyListeners();
  }

  /// The signed-in role, for calls made on a ticket.
  String get _role => AuthService.instance.currentUser?.role.name ?? UserRole.seeker.name;

  List<SupportTicket> _list(AppUser user) => _tickets.putIfAbsent(user.email, () => []);

  /// Replaces the user's tickets and reports with what the API returned.
  void setTickets(AppUser user, List<SupportTicket> tickets) {
    _tickets[user.email] = [...tickets];
    notifyListeners();
  }

  /// A ticket from the API, keeping the conversation already loaded for it.
  SupportTicket _merge(SupportTicket? known, Map<String, dynamic> t, {TicketKind? kind, String? label}) {
    final category = t['category'] as String? ?? 'other';
    final report = const {'content_report', 'content_duplication', 'harassment'}.contains(category);
    final ticket = SupportTicket(
      id: t['ticket_id'] as String? ?? '',
      apiId: t['id'] as String? ?? '',
      kind: kind ?? known?.kind ?? (report ? TicketKind.report : TicketKind.ticket),
      category: label ?? known?.category ?? _categoryLabels[category] ?? _titleCase(category),
      subject: t['subject'] as String? ?? '',
      description: (t['description'] as String?)?.isNotEmpty == true
          ? t['description'] as String
          : known?.description ?? '',
      createdAt: _date(t['created_at']),
      links: known?.links ?? const [],
      attachments: known?.attachments ?? const [],
    )..status = _status(t['status'] as String?);
    if (known != null) ticket.messages.addAll(known.messages);
    return ticket;
  }

  static TicketStatus _status(String? status) => switch (status) {
    'resolved' || 'closed' => TicketStatus.resolved,
    'in_progress' || 'waiting_on_user' => TicketStatus.inProgress,
    _ => TicketStatus.open,
  };

  static DateTime _date(Object? value) => (DateTime.tryParse('${value ?? ''}') ?? DateTime.now()).toLocal();

  static String _titleCase(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1).replaceAll('_', ' ');
}
