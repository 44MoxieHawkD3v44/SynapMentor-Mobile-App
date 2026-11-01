import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/community_api.dart';
import '../api/session_store.dart';
import '../core/html_entities.dart';
import 'auth_service.dart';

enum EventType {
  conference('Conference'),
  workshop('Workshop'),
  meetup('Meetup'),
  webinar('Webinar'),
  hackathon('Hackathon'),

  /// The host names the type themselves.
  other('Other');

  const EventType(this.label);
  final String label;
}

enum EventMode {
  online('Online'),
  offline('Offline'),
  hybrid('Hybrid');

  const EventMode(this.label);
  final String label;
}

/// A reaction on a community message: its emoji, as the API stores it, and
/// its name.
class Reaction {
  const Reaction._(this.emoji, this.name);

  final String emoji;
  final String name;

  /// The reactions the app offers, in picker order.
  static const all = [
    Reaction._('❤️', 'Heart'),
    Reaction._('👏', 'Clapping Hands'),
    Reaction._('👍', 'Thumbs Up'),
    Reaction._('👎', 'Thumbs Down'),
    Reaction._('😂', 'Face with Tears of Joy'),
    Reaction._('😮', 'Face with Open Mouth'),
    Reaction._('😡', 'Enraged Face'),
    Reaction._('🔥', 'Fire'),
    Reaction._('🙌', 'Raising Hands'),
    Reaction._('💯', 'Hundred Points'),
    Reaction._('🔗', 'Link'),
    Reaction._('🤝', 'Handshake'),
    Reaction._('🗣️', 'Speaking Head'),
    Reaction._('🎉', 'Party Popper'),
    Reaction._('🎊', 'Confetti Ball'),
    Reaction._('🤲', 'Palms Up Together'),
    Reaction._('👊', 'Oncoming Fist'),
    Reaction._('😳', 'Flushed Face'),
    Reaction._('😆', 'Grinning Squinting Face'),
    Reaction._('😍', 'Smiling Face with Heart-Eyes'),
  ];

  static Reaction? of(Object? emoji) => all.where((r) => r.emoji == emoji).firstOrNull;
}

class CommunityEvent {
  CommunityEvent({
    required this.id,
    required this.communityId,
    required this.type,
    required this.mode,
    required this.title,
    required this.description,
    required this.start,
    required this.end,
    required this.registrationEnds,
    this.registrationStarts,
    this.link,
    this.location,
    this.memberLimit,
    this.registered = 0,
    this.communityName,
    this.typeOther,
  });

  /// The type the host entered when [type] is [EventType.other].
  final String? typeOther;

  /// The wide banner shown across the top of event cards, and the portrait
  /// flyer shown in full in the details. Links that expire 10 minutes after
  /// they're issued (see [CommunityService.refreshExpiredArtwork]).
  String? coverUrl;
  String? posterUrl;

  /// What event cards show: the cover, else the poster.
  String? get bannerUrl => coverUrl ?? posterUrl;

  /// The type as shown: the host's own for [EventType.other].
  String get typeLabel => type == EventType.other && typeOther != null ? typeOther! : type.label;

  /// The host community's name, from the API (platform events have none).
  final String? communityName;

  final String id;
  final String communityId;
  final EventType type;
  final EventMode mode;
  final String title;
  final String description;
  final DateTime start;
  final DateTime end;

  /// Registration opens at [registrationStarts] (immediately when null) and
  /// closes at [registrationEnds].
  final DateTime? registrationStarts;
  final DateTime registrationEnds;
  final String? link;
  final String? location;

  /// Maximum registrations, if limited.
  final int? memberLimit;
  int registered;

  bool get full => memberLimit != null && registered >= memberLimit!;

  bool get registrationNotStarted => registrationStarts != null && DateTime.now().isBefore(registrationStarts!);

  bool get registrationOpen => !registrationNotStarted && DateTime.now().isBefore(registrationEnds) && !full;
}

class CommunityMessage {
  CommunityMessage({
    required this.author,
    required this.text,
    required this.sentAt,
    this.fileName,
    this.fileUrl,
    this.fileType,
    this.localPath,
    this.quotedId,
    this.quotedText,
    this.id = '',
    this.threadId = '',
  });

  final String id;
  final String threadId;

  /// The author's pseudo name; real identities never appear in communities.
  final String author;
  final String text;
  final DateTime sentAt;
  final String? fileName;

  /// Where the shared file can be opened, and its type.
  final String? fileUrl;
  final String? fileType;

  /// The file on this device, for one the user just shared.
  final String? localPath;

  /// The message this one replies to, and its text when it was quoted.
  final String? quotedId;
  final String? quotedText;

  final reactions = <Reaction, Set<String>>{};
}

class Discussion {
  Discussion({
    required this.id,
    required this.title,
    required this.description,
    required this.author,
    required this.createdAt,
    this.general = false,
  });

  final String id;
  final String title;
  final String description;
  final String author;
  final DateTime createdAt;

  /// The community's main chat, always listed first.
  final bool general;

  /// Pinned threads are listed right after General.
  bool pinned = false;

  /// Locked threads accept no new messages, except from the owner.
  bool locked = false;
  final messages = <CommunityMessage>[];
}

class Community {
  Community({
    required this.id,
    required this.name,
    required this.tagline,
    required this.about,
    required this.scope,
    required this.domain,
    required this.topics,
    required this.technologies,
    required this.rules,
    required this.members,
    this.featured = false,
    this.private = false,
    this.inviteCode,
  });

  /// Members including the user, from the API.
  int? memberTotal;

  /// The signed-in solver runs this community (from the API).
  bool ownedByMe = false;

  /// Member and banned user ids by pseudo name, for the owner's tools.
  final memberIds = <String, String>{};
  final bannedIds = <String, String>{};

  final String id;
  final String name;

  /// The community's purpose, in one line.
  final String tagline;
  final String about;
  final String scope;
  final String domain;
  final List<String> topics;
  final List<String> technologies;

  /// One rule per line; the owner can replace them.
  List<String> rules;

  /// Other members, by pseudo name.
  final List<String> members;
  final bool featured;

  /// Private communities are joinable only with their invite code.
  final bool private;

  /// Joins the community directly, also as a link. The owner can renew it.
  String? inviteCode;

