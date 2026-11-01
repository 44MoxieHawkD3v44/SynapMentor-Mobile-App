import 'api_client.dart';

/// Communities, discussions and events for members (Postman: Shared >
/// Communities, Threads, Events; Seeker App > Threads).
abstract final class CommunityApi {
  static ApiClient get _api => ApiClient.instance;

  /// GET /communities: every active public community.
  static Future<List<Map<String, dynamic>>> communities() async {
    final all = <Map<String, dynamic>>[];
    for (var page = 1; ; page++) {
      final data = _map(await _api.get('/communities/', query: {'page': page, 'limit': 100}));
      final batch = _list(data['communities']);
      all.addAll(batch);
      final total = _map(data['pagination'])['total'];
      if (batch.length < 100 || (total is int && all.length >= total)) return all;
    }
  }

  /// GET /communities/:id: one community, with a displayable `logo_url`
  /// (a link that expires after 10 minutes) when it has a logo.
  static Future<Map<String, dynamic>> detail(String communityId) async =>
      _map(await _api.get('/communities/$communityId'));

  /// GET /communities/joined.
  static Future<List<Map<String, dynamic>>> joined() async => _list(await _api.get('/communities/joined'));

  /// GET /communities/invite/:code: the community behind an invite code.
  static Future<Map<String, dynamic>> byInviteCode(String code) async =>
      _map(await _api.get('/communities/invite/${Uri.encodeComponent(code)}'));

  /// POST /communities/:id/action with `join` or `leave`. Returns the new
  /// member count.
  static Future<int?> action(String communityId, String action) async =>
      _map(await _api.post('/communities/$communityId/action', data: {'action': action}))['member_count'] as int?;

  /// POST /communities/invite/:code/join (also private communities).
  static Future<int?> joinWithCode(String code) async =>
      _map(await _api.post('/communities/invite/${Uri.encodeComponent(code)}/join'))['member_count'] as int?;

  /// GET /communities/:id/members, by pseudo name.
  static Future<List<Map<String, dynamic>>> members(String communityId) async =>
      _list(await _api.get('/communities/$communityId/members', query: {'limit': 200}));

  /// POST /communities/:id/read.
  static Future<void> markRead(String communityId) => _api.post('/communities/$communityId/read');

  /// GET /communities/:id/threads, pinned first.
  static Future<List<Map<String, dynamic>>> threads(String communityId) async =>
      _list(await _api.get('/communities/$communityId/threads', query: {'limit': 200}));

  /// POST /communities/:id/threads.
  static Future<Map<String, dynamic>> createThread(String communityId, String title, String description) async => _map(
    await _api.post(
      '/communities/$communityId/threads',
      data: {'title': title.trim(), 'description': description.trim()},
    ),
  );

  /// GET /threads/:id/messages, oldest first (up to the latest 200).
  static Future<List<Map<String, dynamic>>> messages(String threadId) async =>
      _list(await _api.get('/threads/$threadId/messages', query: {'limit': 200}));

  /// POST /threads/:id/messages, optionally with a file uploaded by
  /// [uploadFile]. Returns the stored message.
  static Future<Map<String, dynamic>> sendMessage(
    String threadId,
    String message, {
    Map<String, dynamic>? file,
    String? quotedId,
  }) async => _map(
    await _api.post(
      '/threads/$threadId/messages',
      data: {
        'message': message,
        'quoted_message_id': ?quotedId,
        if (file != null) ...{
          'file_url': file['file_url'],
          'file_context': {
            'file_name': file['file_name'],
            'file_size': file['file_size'],
            'content_type': file['content_type'],
          },
        },
      },
    ),
  );

  /// POST /communities/:id/threads/:thread/upload (up to 10 MB). Returns
  /// `{file_url, file_name, file_size, content_type}` for [sendMessage].
  static Future<Map<String, dynamic>> uploadFile(String communityId, String threadId, String path, String name) async =>
      _map(
        await _api.upload(
          '/communities/$communityId/threads/$threadId/upload',
          files: [UploadFile(field: 'file', path: path, fileName: name)],
        ),
      );

  /// POST /threads/:id/messages/:message/reactions.
  static Future<void> react(String threadId, String messageId, String emoji) =>
      _api.post('/threads/$threadId/messages/$messageId/reactions', data: {'emoji': emoji});

  /// DELETE /threads/:id/messages/:message/reactions/:emoji.
  static Future<void> unreact(String threadId, String messageId, String emoji) =>
      _api.delete('/threads/$threadId/messages/$messageId/reactions/${Uri.encodeComponent(emoji)}');

  /// GET /events: upcoming and ongoing events with the caller's registration.
  static Future<List<Map<String, dynamic>>> events() async =>
      _list(_map(await _api.get('/events/', query: {'limit': 100}))['events']);

  /// POST /events/:id/registrations. The user agreed to share their name and
  /// email with the host.
  static Future<Map<String, dynamic>> register(String eventId) async =>
      _map(await _api.post('/events/$eventId/registrations', data: {'share_contact': true}));

  /// DELETE /events/:id/registrations.
  static Future<void> unregister(String eventId) => _api.delete('/events/$eventId/registrations');

  // ---- Owner tools (solvers; Postman: Solver App > Communities, Community,
  // Communities Request, Community Requests) -----------------------------------

  /// GET /solver/communities/my-communities, with their invite codes.
  static Future<List<Map<String, dynamic>>> myCommunities() async =>
      _list(await _api.get('/solver/communities/my-communities'));

  /// GET /solver/community-requests.
  static Future<List<Map<String, dynamic>>> requests() async => _list(await _api.get('/solver/community-requests'));

