import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/auth_service.dart' show AuthException;
import 'session_store.dart';

/// Build-time API settings. Override per environment with
/// `--dart-define=API_BASE_URL=https://…`.
abstract final class ApiConfig {
  static const baseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://213.199.40.111:8081');
  static const apiPath = '/api/v1';

  /// The API requires a reCAPTCHA token on login and register. It's only
  /// checked when the server has a reCAPTCHA secret configured; until mobile
  /// reCAPTCHA is set up this placeholder is sent.
  static const recaptchaToken = String.fromEnvironment('RECAPTCHA_TOKEN', defaultValue: 'mobile-app');

  /// The realtime socket only accepts browser origins on the server's allow
  /// list, so the app presents one. Set per environment with
  /// `--dart-define=WS_ORIGIN=...` once the backend allows the app directly.
  static const wsOrigin = String.fromEnvironment('WS_ORIGIN', defaultValue: 'http://213.199.40.111:5173');

  static const connectTimeout = Duration(seconds: 15);
  static const receiveTimeout = Duration(seconds: 30);
  static const sendTimeout = Duration(seconds: 60);
}

/// Every API failure, with the server's message ready to show. It extends
/// [AuthException], so screens that already show those keep working.
class ApiException extends AuthException {
  const ApiException(super.message, {this.statusCode, this.requestId, this.cancelled = false, this.code});

  final int? statusCode;

  /// The server's error_code, e.g. KYC_REQUIRED.
  final String? code;
  final String? requestId;
  final bool cancelled;
}

/// A file to upload in a multipart request.
class UploadFile {
  const UploadFile({required this.field, required this.path, this.fileName, this.contentType});

  final String field;
  final String path;
  final String? fileName;

  /// Sent as the part's type when the API checks it, e.g. `video/mp4`.
  final String? contentType;
}

/// The one shared HTTP client. Every request in the app goes through here,
/// so headers, the session, CSRF protection, token refresh, timeouts and error
/// handling are defined once.
class ApiClient {
  ApiClient._() {
    final options = BaseOptions(
      baseUrl: '${ApiConfig.baseUrl}${ApiConfig.apiPath}',
      connectTimeout: ApiConfig.connectTimeout,
      receiveTimeout: ApiConfig.receiveTimeout,
      sendTimeout: ApiConfig.sendTimeout,
      responseType: ResponseType.json,
      headers: {'Accept': 'application/json'},
    );
    final session = InterceptorsWrapper(onRequest: _onRequest, onResponse: _onResponse, onError: _onErrorCapture);
    _dio = Dio(options)..interceptors.addAll([session, QueuedInterceptorsWrapper(onError: _onAuthError)]);
    // Same headers and session handling, without the 401 handler: used to
    // refresh, retry and fetch the CSRF cookie from inside an interceptor
    // without queueing behind it.
    _plain = Dio(options)..interceptors.add(session);
  }

  static final ApiClient instance = ApiClient._();

  late final Dio _dio;
  late final Dio _plain;
  final _session = SessionStore.instance;
  final _random = Random.secure();

  /// Bumped when the session can't be renewed; the app returns to sign-in.
  final sessionExpired = ValueNotifier<int>(0);

  /// The admin's message when a request was refused because the app is under
  /// maintenance (HTTP 503, MAINTENANCE_MODE).
  final maintenanceNotice = ValueNotifier<String?>(null);

  // The API validates these: platform must be ios|android|web, the version
  // major.minor.patch and the timezone an IANA name, or it rejects the request.
  String? _platform;
  String _appVersion = '1.0.0';
  String _timezone = 'UTC';

  /// The phone app (ios|android) signs in with tokens, not cookies: the API
  /// returns them in the body, accepts them as a Bearer header and the
  /// refresh token in the body, and needs no CSRF token.
  bool get _native => _platform != null;

  /// Sessions are bound to the client, so this must stay the same across
  /// launches and app updates.
  String get _userAgent => 'SynapMentor-App (${_platform ?? Platform.operatingSystem})';

  /// The identity sessions are tied to; the GitHub sign-in page uses it too.
  String get userAgent => _userAgent;

  /// The same identity as every request (the server ties sessions to it)
  /// plus the current session token.
  Map<String, String> get _identityHeaders => {
    'X-App-Platform': ?_platform,
    'X-App-Version': _appVersion,
    'X-Timezone': _timezone,
    'User-Agent': _userAgent,
    if (_session.accessToken != null) 'Authorization': 'Bearer ${_session.accessToken}',
  };

  /// Headers for the realtime socket.
  Map<String, String> get socketHeaders => {..._identityHeaders, 'Origin': ApiConfig.wsOrigin};

