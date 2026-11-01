import 'api_client.dart';

/// Live sessions for both roles (Postman: Seeker App > Sessions, Solver App >
/// Sessions): joining, the LiveKit meeting, chat, the timer, extensions,
/// completing and reviews. [role] is `seeker` or `solver`; [sessionId] is the
/// session's id, not the booking's.
abstract final class SessionApi {
  static ApiClient get _api => ApiClient.instance;

  static String _base(String role, String sessionId) => '/$role/sessions/$sessionId';

  /// GET /…/sessions/:id/lobby: the session's lobby view, including the
  /// other person's name and picture (`solver_info` for seekers,
  /// `seeker_brief` for solvers).
  static Future<Map<String, dynamic>> lobby(String role, String sessionId) async =>
      _map(await _api.get('${_base(role, sessionId)}/lobby'));

  /// POST /…/bookings/:id/face-match: the pre-session face check against the
  /// face enrolled at verification (3–10 JPEG frames, 500 KB each). Returns
  /// `{matched, attempts_remaining, blocked, reason}`.
  static Future<Map<String, dynamic>> faceMatch(String role, String bookingId, List<String> framePaths) async => _map(
    await _api.upload(
      '/$role/bookings/$bookingId/face-match',
      files: [
        for (final (i, p) in framePaths.indexed)
          UploadFile(field: 'frames[]', path: p, fileName: 'frame_$i.jpg', contentType: 'image/jpeg'),
      ],
      fields: {
        'timings': [for (var i = 0; i < framePaths.length; i++) i * 300].join(','),
      },
    ),
  );

  /// POST /…/join: records the join; the session goes live once both joined.
  static Future<Map<String, dynamic>> join(String role, String sessionId) async =>
      _map(await _api.post('${_base(role, sessionId)}/join'));

  /// Creates (or returns) the LiveKit room, then joins it. Returns
  /// `{token, livekit_url, room_name, features, remaining_time_seconds}`.
  static Future<Map<String, dynamic>> joinMeeting(String role, String sessionId) async {
    await _api.post('${_base(role, sessionId)}/meeting/room', data: {'recording_consent': true});
    return _map(await _api.post('${_base(role, sessionId)}/meeting/join', data: {'recording_consent': true}));
  }

  /// POST /…/meeting/refresh: a fresh LiveKit token.
  static Future<Map<String, dynamic>> refreshMeeting(String role, String sessionId) async =>
      _map(await _api.post('${_base(role, sessionId)}/meeting/refresh'));

  /// GET /…/meeting/status: `{room_status, participants, recording_active,
  /// duration_seconds, remaining_time_seconds}`.
  static Future<Map<String, dynamic>> meetingStatus(String role, String sessionId) async =>
      _map(await _api.get('${_base(role, sessionId)}/meeting/status'));

  /// POST /…/meeting/leave.
  static Future<void> leaveMeeting(String role, String sessionId) =>
      _api.post('${_base(role, sessionId)}/meeting/leave', data: const <String, dynamic>{});

  /// GET /…/timer: `{remaining_time_seconds, extended_minutes, status,
  /// pending_extension?}` (the pending extension only for solvers).
  static Future<Map<String, dynamic>> timer(String role, String sessionId) async =>
      _map(await _api.get('${_base(role, sessionId)}/timer'));

  /// POST /…/chat/join: joins the realtime chat room (opens 3 minutes early).
  static Future<void> joinChat(String role, String sessionId) => _api.post('${_base(role, sessionId)}/chat/join');

  /// POST /…/chat/leave.
  static Future<void> leaveChat(String role, String sessionId) => _api.post('${_base(role, sessionId)}/chat/leave');

  /// GET /…/chat/messages, oldest first; [since] returns only newer ones.
  static Future<List<Map<String, dynamic>>> messages(String role, String sessionId, {String? since}) async {
    final data = _map(
      await _api.get('${_base(role, sessionId)}/chat/messages', query: {'limit': 100, 'since': ?since}),
    );
    return [
      if (data['messages'] is List)
        for (final m in data['messages'] as List) _map(m),
    ];
  }

  /// GET /…/chat/messages page by page: a session's whole chat (Meet or
  /// Chat), oldest first.
  static Future<List<Map<String, dynamic>>> chatHistory(String role, String sessionId) async {
    final all = <Map<String, dynamic>>[];
    while (true) {
      final data = _map(
        await _api.get('${_base(role, sessionId)}/chat/messages', query: {'limit': 100, 'offset': all.length}),
      );
      final page = [
        if (data['messages'] is List)
          for (final m in data['messages'] as List) _map(m),
      ];
      all.addAll(page);
      if (data['has_more'] != true || page.isEmpty || all.length >= 2000) return all;
    }
  }

