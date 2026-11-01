import 'api_client.dart';

/// Help & Support for both roles (Postman: Seeker App > Support, Solver App >
/// Support, Shared > Support). Solvers use the same calls under
/// `/solver/support`; [role] is `seeker` or `solver`.
abstract final class SupportApi {
  static ApiClient get _api => ApiClient.instance;

  static String _base(String role) => role == 'solver' ? '/solver/support' : '/support';

  /// GET /support/faqs for the caller's role.
  static Future<List<Map<String, dynamic>>> faqs() async => _list(await _api.get('/support/faqs'));

  /// GET /support/tickets, every page, newest first.
  static Future<List<Map<String, dynamic>>> tickets(String role) async {
    final tickets = <Map<String, dynamic>>[];
    for (var page = 1; ; page++) {
      final data = _map(await _api.get('${_base(role)}/tickets', query: {'page': page, 'limit': 100}));
      final batch = _list(data['tickets']);
      tickets.addAll(batch);
      final total = _map(data['pagination'])['total'];
      if (batch.length < 100 || (total is int && tickets.length >= total)) return tickets;
    }
  }

  /// GET /support/tickets/:id: `{ticket, messages, attachments}`.
  static Future<Map<String, dynamic>> ticket(String role, String id) async =>
      _map(await _api.get('${_base(role)}/tickets/$id'));

  /// POST /support/ticket. Returns the new ticket.
  static Future<Map<String, dynamic>> createTicket(
    String role, {
    required String category,
    required String subject,
    required String description,
    String? context,
    List<String> links = const [],
  }) async => _map(
    await _api.post(
      role == 'solver' ? '/solver/support/tickets' : '/support/ticket',
      data: {
        'category': category,
        'subject': subject.trim(),
        'description': description.trim(),
        'context': ?context,
        if (links.isNotEmpty) 'evidence': _evidence(links),
      },
    ),
  );

  /// POST /support/report: reports content or suspicious activity.
  static Future<Map<String, dynamic>> report(
    String role, {
    required String category,
    required String subject,
    required String message,
    String? reportType,
    List<String> links = const [],
  }) async => _map(
    await _api.post(
      '${_base(role)}/report',
      data: {
        'category': category,
        'subject': subject.trim(),
        'message': message.trim(),
        if (reportType != null) 'report_type': reportType.length > 50 ? reportType.substring(0, 50) : reportType,
        if (links.isNotEmpty) 'evidence': _evidence(links),
      },
    ),
  );

  /// POST /support/tickets/:id/attachments (JPG, PNG, WebP or PDF, 5 MB).
  static Future<void> attach(String role, String ticketId, {required String path, String? fileName}) => _api.upload(
    '${_base(role)}/tickets/$ticketId/attachments',
    files: [UploadFile(field: 'file', path: path, fileName: fileName)],
  );

  /// POST /support/tickets/:id/messages.
  static Future<void> reply(String role, String ticketId, String message) =>
      _api.post('${_base(role)}/tickets/$ticketId/messages', data: {'message': message.trim()});

  static List<Map<String, dynamic>> _evidence(List<String> links) => [
    for (final link in links) {'type': 'link', 'value': link},
  ];

  static List<Map<String, dynamic>> _list(Object? data) => [
    if (data is List)
      for (final item in data) _map(item),
  ];

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
