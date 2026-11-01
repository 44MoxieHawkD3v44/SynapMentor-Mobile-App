import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' show ParticipantKind, Room;

import '../api/api_client.dart' show ApiClient, ApiException;
import '../api/explore_api.dart';

import '../api/realtime_client.dart';
import '../api/session_api.dart';
import '../api/solver_booking_api.dart';
import 'auth_service.dart';
import 'explore_service.dart';
import 'face_photos.dart';
import 'wallet_service.dart';

/// Where a booking is in its life, derived from the clock.
enum SessionPhase { upcoming, live, completed }

enum ExtensionStatus { pending, approved, rejected }

class ChatMessage {
  ChatMessage({
    required this.fromSeeker,
    required this.text,
    required this.sentAt,
    this.fileName,
    this.fileUrl,
    this.localPath,
    this.id,
    this.replyToId,
    this.system = false,
  });

  /// The file on this device, for one the user just sent.
  final String? localPath;

  /// The server's id; set once a message the user sent is stored.
  String? id;

  /// The message this one replies to.
  final String? replyToId;

  /// A note from the app or server (e.g. someone joined), not from a person.
  final bool system;

  /// Where a shared file can be downloaded (an API path); set once stored.
  String? fileUrl;

  final bool fromSeeker;
  final String text;
  final DateTime sentAt;

  /// Set when the message shares a file.
  final String? fileName;
}

class ExtensionRequest {
  ExtensionRequest(this.minutes, this.note);

  final int minutes;
  final String note;
  ExtensionStatus status = ExtensionStatus.pending;

  /// When it was asked for, and the extra minutes the session had then:
  /// more minutes afterwards means it was approved.
  final DateTime sentAt = DateTime.now();
  int extraBefore = 0;

  /// Declined by the system because the solver has another session right after.
  bool autoDeclined = false;

  /// Nobody answered within the approval window; the minutes were returned.
  bool expired = false;

  /// When the approval window closes, from the server.
  DateTime? expiresAt;

  /// Time left to answer, when known.
  Duration? get timeLeft {
    final at = expiresAt;
    if (at == null) return null;
    final left = at.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }
}

/// The seeker's feedback on a session. Only the rating is required.
class SessionReview {
  const SessionReview({
    required this.rating,
    this.helpful = const [],
    this.unclear = const [],
    this.feedback = '',
    this.learned = '',
    this.wouldRebook,
  });

  /// What helped and what was unclear, as the options' labels.
  static const helpfulOptions = ['Clear explanation', 'Good examples', 'Patient teaching', 'Practical tips', 'Others'];
  static const unclearOptions = ['Too fast', 'Too complex', 'Off topic', 'Audio issues', 'Others'];

  final int rating;
  final List<String> helpful;
  final List<String> unclear;
  final String feedback;
  final String learned;
  final bool? wouldRebook;
}

/// The solver's review of a session.
class SolverSessionReview {
  const SolverSessionReview({
    required this.rating,
    required this.punctuality,
    required this.engagement,
    required this.feedback,
    this.punctualityOther = '',
    this.engagementOther = '',
  });

  /// How the session went, out of 5.
  final int rating;
  final SeekerPunctuality punctuality;
  final SeekerEngagement engagement;

  /// What the solver wrote when they chose Other.
  final String punctualityOther;
  final String engagementOther;
  final String feedback;

  /// Shown for an answer, with what was written for Other.
  static String describe(String label, String other) => other.isEmpty ? label : '$label: $other';
}

/// How on time the seeker was, as the server names it.
enum SeekerPunctuality {
  onTime('On time', 'on_time'),
  slightlyLate('Slightly late', 'slightly_late'),
  veryLate('Very late', 'very_late'),
  noShow('No show', 'no_show'),
  other('Other', 'other');

  const SeekerPunctuality(this.label, this.code);
  final String label;
  final String code;
}

/// How engaged the seeker was, as the server names it.
enum SeekerEngagement {
  excellent('Excellent', 'excellent'),
  good('Good', 'good'),
  average('Average', 'average'),
  poor('Poor', 'poor'),
  other('Other', 'other');

  const SeekerEngagement(this.label, this.code);
  final String label;
  final String code;
}

class SessionState {
  /// The seeker's one-time face check.
  bool faceVerified = false;

  /// The solver agreed that this podcast session is recorded.
  bool recordingConsented = false;

  /// The solver's one-time face check.
  bool solverFaceVerified = false;

  /// Whether each side entered the room at least once.
  bool seekerJoined = false;
  bool solverJoined = false;

  /// The chat already says the other person joined.
  bool joinNoticeShown = false;

  /// The server has recorded this user's join.
  bool serverJoined = false;
  final messages = <ChatMessage>[];
  int extraMinutes = 0;
  ExtensionRequest? extension;
  SessionReview? review;
  SolverSessionReview? solverReview;

  /// Wallet minutes the seeker paid for approved extensions.
  int extensionValue = 0;

  /// Minutes credited to the solver's wallet.
  bool credited = false;

  /// Whiteboard strokes, in board coordinates ([SessionService.boardWidth]
  /// wide).
  final strokes = <List<Offset>>[];

  /// Live sessions: the board's Excalidraw elements by id (the strokes are
  /// drawn from these), the scene's app state and its saved version.
  final board = <String, Map<String, dynamic>>{};
  Object boardAppState = const <String, dynamic>{};
  int boardVersion = 0;

  // ---- From the API ----

  /// When the server says the session ends (base + approved extensions).
  DateTime? serverEnd;

  /// Ids of chat messages already shown, and the newest one.
  final messageIds = <String>{};
  String? lastMessageId;

  /// The pending extension request the solver can answer.
  String? extensionRequestId;

  /// Completion was sent to the server.
  bool completeSent = false;

  /// The server is recording the meeting right now (its `recording_active`).
  bool recordingActive = false;
}

/// Sessions: video, chat, whiteboard, extensions and reviews, from the
/// sessions API. Recordings are processed and stored by the backend.
class SessionService extends ChangeNotifier {
  static final SessionService instance = SessionService();

  /// A session goes live this long before its start time.
  static const liveLead = Duration(minutes: 5);

  /// Extensions can be requested only in this final window: the admin's
  /// setting from the server's booking config (see
  /// [ExploreService.loadBookingConfig]). 5 minutes until it has loaded.
  static Duration extensionWindow = const Duration(minutes: 5);

