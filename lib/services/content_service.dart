import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/content_api.dart';
import '../core/html_entities.dart';

import 'auth_service.dart';
import 'kyc_service.dart';
import 'skill_verification_service.dart';
import 'solver_service.dart';
import 'wallet_service.dart';

enum ContentType {
  reel('Reel', 'Reels'),
  video('Video', 'Videos'),
  blog('Blog', 'Blogs'),
  image('Image', 'Images'),
  repo('Repo', 'Repos'),
  podcast('Podcast', 'Podcasts');

  const ContentType(this.label, this.plural);
  final String label;
  final String plural;

  /// Playable content counts against the daily free minutes.
  bool get isMedia => this == reel || this == video || this == podcast;
}

class ContentComment {
  const ContentComment(this.author, this.text, this.at);

  /// Pseudo name, as everywhere seekers interact.
  final String author;
  final String text;
  final DateTime at;
}

class ContentItem {
  ContentItem({
    required this.id,
    required this.type,
    required this.title,
    required this.description,
    required this.category,
    required this.subcategory,
    required this.tags,
    required this.solverId,
    required this.solverName,
    required this.createdAt,
    required this.views,
    this.premium = false,
    this.durationSeconds = 0,
    this.readMinutes = 0,
    this.keyPoints = const [],
    this.body = const [],
    this.repoUrl,
    this.featured = false,
    this.youtubeId,
    this.imageUrl,
    this.source,
    this.draft = false,
    this.format,
    this.coverPath,
    this.mediaPath,
    this.mediaFileName,
    this.html = false,
    this.remote = false,
  });

  /// Loaded from the content API.
  final bool remote;

  /// Set once the full item has been loaded from the API.
  bool detailLoaded = false;

  /// Why the server refused to show it (premium, preview used up,
  /// verification), if it did.
  String? accessError;

  final String id;
  final ContentType type;
  // Editable by the solver who owns the item.
  String title;
  String description;
  String category;
  String subcategory;
  List<String> tags;
  final String solverId;
  final String solverName;
  final DateTime createdAt;
  int views;

  /// Premium content (such as 3D videos and reels) needs a subscription.
  bool premium;
  int durationSeconds;
  int readMinutes;
  final List<String> keyPoints;
  List<String> body;
  String? repoUrl;
  final bool featured;

  /// Reels, videos and podcasts with a YouTube id play the real video.
  final String? youtubeId;

  /// The picture itself for images; a cover photo for blogs.
  String? imageUrl;

  /// An image post's uploaded picture, from the server. Shown when the post
  /// has no separate cover.
  String? mediaUrl;

  /// Credit for media made by someone else, such as the YouTube channel.
  final String? source;

  /// Drafts are visible only to their solver, never to seekers.
  bool draft;

  /// How the content is made, e.g. "Tutorial" or "3D Animation".
  String? format;

  /// Local files the solver uploaded: the cover, and the picture for images.
  String? coverPath;
  String? mediaPath;

  /// The uploaded video, reel or image file's name.
  String? mediaFileName;

  /// A podcast draft made from a session recording, and when the server
  /// deletes it unless it's published.
  bool autoRecorded = false;
  DateTime? draftExpiresAt;

  /// Blog bodies written in the editor are HTML, rendered for readers.
  bool html;

  /// Best available preview picture, or null for the icon placeholder.
  String? get thumbnailUrl {
    if (imageUrl != null) return imageUrl;
    if (type == ContentType.image && mediaUrl != null) return mediaUrl;
    if (youtubeId != null) return 'https://i.ytimg.com/vi/$youtubeId/hqdefault.jpg';
    final repo = repoUrl == null ? null : Uri.tryParse(repoUrl!);
    if (repo != null && repo.host == 'github.com' && repo.pathSegments.length >= 2) {
      return 'https://opengraph.githubassets.com/1/${repo.pathSegments[0]}/${repo.pathSegments[1]}';
    }
    return null;
  }

  final appreciatedBy = <String>{};
  final comments = <ContentComment>[];
}

/// Content: the catalogue, engagement, saved folders and the daily free
/// viewing allowance, and the solver's own content, from the content API.
class ContentService extends ChangeNotifier {
  static final ContentService instance = ContentService();

  // ---- API -----------------------------------------------------------------------

  /// Why the catalogue couldn't be loaded, if it couldn't.
  String? loadError;

