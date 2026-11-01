import 'api_client.dart';

/// Content for seekers (Postman: Seeker App > Content, Content Extended,
/// Folders, Content Categories; Shared > Content): the catalogue, details and
/// streams, likes, comments, saved folders and the free-preview meter.
abstract final class ContentApi {
  static ApiClient get _api => ApiClient.instance;

  /// GET /public/content-categories: category → sub-categories.
  static Future<Map<String, List<String>>> categories() async {
    final list = _map(await _api.get('/public/content-categories'))['categories'];
    return {
      if (list is List)
        for (final c in list)
          if (c is Map && c['is_active'] != false && c['name'] is String)
            c['name'] as String: [
              for (final s in c['sub_categories'] as List? ?? const [])
                if (s is Map && s['is_active'] != false && s['name'] is String) s['name'] as String,
            ],
    };
  }

  /// GET /public/content/search: published content, newest first, up to
  /// [max] items.
  static Future<List<Map<String, dynamic>>> search({int max = 200}) async {
    final all = <Map<String, dynamic>>[];
    for (var page = 1; all.length < max; page++) {
      final data = _map(await _api.get('/public/content/search', query: {'page': page, 'limit': 50}));
      final batch = _list(data['content']);
      all.addAll(batch);
      final total = _map(data['pagination'])['total'];
      if (batch.length < 50 || (total is int && all.length >= total)) break;
    }
    return all;
  }

  /// GET /public/content/:id: the full item, `is_liked` and `is_saved`. Also
  /// counts the view and checks premium and free-preview access.
  static Future<Map<String, dynamic>> detail(String id) async => _map(await _api.get('/public/content/$id'));

  /// POST /seeker/content-extended/:id/share or /solver/content/:id/share: a
  /// 7-day link with a random token instead of the content id. Returns
  /// `{share_token, share_url}`.
  static Future<Map<String, dynamic>> shareLink(String role, String id) async =>
      _map(await _api.post(role == 'solver' ? '/solver/content/$id/share' : '/seeker/content-extended/$id/share'));

  /// GET /public/content/:id/stream: a playable URL for the item's media.
  static Future<String?> streamUrl(String id) async =>
      _map(await _api.get('/public/content/$id/stream'))['url'] as String?;

  /// POST /content/:id/react: toggles the like. Returns whether it's liked now.
  static Future<bool> toggleLike(String id) async =>
      _map(await _api.post('/content/$id/react', data: {'reaction_type': 'like'}))['liked'] == true;

  /// GET /content/:id/comments, newest first.
  static Future<List<Map<String, dynamic>>> comments(String id) async =>
      _list(_map(await _api.get('/content/$id/comments', query: {'limit': 100}))['comments']);

  /// POST /content/:id/comments.
  static Future<void> addComment(String id, String message) =>
      _api.post('/content/$id/comments', data: {'message': message.trim()});

  /// GET /seeker/folders: the named folders.
  static Future<List<Map<String, dynamic>>> folders() async => _list(await _api.get('/seeker/folders/'));

  /// POST /seeker/folders. Returns the new folder.
  static Future<Map<String, dynamic>> createFolder(String name) async =>
      _map(await _api.post('/seeker/folders/', data: {'name': name.trim()}));

  /// GET /seeker/folders/saved: content ids saved in a folder, or in the
  /// default bucket when [folderId] is null.
  static Future<List<String>> savedIn(String? folderId) async {
    final items = _map(await _api.get('/seeker/folders/saved', query: {'folder_id': ?folderId, 'limit': 100}))['items'];
    return [
      if (items is List)
        for (final i in items)
          if (i is Map && i['content_id'] != null) '${i['content_id']}',
    ];
  }

  /// POST or DELETE /seeker/folders/save for one folder (null = default).
  static Future<void> setSaved(String contentId, String? folderId, {required bool saved}) {
    final body = {'content_id': contentId, 'folder_id': folderId};
    return saved ? _api.post('/seeker/folders/save', data: body) : _api.delete('/seeker/folders/save', data: body);
  }