  /// POST /solver/communities-request for admin approval. Returns the request id.
  static Future<String?> submitRequest({
    required String name,
    required String purpose,
    required String scope,
    required List<String> technologies,
  }) async =>
      _map(
            await _api.post(
              '/solver/communities-request',
              data: {
                'name': name.trim(),
                'purpose': purpose.trim(),
                if (scope.trim().isNotEmpty) 'scope': scope.trim(),
                'technologies': technologies,
              },
            ),
          )['request_id']
          as String?;

  /// POST /solver/communities/:id/logo (owner only): uploads the logo, or
  /// replaces it. An image up to 2 MB.
  static Future<void> uploadLogo(String communityId, {required String path, required String fileName}) {
    final type = switch (fileName.split('.').last.toLowerCase()) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => 'image/jpeg',
    };
    return _api.upload(
      '/solver/communities/$communityId/logo',
      files: [UploadFile(field: 'file', path: path, fileName: fileName, contentType: type)],
    );
  }

  /// POST /solver/communities/:id/invite: a new code; the old one stops working.
  static Future<String?> newInviteCode(String communityId) async =>
      _map(await _api.post('/solver/communities/$communityId/invite'))['code'] as String?;

  /// Pins or unpins a discussion.
  static Future<void> pin(String communityId, String threadId, {required bool on}) => on
      ? _api.post('/solver/communities/$communityId/threads/$threadId/pin')
      : _api.delete('/solver/communities/$communityId/threads/$threadId/pin');

  /// Locks or unlocks a discussion.
  static Future<void> lock(String communityId, String threadId, {required bool on}) => on
      ? _api.post('/solver/communities/$communityId/threads/$threadId/lock')
      : _api.delete('/solver/communities/$communityId/threads/$threadId/lock');

  /// DELETE /solver/communities/:id/threads/:thread ([reason] 10+ characters).
  static Future<void> deleteThread(String communityId, String threadId, String reason) =>
      _api.delete('/solver/communities/$communityId/threads/$threadId', data: {'reason': reason});

  /// DELETE /solver/communities/:id/members/:user ([reason] 5+ characters).
  static Future<void> kick(String communityId, String userId, String reason) =>
      _api.delete('/solver/communities/$communityId/members/$userId', data: {'reason': reason});

  /// POST /solver/communities/:id/bans: permanent unless [until] is given.
  static Future<void> ban(String communityId, String userId, String reason, {DateTime? until}) => _api.post(
    '/solver/communities/$communityId/bans',
    data: {'user_id': userId, 'reason': reason, if (until != null) 'expires_at': until.toUtc().toIso8601String()},
  );

  /// POST /solver/communities/:id/rules: replaces the rules text (empty clears it).
  static Future<void> setRules(String communityId, String rules) =>
      _api.post('/solver/communities/$communityId/rules', data: {'rules': rules});

  /// GET /solver/communities/:id/activity: the moderation and activity log, newest first.
  static Future<List<Map<String, dynamic>>> activity(String communityId) async =>
      _list(await _api.get('/solver/communities/$communityId/activity', query: {'limit': 200}));

  /// DELETE /solver/communities/:id/bans/:user.
  static Future<void> unban(String communityId, String userId, String reason) =>
      _api.delete('/solver/communities/$communityId/bans/$userId', data: {'reason': reason});

  /// GET /solver/communities/:id/bans.
  static Future<List<Map<String, dynamic>>> bans(String communityId) async =>
      _list(await _api.get('/solver/communities/$communityId/bans', query: {'limit': 200}));

  /// POST /solver/community/events/:id/poster or /cover ([kind]): uploads or
  /// replaces an event's artwork (owner only, while it's upcoming or
  /// ongoing; JPG, PNG, WebP or GIF up to 5 MB). Returns the new picture's
  /// link, which expires after 10 minutes.
  static Future<String?> uploadEventArtwork(
    String eventId,
    String kind, {
    required String path,
    required String fileName,
  }) async {
    final type = switch (fileName.split('.').last.toLowerCase()) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => 'image/jpeg',
    };
    final data = _map(
      await _api.upload(
        '/solver/community/events/$eventId/$kind',
        files: [UploadFile(field: 'file', path: path, fileName: fileName, contentType: type)],
      ),
    );
    return (data[kind == 'cover' ? 'cover_image_url' : 'poster_url'] as String?)?.trim();
  }

  /// GET /events/:id: one event, with fresh artwork links.
  static Future<Map<String, dynamic>> event(String eventId) async => _map(await _api.get('/events/$eventId'));

  /// GET /solver/community/events/:id/edit-status: `{editable, edited,
  /// reason?}`. Events can be edited any number of times until they start,
  /// complete or are cancelled.
  static Future<Map<String, dynamic>> eventEditStatus(String eventId) async =>
      _map(await _api.get('/solver/community/events/$eventId/edit-status'));

  /// POST /solver/community/events/:id: changes only the fields sent. `0`
  /// clears the member limit and `""` clears a link or location. The event
  /// isn't returned; read it again.
  static Future<void> updateEvent(String eventId, Map<String, dynamic> fields) =>
      _api.post('/solver/community/events/$eventId', data: fields);

  /// POST /solver/community/events in a community the solver owns.
  static Future<Map<String, dynamic>> createEvent(Map<String, dynamic> event) async =>
      _map(await _api.post('/solver/community/events', data: event));

  static List<Map<String, dynamic>> _list(Object? data) => [
    if (data is List)
      for (final item in data) _map(item),
  ];

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