  /// Folder ids by name; the default "Saved" bucket has none.
  final _folderIds = <String, String>{};
  final _folderCreations = <String, Future<String?>>{};

  /// Seconds watched since the last preview heartbeat, per user.
  final _sinceHeartbeat = <String, int>{};

  /// The server meters free previews; a heartbeat goes up this often.
  static const _heartbeatSeconds = 30;

  /// Loads the categories and published content, and for seekers their saved
  /// folders, today's free preview and their subscription.
  Future<void> load(AppUser user) async {
    try {
      final results = await Future.wait([ContentApi.categories(), ContentApi.search()]);
      setReferenceData(categories: results[0] as Map<String, List<String>>);
      final known = {for (final i in _all) i.id: i};
      _all
        ..removeWhere((i) => i.remote)
        ..addAll([for (final c in results[1] as List<Map<String, dynamic>>) _itemFrom(c, known[c['id']])]);
      _linksLoadedAt = DateTime.now();
      loadError = null;
    } on AuthException catch (e) {
      loadError = e.message;
    }
    if (user.role == UserRole.seeker) {
      await Future.wait([
        _loadFolders(user).catchError((Object _) {}),
        _loadPreview(user).catchError((Object _) {}),
        WalletService.instance.load(user),
      ]);
    }
    notifyListeners();
  }

  Future<void> _loadFolders(AppUser user) async {
    final named = await ContentApi.folders();
    _folderIds
      ..clear()
      ..addAll({for (final f in named) '${f['name']}': '${f['id']}'});
    final entries = await Future.wait([
      ContentApi.savedIn(null).then((ids) => MapEntry(defaultFolder, ids.toSet())),
      for (final f in named) ContentApi.savedIn('${f['id']}').then((ids) => MapEntry('${f['name']}', ids.toSet())),
    ]);
    _folders[user.email] = {defaultFolder: <String>{}, ...Map.fromEntries(entries)};
  }

  Future<void> _loadPreview(AppUser user) async => _applyPreview(user, await ContentApi.previewUsage());

  void _applyPreview(AppUser user, Map<String, dynamic> usage) {
    final used = usage['minutes_used'];
    if (used is num) _freeUsed[_dayKey(user)] = (used * 60).round().clamp(0, freeSecondsPerDay);
    if (usage['is_preview_exhausted'] == true) _freeUsed[_dayKey(user)] = freeSecondsPerDay;
  }

  /// Records a refusal because the free preview is used up: KYC is needed
  /// (after 5 minutes without it) or a subscription (after today's 10).
  /// Returns whether [error] was one.
  bool previewDenied(AppUser user, Object error) {
    if (error is! ApiException || user.role != UserRole.seeker) return false;
    final key = _dayKey(user);
    final used = _freeUsed[key] ?? 0;
    switch (error.code) {
      case 'KYC_REQUIRED':
        if (used < kycPreviewSeconds) _freeUsed[key] = kycPreviewSeconds;
      case 'PREVIEW_EXHAUSTED':
        _freeUsed[key] = freeSecondsPerDay;
      default:
        return false;
    }
    notifyListeners();
    return true;
  }

  /// After KYC (or a subscription), picks up the new allowance from the
  /// server and loads [item] if it was refused before.
  Future<void> refreshAccess(AppUser user, ContentItem item) async {
    if (user.role == UserRole.seeker) {
      await _loadPreview(user).catchError((Object _) {});
      notifyListeners();
    }
    if (item.remote && !item.detailLoaded && !outOfFree(user)) await open(user, item);
  }

  static ContentType _typeOf(String? type) => switch ('$type'.toLowerCase()) {
    'reel' || 'short' => ContentType.reel,
    'video' => ContentType.video,
    'podcast' || 'audio' => ContentType.podcast,
    'image' || 'infographic' => ContentType.image,
    // The API calls repositories `github_repo`.
    'github_repo' || 'repo' || 'repository' || 'github' => ContentType.repo,
    _ => ContentType.blog,
  };

  static String? _youtubeId(String? url) {
    final uri = Uri.tryParse(url ?? '');
    if (uri == null) return null;
    if (uri.host.endsWith('youtu.be')) return uri.pathSegments.firstOrNull;
    if (!uri.host.contains('youtube.com')) return null;
    return uri.queryParameters['v'] ??
        (uri.pathSegments.length >= 2 && (uri.pathSegments[0] == 'shorts' || uri.pathSegments[0] == 'embed')
            ? uri.pathSegments[1]
            : null);
  }

