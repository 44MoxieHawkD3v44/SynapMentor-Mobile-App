import 'api_client.dart';

/// Mobile app maintenance mode and version check. Both stay reachable while
/// maintenance is on, so the app can show it and a required update.
abstract final class AppStatusApi {
  static ApiClient get _api => ApiClient.instance;

  /// GET /public/app/maintenance: `{maintenance_enabled, message}`.
  static Future<Map<String, dynamic>> maintenance() async => _map(await _api.get('/public/app/maintenance'));

  /// GET /public/app/version-check for this install (the platform and version
  /// come from the request headers): `{update_type: none|optional|mandatory,
  /// latest_version, download_url, release_notes, …}`.
  static Future<Map<String, dynamic>> versionCheck() async => _map(await _api.get('/public/app/version-check'));

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