  /// POST /…/chat/messages. [clientId] makes a retry safe.
  static Future<Map<String, dynamic>> send(
    String role,
    String sessionId,
    String text, {
    required String clientId,
    String? replyToId,
  }) async => _map(
    await _api.post(
      '${_base(role, sessionId)}/chat/messages',
      data: {'content': text, 'message_type': 'text', 'client_message_id': clientId, 'reply_to_id': ?replyToId},
    ),
  );

  /// POST /…/chat/files (up to 25 MB).
  static Future<Map<String, dynamic>> sendFile(
    String role,
    String sessionId, {
    required String path,
    required String fileName,
    required String clientId,
  }) async => _map(
    await _api.upload(
      '${_base(role, sessionId)}/chat/files',
      files: [UploadFile(field: 'file', path: path, fileName: fileName)],
      fields: {'client_message_id': clientId},
    ),
  );

  /// POST /seeker/sessions/:id/extend: asks the solver for [minutes] more
  /// (10–60, in the session's final minutes only); the minutes are frozen
  /// meanwhile.
  static Future<Map<String, dynamic>> requestExtension(String sessionId, int minutes) async =>
      _map(await _api.post('/seeker/sessions/$sessionId/extend', data: {'extra_minutes': minutes}));

  /// POST /solver/sessions/:id/approve-extension.
  static Future<Map<String, dynamic>> answerExtension(String sessionId, {required bool approve}) async =>
      _map(await _api.post('/solver/sessions/$sessionId/approve-extension', data: {'approve': approve}));

  /// GET /…/whiteboard/: the saved Excalidraw scene `{elements, app_state,
  /// version}` (version 0 and no elements before the first save).
  static Future<Map<String, dynamic>> whiteboard(String role, String sessionId) async =>
      _map(await _api.get('${_base(role, sessionId)}/whiteboard/'));

  /// PUT /solver/sessions/:id/whiteboard/: saves the scene. [version] must
  /// match the stored one (409 when someone saved in between).
  static Future<Map<String, dynamic>> saveWhiteboard(
    String sessionId, {
    required List<Map<String, dynamic>> elements,
    required Object appState,
    required int version,
  }) async => _map(
    await _api.put(
      '/solver/sessions/$sessionId/whiteboard/',
      data: {'elements': elements, 'app_state': appState, 'version': version},
    ),
  );

  /// POST /…/complete: ends the session (idempotent).
  static Future<void> complete(String role, String sessionId) => _api.post('${_base(role, sessionId)}/complete');

  /// GET /…/pending-reviews: completed sessions still waiting for the
  /// caller's review.
  static Future<List<Map<String, dynamic>>> pendingReviews(String role) async {
    final data = _map(await _api.get('/$role/sessions/pending-reviews'));
    return [
      if (data['sessions'] is List)
        for (final s in data['sessions'] as List) _map(s),
    ];
  }

  /// POST /solver/sessions/:id/meeting/podcast-recording/discard: the solver
  /// chose to delete a podcast's recording; its draft goes too. Returns how
  /// many were removed now (0 is fine: one still uploading is deleted when it
  /// arrives). Keeping it needs no call: it becomes a draft by itself.
  static Future<int> discardPodcastRecording(String sessionId) async {
    final data = _map(await _api.post('/solver/sessions/$sessionId/meeting/podcast-recording/discard'));
    return data['removed'] is int ? data['removed'] as int : 0;
  }

  /// GET /solver/sessions: the solver's last 200 bookings by stage (`upcoming`,
  /// `active`, `completed`, `rescheduled`, `cancelled`), each with the solver's
  /// own review (`solver_*`) and, once that's in, the seeker's (`seeker_*`).
  static Future<Map<String, dynamic>> solverSessions() async => _map(await _api.get('/solver/sessions'));

  /// GET /solver/sessions/:id/seeker-review: the seeker's review of the solver
  /// (`has_review`, `rating`, `feedback`, `helpful`, `unclear`, `learning`,
  /// `would_book_again`). The server doesn't hold it back until the solver has
  /// reviewed, so the app asks only after that.
  static Future<Map<String, dynamic>> seekerReview(String sessionId) async =>
      _map(await _api.get('/solver/sessions/$sessionId/seeker-review'));

  /// POST /…/review.
  static Future<void> review(String role, String sessionId, Map<String, dynamic> review) =>
      _api.post('${_base(role, sessionId)}/review', data: review);

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