  ContentItem _itemFrom(Map<String, dynamic> c, ContentItem? known) {
    String text(String key) => (c[key] as String?)?.trim() ?? '';
    final type = _typeOf(c['content_type'] as String?);
    final youtube = _youtubeId(c['media_url'] as String?) ?? _youtubeId(c['content_url'] as String?);
    final item =
        ContentItem(
            id: '${c['id']}',
            type: type,
            title: text('title'),
            description: known?.description ?? text('description'),
            category: text('category'),
            subcategory: text('sub_category'),
            tags: [for (final t in c['tags'] as List? ?? const []) '$t'],
            solverId: '${c['solver_id'] ?? ''}',
            solverName: text('solver_name').isEmpty ? 'Solver' : text('solver_name'),
            createdAt: (DateTime.tryParse('${c['published_at'] ?? c['created_at']}') ?? DateTime.now()).toLocal(),
            views: c['view_count'] is int ? c['view_count'] as int : 0,
            premium: c['is_premium'] == true,
            durationSeconds: c['duration'] is int ? c['duration'] as int : 0,
            featured: c['is_featured'] == true,
            youtubeId: youtube ?? known?.youtubeId,
            imageUrl: _link(c['thumbnail_url']) ?? known?.imageUrl,
            format: text('format').isEmpty ? null : text('format'),
            body: known?.body ?? const [],
            html: known?.html ?? false,
            repoUrl: type == ContentType.repo ? (text('content_url').isEmpty ? null : text('content_url')) : null,
            remote: true,
          )
          ..detailLoaded = known?.detailLoaded ?? false
          ..mediaUrl = type == ContentType.image ? _link(c['media_url']) ?? known?.mediaUrl : null;
    _setLikes(
      item,
      c['like_count'] is int ? c['like_count'] as int : 0,
      liked: known != null && known.appreciatedBy.contains(_meKey),
    );
    if (known != null) item.comments.addAll(known.comments);
    return item;
  }

  /// The user's own like is kept under one key; the other likes are counted
  /// with placeholders so the screens can show the total.
  static const _meKey = '\u0000me';

  void _setLikes(ContentItem item, int count, {required bool liked}) {
    item.appreciatedBy
      ..clear()
      ..addAll([for (var i = 0; i < count - (liked ? 1 : 0); i++) '\u0000like$i'])
      ..addAll([if (liked) _meKey]);
  }

  /// Loads the full item (body, media, likes) and its comments. The server
  /// also counts the view and checks access.
  Future<void> open(AppUser user, ContentItem item) async {
    if (!item.remote) return;
    try {
      final d = await ContentApi.detail(item.id);
      final c = d['content'] is Map ? Map<String, dynamic>.from(d['content'] as Map) : const <String, dynamic>{};
      final body = (c['body'] as String?)?.trim() ?? '';
      item
        ..description = (c['description'] as String?)?.trim() ?? item.description
        ..tags = [for (final t in c['tags'] as List? ?? const []) '$t']
        ..premium = c['is_premium'] == true
        ..views = c['view_count'] is int ? c['view_count'] as int : item.views
        ..durationSeconds = c['duration'] is int ? c['duration'] as int : item.durationSeconds
        ..body = body.isEmpty ? const [] : [body]
        ..html = body.contains('<')
        ..accessError = null
        ..detailLoaded = true;
      if (_link(c['thumbnail_url']) case final url?) item.imageUrl = url;
      if (item.type == ContentType.image) {
        if (_link(c['media_url']) case final url?) item.mediaUrl = url;
      }
      if (item.type == ContentType.repo && c['content_url'] is String) item.repoUrl = c['content_url'] as String;
      _setLikes(item, c['like_count'] is int ? c['like_count'] as int : 0, liked: d['is_liked'] == true);
      final folders = this.folders(user);
      if (d['is_saved'] == true && !isSaved(user, item)) folders[defaultFolder]!.add(item.id);
      notifyListeners();
      // Opening counts toward the free preview on the server; show its count.
      if (metered(user)) unawaited(_loadPreview(user).then((_) => notifyListeners(), onError: (Object _) {}));
      final comments = await ContentApi.comments(item.id);
      item.comments
        ..clear()
        ..addAll([
          for (final m in comments.reversed)
            ContentComment(
              m['user_name'] as String? ?? 'User',
              decodeHtmlEntities(m['message'] as String? ?? ''),
              (DateTime.tryParse('${m['created_at']}') ?? DateTime.now()).toLocal(),
            ),
        ]);
      notifyListeners();
    } on AuthException catch (e) {
      // A used-up free preview is shown as the KYC (or subscription) lock
      // rather than an error.
      if (!previewDenied(user, e)) item.accessError = e.message;
      notifyListeners();
    }
  }

