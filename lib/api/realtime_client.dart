import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// The realtime socket (Postman: Shared > Ws, GET /ws): live chat, typing,
/// session timer and extension/meeting events. After connecting the server
/// sends an AES-256 key; every later frame both ways is
/// base64(nonce ‖ AES-256-GCM ciphertext) of a JSON object.
class RealtimeClient {
  RealtimeClient._();

  static final RealtimeClient instance = RealtimeClient._();

  static final _cipher = AesGcm.with256bits();

  /// Every decrypted event from the server, e.g. `{type: 'chat.message', …}`.
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  WebSocket? _socket;
  SecretKey? _key;
  Timer? _heartbeat;
  Timer? _retry;
  Future<void>? _connecting;
  int _users = 0;

  bool get connected => _socket != null && _key != null;

  /// Keeps the socket open while at least one screen uses it.
  Future<void> acquire() {
    _users++;
    return _connect();
  }

  /// Closes the socket once no screen uses it any more.
  void release() {
    _users = max(0, _users - 1);
    if (_users == 0) _close();
  }

  Uri get _url {
    final base = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.apiPath}/ws');
    return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws');
  }

  Future<void> _connect() => _connecting ??= () async {
    try {
      if (connected) return;
      await ApiClient.instance.ensureFreshToken();
      final socket = await WebSocket.connect(
        _url.toString(),
        headers: ApiClient.instance.socketHeaders,
      ).timeout(ApiConfig.connectTimeout);
      _socket = socket;
      socket.listen(_onFrame, onDone: _onClosed, onError: (Object _) => _onClosed(), cancelOnError: true);
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => sendJson({'type': 'heartbeat'}));
    } catch (e) {
      if (kDebugMode) debugPrint('Realtime: connect failed ($e)');
      _scheduleRetry();
    } finally {
      _connecting = null;
    }
  }();

  Future<void> _onFrame(dynamic frame) async {
    if (frame is! String) return;
    try {
      if (_key == null) {
        // The first frame is plaintext: the key, or an error before closing.
        final first = jsonDecode(frame);
        if (first is Map && first['type'] == 'encryption_key' && first['key'] is String) {
          _key = SecretKey(base64Decode(first['key'] as String));
        }
        return;
      }
      final bytes = base64Decode(frame);
      final clear = await _cipher.decrypt(
        SecretBox(
          bytes.sublist(12, bytes.length - 16),
          nonce: bytes.sublist(0, 12),
          mac: Mac(bytes.sublist(bytes.length - 16)),
        ),
        secretKey: _key!,
      );
      final event = jsonDecode(utf8.decode(clear));
      if (event is Map) _events.add(Map<String, dynamic>.from(event));
    } catch (e) {
      if (kDebugMode) debugPrint('Realtime: dropped a frame ($e)');
    }
  }

  /// Sends an encrypted message, e.g. `{type: 'chat.typing', session_id: …}`.
  Future<void> sendJson(Map<String, dynamic> message) async {
    final socket = _socket;
    final key = _key;
    if (socket == null || key == null) return;
    final box = await _cipher.encrypt(utf8.encode(jsonEncode(message)), secretKey: key);
    socket.add(base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]));
  }

  void _onClosed() {
    _heartbeat?.cancel();
    _socket = null;
    _key = null;
    if (_users > 0) _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_users == 0) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), _connect);
  }

  void _close() {
    _retry?.cancel();
    _heartbeat?.cancel();
    _socket?.close();
    _socket = null;
    _key = null;
  }
}
