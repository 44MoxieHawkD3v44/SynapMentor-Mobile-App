import 'api_client.dart';

/// In-app notifications for both roles (Postman: Shared > Users >
/// notifications). Needs standard verification; below it the list is empty.
abstract final class NotificationsApi {
  static ApiClient get _api => ApiClient.instance;

  /// GET /users/notifications/, newest first: `{id, event_type, title, body,
  /// link, is_read, created_at}`.
  static Future<List<Map<String, dynamic>>> list() async {
    final data = _map(await _api.get('/users/notifications/', query: {'limit': 100}));
    return [
      if (data['notifications'] is List)
        for (final n in data['notifications'] as List) _map(n),
    ];
  }

  /// POST /users/notifications/:id/read.
  static Future<void> markRead(String id) => _api.post('/users/notifications/$id/read');

  /// POST /users/notifications/read-all.
  static Future<void> markAllRead() => _api.post('/users/notifications/read-all');

  /// POST /users/notifications/clear-all: deletes them all.
  static Future<void> clearAll() => _api.post('/users/notifications/clear-all');

  /// POST /app/push-tokens: this device's Firebase Cloud Messaging token, bound
  /// to the current login session, so the server can send notifications while
  /// the app is closed. [platform] is `android` or `ios` and must match the
  /// app's platform header. Sent after sign-in, at every start and when
  /// Firebase issues a new token; registering it again refreshes it.
  static Future<void> registerPushToken(String token, String platform) =>
      _api.post('/app/push-tokens', data: {'token': token, 'platform': platform});

  /// POST /app/push-tokens/remove: stops pushes to this device. Sent before
  /// sign-out, while the session still works; succeeds even if it's gone.
  static Future<void> removePushToken(String token) => _api.post('/app/push-tokens/remove', data: {'token': token});

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