  /// A playable URL for the item's media, when it isn't a YouTube video.
  Future<String?> streamUrlOf(ContentItem item) => ContentApi.streamUrl(item.id);

  /// The link to share [item]: a token link from the server, so no content id
  /// shows. Without one, the share points to the app.
  Future<String> shareLink(AppUser user, ContentItem item) async {
    if (item.remote) {
      try {
        final r = await ContentApi.shareLink(user.role.name, item.id);
        final url = (r['share_url'] as String?)?.trim() ?? '';
        if (url.isNotEmpty) return url;
        final token = (r['share_token'] as String?)?.trim() ?? '';
        if (token.isNotEmpty) return 'https://synapmentor.app/shared/$token';
      } on AuthException {
        // Falls back to the app link.
      }
    }
    return 'https://synapmentor.app';
  }

  /// Media links can come back as paths on the API server.
  static String _absolute(String url) => url.startsWith('/') ? '${ApiConfig.baseUrl}$url' : url;

  /// A picture link the app can load: a full (signed) link or a path on the
  /// API server. Some responses carry the raw storage key instead, which
  /// isn't a link, so it gives null.
  static String? _link(Object? value) {
    final url = value is String ? value.trim() : '';
    if (url.startsWith('http://') || url.startsWith('https://') || url.startsWith('/')) return _absolute(url);
    return null;
  }

  /// When the catalogue's links were last fetched. Signed picture links
  /// expire an hour after they're issued.
  DateTime? _linksLoadedAt;
  bool _refreshingLinks = false;

  /// Called when a cover fails to load: once the links are close to expiring,
  /// fetches fresh ones (once per load, so a broken picture can't loop).
  void refreshExpiredLinks() {
    final user = AuthService.instance.currentUser;
    final at = _linksLoadedAt;
    if (user == null || _refreshingLinks || at == null) return;
    if (DateTime.now().difference(at) < const Duration(minutes: 45)) return;
    _refreshingLinks = true;
    (user.role == UserRole.solver ? loadMine(user) : load(user))
        .catchError((Object _) {})
        .whenComplete(() => _refreshingLinks = false);
  }

  /// Free viewing per day for users without a subscription.
  static const freeSecondsPerDay = 10 * 60;

  /// Seekers without KYC get this much free preview; then the server asks
  /// them to complete KYC.
  static const kycPreviewSeconds = 5 * 60;

  /// Category → subcategories, loaded from the API.
  static final categories = <String, List<String>>{};

  final _all = <ContentItem>[];

  /// Replaces the content catalog with what the API returned.
  void setItems(List<ContentItem> items) {
    _all
      ..clear()
      ..addAll(items);
    notifyListeners();
  }

  /// Replaces the categories and formats with what the API returned.
  void setReferenceData({Map<String, List<String>>? categories, List<String>? formats}) {
    if (categories != null) {
      ContentService.categories
        ..clear()
        ..addAll(categories);
    }
    if (formats != null) {
      ContentService.formats
        ..clear()
        ..addAll(formats);
    }
    notifyListeners();
  }

  /// Published content, as seekers see it.
  List<ContentItem> get items => [
    for (final i in _all)
      if (!i.draft) i,
  ];
  final _folders = <String, Map<String, Set<String>>>{}; // user → folder → item ids
  final _freeUsed = <String, int>{}; // "email|yyyy-m-d" → seconds

  ContentItem byId(String id) => _all.firstWhere((i) => i.id == id);

  ContentItem? find(String id) => _all.where((i) => i.id == id).firstOrNull;

  List<ContentItem> ofType(ContentType t) => items.where((i) => i.type == t).toList();

  // ---- Access ----------------------------------------------------------------------

  /// Solvers create content, so they browse it without the seeker paywall or
  /// daily free-minute limit.
  bool subscribed(AppUser user) => user.role == UserRole.solver || WalletService.instance.subscription(user) != null;

  bool canOpen(AppUser user, ContentItem item) => !item.premium || subscribed(user);