  /// The community's logo, a link that expires 10 minutes after it's issued.
  String? logoUrl;

  /// Pseudo names banned by the owner; they can't join again.
  final banned = <String>{};

  /// The bans with their reason and end, newest first (owner's tools).
  final bans = <CommunityBan>[];

  /// The moderation and activity log, newest first (owner's tools).
  final activity = <CommunityActivity>[];
  final discussions = <Discussion>[];

  String get initials => name.split(' ').take(2).map((w) => w[0]).join().toUpperCase();
}

/// A member banned from a community: permanently, or until [expiresAt].
class CommunityBan {
  const CommunityBan({
    required this.userId,
    required this.member,
    required this.reason,
    required this.bannedAt,
    this.expiresAt,
    this.bannedBy,
  });

  final String userId;

  /// The member's pseudo name.
  final String member;
  final String reason;
  final DateTime bannedAt;
  final DateTime? expiresAt;
  final String? bannedBy;

  bool get permanent => expiresAt == null;

  /// A temporary ban whose end has passed.
  bool get ended => expiresAt != null && DateTime.now().isAfter(expiresAt!);
}

/// One entry of a community's moderation and activity log.
class CommunityActivity {
  const CommunityActivity({
    required this.id,
    required this.action,
    required this.at,
    this.member,
    this.performer,
    this.details = const {},
  });

  final String id;

  /// The API's action type, e.g. `member_banned`.
  final String action;
  final DateTime at;

  /// Who it happened to and who did it, by pseudo name.
  final String? member;
  final String? performer;
  final Map<String, dynamic> details;

  /// The action in words: `member_banned` reads "Member banned".
  String get label {
    final words = action.replaceAll(RegExp(r'[_\-.]+'), ' ').trim();
    return words.isEmpty ? 'Activity' : '${words[0].toUpperCase()}${words.substring(1).toLowerCase()}';
  }

  /// The reason or subject recorded with it, if any.
  String? get note {
    for (final key in const ['reason', 'title', 'thread_title', 'name', 'message']) {
      final v = details[key];
      if (v is String && v.trim().isNotEmpty) return decodeHtmlEntities(v.trim());
    }
    return null;
  }
}

enum RequestStatus {
  pending('Pending'),
  approved('Approved'),
  rejected('Rejected');

  const RequestStatus(this.label);
  final String label;
}

/// A solver's request to create a community, reviewed by the admin.
class CommunityRequest {
  CommunityRequest({
    required this.id,
    required this.name,
    required this.purpose,
    required this.scope,
    required this.technologies,
    required this.submittedAt,
  });

  final String id;
  final String name;
  final String purpose;
  final String scope;
  final List<String> technologies;
  final DateTime submittedAt;
  RequestStatus status = RequestStatus.pending;
  String? rejectionReason;

  /// The community created on approval.
  String? communityId;
}

/// Communities: membership, discussions, events and the solver's owner tools,
/// from the communities API.
class CommunityService extends ChangeNotifier {
  static final CommunityService instance = CommunityService();

  /// The thread on screen, so its new messages show at once and don't also
  /// pop up as notifications.
  ({AppUser user, Discussion discussion})? openThread;

  /// Reloads the thread on screen if [threadId] is it (or not given).
  Future<void> refreshOpenThread([String? threadId]) async {
    final open = openThread;
    if (open == null || (threadId != null && open.discussion.id != threadId)) return;
    await loadMessages(open.user, open.discussion);
  }

  // ---- API -----------------------------------------------------------------------

  /// Loads the public and joined communities and the events.
  /// Loads the public and joined communities and the events, and for solvers
  /// the communities they run and their requests. A solver's own communities
  /// load even when browsing is refused (e.g. before verification).
  Future<void> load(AppUser user) async {
    final solver = user.role == UserRole.solver;
    final owner = solver ? _loadOwned(user) : Future<void>.value();
    try {
      final results = await Future.wait([CommunityApi.communities(), CommunityApi.joined(), CommunityApi.events()]);
      final known = {for (final c in _communities) c.id: c};
      final byId = <String, Community>{};
      for (final data in [...results[0], ...results[1]]) {
        final c = _communityFrom(data, known[data['id']]);
        byId[c.id] = c;
      }
      _communities
        ..removeWhere((c) => !c.ownedByMe)
        ..removeWhere((c) => byId.containsKey(c.id))
        ..addAll(byId.values);
      _logosLoadedAt = DateTime.now();
      _joined[user.email] = {for (final c in results[1]) '${c['id']}'};
      final registered = _registrations.putIfAbsent(user.email, () => {})..clear();
      _eventsLoadedAt = DateTime.now();
      _events
        ..clear()
        ..addAll([for (final e in results[2]) ?_eventFrom(e)]);
      for (final e in results[2]) {
        if (e['is_registered'] == true) registered.add('${e['id']}');
      }
    } finally {
      await owner;
      notifyListeners();
    }
  }

  /// The solver's own communities (with invite codes) and creation requests.
  Future<void> _loadOwned(AppUser user) async {
    final results = await Future.wait([CommunityApi.myCommunities(), CommunityApi.requests()]);
    final known = {for (final c in _communities) c.id: c};
    final owned = [
      for (final data in results[0])
        _communityFrom(data, known[data['id']])
          ..ownedByMe = true
          ..inviteCode = data['invitation_code'] as String?,
    ];
    final ids = {for (final c in owned) c.id};
    _communities
      ..removeWhere((c) => ids.contains(c.id) || c.ownedByMe)
      ..addAll(owned);
    _requests[user.email] = [
      for (final r in results[1])
        CommunityRequest(
            id: '${r['id']}',
            name: decodeHtmlEntities(r['name'] as String? ?? ''),
            purpose: decodeHtmlEntities(r['purpose'] as String? ?? ''),
            scope: decodeHtmlEntities(r['scope'] as String? ?? ''),
            technologies: [for (final t in r['technologies'] as List? ?? const []) '$t'],
            submittedAt: _date(r['created_at']),
          )
          ..status = switch (r['status']) {
            'approved' => RequestStatus.approved,
            'rejected' => RequestStatus.rejected,
            _ => RequestStatus.pending,
          }
          ..rejectionReason = r['rejection_reason'] as String?
          ..communityId = owned.where((c) => c.name == decodeHtmlEntities(r['name'] as String? ?? '')).firstOrNull?.id,
    ];
  }