  /// [extensionWindow] for messages, e.g. "5 minutes".
  static String get extensionWindowLabel {
    final minutes = extensionWindow.inMinutes;
    return '$minutes minute${minutes == 1 ? '' : 's'}';
  }

  /// The most one request may add, and the longest a session may run in all
  /// (the server's limits).
  static const maxExtension = 60;
  static const maxSessionMinutes = 240;
  static const minExtension = 10;

  /// Reschedules must happen more than this long before the start.
  static const rescheduleCutoff = Duration(hours: 1);

  final _states = <String, SessionState>{};
  Timer? _ticker;

  // Tick while anyone is listening so phases and countdowns stay current.
  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  SessionState stateOf(Booking b) => _states.putIfAbsent(b.id, SessionState.new);

  DateTime endOf(Booking b) =>
      stateOf(b).serverEnd ?? b.start.add(Duration(minutes: b.minutes + stateOf(b).extraMinutes));

  // ---- Live sessions (API) ------------------------------------------------------

  /// Bookings with a session on the server run live: real face check,
  /// meeting, chat and timer.
  bool isRemote(Booking b) => b.sessionId != null;

  String get _role => AuthService.instance.currentUser?.role.name ?? 'seeker';

  /// The seeker's pre-session face check is skipped for anonymous bookings;
  /// the solver always does it.
  bool faceRequired(Booking b, {required bool asSolver}) => !isRemote(b) || asSolver || b.type != BookingType.anonymous;

  /// The face check for this session is done: once per session, so leaving
  /// and rejoining (even after restarting the app) doesn't ask again.
  bool faceDone(Booking b, {required bool asSolver}) =>
      (asSolver ? stateOf(b).solverFaceVerified : stateOf(b).faceVerified) || (isRemote(b) && b.faceVerified);

  /// After a restart the app no longer knows a session's extensions, so a
  /// session still running on the server could look finished. For sessions
  /// that started in the last few hours and aren't closed on the server, the
  /// real end time is asked for.
  Future<void> refreshEnds(Iterable<Booking> bookings) async {
    final now = DateTime.now().toUtc();
    final checks = [
      for (final b in bookings)
        if (isRemote(b) &&
            b.cancellation == null &&
            b.serverStatus != 'completed' &&
            stateOf(b).serverEnd == null &&
            now.isAfter(b.start) &&
            now.difference(b.start) < const Duration(hours: 8))
          () async {
            try {
              final t = await SessionApi.timer(_role, b.sessionId!);
              final remaining = t['remaining_time_seconds'];
              final state = stateOf(b);
              if (t['extended_minutes'] is int) state.extraMinutes = t['extended_minutes'] as int;
              if (t['status'] == 'completed' || t['status'] == 'cancelled') {
                state.serverEnd = now;
              } else if (remaining is int) {
                state.serverEnd = now.add(Duration(seconds: remaining));
              }
            } catch (_) {
              // Shown from the booking until the session is opened.
            }
          }(),
    ];
    if (checks.isEmpty) return;
    await Future.wait(checks);
    notifyListeners();
  }

  final _live = <String, ({StreamSubscription<Map<String, dynamic>> events, Timer poll})>{};

  /// Opens a live session: records the join, joins the chat room, loads the
  /// messages and follows the timer and messages until [leave].
  Future<void> enter(Booking b) async {
    if (!isRemote(b) || _live.containsKey(b.id)) return;
    final id = b.sessionId!;
    final role = _role;
    unawaited(RealtimeClient.instance.acquire());
    final events = RealtimeClient.instance.events.listen((e) => _onEvent(b, e));
    final poll = Timer.periodic(const Duration(seconds: 5), (_) => _sync(b));
    _live[b.id] = (events: events, poll: poll);
    await _joinSession(b);
    try {
      await SessionApi.joinChat(role, id);
    } on AuthException {
      // Chat opens 3 minutes early; messages still load below.
    }
    await _sync(b);
  }

  /// Leaves the live session's chat and meeting; the session itself keeps
  /// running until its end time.
  Future<void> leave(Booking b) async {
    closeBoard(b);
    final live = _live.remove(b.id);
    if (live == null) return;
    await live.events.cancel();
    live.poll.cancel();
    RealtimeClient.instance.release();
    final id = b.sessionId!;
    await SessionApi.leaveChat(_role, id).catchError((Object _) {});
    if (b.mode == SessionMode.meet) await SessionApi.leaveMeeting(_role, id).catchError((Object _) {});
  }

  /// The LiveKit connection for the meeting: `{token, livekit_url, …}`.
  Future<Map<String, dynamic>> joinMeeting(Booking b) => SessionApi.joinMeeting(_role, b.sessionId!);

  /// Refreshes the timer, extension and new messages.
  Future<void> _sync(Booking b) async {
    final id = b.sessionId!;
    final state = stateOf(b);
    if (!state.serverJoined && phaseOf(b) == SessionPhase.live) await _joinSession(b);
    try {
      final t = await SessionApi.timer(_role, id);
      final remaining = t['remaining_time_seconds'];
      if (remaining is int) state.serverEnd = DateTime.now().toUtc().add(Duration(seconds: remaining));
      if (t['status'] == 'completed' || t['status'] == 'cancelled') state.serverEnd = DateTime.now().toUtc();
      if (t['extended_minutes'] is int) state.extraMinutes = t['extended_minutes'] as int;
      _noticeJoined(b, t['status'] == 'active');
      final pending = t['pending_extension'];
      if (pending is Map && pending['request_id'] is String) {
        if (state.extensionRequestId != pending['request_id']) {
          state
            ..extensionRequestId = pending['request_id'] as String
            ..extension = ExtensionRequest(pending['extra_minutes'] is int ? pending['extra_minutes'] as int : 10, '');
          if (_role == 'solver') unawaited(_declineIfBusy(b));
        }
        // The approval window, from the server (not a fixed two minutes).
        state.extension?.expiresAt = _windowEnd(pending['expires_at'], pending['remaining_seconds']);
      } else if (state.extension?.status == ExtensionStatus.pending && _role == 'solver') {
        // Answered, or it lapsed without an answer.
        final request = state.extension!;
        request
          ..status = ExtensionStatus.rejected
          ..expired = request.timeLeft == Duration.zero;
      }
      // The seeker's request: its state is on the booking (the timer doesn't
      // carry it); live updates usually arrive first.
      final mine = state.extension;
      if (_role == 'seeker' && mine != null && mine.status == ExtensionStatus.pending) {
        if (state.extraMinutes > mine.extraBefore) {
          mine.status = ExtensionStatus.approved;
        } else {
          await _seekerExtensionStatus(b, mine);
        }
      }
    } on AuthException {
      // Kept as it was; tried again shortly.
    }
    if (b.mode == SessionMode.meet) {
      try {
        final status = await SessionApi.meetingStatus(_role, id);
        state.recordingActive = status['recording_active'] == true;
      } on AuthException {
        // Kept as it was; tried again shortly.
      }
    }
    try {
      final list = await SessionApi.messages(_role, id, since: state.lastMessageId);
      for (final m in list) {
        _addMessage(b, m);
      }
    } on AuthException {
      // Chat may not be open yet.
    }
    // Once the time is up, the session is completed on the server.
    if (!state.completeSent && phaseOf(b) == SessionPhase.completed && (state.seekerJoined || state.solverJoined)) {
      state.completeSent = true;
      final role = _role;
      // Then the review is asked for straight away.
      unawaited(SessionApi.complete(role, id).catchError((Object _) {}).whenComplete(() => _awaitReviewOwed(role, id)));
    }
    notifyListeners();
  }