  bool _kycDone(AppUser user) => KycService.instance.stateFor(user).completed;

  /// Whether the server meters this user's viewing: every seeker except
  /// subscribers who have completed KYC.
  bool metered(AppUser user) => user.role == UserRole.seeker && !(subscribed(user) && _kycDone(user));

  /// Whether the preview ends with a request to complete KYC (rather than to
  /// subscribe).
  bool kycLimited(AppUser user) => metered(user) && !_kycDone(user);

  int _limit(AppUser user) => kycLimited(user) ? kycPreviewSeconds : freeSecondsPerDay;

  int freeSecondsLeft(AppUser user) =>
      !metered(user) ? freeSecondsPerDay : (_limit(user) - (_freeUsed[_dayKey(user)] ?? 0)).clamp(0, _limit(user));

  /// Whether metered viewing has run out for now.
  bool outOfFree(AppUser user) => metered(user) && freeSecondsLeft(user) <= 0;

  /// Called once a second while free media plays. Returns false when the free
  /// preview is used up and playback must stop.
  bool tickFreeViewing(AppUser user) {
    if (!metered(user)) return true;
    final key = _dayKey(user);
    final used = (_freeUsed[key] ?? 0) + 1;
    _freeUsed[key] = used;
    // The server keeps the real count; a heartbeat syncs it now and then.
    if (user.role == UserRole.seeker) {
      final since = (_sinceHeartbeat[user.email] ?? 0) + 1;
      _sinceHeartbeat[user.email] = since % _heartbeatSeconds;
      if (since >= _heartbeatSeconds) _heartbeat(user);
    }
    notifyListeners();
    return used < _limit(user);
  }

  /// Opening it on the server loads the details and counts the view there.
  void recordView(AppUser user, ContentItem item) {
    if (item.remote) unawaited(open(user, item));
  }

  // ---- Solver's own content ---------------------------------------------------------

  /// Content formats solvers choose from when creating, loaded from the API.
  static final formats = <String>[];

  /// Whose content this is: the solver's public profile id, or their email
  /// before they have a profile.
  static String ownerId(AppUser user) => SolverService.instance.profileFor(user)?.id ?? user.email;