  /// Loads what the owner's tools need: member and banned ids, and an invite
  /// code if the community has none yet.
  Future<void> prepareOwnerTools(AppUser owner, Community c) async {
    if (!isOwner(owner, c)) return;
    final results = await Future.wait([CommunityApi.members(c.id), CommunityApi.bans(c.id)]);
    final me = owner.profile.pseudoName;
    c.memberIds
      ..clear()
      ..addAll({
        for (final m in results[0])
          if (m['pseudo_name'] is String && m['pseudo_name'] != me) m['pseudo_name'] as String: '${m['user_id']}',
      });
    c.members
      ..clear()
      ..addAll(c.memberIds.keys);
    _applyBans(c, results[1]);
    c.inviteCode ??= await CommunityApi.newInviteCode(c.id);
    notifyListeners();
  }

  void _applyBans(Community c, List<Map<String, dynamic>> bans) {
    c.bannedIds
      ..clear()
      ..addAll({for (final b in bans) '${b['user_name'] ?? 'Member'}': '${b['user_id']}'});
    c.banned
      ..clear()
      ..addAll(c.bannedIds.keys);
    c.bans
      ..clear()
      ..addAll([
        for (final b in bans)
          CommunityBan(
            userId: '${b['user_id']}',
            member: '${b['user_name'] ?? 'Member'}',
            reason: decodeHtmlEntities(b['reason'] as String? ?? ''),
            bannedAt: _date(b['banned_at']),
            expiresAt: b['is_permanent'] == true ? null : DateTime.tryParse('${b['expires_at']}')?.toLocal(),
            bannedBy: b['banned_by_name'] as String?,
          ),
      ]);
  }

  /// Loads a community's discussions and members, and marks it read.
  Future<void> loadThreads(AppUser user, Community c) async {
    final results = await Future.wait([CommunityApi.threads(c.id), CommunityApi.members(c.id)]);
    final known = {for (final d in c.discussions) d.id: d};
    final me = user.profile.pseudoName;
    c.discussions
      ..clear()
      ..addAll([for (final t in results[0]) _discussionFrom(t, known[t['id']], user)]);
    c.memberIds
      ..clear()
      ..addAll({
        for (final m in results[1])
          if (m['pseudo_name'] is String && m['pseudo_name'] != me) m['pseudo_name'] as String: '${m['user_id']}',
      });
    c.members
      ..clear()
      ..addAll(c.memberIds.keys);
    notifyListeners();
    unawaited(CommunityApi.markRead(c.id).catchError((Object _) {}));
  }

  /// Loads a discussion's messages.
  Future<void> loadMessages(AppUser user, Discussion d) async {
    final list = await CommunityApi.messages(d.id);
    // Files the user just shared keep opening from the device copy.
    final local = {
      for (final m in d.messages)
        if (m.localPath != null) m.id: m.localPath,
    };
    d.messages
      ..clear()
      ..addAll([for (final m in list) _messageFrom(m, d.id, user, localPath: local['${m['id']}'])]);
    notifyListeners();
  }

  /// A logo link the app can show. The upload's response holds the storage
  /// key instead, which isn't a link.
  static String? _logoLink(Object? value) {
    final url = value is String ? value.trim() : '';
    return url.startsWith('http://') || url.startsWith('https://') ? url : null;
  }

  /// When the logo links were last fetched; they expire after 10 minutes.
  DateTime? _logosLoadedAt;
  bool _refreshingLogos = false;

  /// Called when a logo fails to load: once the links are close to expiring,
  /// fetches fresh ones and updates the communities on screen (once per
  /// fetch, so a broken picture can't loop).
  void refreshExpiredLogos() {
    final user = AuthService.instance.currentUser;
    final at = _logosLoadedAt;
    if (user == null || _refreshingLogos || at == null) return;
    if (DateTime.now().difference(at) < const Duration(minutes: 8)) return;
    _refreshingLogos = true;
    Future.wait([
          CommunityApi.communities().catchError((Object _) => <Map<String, dynamic>>[]),
          CommunityApi.joined().catchError((Object _) => <Map<String, dynamic>>[]),
          if (user.role == UserRole.solver)
            CommunityApi.myCommunities().catchError((Object _) => <Map<String, dynamic>>[]),
        ])
        .then((lists) {
          final fresh = {
            for (final list in lists)
              for (final c in list) '${c['id']}': ?_logoLink(c['logo_url']),
          };
          for (final c in _communities) {
            c.logoUrl = fresh[c.id] ?? c.logoUrl;
          }
          _logosLoadedAt = DateTime.now();
          notifyListeners();
        })
        .whenComplete(() => _refreshingLogos = false);
  }

  /// Uploads [c]'s logo, or replaces it (owner only; an image up to 2 MB),
  /// then shows the new one.
  Future<void> uploadLogo(AppUser owner, Community c, {required String path, required String fileName}) async {
    _requireOwner(owner, c);
    await CommunityApi.uploadLogo(c.id, path: path, fileName: fileName);
    final data = await CommunityApi.detail(c.id).catchError((Object _) => <String, dynamic>{});
    c.logoUrl = _logoLink(data['logo_url']) ?? c.logoUrl;
    notifyListeners();
  }

  Community _communityFrom(Map<String, dynamic> c, Community? known) {
    final purpose = decodeHtmlEntities(c['purpose'] as String? ?? '').trim();
    final technologies = [for (final t in c['technologies'] as List? ?? const []) decodeHtmlEntities('$t')];
    final scope = decodeHtmlEntities(c['scope'] as String? ?? '').trim();
    final community =
        Community(
            id: '${c['id']}',
            name: decodeHtmlEntities(c['name'] as String? ?? 'Community'),
            tagline: purpose.split(RegExp(r'(?<=[.!?])\s|\n')).first,
            about: purpose,
            scope: scope,
            domain: scope.isEmpty ? 'General' : scope,
            topics: technologies.take(2).toList(),
            technologies: technologies,
            rules: [
              for (final line in decodeHtmlEntities(c['rules'] as String? ?? '').split('\n'))
                if (line.replaceFirst(RegExp(r'^[\s\-•*\d.)]+'), '').trim().isNotEmpty)
                  line.replaceFirst(RegExp(r'^[\s\-•*\d.)]+'), '').trim(),
            ],
            members: known?.members ?? [],
            featured: c['is_featured'] == true,
            private: c['is_public'] == false,
            inviteCode: known?.inviteCode,
          )
          ..memberTotal = c['member_count'] is int ? c['member_count'] as int : null
          ..logoUrl = _logoLink(c['logo_url']) ?? known?.logoUrl
          ..ownedByMe = known?.ownedByMe ?? (c['owner_id'] != null && c['owner_id'] == SessionStore.instance.userId);
    if (known != null) community.discussions.addAll(known.discussions);
    return community;
  }