  /// Records the join on the server. Before the start time it's refused, so
  /// [_sync] keeps trying until it's in: the session only becomes active (and
  /// can be extended) once both have joined.
  Future<bool> _joinSession(Booking b) async {
    final state = stateOf(b);
    if (state.serverJoined) return true;
    try {
      final joined = await SessionApi.join(_role, b.sessionId!);
      state.serverJoined = true;
      _noticeJoined(b, joined['both_joined'] == true || joined['status'] == 'active');
      return true;
    } on AuthException {
      return false;
    }
  }

  /// Once both are in, a note in the chat that the other person joined (the
  /// solver, for the seeker; the seeker, for the solver).
  void _noticeJoined(Booking b, bool bothIn) {
    final state = stateOf(b);
    if (!bothIn || state.joinNoticeShown) return;
    state.joinNoticeShown = true;
    final seeker = _role == 'seeker';
    state.messages.add(
      ChatMessage(
        fromSeeker: !seeker,
        text: '${seeker ? b.solver.name : b.seekerLabel} has joined the session.',
        sentAt: DateTime.now(),
        system: true,
      ),
    );
    notifyListeners();
  }

  void _addMessage(Booking b, Map<String, dynamic> m) {
    final state = stateOf(b);
    final id = (m['id'] ?? m['message_id'])?.toString();
    if (id == null || !state.messageIds.add(id)) return;
    state.lastMessageId = id;
    // The sender already shows their own message from when they sent it.
    final client = m['client_message_id']?.toString();
    if (client != null && _pendingByClient.remove(client) != null) return;
    final type = '${m['message_type'] ?? 'text'}';
    final file = type == 'file';
    state.messages.add(
      ChatMessage(
        fromSeeker: m['sender_role'] == 'seeker',
        text: file ? 'Shared a file' : '${m['content'] ?? ''}',
        sentAt: (DateTime.tryParse('${m['created_at']}') ?? DateTime.now()).toLocal(),
        fileName: file ? (m['file_name'] ?? m['content'])?.toString() : null,
        fileUrl: file ? m['file_url']?.toString() : null,
        id: id,
        replyToId: m['reply_to_id']?.toString(),
        system: type == 'system',
      ),
    );
  }

  /// Loads a session's whole chat (Meet or Chat) from the server, e.g. to read
  /// it back after the session.
  Future<void> loadChatHistory(Booking b) async {
    if (!isRemote(b)) return;
    for (final m in await SessionApi.chatHistory(_role, b.sessionId!)) {
      _addMessage(b, m);
    }
    stateOf(b).messages.sort((x, y) => x.sentAt.compareTo(y.sentAt));
    notifyListeners();
  }

  /// Optimistic messages by their client id, until the server confirms them.
  final _pendingByClient = <String, ChatMessage>{};

  void _onEvent(Booking b, Map<String, dynamic> e) {
    final data = e['data'] is Map ? Map<String, dynamic>.from(e['data'] as Map) : e;
    final session = (data['session_id'] ?? e['session_id'])?.toString();
    if (session != null && session != b.sessionId) return;
    final type = '${e['type']}';
    if (type == 'chat.message' || type == 'booking.chat.message') {
      final message = data['message'] is Map ? Map<String, dynamic>.from(data['message'] as Map) : data;
      _addMessage(b, message);
      notifyListeners();
    } else if (type == 'extension.approved' || type == 'extension.declined' || type == 'extension.expired') {
      // The new end comes with the approval: used at once, so a session
      // extended in its last seconds isn't ended at the old time.
      if (type == 'extension.approved') _applyNewEnd(b, data);
      final mine = stateOf(b).extension;
      if (mine != null && mine.status == ExtensionStatus.pending) {
        mine
          ..status = type == 'extension.approved' ? ExtensionStatus.approved : ExtensionStatus.rejected
          ..expired = type == 'extension.expired';
        notifyListeners();
      }
      unawaited(_sync(b));
    } else if (type.startsWith('extension') ||
        type.startsWith('session') ||
        type.startsWith('meeting.timer') ||
        type == 'meeting.extension') {
      unawaited(_sync(b));
    }
  }