  /// Headers for loading a picture from [url]. The API's own links (proxied
  /// files) need the app's identity and session like any request, or the
  /// server refuses them; other hosts (some throttle requests without a
  /// descriptive agent) get just that.
  Map<String, String> imageHeaders(String url) =>
      url.startsWith(ApiConfig.baseUrl) ? _identityHeaders : const {'User-Agent': 'SynapMentor/1.0 (Flutter app)'};

  /// Renews the session token if it has expired; true when there's a valid
  /// one afterwards. Used before opening the realtime socket.
  Future<bool> ensureFreshToken() async {
    try {
      await _dio.get<dynamic>('/auth/ws-token');
      return _session.accessToken != null;
    } on DioException catch (e) {
      // Auth paths aren't renewed automatically; renew here once.
      return e.response?.statusCode == 401 && await _refresh();
    }
  }

  /// Reads the device details sent with every request. Call once at startup.
  Future<void> init() async {
    if (!kReleaseMode && !ApiConfig.baseUrl.startsWith('https://')) {
      debugPrint('ApiClient: the API is not on HTTPS (${ApiConfig.baseUrl}). Use HTTPS in production.');
    }
    _platform = Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : null);
    try {
      // "1.2.3+4" or "1.2.3-beta" -> "1.2.3"; anything else keeps the default.
      final version = RegExp(r'^\d+\.\d+\.\d+').stringMatch((await PackageInfo.fromPlatform()).version);
      if (version != null) _appVersion = version;
    } catch (_) {}
    try {
      final zone = (await FlutterTimezone.getLocalTimezone()).identifier;
      // Only IANA names ("Asia/Kolkata", "UTC"); never abbreviations like "IST".
      if (zone == 'UTC' || RegExp(r'^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$').hasMatch(zone)) _timezone = zone;
    } catch (_) {
      debugPrint('ApiClient: device timezone unavailable, sending UTC');
    }
  }

  // ---- Requests -------------------------------------------------------------------

  Future<dynamic> get(String path, {Map<String, dynamic>? query, CancelToken? cancelToken}) =>
      _send(() => _dio.get<dynamic>(path, queryParameters: query, cancelToken: cancelToken));

  /// A profile picture link the app can load: web links as they are, the
  /// API's own paths on the API server, and stored `profiles/…` keys through
  /// the signed-in file proxy. Anything else gives null.
  static String? photoLink(Object? value) {
    final v = value is String ? value.trim() : '';
    if (v.startsWith('http://') || v.startsWith('https://')) return v;
    if (v.startsWith('/')) return '${ApiConfig.baseUrl}$v';
    if (v.startsWith('profiles/')) {
      return '${ApiConfig.baseUrl}${ApiConfig.apiPath}/files/secure?key=${Uri.encodeQueryComponent(v)}';
    }
    return null;
  }

  /// Whether [url] is on the API server (and needs the session to load).
  static bool isApiLink(String url) => Uri.tryParse(url)?.origin == Uri.parse(ApiConfig.baseUrl).origin;

  /// Downloads a protected file (avatar, ticket attachment). Accepts the
  /// API's own links, e.g. `/api/v1/files/secure?key=…`.
  Future<Uint8List> download(String path) async {
    final uri = Uri.parse(path);
    final ours = !uri.hasScheme || uri.origin == Uri.parse(ApiConfig.baseUrl).origin;
    final local = ours ? (uri.hasScheme ? uri.toString().substring(uri.origin.length) : path) : path;
    final relative = local.startsWith(ApiConfig.apiPath) ? local.substring(ApiConfig.apiPath.length) : local;
    try {
      // Links to other hosts (public storage) never get the session headers.
      final response = ours
          ? await _dio.get<List<int>>(relative, options: Options(responseType: ResponseType.bytes))
          : await Dio().get<List<int>>(path, options: Options(responseType: ResponseType.bytes));
      return Uint8List.fromList(response.data ?? const []);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  Future<dynamic> post(
    String path, {
    Object? data,
    Map<String, dynamic>? query,
    bool idempotent = false,
    Map<String, dynamic>? extra,
  }) => _send(() => _dio.post<dynamic>(path, data: data, queryParameters: query, options: _write(idempotent, extra)));

  /// A GET that stops at a redirect instead of following it, for the GitHub
  /// sign-in hand-offs where the Location and cookies are the answer. Session
  /// cookies it receives are saved like any others. [cookie] adds one, e.g.
  /// the sign-in nonce.
  Future<Response<dynamic>> getRedirect(String path, {Map<String, dynamic>? query, String? cookie}) async {
    try {
      return await _dio.get<dynamic>(
        path,
        queryParameters: query,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
          extra: {'cookie': ?cookie},
        ),
      );
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  /// The value of the cookie [name] a response sets, if it does.
  static String? cookieIn(Response<dynamic> response, String name) {
    for (final header in response.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
      final pair = header.split(';').first;
      final eq = pair.indexOf('=');
      if (eq > 0 && pair.substring(0, eq).trim() == name) return pair.substring(eq + 1).trim();
    }
    return null;
  }

  Future<dynamic> put(String path, {Object? data}) =>
      _send(() => _dio.put<dynamic>(path, data: data, options: _write(false)));

  Future<dynamic> patch(String path, {Object? data}) =>
      _send(() => _dio.patch<dynamic>(path, data: data, options: _write(false)));

  Future<dynamic> delete(String path, {Object? data}) =>
      _send(() => _dio.delete<dynamic>(path, data: data, options: _write(false)));

  /// Multipart upload with progress, cancellable.
  Future<dynamic> upload(
    String path, {
    required List<UploadFile> files,
    Map<String, String> fields = const {},
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final form = FormData.fromMap(fields);
    for (final f in files) {
      form.files.add(
        MapEntry(
          f.field,
          await MultipartFile.fromFile(
            f.path,
            filename: f.fileName,
            contentType: f.contentType == null ? null : DioMediaType.parse(f.contentType!),
          ),
        ),
      );
    }
    return _send(
      () => _dio.post<dynamic>(
        path,
        data: form,
        options: _write(false),
        onSendProgress: onProgress,
        cancelToken: cancelToken,
      ),
    );
  }

  /// Writes that must never run twice (payments, bookings, withdrawals) carry
  /// an idempotency key, so a retry or double tap is safe.
  Options _write(bool idempotent, [Map<String, dynamic>? extra]) => Options(
    contentType: Headers.jsonContentType,
    headers: {if (idempotent) 'X-Idempotency-Key': _randomHex(16)},
    extra: extra,
  );

  /// Runs a request and unwraps the API envelope `{success, data, meta}`.
  Future<dynamic> _send(Future<Response<dynamic>> Function() request) async {
    try {
      final body = (await request()).data;
      if (body is Map && body['success'] == false) {
        throw ApiException(_messageOf(body) ?? 'Something went wrong. Please try again.');
      }
      return body is Map && body.containsKey('data') ? body['data'] : body;
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  // ---- Interceptors ---------------------------------------------------------------

  Future<void> _onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    final write = !const {'GET', 'HEAD', 'OPTIONS'}.contains(options.method);
    if (write && !_native && _session.csrfToken == null && !options.path.startsWith('/auth/oauth/providers')) {
      await _seedCsrf();
    }

    options.headers.addAll({
      if (_platform != null) 'X-App-Platform': _platform,
      'X-App-Version': _appVersion,
      'X-Timezone': _timezone,
      'User-Agent': _userAgent,
      'Accept-Language': Platform.localeName.split('.').first.replaceAll('_', '-'),
      'X-Request-Id': _randomHex(16),
    });

    // The phone app sends its session only as a Bearer token (refresh and
    // logout carry the refresh token in the body). Elsewhere it goes back as
    // the cookies the server set; the refresh token only to the auth
    // endpoints, like its cookie path.
    final cookies = <String>[
      if (!_native && _session.accessToken != null) 'access_token=${_session.accessToken}',
      if (!_native && _session.refreshToken != null && options.path.startsWith('/auth/'))
        'refresh_token=${_session.refreshToken}',
      if (_session.csrfToken != null) 'csrf_token=${_session.csrfToken}',
      // A one-off cookie from outside the client, e.g. a pending GitHub signup.
      if (options.extra['cookie'] is String) options.extra['cookie'] as String,
    ];
    options.headers.remove('Cookie');
    options.headers.remove('Authorization');
    if (cookies.isNotEmpty) options.headers['Cookie'] = cookies.join('; ');
    if (_session.accessToken != null) options.headers['Authorization'] = 'Bearer ${_session.accessToken}';
    if (write && _session.csrfToken != null) options.headers['X-CSRF-Token'] = _session.csrfToken;
    options.extra['sentAccessToken'] = _session.accessToken;

    if (kDebugMode) debugPrint('→ ${options.method} ${options.path}');
    handler.next(options);
  }

  Future<void> _onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) async {
    await _capture(response);
    if (kDebugMode) debugPrint('← ${response.statusCode} ${response.requestOptions.path}');
    handler.next(response);
  }

  Future<void> _onErrorCapture(DioException error, ErrorInterceptorHandler handler) async {
    final response = error.response;
    if (response != null) await _capture(response);
    final body = response?.data;
    if (response?.statusCode == 503 && body is Map && body['code'] == 'MAINTENANCE_MODE') {
      final data = body['data'];
      final message = data is Map ? data['message'] : body['error'];
      maintenanceNotice.value = message is String && message.trim().isNotEmpty ? message.trim() : '';
    }
    if (kDebugMode) debugPrint('✕ ${response?.statusCode ?? error.type.name} ${error.requestOptions.path}');
    handler.next(error);
  }

  /// On 401, renews the session once (concurrent requests wait for it) and
  /// retries. If it can't be renewed, the user is signed out.
  Future<void> _onAuthError(DioException error, ErrorInterceptorHandler handler) async {
    final options = error.requestOptions;
    final unauthorized = error.response?.statusCode == 401;
    if (!unauthorized || options.path.startsWith('/auth/') || options.extra['retried'] == true) {
      return handler.next(error);
    }
    if (!_session.hasSession) return handler.next(error);

    // Another request may have renewed the session while this one waited.
    final renewed = _session.accessToken != null && _session.accessToken != options.extra['sentAccessToken'];
    if (renewed || await _refresh()) {
      try {
        options.extra['retried'] = true;
        return handler.resolve(await _plain.fetch<dynamic>(options));
      } on DioException catch (e) {
        return handler.next(e);
      }
    }
    await _session.clear();
    sessionExpired.value++;
    handler.next(error);
  }

  Future<bool> _refresh() async {
    try {
      await _plain.post<dynamic>(
        '/auth/refresh',
        data: {if (_session.refreshToken != null) 'refresh_token': _session.refreshToken},
        options: Options(contentType: Headers.jsonContentType),
      );
      return _session.accessToken != null;
    } catch (_) {
      return false;
    }
  }

  /// The API issues a CSRF cookie on any GET; writes must echo it back.
  Future<void> _seedCsrf() async {
    try {
      await _plain.get<dynamic>('/auth/oauth/providers');
    } catch (_) {}
  }

  /// Saves the session cookies the server sets, and the tokens in the body
  /// (the phone app always gets them there).
  Future<void> _capture(Response<dynamic> response) async {
    for (final header in response.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
      final pair = header.split(';').first;
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      final expired = value.isEmpty || RegExp(r'max-age=-|max-age=0\b', caseSensitive: false).hasMatch(header);
      switch (name) {
        case 'access_token':
          await _session.setAccessToken(expired ? null : value);
        case 'refresh_token':
          await _session.setRefreshToken(expired ? null : value);
        case 'csrf_token':
          await _session.setCsrfToken(expired ? null : value);
      }
    }
    final body = response.data;
    final data = body is Map ? body['data'] : null;
    if (data is Map) {
      if (data['access_token'] is String && (data['access_token'] as String).isNotEmpty) {
        await _session.setAccessToken(data['access_token'] as String);
      }
      if (data['refresh_token'] is String && (data['refresh_token'] as String).isNotEmpty) {
        await _session.setRefreshToken(data['refresh_token'] as String);
      }
    }
  }

  // ---- Errors ---------------------------------------------------------------------

  ApiException _toApiException(DioException e) {
    final response = e.response;
    final body = response?.data;
    final requestId = body is Map && body['meta'] is Map ? (body['meta'] as Map)['request_id']?.toString() : null;
    final status = response?.statusCode;
    final code = body is Map ? body['error_code']?.toString() : null;
    // Content past the free preview needs KYC; said the way the app says it.
    final serverMessage = code == 'KYC_REQUIRED'
        ? 'Complete KYC verification to continue.'
        : (body is Map ? _messageOf(body) : null);
    final message = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => 'The server is taking too long to respond. Please try again.',
      DioExceptionType.connectionError => 'Can\'t reach the server. Check your internet connection and try again.',
      DioExceptionType.cancel => 'Cancelled.',
      DioExceptionType.badCertificate => 'The connection isn\'t secure. Please try again later.',
      _ => switch (status) {
        413 => 'That\'s too large to upload.',
        429 => serverMessage ?? 'Too many requests. Please wait a moment and try again.',
        final s? when s >= 500 => 'Something went wrong on our side. Please try again in a moment.',
        _ => serverMessage ?? 'Something went wrong. Please try again.',
      },
    };
    return ApiException(
      message,
      statusCode: status,
      requestId: requestId,
      cancelled: e.type == DioExceptionType.cancel,
      code: code,
    );
  }

  static String? _messageOf(Map<dynamic, dynamic> body) {
    final error = body['error'];
    if (error is String && error.isNotEmpty) return error;
    if (error is Map && error['message'] is String) return error['message'] as String;
    final message = body['message'];
    return message is String && message.isNotEmpty ? message : null;
  }

  String _randomHex(int bytes) =>
      List.generate(bytes, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