  Discussion _discussionFrom(Map<String, dynamic> t, Discussion? known, AppUser user) {
    final title = decodeHtmlEntities(t['title'] as String? ?? '');
    final mine = t['creator_id'] != null && t['creator_id'] == SessionStore.instance.userId;
    final d =
        Discussion(
            id: '${t['id']}',
            title: title,
            description: decodeHtmlEntities(t['description'] as String? ?? ''),
            author: mine ? _me(user) : 'Member',
            createdAt: _date(t['created_at']),
            general: title.trim().toLowerCase() == 'general',
          )
          ..pinned = t['pinned'] == true
          ..locked = t['is_locked'] == true;
    if (known != null) d.messages.addAll(known.messages);
    return d;
  }

  CommunityMessage _messageFrom(Map<String, dynamic> m, String threadId, AppUser user, {String? localPath}) {
    final file = m['file_context'] is Map ? m['file_context'] as Map : const {};
    final message = CommunityMessage(
      id: '${m['id']}',
      threadId: threadId,
      author: m['sender_pseudo_name'] as String? ?? 'Member',
      text: decodeHtmlEntities(m['message'] as String? ?? ''),
      sentAt: _date(m['created_at']),
      fileName: (m['file_url'] as String?)?.isNotEmpty == true ? (file['file_name'] as String? ?? 'File') : null,
      fileUrl: (m['file_url'] as String?)?.startsWith('http') == true ? m['file_url'] as String : null,
      fileType: file['content_type'] as String?,
      localPath: localPath,
      quotedId: m['quoted_message_id'] as String? ?? m['parent_message_id'] as String?,
      quotedText: m['quoted_text'] is String ? decodeHtmlEntities(m['quoted_text'] as String) : null,
    );
    // The user's own reaction is kept by pseudo name, as the screens expect.
    final me = _me(user);
    for (final r in m['reactions'] as List? ?? const []) {
      if (r is! Map) continue;
      final reaction = Reaction.of(r['emoji']);
      if (reaction == null) continue;
      final ids = {for (final id in r['user_ids'] as List? ?? const []) '$id'}..remove(SessionStore.instance.userId);
      if (r['mine'] == true) ids.add(me);
      if (ids.isNotEmpty) message.reactions[reaction] = ids;
    }
    return message;
  }

  CommunityEvent? _eventFrom(Map<String, dynamic> e) {
    final start = DateTime.tryParse('${e['start_time']}');
    if (start == null) return null;
    final end = DateTime.tryParse('${e['end_time']}')?.toLocal() ?? start.toLocal().add(const Duration(hours: 1));
    String? text(String key) =>
        (e[key] as String?)?.trim().isNotEmpty == true ? decodeHtmlEntities((e[key] as String).trim()) : null;
    final type = '${e['event_type']}'.toLowerCase();
    final mode = '${e['event_mode']}'.toLowerCase();
    return CommunityEvent(
        id: '${e['id']}',
        communityId: e['community_id'] as String? ?? '',
        communityName: text('community_name'),
        type: EventType.values.where((t) => t.name == type).firstOrNull ?? EventType.meetup,
        typeOther: type == EventType.other.name ? text('event_type_other') : null,
        mode: EventMode.values.where((m) => m.name == mode).firstOrNull ?? EventMode.online,
        title: decodeHtmlEntities(e['name'] as String? ?? 'Event'),
        description: decodeHtmlEntities(e['description'] as String? ?? ''),
        start: start.toLocal(),
        end: end,
        registrationStarts: DateTime.tryParse('${e['registration_start_time']}')?.toLocal(),
        registrationEnds: DateTime.tryParse('${e['registration_end_time']}')?.toLocal() ?? end,
        link: text('registration_url') ?? text('location_url'),
        location: [text('location_name'), text('location_address')].nonNulls.join(', ').trim().isEmpty
            ? null
            : [text('location_name'), text('location_address')].nonNulls.join(', '),
        memberLimit: e['max_attendees'] as int?,
        registered: e['registered_count'] is int ? e['registered_count'] as int : 0,
      )
      ..coverUrl = _artworkLink(e['cover_image_url'])
      ..posterUrl = _artworkLink(e['poster_url']);
  }

  /// An event artwork link the app can show (signed links only).
  static String? _artworkLink(Object? value) {
    final url = value is String ? value.trim() : '';
    return url.startsWith('http://') || url.startsWith('https://') ? url : null;
  }

  /// When the events (and their artwork links) were last fetched.
  DateTime? _eventsLoadedAt;
  bool _refreshingArtwork = false;

  /// Called when an event picture fails to load: once the links are close to
  /// expiring (10 minutes), fetches fresh ones and updates the events on
  /// screen. Once per fetch, so a broken picture can't loop.
  void refreshExpiredArtwork() {
    final at = _eventsLoadedAt;
    if (_refreshingArtwork || at == null || DateTime.now().difference(at) < const Duration(minutes: 8)) return;
    _refreshingArtwork = true;
    CommunityApi.events()
        .then((list) {
          final fresh = {for (final e in list) '${e['id']}': e};
          for (final event in _events) {
            final data = fresh[event.id];
            if (data == null) continue;
            event
              ..coverUrl = _artworkLink(data['cover_image_url'])
              ..posterUrl = _artworkLink(data['poster_url']);
          }
          _eventsLoadedAt = DateTime.now();
          notifyListeners();
        })
        .catchError((Object _) {})
        .whenComplete(() => _refreshingArtwork = false);
  }