  String _clientId() {
    final r = Random.secure();
    String hex(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${(8 + r.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }

  SessionPhase phaseOf(Booking b, [DateTime? at]) {
    final now = (at ?? DateTime.now()).toUtc();
    // The server has the final word once it has closed the session.
    if (b.serverStatus == 'completed') return SessionPhase.completed;
    if (now.isBefore(b.start.subtract(liveLead))) return SessionPhase.upcoming;
    if (now.isBefore(endOf(b))) return SessionPhase.live;
    return SessionPhase.completed;
  }

  bool hasStarted(Booking b) => !DateTime.now().toUtc().isBefore(b.start);

  bool canReschedule(Booking b) => b.start.difference(DateTime.now().toUtc()) > rescheduleCutoff;

  bool inExtensionWindow(Booking b) {
    final left = endOf(b).difference(DateTime.now().toUtc());
    return hasStarted(b) && left > Duration.zero && left <= extensionWindow;
  }

  /// Only sessions that finished are reviewed, never cancelled ones (the
  /// server's pending list can include those).
  bool _reviewable(Booking b) => b.cancellation == null && phaseOf(b) == SessionPhase.completed;

  /// The oldest completed session the user hasn't reviewed. Reviews are
  /// mandatory, so this blocks the app until it's answered.
  Booking? pendingReview(AppUser user) {
    _refreshPendingReviews(user);
    final done =
        ExploreService.instance
            .bookingsFor(user)
            .where(
              (b) =>
                  _reviewable(b) &&
                  (isRemote(b)
                      ? (_pendingReviewIds['seeker']?.contains(b.sessionId) ?? false)
                      : stateOf(b).review == null),
            )
            .toList()
          ..sort((a, b) => endOf(a).compareTo(endOf(b)));
    return done.firstOrNull;
  }

  // ---- In session --------------------------------------------------------------

  /// Dummy face check, required once per session (not on every rejoin). Each
  /// side verifies separately.
  /// For live sessions [framePaths] are camera frames matched by the server
  /// against the face enrolled at verification.
  Future<void> verifyFace(Booking b, {bool asSolver = false, List<String>? framePaths}) async {
    if (isRemote(b)) {
      final List<String> photos;
      try {
        // Small enough for the server: camera photos are far too large.
        final paths = framePaths ?? const <String>[];
        photos = await FacePhotos.prepare([for (final i in FacePhotos.keep(paths.length)) paths[i]]);
      } catch (_) {
        throw const AuthException('Verification submission failed. Please try again.');
      }
      final r = await SessionApi.faceMatch(asSolver ? 'solver' : 'seeker', b.id, photos);
      if (r['matched'] != true) {
        final left = r['attempts_remaining'];
        throw AuthException(
          r['blocked'] == true
              ? 'Face verification is blocked for this booking. Please contact support.'
              : 'Your face didn\'t match. Look straight at the camera in good light and try again.'
                    '${left is int ? ' $left attempt${left == 1 ? '' : 's'} left.' : ''}',
        );
      }
    } else {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (asSolver) {
      stateOf(b).solverFaceVerified = true;
    } else {
      stateOf(b).faceVerified = true;
    }
    notifyListeners();
  }

  /// Records attendance the first time each side enters the room.
  void markJoined(Booking b, {required bool asSolver}) {
    final state = stateOf(b);
    if (asSolver ? state.solverJoined : state.seekerJoined) return;
    if (asSolver) {
      state.solverJoined = true;
    } else {
      state.seekerJoined = true;
    }
  }

  /// For live sessions the message goes to the server ([filePath] uploads a
  /// file); it shows straight away and the other side gets it live.
  /// Sends a message, or a file; [replyTo] is the message it answers.
  void send(
    Booking b,
    String text, {
    String? fileName,
    String? filePath,
    bool fromSeeker = true,
    ChatMessage? replyTo,
  }) {
    final message = ChatMessage(
      fromSeeker: fromSeeker,
      text: text,
      sentAt: DateTime.now(),
      fileName: fileName,
      localPath: filePath,
      replyToId: replyTo?.id,
    );
    stateOf(b).messages.add(message);
    notifyListeners();
    if (isRemote(b)) {
      final client = _clientId();
      _pendingByClient[client] = message;
      final id = b.sessionId!;
      final sent = filePath != null
          ? SessionApi.sendFile(_role, id, path: filePath, fileName: fileName ?? 'file', clientId: client)
          : SessionApi.send(_role, id, text, clientId: client, replyToId: replyTo?.id);
      sent.then(
        (m) {
          final serverId = (m['id'] ?? m['message_id'])?.toString();
          if (serverId != null) stateOf(b).messageIds.add(serverId);
          message.id = serverId;
          final url = m['file_url']?.toString();
          if (url != null && url.isNotEmpty) {
            message.fileUrl = url;
            notifyListeners();
          }
          _pendingByClient.remove(client);
        },
        onError: (Object e) {
          _pendingByClient.remove(client);
          stateOf(b).messages.remove(message);
          sendError = e is AuthException ? e.message : 'Your message couldn\'t be sent.';
          notifyListeners();
        },
      );
      return;
    }
  }

  void addStroke(Booking b, List<Offset> stroke) {
    if (isRemote(b)) return _changeBoard(b, [_freedraw(stroke)]);
    stateOf(b).strokes.add(stroke);
    notifyListeners();
  }

  void clearWhiteboard(Booking b) {
    if (isRemote(b)) {
      return _changeBoard(b, [
        for (final e in stateOf(b).board.values)
          if (e['isDeleted'] != true) _bump({...e, 'isDeleted': true}),
      ]);
    }
    stateOf(b).strokes.clear();
    notifyListeners();
  }

  // ---- Whiteboard (live sessions) -----------------------------------------------
  //
  // The board is the session's Excalidraw scene on the server. Changes travel
  // live to the other person over the meeting's LiveKit data channel; the
  // solver saves the scene (only solvers can), and an open board refetches it
  // every few seconds to catch up on anything missed.

  /// Board coordinates span this width whatever the screen size.
  static const boardWidth = 1000.0;
  static const _boardTopic = 'whiteboard';

  final _rooms = <String, Room>{};
  final _boardPolls = <String, Timer>{};
  final _boardSaves = <String, Timer>{};

  /// The meeting's LiveKit room, for sending board changes live.
  void attachRoom(Booking b, Room? room) {
    // Screens follow who's in the room as people join and leave.
    _rooms.remove(b.id)?.removeListener(notifyListeners);
    if (room != null) {
      _rooms[b.id] = room..addListener(notifyListeners);
      // Not when detaching: that happens while the screen closes.
      notifyListeners();
    }
  }

  /// The other person's profile picture in [b]: the solver's for a seeker,
  /// the seeker's for a solver (never an anonymous seeker's).
  String? peerPhoto(Booking b) {
    final explore = ExploreService.instance;
    return _role == 'solver' ? explore.seekerPhoto(b) : explore.solverPhoto(b.solver);
  }

  final _photoLookups = <String>{};

  /// Fetches the other person's picture from the session's lobby when the
  /// directory and bookings didn't have it (once per session).
  Future<void> loadPeerPhoto(Booking b) async {
    final sessionId = b.sessionId;
    if (sessionId == null || peerPhoto(b) != null || !_photoLookups.add(b.id)) return;
    if (_role == 'solver' && b.type == BookingType.anonymous) return;
    try {
      final lobby = await SessionApi.lobby(_role, sessionId);
      final peer = lobby[_role == 'solver' ? 'seeker_brief' : 'solver_info'];
      final url = peer is Map ? ApiClient.photoLink(peer['avatar_url']) : null;
      if (url == null) return;
      ExploreService.instance.rememberPhoto(
        solverId: _role == 'solver' ? null : b.solver.id,
        bookingId: _role == 'solver' ? b.id : null,
        url: url,
      );
      notifyListeners();
    } catch (_) {
      // The initials stay.
    }
  }

  /// Whether the other person is in the meeting room right now; null when
  /// this device isn't in the meeting for [b] (e.g. a chat session), where
  /// it isn't known.
  bool? otherInMeeting(Booking b) {
    final room = _rooms[b.id];
    return room?.remoteParticipants.values.any((p) => p.kind == ParticipantKind.STANDARD);
  }

  /// Loads the saved board and keeps it in step while it's open.
  void openBoard(Booking b) {
    if (!isRemote(b) || _boardPolls.containsKey(b.id)) return;
    _loadBoard(b);
    _boardPolls[b.id] = Timer.periodic(const Duration(seconds: 4), (_) => _loadBoard(b));
  }

  void closeBoard(Booking b) => _boardPolls.remove(b.id)?.cancel();

  /// Board changes from the other person, sent over the LiveKit data channel.
  void receiveBoardData(Booking b, List<int> data, String? topic) {
    if (topic != null && topic != _boardTopic) return;
    try {
      final message = jsonDecode(utf8.decode(data));
      if (message is! Map || message['type'] != 'whiteboard.elements') return;
      if (message['session_id'] != null && message['session_id'] != b.sessionId) return;
      if (_mergeBoard(b, message['elements'])) _scheduleBoardSave(b);
    } catch (_) {
      // Not a board message.
    }
  }

  Future<void> _loadBoard(Booking b) async {
    try {
      final scene = await SessionApi.whiteboard(_role, b.sessionId!);
      final s = stateOf(b);
      final version = (scene['version'] as num?)?.toInt() ?? 0;
      if (version < s.boardVersion) return;
      s.boardVersion = version;
      final appState = scene['app_state'];
      if (appState != null) s.boardAppState = appState as Object;
      _mergeBoard(b, scene['elements']);
    } catch (_) {
      // Shown from what's already here; the next refetch tries again.
    }
  }

  /// Applies elements newer than the ones here (by Excalidraw's per-element
  /// version), so edits from both sides and the saved scene combine.
  bool _mergeBoard(Booking b, Object? elements) {
    if (elements is! List) return false;
    final s = stateOf(b);
    var changed = false;
    for (final e in elements) {
      if (e is! Map || e['id'] is! String) continue;
      final element = Map<String, dynamic>.from(e);
      final mine = s.board[element['id']];
      if (mine != null && _versionOf(mine) >= _versionOf(element)) continue;
      s.board[element['id'] as String] = element;
      changed = true;
    }
    if (changed) {
      _redrawBoard(s);
      notifyListeners();
    }
    return changed;
  }

  void _changeBoard(Booking b, List<Map<String, dynamic>> elements) {
    if (elements.isEmpty) return;
    final s = stateOf(b);
    for (final e in elements) {
      s.board[e['id'] as String] = e;
    }
    _redrawBoard(s);
    notifyListeners();
    _publishBoard(b, elements);
    _scheduleBoardSave(b);
  }

  void _redrawBoard(SessionState s) {
    s.strokes
      ..clear()
      ..addAll([
        for (final e in s.board.values)
          if (e['type'] == 'freedraw' && e['isDeleted'] != true && e['points'] is List)
            [
              for (final p in e['points'] as List)
                if (p is List && p.length >= 2) Offset(_num(e['x']) + _num(p[0]), _num(e['y']) + _num(p[1])),
            ],
      ]);
  }

  Future<void> _publishBoard(Booking b, List<Map<String, dynamic>> elements) async {
    try {
      await _rooms[b.id]?.localParticipant?.publishData(
        utf8.encode(jsonEncode({'type': 'whiteboard.elements', 'session_id': b.sessionId, 'elements': elements})),
        reliable: true,
        topic: _boardTopic,
      );
    } catch (_) {
      // The other side catches up from the saved scene.
    }
  }

  void _scheduleBoardSave(Booking b) {
    if (_role != 'solver') return;
    _boardSaves[b.id]?.cancel();
    _boardSaves[b.id] = Timer(const Duration(milliseconds: 1500), () => _saveBoard(b));
  }

  Future<void> _saveBoard(Booking b, {bool retried = false}) async {
    final s = stateOf(b);
    try {
      final saved = await SessionApi.saveWhiteboard(
        b.sessionId!,
        elements: s.board.values.toList(),
        appState: s.boardAppState,
        version: s.boardVersion,
      );
      s.boardVersion = (saved['version'] as num?)?.toInt() ?? s.boardVersion + 1;
    } on ApiException catch (e) {
      // Saved from elsewhere meanwhile: combine with that scene and save again.
      if (e.statusCode != 409 || retried) return;
      await _loadBoard(b);
      await _saveBoard(b, retried: true);
    } catch (_) {
      // The next change saves again.
    }
  }

  /// A pen stroke as an Excalidraw freedraw element.
  Map<String, dynamic> _freedraw(List<Offset> stroke) {
    final xs = stroke.map((p) => p.dx);
    final ys = stroke.map((p) => p.dy);
    final x = xs.reduce(min), y = ys.reduce(min);
    final r = Random();
    return {
      'id': _clientId(),
      'type': 'freedraw',
      'x': x,
      'y': y,
      'width': xs.reduce(max) - x,
      'height': ys.reduce(max) - y,
      'angle': 0,
      'strokeColor': '#1e1e1e',
      'backgroundColor': 'transparent',
      'fillStyle': 'solid',
      'strokeWidth': 2,
      'strokeStyle': 'solid',
      'roughness': 0,
      'opacity': 100,
      'groupIds': const <String>[],
      'frameId': null,
      'roundness': null,
      'seed': r.nextInt(1 << 31),
      'version': 1,
      'versionNonce': r.nextInt(1 << 31),
      'isDeleted': false,
      'boundElements': null,
      'updated': DateTime.now().millisecondsSinceEpoch,
      'link': null,
      'locked': false,
      'points': [
        for (final p in stroke) [p.dx - x, p.dy - y],
      ],
      'pressures': const <double>[],
      'simulatePressure': true,
      'lastCommittedPoint': null,
    };
  }

  /// The element with its version raised, as Excalidraw does on each edit.
  Map<String, dynamic> _bump(Map<String, dynamic> e) => {
    ...e,
    'version': _versionOf(e) + 1,
    'versionNonce': Random().nextInt(1 << 31),
    'updated': DateTime.now().millisecondsSinceEpoch,
  };

  static int _versionOf(Map<String, dynamic> e) => (e['version'] as num?)?.toInt() ?? 0;
  static double _num(Object? v) => v is num ? v.toDouble() : 0;

  /// Sessions waiting for the caller's review on the server, by role.
  final _pendingReviewIds = <String, Set<String>>{};
  DateTime? _pendingCheckedAt;

  /// Reloads the server's review queue at most once a minute.
  void _refreshPendingReviews(AppUser user) {
    final now = DateTime.now();
    // Every 10 seconds while a session has just ended, so its review comes
    // straight away; every minute otherwise.
    final explore = ExploreService.instance;
    final recent = (user.role == UserRole.solver ? explore.bookingsForSolver(user) : explore.bookingsFor(user)).any((
      b,
    ) {
      final since = now.toUtc().difference(endOf(b));
      return b.cancellation == null && !since.isNegative && since < const Duration(minutes: 15);
    });
    final every = recent ? const Duration(seconds: 10) : const Duration(minutes: 1);
    if (_pendingCheckedAt != null && now.difference(_pendingCheckedAt!) < every) return;
    _pendingCheckedAt = now;
    unawaited(_fetchPendingReviews(user.role.name));
  }

  Future<Set<String>?> _fetchPendingReviews(String role) async {
    try {
      final list = await SessionApi.pendingReviews(role);
      final ids = {for (final s in list) '${s['session_id']}'};
      _pendingReviewIds[role] = ids;
      notifyListeners();
      return ids;
    } on AuthException {
      return null;
    }
  }

  /// Right after a session completes: checks until the server lists its
  /// review as owed (it may take a moment), so the review form opens at once.
  Future<void> _awaitReviewOwed(String role, String sessionId) async {
    for (final wait in const [Duration.zero, Duration(seconds: 2), Duration(seconds: 4), Duration(seconds: 8)]) {
      await Future<void>.delayed(wait);
      _pendingCheckedAt = DateTime.now();
      if ((await _fetchPendingReviews(role))?.contains(sessionId) ?? false) return;
    }
  }

  /// Why the last message couldn't be sent, if it couldn't.
  String? sendError;

  /// Whether the seeker can ask for more time now: in [extensionWindow],
  /// with no request waiting for an answer. A session can be extended again
  /// and again, as long as the solver is free.
  bool canRequestExtension(Booking b) =>
      b.type != BookingType.podcast && inExtensionWindow(b) && stateOf(b).extension?.status != ExtensionStatus.pending;

  /// The end of an approval window: [at] (RFC3339) or [seconds] from now.
  static DateTime? _windowEnd(Object? at, Object? seconds) =>
      DateTime.tryParse('${at ?? ''}')?.toLocal() ??
      (seconds is int && seconds > 0 ? DateTime.now().add(Duration(seconds: seconds)) : null);

  /// The seeker's newest request, read from the booking: `pending`,
  /// `approved`, `declined` or `expired`. Without it (offline), a request
  /// past its window counts as lapsed.
  Future<void> _seekerExtensionStatus(Booking b, ExtensionRequest request) async {
    try {
      final d = await ExploreApi.bookingDetail(b.id);
      switch ('${d['extension_status'] ?? ''}') {
        case 'approved':
          request.status = ExtensionStatus.approved;
        case 'declined':
          request.status = ExtensionStatus.rejected;
        case 'expired':
          request
            ..status = ExtensionStatus.rejected
            ..expired = true;
        case 'pending':
          request.expiresAt = _windowEnd(null, d['extension_remaining_seconds']) ?? request.expiresAt;
      }
    } on AuthException {
      final over =
          request.timeLeft == Duration.zero || DateTime.now().difference(request.sentAt) > const Duration(seconds: 150);
      if (over) {
        request
          ..status = ExtensionStatus.rejected
          ..expired = true;
      }
    }
  }

  /// The longest extension that fits right now, in minutes: within the
  /// server's limits and before the solver's next booking or the end of their
  /// available hours (the server checks neither). Below [minExtension] the
  /// session can't be extended. A seeker sees the solver's free time; the
  /// solver's app checks their own bookings and hours.
  Future<int> extensionRoom(AppUser user, Booking b) async {
    final end = endOf(b);
    var room = min(maxExtension, maxSessionMinutes - b.minutes - stateOf(b).extraMinutes);
    DateTime? freeUntil;
    void until(DateTime t) {
      if (freeUntil == null || t.isBefore(freeUntil!)) freeUntil = t;
    }

    // The end's date in the user's zone, and the next one when the end is
    // close to midnight.
    final zone = ExploreService.userZone(user);
    final wall = zone.wall(end);
    final days = [
      DateTime.utc(wall.year, wall.month, wall.day),
      if (wall.hour == 23) DateTime.utc(wall.year, wall.month, wall.day + 1),
    ];
    String key(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    DateTime at(DateTime day, String hhmm) {
      final parts = hhmm.split(':');
      final minutes = (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 0);
      return zone.toUtc(day.add(Duration(minutes: minutes)));
    }

    Future<List<({DateTime start, DateTime end})>> ranges(
      Future<List<({String start, String end})>> Function(String date) fetch,
    ) async => _merged([
      for (final d in days)
        for (final r in await fetch(key(d))) (start: at(d, r.start), end: at(d, r.end)),
    ]);

    try {
      if (user.role == UserRole.solver) {
        final explore = ExploreService.instance;
        await explore.loadSolverBookings(user).catchError((Object _) {});
        for (final other in explore.bookingsForSolver(user)) {
          if (other.id == b.id || other.cancellation != null || other.serverStatus == 'completed') continue;
          if (other.start.add(Duration(minutes: other.minutes)).isAfter(end)) {
            until(other.start.isBefore(end) ? end : other.start);
          }
        }
        // A session booked outside the solver's hours (through a link) isn't
        // held to them.
        final last = end.subtract(const Duration(minutes: 1));
        final hours = (await ranges(SolverBookingApi.savedWindows))
            .where((w) => !w.start.isAfter(last) && w.end.isAfter(last))
            .firstOrNull;
        if (hours != null) until(hours.end);
      } else {
        // The solver's free time after the session (it may start a few
        // minutes later, after their buffer).
        final free = (await ranges((date) => ExploreApi.freeRanges(b.solver.id, date)))
            .where((r) => !r.start.isAfter(end.add(const Duration(minutes: 10))) && r.end.isAfter(end))
            .firstOrNull;
        if (free != null) until(free.end);
      }
    } on AuthException {
      // Not known: only the server's limits apply, and the solver's app checks.
    }
    final limit = freeUntil;
    if (limit != null) room = min(room, limit.difference(end).inMinutes);
    return max(room, 0);
  }

  /// Ranges sorted, with touching ones joined.
  static List<({DateTime start, DateTime end})> _merged(List<({DateTime start, DateTime end})> ranges) {
    final sorted = [...ranges]..sort((a, b) => a.start.compareTo(b.start));
    final merged = <({DateTime start, DateTime end})>[];
    for (final r in sorted) {
      final last = merged.lastOrNull;
      if (last != null && !r.start.isAfter(last.end.add(const Duration(minutes: 1)))) {
        merged[merged.length - 1] = (start: last.start, end: r.end.isAfter(last.end) ? r.end : last.end);
      } else {
        merged.add(r);
      }
    }
    return merged;
  }

  /// The solver's app turns down a request that runs into their next booking
  /// or past their available hours.
  Future<void> _declineIfBusy(Booking b) async {
    final user = AuthService.instance.currentUser;
    final request = stateOf(b).extension;
    if (user == null || request == null) return;
    final room = await extensionRoom(user, b);
    if (request.minutes <= room || request.status != ExtensionStatus.pending || stateOf(b).extension != request) return;
    request.autoDeclined = true;
    resolveExtension(null, b, approve: false);
  }

  /// Sends an extension request to the solver. Minutes are charged only if
  /// the solver approves.
  Future<void> requestExtension(AppUser user, Booking b, int minutes, String note) async {
    if (!inExtensionWindow(b)) {
      throw AuthException('You can request an extension in the last $extensionWindowLabel of the session.');
    }
    if (!canRequestExtension(b)) {
      throw AuthException('Wait for ${b.solver.name} to answer your last request.');
    }
    if (minutes < minExtension) throw const AuthException('Extensions are at least 10 minutes.');
    final room = await extensionRoom(user, b);
    if (room < minExtension) {
      throw AuthException('${b.solver.name} isn\'t free right after this session, so it can\'t be extended.');
    }
    if (minutes > room) {
      throw AuthException('${b.solver.name} is free for $room more minutes after this session. Choose $room or less.');
    }
    final cost = ExploreService.walletCost(b.solver, b.type, minutes);
    if (cost > WalletService.instance.balance(user)) {
      throw AuthException('This extension needs $cost minutes. Add minutes to your wallet first.');
    }
    if (isRemote(b)) {
      // The server freezes the minutes and asks the solver. A session the
      // server doesn't see as active yet is joined first, then asked again.
      Map<String, dynamic> r;
      try {
        r = await SessionApi.requestExtension(b.sessionId!, minutes);
      } on AuthException catch (e) {
        if (!e.message.toLowerCase().contains('active')) rethrow;
        stateOf(b).serverJoined = false;
        await _joinSession(b);
        try {
          r = await SessionApi.requestExtension(b.sessionId!, minutes);
        } on AuthException catch (e) {
          if (!e.message.toLowerCase().contains('active')) rethrow;
          throw const AuthException(
            'The session can be extended once both of you have joined it. Ask the other person to join, then try again.',
          );
        }
      }
      stateOf(b).extension = ExtensionRequest(minutes, note.trim())
        ..extraBefore = stateOf(b).extraMinutes
        ..expiresAt = _windowEnd(null, r['remaining_seconds'])
        ..status = r['status'] == 'approved' ? ExtensionStatus.approved : ExtensionStatus.pending;
      notifyListeners();
      return;
    }
    throw const AuthException('This session can be extended once it has started. Please try again in a moment.');
  }

  /// The solver's decision. Approving charges the seeker and adds the time;
  /// the solver earns those minutes with the session (the server bills it).
  /// An approval's new end (`new_end_time_utc`, else `remaining_time_seconds`
  /// or `remaining_seconds`) and total length, used at once so a session
  /// extended in its last seconds isn't ended at the old time.
  void _applyNewEnd(Booking b, Map<String, dynamic> data) {
    final state = stateOf(b);
    final end = DateTime.tryParse('${data['new_end_time_utc'] ?? ''}')?.toUtc();
    final left = data['remaining_time_seconds'] ?? data['remaining_seconds'];
    if (end != null) {
      state.serverEnd = end;
    } else if (left is int && left > 0) {
      state.serverEnd = DateTime.now().toUtc().add(Duration(seconds: left));
    }
    final total = data['new_duration_minutes'];
    if (total is int && total > b.minutes) state.extraMinutes = total - b.minutes;
    notifyListeners();
  }

  void resolveExtension(AppUser? seeker, Booking b, {required bool approve}) {
    final request = stateOf(b).extension;
    if (request == null || request.status != ExtensionStatus.pending) return;
    if (isRemote(b)) {
      request.status = approve ? ExtensionStatus.approved : ExtensionStatus.rejected;
      notifyListeners();
      SessionApi.answerExtension(b.sessionId!, approve: approve).then(
        (r) {
          if (approve) _applyNewEnd(b, r);
          return _sync(b);
        },
        onError: (Object e) {
          request.status = ExtensionStatus.pending;
          sendError = e is AuthException ? e.message : 'The extension couldn\'t be answered.';
          notifyListeners();
        },
      );
      return;
    }
  }

  Future<void> submitReview(Booking b, SessionReview review) async {
    if (isRemote(b)) {
      await SessionApi.review('seeker', b.sessionId!, {
        'rating': review.rating,
        if (review.helpful.isNotEmpty) 'helpful': review.helpful,
        if (review.unclear.isNotEmpty) 'unclear': review.unclear,
        'would_book_again': ?review.wouldRebook,
        if (review.learned.trim().isNotEmpty) 'learning_outcome': review.learned.trim(),
        if (review.feedback.trim().isNotEmpty) 'feedback': review.feedback.trim(),
      });
      _pendingReviewIds['seeker']?.remove(b.sessionId);
    }
    stateOf(b).review = review;
    notifyListeners();
  }

  Future<void> submitSolverReview(Booking b, SolverSessionReview review) async {
    if (isRemote(b)) {
      await SessionApi.review('solver', b.sessionId!, {
        'rating': review.rating,
        'feedback': review.feedback.trim(),
        'seeker_punctuality': review.punctuality.code,
        'seeker_engagement': review.engagement.code,
        if (review.punctuality == SeekerPunctuality.other) 'seeker_punctuality_other': review.punctualityOther.trim(),
        if (review.engagement == SeekerEngagement.other) 'seeker_engagement_other': review.engagementOther.trim(),
      });
      _pendingReviewIds['solver']?.remove(b.sessionId);
    }
    stateOf(b).solverReview = review;
    notifyListeners();
    // With their own review in, the solver may see the seeker's.
    if (isRemote(b)) unawaited(loadSeekerReview(b).catchError((Object _) {}));
  }

  /// The solver deletes a podcast's recording (and its draft) after it ends.
  Future<void> discardPodcastRecording(Booking b) async {
    if (!isRemote(b) || b.type != BookingType.podcast) return;
    await SessionApi.discardPodcastRecording(b.sessionId!);
  }

  /// The solver's reviews and, where the solver has reviewed, the seeker's,
  /// for their completed sessions (so they show after a restart too).
  Future<void> loadSolverReviews(AppUser user) async {
    if (user.role != UserRole.solver) return;
    final data = await SessionApi.solverSessions();
    final byId = {for (final b in ExploreService.instance.bookingsForSolver(user)) b.id: b};
    for (final raw in data['completed'] is List ? data['completed'] as List : const []) {
      if (raw is! Map) continue;
      final b = byId['${raw['id']}'];
      if (b == null) continue;
      final state = stateOf(b);
      final rating = raw['solver_rating'];
      if (rating is int) {
        String text(String key) => '${raw[key] ?? ''}'.trim();
        state.solverReview = SolverSessionReview(
          rating: rating,
          feedback: text('solver_feedback'),
          punctuality:
              SeekerPunctuality.values.where((p) => p.code == raw['solver_seeker_punctuality']).firstOrNull ??
              SeekerPunctuality.other,
          engagement:
              SeekerEngagement.values.where((e) => e.code == raw['solver_seeker_engagement']).firstOrNull ??
              SeekerEngagement.other,
          punctualityOther: text('solver_seeker_punctuality_other'),
          engagementOther: text('solver_seeker_engagement_other'),
        );
      }
      // Sent only once the solver has reviewed (the blind rule).
      if (raw['seeker_rating'] is int) {
        state.review = _seekerReviewFrom(
          rating: raw['seeker_rating'] as int,
          feedback: raw['seeker_feedback'],
          helpful: raw['seeker_review_helpful'],
          unclear: raw['seeker_review_unclear'],
          learned: raw['seeker_learning_outcome'],
          wouldRebook: raw['seeker_would_book_again'],
        );
      }
    }
    notifyListeners();
  }

  /// The seeker's review of [b]; asked only after the solver's own review
  /// (the server doesn't hold it back itself).
  Future<void> loadSeekerReview(Booking b) async {
    if (!isRemote(b) || stateOf(b).solverReview == null) return;
    final d = await SessionApi.seekerReview(b.sessionId!);
    if (d['has_review'] != true || d['rating'] is! int) return;
    stateOf(b).review = _seekerReviewFrom(
      rating: d['rating'] as int,
      feedback: d['feedback'],
      helpful: d['helpful'],
      unclear: d['unclear'],
      learned: d['learning'],
      wouldRebook: d['would_book_again'],
    );
    notifyListeners();
  }

  /// A seeker review as the server stores it: the chip lists comma-joined.
  static SessionReview _seekerReviewFrom({
    required int rating,
    Object? feedback,
    Object? helpful,
    Object? unclear,
    Object? learned,
    Object? wouldRebook,
  }) {
    List<String> chips(Object? v) => [
      for (final c in '${v ?? ''}'.split(','))
        if (c.trim().isNotEmpty) c.trim(),
    ];
    return SessionReview(
      rating: rating,
      feedback: '${feedback ?? ''}'.trim(),
      helpful: chips(helpful),
      unclear: chips(unclear),
      learned: '${learned ?? ''}'.trim(),
      wouldRebook: wouldRebook is bool ? wouldRebook : null,
    );
  }

  /// The oldest finished session the solver attended but hasn't reviewed.
  /// Solver reviews are mandatory too: minutes are credited only after them.
  Booking? pendingSolverReview(AppUser user) {
    _refreshPendingReviews(user);
    final done =
        ExploreService.instance
            .bookingsForSolver(user)
            .where(
              (b) =>
                  _reviewable(b) &&
                  (isRemote(b)
                      ? (_pendingReviewIds['solver']?.contains(b.sessionId) ?? false)
                      : stateOf(b).solverJoined && stateOf(b).solverReview == null),
            )
            .toList()
          ..sort((a, b) => endOf(a).compareTo(endOf(b)));
    return done.firstOrNull;
  }

  /// Where the solver's minutes for [b] stand.
  String payoutStatus(Booking b) {
    final state = stateOf(b);
    if (state.credited) return 'Minutes credited';
    if (!state.solverJoined) return 'Not credited · you didn\'t attend';
    if (state.solverReview == null) return 'Review to receive your minutes';
    if (state.seekerJoined && state.review == null) return 'Waiting for the seeker\'s review';
    return 'Processing';
  }

  /// Applies session state loaded from the API (messages, reviews, attendance).
  void setState(Booking b, SessionState state) {
    _states[b.id] = state;
    notifyListeners();
  }
}