  /// Everything the solver made, drafts included, newest first. Solvers see
  /// only their own content.
  List<ContentItem> mine(AppUser user) {
    final id = ownerId(user);
    return _all.where((i) => i.solverId == id).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// The server's publish gate, once checked: `SOLVER_NOT_VERIFIED`,
  /// `SOLVER_KYC_INCOMPLETE`, or null when the solver can publish.
  ({bool allowed, String? code})? _eligibility;

  /// Publishing needs Skill Verification and full KYC. The server's verdict
  /// once it's loaded; until then, the verification states on the device.
  bool canPublish(AppUser user) =>
      !kEnforceVerification ||
      (_eligibility?.allowed ??
          (KycService.instance.stateFor(user).completed &&
              SkillVerificationService.instance.verifiedSkills(user).isNotEmpty));

  /// Why the solver can't publish yet, in words.
  String publishBlockedReason(AppUser user) => switch (_eligibility?.code) {
    'SOLVER_NOT_VERIFIED' => 'Complete Skill Verification to publish. You can save it as a draft for now.',
    'SOLVER_KYC_INCOMPLETE' => 'Complete KYC verification to publish. You can save it as a draft for now.',
    _ => 'Complete KYC and Skill Verification to publish. You can save it as a draft for now.',
  };

  /// Asks the server whether the solver can publish (on opening the form and
  /// before publishing). Keeps the last answer if it can't be reached.
  Future<void> loadPublishEligibility(AppUser user) async {
    if (user.role != UserRole.solver) return;
    try {
      final d = await ContentApi.publishEligibility();
      final code = d['error_code'];
      _eligibility = (allowed: d['can_publish'] == true, code: code is String && code.isNotEmpty ? code : null);
      notifyListeners();
    } on AuthException {
      // The device's view stands in.
    }
  }

  Future<void> _requirePublish(AppUser user) async {
    await loadPublishEligibility(user);
    if (!canPublish(user)) throw AuthException(publishBlockedReason(user));
  }

  /// Adds a new item. Published immediately, or kept as a draft.
  void add(ContentItem item) {
    _all.add(item);
    notifyListeners();
  }

  // ---- The solver's own content (API) --------------------------------------------------

  /// The formats the API accepts, by label.
  /// The only format the server lets videos and reels be Premium in.
  static const premiumFormat = '3D animation';

  static const _formats = {
    'Practical demo': 'practical_demo',
    '2D animation': '2d_animation',
    premiumFormat: '3d_animation',
    'Slide-based': 'slide_based',
  };

  static const _apiTypes = {
    ContentType.reel: 'reel',
    ContentType.video: 'video',
    ContentType.blog: 'blog',
    ContentType.image: 'image',
    ContentType.repo: 'github_repo',
    ContentType.podcast: 'podcast',
  };

  /// Loads the solver's own content, drafts included.
  Future<void> loadMine(AppUser user) async {
    if (user.role != UserRole.solver) return;
    setReferenceData(formats: _formats.keys.toList());
    if (categories.isEmpty) {
      setReferenceData(categories: await ContentApi.categories().catchError((Object _) => <String, List<String>>{}));
    }
    final list = await ContentApi.mine();
    final known = {for (final i in _all) i.id: i};
    final ids = {for (final c in list) '${c['id']}'};
    _all
      ..removeWhere((i) => ids.contains(i.id))
      ..addAll([for (final c in list) _mineFrom(user, c, known[c['id']])]);
    _linksLoadedAt = DateTime.now();
    notifyListeners();
  }

  /// One of the solver's items, owned by them so it shows under [mine].
  ContentItem _mineFrom(AppUser user, Map<String, dynamic> c, ContentItem? known) {
    final base = _itemFrom({...c, 'solver_id': ownerId(user), 'solver_name': user.name}, known);
    final format = _formats.entries.where((e) => e.value == c['format']).firstOrNull?.key;
    return ContentItem(
        id: base.id,
        type: _apiTypes.entries.where((e) => e.value == c['content_type']).firstOrNull?.key ?? base.type,
        title: base.title,
        description: known?.description ?? (c['description'] as String? ?? base.description),
        category: base.category,
        subcategory: base.subcategory,
        tags: base.tags,
        solverId: ownerId(user),
        solverName: user.name,
        createdAt: base.createdAt,
        views: base.views,
        premium: base.premium,
        durationSeconds: base.durationSeconds,
        youtubeId: base.youtubeId,
        imageUrl: base.imageUrl,
        format: format ?? base.format,
        body: known?.body ?? const [],
        html: known?.html ?? false,
        repoUrl: base.repoUrl ?? known?.repoUrl,
        mediaFileName: c['has_media'] == true ? (known?.mediaFileName ?? 'Uploaded file') : known?.mediaFileName,
        coverPath: known?.coverPath,
        draft: c['status'] != 'published',
        remote: true,
      )
      ..mediaUrl = base.mediaUrl
      ..autoRecorded = c['source_recording_id'] is String
      ..draftExpiresAt = DateTime.tryParse('${c['draft_expires_at'] ?? ''}')?.toLocal()
      ..appreciatedBy.addAll(base.appreciatedBy);
  }

  /// Creates a solver's content item from the create form. It's created on
  /// the server as a draft, its cover and file are uploaded, and then it's
  /// published if asked. [uploadPath] is the media file to upload.
  Future<ContentItem> create(
    AppUser user, {
    required ContentType type,
    required String title,
    required String description,
    required String category,
    required String subcategory,
    required String format,
    required List<String> tags,
    required bool premium,
    required bool publish,
    String? coverPath,
    String? mediaPath,
    String? mediaFileName,
    String? repoUrl,
    String? htmlBody,
    String? uploadPath,
  }) async {
    if (user.role != UserRole.solver) throw const AuthException('Only solvers can create content.');
    if (publish) await _requirePublish(user);
    final created = await ContentApi.create({
      'content_type': _apiTypes[type],
      'format': _formats[format] ?? 'practical_demo',
      'title': title.trim(),
      if (description.trim().isNotEmpty) 'description': description.trim(),
      'category': category,
      'sub_category': subcategory,
      if (tags.isNotEmpty) 'tags': [for (final t in tags.take(10)) t],
      'is_premium': premium,
      'content_url': ?repoUrl,
      'body': ?htmlBody,
    });
    final id = created['id'] as String?;
    if (id == null) throw const AuthException('The content couldn\'t be created. Please try again.');
    try {
      if (coverPath != null) {
        await ContentApi.upload(id, 'thumbnail', path: coverPath, fileName: coverPath.split(RegExp(r'[/\\]')).last);
      }
      final media = uploadPath ?? mediaPath;
      if (media != null) {
        await ContentApi.upload(
          id,
          'media',
          path: media,
          fileName: mediaFileName ?? media.split(RegExp(r'[/\\]')).last,
        );
      }
    } on AuthException {
      // A draft without its file is removed again.
      await ContentApi.rollback(id).catchError((Object _) {});
      rethrow;
    }
    var data = created;
    String? publishError;
    if (publish) {
      try {
        data = await ContentApi.publish(id);
      } on AuthException catch (e) {
        publishError = e.message;
      }
    }
    final item = _mineFrom(user, {...data, 'has_media': uploadPath != null || mediaPath != null}, null)
      ..body = htmlBody == null ? const [] : [htmlBody]
      ..html = htmlBody != null
      ..description = description.trim()
      ..coverPath = coverPath
      ..mediaPath = mediaPath
      ..mediaFileName = mediaFileName;
    add(item);
    // The uploaded cover's link comes with the solver's content list.
    if (coverPath != null) unawaited(loadMine(user).catchError((Object _) {}));
    // Saved as a draft, but the server didn't allow publishing yet.
    if (publishError != null) throw AuthException('Saved as a draft. $publishError');
    return item;
  }

  /// Saves edits from the form: only what changed is sent, a new cover or file
  /// is uploaded, and then it's published or moved to drafts if that changed. The format and a podcast's recording can't
  /// change once it's created.
  Future<void> update(
    AppUser user,
    ContentItem item, {
    required String title,
    required String description,
    required String category,
    required String subcategory,
    required String format,
    required List<String> tags,
    required bool premium,
    required bool publish,
    String? coverPath,
    String? mediaPath,
    String? mediaFileName,
    String? repoUrl,
    String? htmlBody,
  }) async {
    _requireRemote(item);
    if (publish && item.draft) await _requirePublish(user);
    if (format != item.format) throw const AuthException('The format can\'t be changed once the content is created.');
    final pairChanged = category != item.category || subcategory != item.subcategory;
    final fields = <String, dynamic>{
      if (title.trim() != item.title) 'title': title.trim(),
      // The form edits the description only for some types; blank means untouched.
      if (description.trim().isNotEmpty && description.trim() != item.description) 'description': description.trim(),
      if (pairChanged) ...{'category': category, 'sub_category': subcategory},
      // Tags are replaced as a whole.
      if (!listEquals(tags, item.tags)) 'tags': [for (final t in tags.take(10)) t],
      if (premium != item.premium) 'is_premium': premium,
      if (repoUrl != null && repoUrl != item.repoUrl) 'content_url': repoUrl,
      if (htmlBody != null && htmlBody != item.body.firstOrNull) 'body': htmlBody,
    };
    if (fields.isNotEmpty) await ContentApi.update(item.id, fields);
    if (coverPath != null) {
      await ContentApi.upload(item.id, 'thumbnail', path: coverPath, fileName: coverPath.split(RegExp(r'[/\\]')).last);
    }
    if (mediaPath != null && item.type != ContentType.podcast) {
      await ContentApi.upload(
        item.id,
        'media',
        path: mediaPath,
        fileName: mediaFileName ?? mediaPath.split(RegExp(r'[/\\]')).last,
      );
    }
    item
      ..title = title.trim()
      ..category = category
      ..subcategory = subcategory
      ..tags = [for (final t in tags.take(10)) t]
      ..premium = premium;
    if (fields.containsKey('description')) item.description = description.trim();
    if (fields.containsKey('content_url')) item.repoUrl = repoUrl;
    if (fields.containsKey('body')) {
      item
        ..body = [htmlBody!]
        ..html = true;
    }
    if (coverPath != null) item.coverPath = coverPath;
    if (mediaPath != null) {
      item
        ..mediaPath = mediaPath
        ..mediaFileName = mediaFileName;
    }
    notifyListeners();
    if (publish && item.draft) {
      await this.publish(user, item);
    } else if (!publish && !item.draft) {
      await unpublish(item);
    }
    // Fresh links for a new cover or file.
    if (coverPath != null || mediaPath != null) unawaited(loadMine(user).catchError((Object _) {}));
  }

  /// Only content saved on the server can be edited or published.
  static void _requireRemote(ContentItem item) {
    if (!item.remote) throw const AuthException('This content isn\'t saved on the server yet. Please try again later.');
  }

  Future<void> publish(AppUser user, ContentItem item) async {
    await _requirePublish(user);
    _requireRemote(item);
    await ContentApi.publish(item.id);
    item.draft = false;
    notifyListeners();
  }

  /// Hides it from seekers again; it goes back to Drafts.
  Future<void> unpublish(ContentItem item) async {
    _requireRemote(item);
    await ContentApi.unpublish(item.id);
    item.draft = true;
    notifyListeners();
  }

  Future<void> delete(ContentItem item) async {
    if (item.remote) await ContentApi.delete(item.id);
    _all.remove(item);
    for (final folders in _folders.values) {
      for (final ids in folders.values) {
        ids.remove(item.id);
      }
    }
    notifyListeners();
  }

  /// How many people saved the item to a folder.
  int savesOf(ContentItem item) => _folders.values.where((f) => f.values.any((ids) => ids.contains(item.id))).length;

  // ---- Engagement -------------------------------------------------------------------

  String _identity(AppUser user) => user.profile.pseudoName ?? user.name;

  bool appreciated(AppUser user, ContentItem item) => item.appreciatedBy.contains(_meKey);

  /// Switches at once and saves; switches back if the save fails.
  void toggleAppreciate(AppUser user, ContentItem item) {
    if (!item.remote) return;
    void flip() {
      if (!item.appreciatedBy.remove(_meKey)) item.appreciatedBy.add(_meKey);
      notifyListeners();
    }

    flip();
    ContentApi.toggleLike(item.id).then<void>((_) {}, onError: (Object _) => flip());
  }

  void comment(AppUser user, ContentItem item, String text) {
    if (!item.remote) return;
    final added = ContentComment(_identity(user), text.trim(), DateTime.now());
    item.comments.add(added);
    notifyListeners();
    ContentApi.addComment(item.id, text).catchError((Object _) {
      item.comments.remove(added);
      notifyListeners();
    });
  }

  // ---- Saved items ------------------------------------------------------------------

  static const defaultFolder = 'Saved';

  Map<String, Set<String>> folders(AppUser user) => _folders.putIfAbsent(user.email, () => {defaultFolder: {}});

  bool isSaved(AppUser user, ContentItem item) => folders(user).values.any((f) => f.contains(item.id));

  void createFolder(AppUser user, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const AuthException('Give the folder a name.');
    if (folders(user).containsKey(trimmed)) throw const AuthException('You already have a folder with that name.');
    folders(user)[trimmed] = {};
    if (user.role == UserRole.seeker) {
      _folderCreations[trimmed] = ContentApi.createFolder(trimmed).then((f) {
        final id = f['id'] as String?;
        if (id != null) _folderIds[trimmed] = id;
        return id;
      }, onError: (Object _) => null);
    }
    notifyListeners();
  }

  /// Switches at once and saves; switches back if the save fails.
  void setSaved(AppUser user, ContentItem item, String folder, bool saved) {
    final set = folders(user).putIfAbsent(folder, () => {});
    saved ? set.add(item.id) : set.remove(item.id);
    notifyListeners();
    if (!item.remote || user.role != UserRole.seeker) return;
    Future<void> save() async {
      final folderId = folder == defaultFolder ? null : _folderIds[folder] ?? await _folderCreations[folder];
      if (folder != defaultFolder && folderId == null) throw const AuthException('Folder not found.');
      await ContentApi.setSaved(item.id, folderId, saved: saved);
    }

    save().catchError((Object _) {
      saved ? set.remove(item.id) : set.add(item.id);
      notifyListeners();
    });
  }

  /// Folders can't be deleted on the server yet; this hides it here.
  void deleteFolder(AppUser user, String folder) {
    if (folder == defaultFolder) return;
    folders(user).remove(folder);
    notifyListeners();
  }

  Future<void> _heartbeat(AppUser user) async {
    try {
      _applyPreview(user, await ContentApi.consumePreview());
    } on ApiException catch (e) {
      // 402: today's free preview is used up; 403: KYC is needed to go on.
      if (!previewDenied(user, e) && e.statusCode == 402) _freeUsed[_dayKey(user)] = freeSecondsPerDay;
    } on AuthException {
      return;
    }
    notifyListeners();
  }

  String _dayKey(AppUser user) {
    final now = DateTime.now();
    return '${user.email}|${now.year}-${now.month}-${now.day}';
  }
}