  /// Uploads or replaces [event]'s cover ([cover] true) or poster (owner
  /// only, while it's upcoming or ongoing), and shows it.
  Future<void> uploadEventArtwork(
    AppUser owner,
    Community c,
    CommunityEvent event, {
    required bool cover,
    required String path,
    required String fileName,
  }) async {
    _requireOwner(owner, c);
    final url = _artworkLink(
      await CommunityApi.uploadEventArtwork(event.id, cover ? 'cover' : 'poster', path: path, fileName: fileName),
    );
    if (cover) {
      event.coverUrl = url ?? event.coverUrl;
    } else {
      event.posterUrl = url ?? event.posterUrl;
    }
    notifyListeners();
  }

  static DateTime _date(Object? value) => (DateTime.tryParse('${value ?? ''}') ?? DateTime.now()).toLocal();

  /// The name shown for an event's host.
  String hostOf(CommunityEvent e) =>
      e.communityName ?? _communities.where((c) => c.id == e.communityId).firstOrNull?.name ?? 'Synap Mentor';

  // Loaded from the API.
  final _communities = <Community>[];
  final _events = <CommunityEvent>[];
  final _joined = <String, Set<String>>{};
  final _muted = <String, Set<String>>{};
  final _registrations = <String, Set<String>>{};

  /// Replaces the communities with what the API returned.
  void setCommunities(List<Community> communities) {
    _communities
      ..clear()
      ..addAll(communities);
    notifyListeners();
  }

  /// Replaces the community events with what the API returned.
  void setEvents(List<CommunityEvent> events) {
    _events
      ..clear()
      ..addAll(events);
    notifyListeners();
  }

  /// Sets the communities the user has joined, from the API.
  void setJoined(AppUser user, Set<String> communityIds) {
    _joined[user.email] = {...communityIds};
    notifyListeners();
  }

  /// Sets the solver's community requests, from the API.
  void setRequests(AppUser user, List<CommunityRequest> requests) {
    _requests[user.email] = [...requests];
    notifyListeners();
  }

  List<String> get domains => {for (final c in _communities) c.domain}.toList()..sort();

  List<String> get topics => {for (final c in _communities) ...c.topics}.toList()..sort();

  /// Public communities; private ones are reached only by invite code.
  List<Community> get publicCommunities => _communities.where((c) => !c.private).toList();

  Community byId(String id) => _communities.firstWhere((c) => c.id == id);

  /// Owners are always members of their own community.
  bool isMember(AppUser user, Community c) => _joinedBy(user).contains(c.id) || isOwner(user, c);

  /// The signed-in solver runs [c] (from the API).
  bool isOwner(AppUser user, Community c) => user.role == UserRole.solver && c.ownedByMe;

  /// The community a solver owns, if any.
  Community? ownedBy(AppUser user) => _communities.where((c) => isOwner(user, c)).firstOrNull;

  /// Every community the solver owns.
  List<Community> ownedAll(AppUser user) => _communities.where((c) => isOwner(user, c)).toList();

  // ---- Community requests (solvers) ------------------------------------------------

  final _requests = <String, List<CommunityRequest>>{};

  /// Newest first.
  List<CommunityRequest> requests(AppUser user) => _requests.putIfAbsent(user.email, () => []);

  /// Sends a request to the admin. The community is created on approval.
  Future<CommunityRequest> submitRequest(
    AppUser user, {
    required String name,
    required String purpose,
    required String scope,
    required List<String> technologies,
  }) async {
    final title = name.trim();
    if (title.length < 3) throw const AuthException('The community name needs at least 3 characters.');
    if (purpose.trim().length < 10) throw const AuthException('Describe the purpose in at least 10 characters.');
    if (scope.trim().length < 10) throw const AuthException('Describe the scope in at least 10 characters.');
    if (technologies.isEmpty) throw const AuthException('Add at least one technology.');
    final taken =
        _communities.any((c) => c.name.toLowerCase() == title.toLowerCase()) ||
        requests(user).any((r) => r.status == RequestStatus.pending && r.name.toLowerCase() == title.toLowerCase());
    if (taken) throw const AuthException('A community with that name already exists or is under review.');
    final id = await CommunityApi.submitRequest(
      name: title,
      purpose: purpose,
      scope: scope,
      technologies: technologies,
    );
    final request = CommunityRequest(
      id: id ?? 'req-${DateTime.now().millisecondsSinceEpoch}',
      name: title,
      purpose: purpose.trim(),
      scope: scope.trim(),
      technologies: technologies,
      submittedAt: DateTime.now(),
    );
    requests(user).insert(0, request);
    notifyListeners();
    return request;
  }

  // ---- Owner tools -------------------------------------------------------------------

  /// The owner's invite code, created by the server on first use (see
  /// [prepareOwnerTools]).
  String inviteCodeOf(Community c) => c.inviteCode ?? '';

  String inviteLink(Community c) => 'https://synapmentor.app/c/${inviteCodeOf(c)}';

  /// Replaces the code; the old code and link stop working.
  Future<void> renewInvite(AppUser owner, Community c) async {
    _requireOwner(owner, c);
    c.inviteCode = await CommunityApi.newInviteCode(c.id);
    notifyListeners();
  }

  Future<void> togglePin(AppUser owner, Community c, Discussion d) async {
    _requireOwner(owner, c);
    await CommunityApi.pin(c.id, d.id, on: !d.pinned);
    d.pinned = !d.pinned;
    notifyListeners();
  }

  Future<void> toggleLock(AppUser owner, Community c, Discussion d) async {
    _requireOwner(owner, c);
    await CommunityApi.lock(c.id, d.id, on: !d.locked);
    d.locked = !d.locked;
    notifyListeners();
  }

  /// [reason] (10+ characters when given) is recorded with the deletion.
  Future<void> deleteDiscussion(AppUser owner, Community c, Discussion d, {String? reason}) async {
    _requireOwner(owner, c);
    if (d.general) throw const AuthException('The General chat can\'t be deleted.');
    final why = reason?.trim() ?? '';
    if (why.isNotEmpty && why.length < 10) throw const AuthException('The reason needs at least 10 characters.');
    await CommunityApi.deleteThread(c.id, d.id, why.isEmpty ? _ownerReason : why);
    c.discussions.remove(d);
    notifyListeners();
  }

  /// Discussions in display order: General, pinned threads, then the rest.
  List<Discussion> discussionsOf(Community c) => [
    ...c.discussions.where((d) => d.general),
    ...c.discussions.where((d) => !d.general && d.pinned),
    ...c.discussions.where((d) => !d.general && !d.pinned),
  ];