  /// GET /seeker/content-extended/preview-usage: `{remaining_minutes, …}`.
  static Future<Map<String, dynamic>> previewUsage() async =>
      _map(await _api.get('/seeker/content-extended/preview-usage'));

  /// POST /seeker/content-extended/preview-usage/consume: the viewing
  /// heartbeat. Returns the new usage.
  static Future<Map<String, dynamic>> consumePreview() async =>
      _map(await _api.post('/seeker/content-extended/preview-usage/consume'));

  // ---- The solver's own content (Postman: Solver App > Content) ---------------

  /// GET /solver/content: the solver's content, drafts included.
  static Future<List<Map<String, dynamic>>> mine() async {
    final all = <Map<String, dynamic>>[];
    for (var page = 1; ; page++) {
      final data = _map(await _api.get('/solver/content/', query: {'page': page, 'limit': 100}));
      final batch = _list(data['content']);
      all.addAll(batch);
      final total = _map(data['pagination'])['total'];
      if (batch.length < 100 || (total is int && all.length >= total)) return all;
    }
  }

  /// POST /solver/content: a draft tagged with one of the solver's verified
  /// skill and focus-area pairs.
  static Future<Map<String, dynamic>> create(Map<String, dynamic> fields) async =>
      _map(await _api.post('/solver/content/', data: fields));

  /// POST /solver/content/:id: saves edits. Only the fields sent change (title,
  /// description, category, sub_category, tags, content_url, is_premium, blog
  /// body); status and media don't change here. The item isn't returned.
  static Future<void> update(String id, Map<String, dynamic> fields) => _api.post('/solver/content/$id', data: fields);

  /// GET /solver/content/publish-eligibility: the same verdict publishing
  /// enforces: `{can_publish, skill_verified, kyc_complete, error_code?}` with
  /// `SOLVER_NOT_VERIFIED` or `SOLVER_KYC_INCOMPLETE`.
  static Future<Map<String, dynamic>> publishEligibility() async =>
      _map(await _api.get('/solver/content/publish-eligibility'));

  /// POST /solver/content/:id/upload/:kind (`media`, `thumbnail` or
  /// `transcript`).
  static Future<void> upload(String id, String kind, {required String path, required String fileName}) => _api.upload(
    '/solver/content/$id/upload/$kind',
    files: [UploadFile(field: 'file', path: path, fileName: fileName)],
  );

  /// POST /solver/content/blog-images: a picture for inside a blog (PNG, JPG,
  /// GIF, WebP or AVIF, up to 8 MB). Returns its link, e.g.
  /// `/api/v1/public/content/blog-images/<id>`, which anyone can open.
  static Future<String> uploadBlogImage({required String path, required String fileName}) async {
    final data = _map(
      await _api.upload(
        '/solver/content/blog-images',
        files: [UploadFile(field: 'file', path: path, fileName: fileName)],
      ),
    );
    final url = data['url'] as String?;
    if (url == null || url.isEmpty) throw const ApiException('The picture couldn\'t be uploaded. Please try again.');
    return url;
  }

  /// POST /solver/content/:id/publish. Returns the published item.
  static Future<Map<String, dynamic>> publish(String id) async => _map(await _api.post('/solver/content/$id/publish'));

  /// POST /solver/content/:id/unpublish: back to draft.
  static Future<void> unpublish(String id) => _api.post('/solver/content/$id/unpublish');

  /// DELETE /solver/content/:id.
  static Future<void> delete(String id) => _api.delete('/solver/content/$id');

  /// POST /solver/content/:id/rollback: removes a draft whose upload failed.
  static Future<void> rollback(String id) => _api.post('/solver/content/$id/rollback');

  static List<Map<String, dynamic>> _list(Object? data) => [
    if (data is List)
      for (final item in data) _map(item),
  ];

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
