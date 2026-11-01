import 'api_client.dart';

/// TODO tasks (Postman: Seeker App > Tasks, Solver App > Tasks). Both roles
/// share the same shapes under their own path.
abstract final class TasksApi {
  static ApiClient get _api => ApiClient.instance;

  static String _base(String role) => role == 'solver' ? '/solver/tasks' : '/seeker/tasks';

  /// GET /tasks, every page.
  static Future<List<Map<String, dynamic>>> list(String role) async {
    final tasks = <Map<String, dynamic>>[];
    for (var page = 1; ; page++) {
      final data = _map(await _api.get('${_base(role)}/', query: {'page': page, 'limit': 100}));
      final batch = [for (final t in data['tasks'] as List? ?? const []) _map(t)];
      tasks.addAll(batch);
      final total = _map(data['pagination'])['total'];
      if (batch.length < 100 || (total is int && tasks.length >= total)) return tasks;
    }
  }

  /// GET /tasks/:id, with the description and recurrence the list leaves out.
  static Future<Map<String, dynamic>> get(String role, String id) async => _map(await _api.get('${_base(role)}/$id'));

  /// POST /tasks.
  static Future<Map<String, dynamic>> create(String role, Map<String, dynamic> fields) async =>
      _map(await _api.post('${_base(role)}/', data: fields));

  /// POST /tasks/:id. Omitted fields stay as they are.
  static Future<Map<String, dynamic>> update(String role, String id, Map<String, dynamic> fields) async =>
      _map(await _api.post('${_base(role)}/$id', data: fields));

  /// POST /tasks/:id/complete. Also schedules a recurring task's next one.
  static Future<Map<String, dynamic>> complete(String role, String id) async =>
      _map(await _api.post('${_base(role)}/$id/complete'));

  /// POST /tasks/:id/recurrence with `daily`, `weekly` or `monthly`.
  static Future<Map<String, dynamic>> setRecurrence(String role, String id, String frequency) async =>
      _map(await _api.post('${_base(role)}/$id/recurrence', data: {'frequency': frequency}));

  /// DELETE /tasks/:id.
  static Future<void> delete(String role, String id) => _api.delete('${_base(role)}/$id');

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