  /// Removes a member. Kicked members can join again; banned ones can't
  /// until [until] (never, when it's null). [reason] (5+ characters when
  /// given) is recorded with it.
  Future<void> removeMember(
    AppUser owner,
    Community c,
    String member, {
    required bool ban,
    String? reason,
    DateTime? until,
  }) async {
    _requireOwner(owner, c);
    final why = reason?.trim() ?? '';
    if (why.isNotEmpty && why.length < 5) throw const AuthException('The reason needs at least 5 characters.');
    if (until != null && !until.isAfter(DateTime.now())) {
      throw const AuthException('The ban must end in the future. Leave the date blank for a permanent ban.');
    }
    final recorded = why.isEmpty ? _ownerReason : why;
    final id = c.memberIds[member];
    if (id == null) throw const AuthException('That member couldn\'t be found. Refresh and try again.');
    ban ? await CommunityApi.ban(c.id, id, recorded, until: until) : await CommunityApi.kick(c.id, id, recorded);
    c.memberIds.remove(member);
    if (ban) c.bannedIds[member] = id;
    if (c.memberTotal != null) c.memberTotal = c.memberTotal! - 1;
    c.members.remove(member);
    if (ban) {
      c.banned.add(member);
      c.bans
        ..removeWhere((b) => b.member == member)
        ..insert(
          0,
          CommunityBan(
            userId: id,
            member: member,
            reason: recorded,
            bannedAt: DateTime.now(),
            expiresAt: until,
            bannedBy: _me(owner),
          ),
        );
    }
    notifyListeners();
  }

  Future<void> unban(AppUser owner, Community c, String member) async {
    _requireOwner(owner, c);
    final id = c.bannedIds.remove(member);
    if (id != null) await CommunityApi.unban(c.id, id, _ownerReason);
    c.banned.remove(member);
    c.bans.removeWhere((b) => b.member == member);
    notifyListeners();
  }

  /// Loads what the Moderate tools show: members, bans, discussions and the
  /// activity log.
  Future<void> loadModeration(AppUser owner, Community c) async {
    _requireOwner(owner, c);
    final results = await Future.wait([
      CommunityApi.members(c.id),
      CommunityApi.bans(c.id),
      CommunityApi.threads(c.id),
      CommunityApi.activity(c.id),
    ]);
    final me = owner.profile.pseudoName;
    c.memberIds
      ..clear()
      ..addAll({
        for (final m in results[0])
          if (m['pseudo_name'] is String && m['pseudo_name'] != me) m['pseudo_name'] as String: '${m['user_id']}',
      });
    c.members
      ..clear()
      ..addAll(c.memberIds.keys);
    _applyBans(c, results[1]);
    final known = {for (final d in c.discussions) d.id: d};
    c.discussions
      ..clear()
      ..addAll([for (final t in results[2]) _discussionFrom(t, known[t['id']], owner)]);
    c.activity
      ..clear()
      ..addAll([
        for (final a in results[3])
          CommunityActivity(
            id: '${a['id']}',
            action: a['action_type'] as String? ?? '',
            at: _date(a['created_at']),
            member: a['user_pseudo_name'] as String?,
            performer: a['performer_pseudo_name'] as String?,
            details: a['details'] is Map ? Map<String, dynamic>.from(a['details'] as Map) : const {},
          ),
      ]);
    notifyListeners();
  }

  /// Replaces the community rules, one per line (none clears them).
  Future<void> setRules(AppUser owner, Community c, List<String> rules) async {
    _requireOwner(owner, c);
    final lines = [
      for (final r in rules)
        if (r.trim().isNotEmpty) r.trim(),
    ];
    final text = lines.join('\n');
    if (text.length > 5000) throw const AuthException('Keep the rules under 5,000 characters.');
    await CommunityApi.setRules(c.id, text);
    c.rules = lines;
    notifyListeners();
  }

  /// The API asks owners for a reason when they moderate; the app's owner
  /// tools don't ask, so this one is recorded.
  static const _ownerReason = 'Moderated by the community owner.';

  void _requireOwner(AppUser user, Community c) {
    if (!isOwner(user, c)) throw const AuthException('Only the community owner can do that.');
  }

  /// Activity figures for the owner.
  ({int members, int discussions, int messages, int events, int registrations}) statsOf(AppUser owner, Community c) {
    final events = _events.where((e) => e.communityId == c.id).toList();
    return (
      members: memberCount(owner, c),
      discussions: c.discussions.where((d) => !d.general).length,
      messages: c.discussions.fold(0, (sum, d) => sum + d.messages.length),
      events: events.length,
      registrations: events.fold(0, (sum, e) => sum + e.registered),
    );
  }

  List<CommunityEvent> eventsOf(Community c) => events.where((e) => e.communityId == c.id).toList();

  /// Creates an event in the owner's community. Members register from Events.
  Future<CommunityEvent> createEvent(
    AppUser owner,
    Community c, {
    required EventType type,
    String? typeOther,
    required EventMode mode,
    required String title,
    required String description,
    required DateTime start,
    required DateTime end,
    required DateTime registrationStarts,
    required DateTime registrationEnds,
    String? link,
    String? location,
    int? memberLimit,
    ({String path, String name})? cover,
    ({String path, String name})? poster,
  }) async {
    _requireOwner(owner, c);
    lastArtworkError = null;
    final otherType = _checkEvent(
      type: type,
      typeOther: typeOther,
      mode: mode,
      title: title,
      description: description,
      start: start,
      end: end,
      registrationStarts: registrationStarts,
      registrationEnds: registrationEnds,
      link: link,
      location: location,
      memberLimit: memberLimit,
    );
    String? text(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
    final created = _eventFrom(
      await CommunityApi.createEvent({
        'community_id': c.id,
        'name': title.trim(),
        'description': description.trim(),
        'event_type': type.name,
        'event_type_other': ?otherType,
        'event_mode': mode.name,
        'start_time': start.toUtc().toIso8601String(),
        'end_time': end.toUtc().toIso8601String(),
        'registration_start_time': registrationStarts.toUtc().toIso8601String(),
        'registration_end_time': registrationEnds.toUtc().toIso8601String(),
        'max_attendees': ?memberLimit,
        'registration_url': ?text(link),
        'location_name': ?text(location),
      }),
    );
    if (created == null) throw const AuthException('The event couldn\'t be created. Please try again.');
    // Keep the custom type even if the response leaves it out.
    final event = otherType != null && created.typeOther == null ? _withTypeOther(created, otherType) : created;
    _events.add(event);
    notifyListeners();
    // The event exists either way; artwork that fails can be added later.
    for (final (isCover, file) in [(true, cover), (false, poster)]) {
      if (file == null) continue;
      try {
        await uploadEventArtwork(owner, c, event, cover: isCover, path: file.path, fileName: file.name);
      } on AuthException catch (e) {
        lastArtworkError = 'The ${isCover ? 'cover image' : 'poster'} couldn\'t be added: ${e.message}';
      }
    }
    return event;
  }

  /// Why artwork chosen for the last created event couldn't be added, if so.
  String? lastArtworkError;

  /// The rules for an event's details; returns the custom type (for Other).
  static String? _checkEvent({
    required EventType type,
    String? typeOther,
    required EventMode mode,
    required String title,
    required String description,
    required DateTime start,
    required DateTime end,
    required DateTime registrationStarts,
    required DateTime registrationEnds,
    String? link,
    String? location,
    int? memberLimit,
  }) {
    final otherType = type == EventType.other ? typeOther?.trim() ?? '' : null;
    if (otherType != null && otherType.length < 2) throw const AuthException('Enter the type of event.');
    if (otherType != null && otherType.length > 50) {
      throw const AuthException('Keep the event type under 50 characters.');
    }
    if (title.trim().length < 5) throw const AuthException('The event name needs at least 5 characters.');
    if (description.trim().length < 10) throw const AuthException('The description needs at least 10 characters.');
    if (!end.isAfter(start)) throw const AuthException('The event must end after it starts.');
    if (!registrationEnds.isAfter(registrationStarts)) {
      throw const AuthException('Registration must close after it opens.');
    }
    if (registrationEnds.isAfter(start)) throw const AuthException('Registration must close before the event starts.');
    if (mode != EventMode.offline && (link == null || link.trim().isEmpty)) {
      throw const AuthException('Add the link for online and hybrid events.');
    }
    // Optional for offline events, but it must be a full web link when given.
    final url = link == null ? null : Uri.tryParse(link.trim());
    if (link != null && link.trim().isNotEmpty && (url == null || !url.hasScheme || !url.scheme.startsWith('http'))) {
      throw const AuthException('Enter the event link in full, starting with https://');
    }
    if (mode != EventMode.online && (location == null || location.trim().isEmpty)) {
      throw const AuthException('Add the venue for offline and hybrid events.');
    }
    if (memberLimit != null && memberLimit < 1) throw const AuthException('The member limit must be at least 1.');
    return otherType;
  }

  /// Why [event] can't be edited any more (started, completed or cancelled),
  /// or null when it can. Edits are unlimited until then.
  Future<String?> eventEditBlocked(CommunityEvent event) async {
    final s = await CommunityApi.eventEditStatus(event.id);
    if (s['editable'] != false) return null;
    final reason = '${s['reason'] ?? ''}'.trim();
    return reason.isEmpty ? 'This event can no longer be edited.' : reason;
  }

  /// Saves the host's changes to [event]: only what changed is sent (dates go
  /// together, as the server needs the registration window with them), then
  /// the event is read again.
  Future<CommunityEvent> updateEvent(
    AppUser owner,
    Community c,
    CommunityEvent event, {
    required EventType type,
    String? typeOther,
    required EventMode mode,
    required String title,
    required String description,
    required DateTime start,
    required DateTime end,
    required DateTime registrationStarts,
    required DateTime registrationEnds,
    String? link,
    String? location,
    int? memberLimit,
  }) async {
    _requireOwner(owner, c);
    final otherType = _checkEvent(
      type: type,
      typeOther: typeOther,
      mode: mode,
      title: title,
      description: description,
      start: start,
      end: end,
      registrationStarts: registrationStarts,
      registrationEnds: registrationEnds,
      link: link,
      location: location,
      memberLimit: memberLimit,
    );
    String utc(DateTime t) => t.toUtc().toIso8601String();
    final scheduleChanged =
        !start.isAtSameMomentAs(event.start) ||
        !end.isAtSameMomentAs(event.end) ||
        event.registrationStarts == null ||
        !registrationStarts.isAtSameMomentAs(event.registrationStarts!) ||
        !registrationEnds.isAtSameMomentAs(event.registrationEnds);
    final newLink = (link ?? '').trim();
    final newLocation = mode == EventMode.online ? '' : (location ?? '').trim();
    final fields = <String, dynamic>{
      if (title.trim() != event.title) 'name': title.trim(),
      if (description.trim() != event.description) 'description': description.trim(),
      if (type != event.type || otherType != event.typeOther) ...{
        'event_type': type.name,
        'event_type_other': ?otherType,
      },
      if (mode != event.mode) 'event_mode': mode.name,
      if (scheduleChanged) ...{
        'start_time': utc(start),
        'end_time': utc(end),
        'registration_start_time': utc(registrationStarts),
        'registration_end_time': utc(registrationEnds),
      },
      // 0 and "" clear the limit, link and venue.
      if (memberLimit != event.memberLimit) 'max_attendees': memberLimit ?? 0,
      if (newLink != (event.link ?? '')) 'registration_url': newLink,
      if (newLocation != (event.location ?? '')) ...{'location_name': newLocation, 'location_address': ''},
    };
    if (fields.isEmpty) return event;
    await CommunityApi.updateEvent(event.id, fields);
    final fresh = _eventFrom(await CommunityApi.event(event.id));
    if (fresh == null) return event;
    final updated = otherType != null && fresh.typeOther == null ? _withTypeOther(fresh, otherType) : fresh;
    final i = _events.indexWhere((e) => e.id == event.id);
    if (i >= 0) _events[i] = updated;
    notifyListeners();
    return updated;
  }

  CommunityEvent _withTypeOther(CommunityEvent e, String typeOther) =>
      CommunityEvent(
          id: e.id,
          communityId: e.communityId,
          type: e.type,
          typeOther: typeOther,
          mode: e.mode,
          title: e.title,
          description: e.description,
          start: e.start,
          end: e.end,
          registrationStarts: e.registrationStarts,
          registrationEnds: e.registrationEnds,
          link: e.link,
          location: e.location,
          memberLimit: e.memberLimit,
          registered: e.registered,
          communityName: e.communityName,
        )
        ..coverUrl = e.coverUrl
        ..posterUrl = e.posterUrl;

  /// How the user appears in communities: their pseudo name, or their name
  /// for solvers in their own community.
  String _me(AppUser user) => user.profile.pseudoName ?? user.name;

  List<Community> joined(AppUser user) => _communities.where((c) => isMember(user, c)).toList();

  int memberCount(AppUser user, Community c) => c.memberTotal ?? c.members.length + (isMember(user, c) ? 1 : 0);

  // ---- Membership --------------------------------------------------------------

  /// Joining needs a pseudo name (the user's only identity inside
  /// communities) and acceptance of the community rules.
  Future<void> join(AppUser user, Community c, {required bool acceptedRules}) async {
    if (user.profile.pseudoName == null) {
      throw const AuthException('Set your pseudo name before joining a community.');
    }
    if (c.banned.contains(user.profile.pseudoName)) {
      throw const AuthException('You were removed from this community and can\'t join again.');
    }
    if (!acceptedRules) throw const AuthException('Please accept the community rules to join.');
    // A community found by invite code joins with that code (it may be private).
    final code = c.inviteCode;
    final count = code != null ? await CommunityApi.joinWithCode(code) : await CommunityApi.action(c.id, 'join');
    if (count != null) c.memberTotal = count;
    if (!_communities.contains(c)) _communities.add(c);
    _joinedBy(user).add(c.id);
    notifyListeners();
  }

  Future<Community> findByInviteCode(String code) async {
    // Accepts the code on its own or the full community link.
    final value = code.trim().split('/').last.toUpperCase();
    final data = await CommunityApi.byInviteCode(value);
    final known = _communities.where((c) => c.id == data['id']).firstOrNull;
    return known ?? (_communityFrom(data, null)..inviteCode = value);
  }

  Future<void> leave(AppUser user, Community c) async {
    final count = await CommunityApi.action(c.id, 'leave');
    if (count != null) c.memberTotal = count;
    _joinedBy(user).remove(c.id);
    notifyListeners();
  }

  /// Per-community notifications stay on this device: the API can read them
  /// but has no endpoint to change them yet.
  bool notificationsOn(AppUser user, Community c) => !(_muted[user.email]?.contains(c.id) ?? false);

  void setNotifications(AppUser user, Community c, bool on) {
    final muted = _muted.putIfAbsent(user.email, () => {});
    on ? muted.remove(c.id) : muted.add(c.id);
    notifyListeners();
  }

  // ---- Discussions -------------------------------------------------------------

  Future<Discussion> createDiscussion(AppUser user, Community c, String title, String description) async {
    if (title.trim().length < 5) throw const AuthException('The title needs at least 5 characters.');
    if (description.trim().length < 10) throw const AuthException('The description needs at least 10 characters.');
    final discussion = _discussionFrom(await CommunityApi.createThread(c.id, title, description), null, user);
    final general = c.discussions.indexWhere((d) => d.general);
    c.discussions.insert(general + 1, discussion); // right after General
    notifyListeners();
    return discussion;
  }

  /// Throws when the thread is locked, unless the owner of [c] is posting.
  /// [filePath] uploads a file with the message.
  /// Posts a message; [replyTo] quotes the message it answers.
  Future<void> send(
    AppUser user,
    Discussion d,
    String text, {
    String? fileName,
    String? filePath,
    CommunityMessage? replyTo,
    Community? c,
  }) async {
    if (d.locked && (c == null || !isOwner(user, c))) {
      throw const AuthException('This thread is locked by the community owner.');
    }
    final community = c ?? _communities.firstWhere((x) => x.discussions.contains(d));
    final file = filePath == null
        ? null
        : await CommunityApi.uploadFile(community.id, d.id, filePath, fileName ?? filePath.split('/').last);
    final sent = await CommunityApi.sendMessage(d.id, text, file: file, quotedId: replyTo?.id);
    d.messages.add(_messageFrom(sent, d.id, user, localPath: filePath));
    notifyListeners();
  }

  /// Switches at once and saves; switches back if the save fails.
  Future<void> toggleReaction(AppUser user, CommunityMessage m, Reaction r) async {
    final me = _me(user);
    void flip() {
      final who = m.reactions.putIfAbsent(r, () => {});
      if (!who.remove(me)) who.add(me);
      if (who.isEmpty) m.reactions.remove(r);
      notifyListeners();
    }

    flip();
    final added = m.reactions[r]?.contains(me) ?? false;
    try {
      added
          ? await CommunityApi.react(m.threadId, m.id, r.emoji)
          : await CommunityApi.unreact(m.threadId, m.id, r.emoji);
    } catch (_) {
      flip();
      rethrow;
    }
  }

  // ---- Events --------------------------------------------------------------------

  List<CommunityEvent> get events => List.of(_events)..sort((a, b) => a.start.compareTo(b.start));

  bool isRegistered(AppUser user, CommunityEvent e) => _registrations[user.email]?.contains(e.id) ?? false;

  /// Registering shares the user's name and email with the host; the screen
  /// asks first.
  Future<void> register(AppUser user, CommunityEvent e) async {
    if (e.registrationNotStarted) throw const AuthException('Registration for this event hasn\'t opened yet.');
    if (e.full && !isRegistered(user, e)) throw const AuthException('This event is full.');
    if (!e.registrationOpen) throw const AuthException('Registration for this event has closed.');
    final status = await CommunityApi.register(e.id);
    _registrations.putIfAbsent(user.email, () => {}).add(e.id);
    e.registered = status['registered_count'] is int ? status['registered_count'] as int : e.registered + 1;
    notifyListeners();
  }

  Future<void> cancelRegistration(AppUser user, CommunityEvent e) async {
    if (!e.registrationOpen) throw const AuthException('Registration has closed, so it can\'t be changed now.');
    await CommunityApi.unregister(e.id);
    if (_registrations[user.email]?.remove(e.id) ?? false) e.registered--;
    notifyListeners();
  }

  Set<String> _joinedBy(AppUser user) => _joined.putIfAbsent(user.email, () => {});
}
