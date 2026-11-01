import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../api/notifications_api.dart';
import '../firebase_options.dart';
import 'auth_service.dart';
import 'notification_service.dart';

/// Firebase for the app: the mobile number check in KYC, and push
/// notifications from the server that arrive even while the app is closed.
/// The server sends them with a title and body, so the system shows them
/// itself; while the app is open the in-app banner shows them instead.
/// Without a Firebase project set up, all of this stays off and notifications
/// stay in the app.
class PushNotifications {
  PushNotifications._();

  static final PushNotifications instance = PushNotifications._();

  bool _ready = false;

  /// The token the server has for the signed-in user on this device.
  String? _token;
  AppUser? _user;
  StreamSubscription<String>? _refresh;

  /// Whether the server pushes to this device, so the app doesn't show the
  /// same update a second time while it's in the background.
  bool get active => _token != null;

  /// Set when a push notification is tapped; the signed-in screens open what
  /// it's about and clear it.
  final openRequested = ValueNotifier<PushTarget?>(null);

  Future<void> init() async {
    try {
      try {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      } on UnsupportedError {
        // No settings in firebase_options.dart for this platform (iOS so
        // far): GoogleService-Info.plist, once it's added.
        await Firebase.initializeApp();
      }
      _ready = true;
    } catch (_) {
      // Firebase isn't set up; notifications stay in the app.
      return;
    }
    try {
      // While the app is open the system doesn't show pushes; the in-app list
      // reloads and its banner shows the new one.
      FirebaseMessaging.onMessage.listen((_) => NotificationService.instance.refreshFromPush());
      FirebaseMessaging.onMessageOpenedApp.listen((m) => openRequested.value = PushTarget.of(m.data));
      // Opened from a notification while the app was closed.
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) openRequested.value = PushTarget.of(initial.data);
    } catch (_) {
      // Pushes still show; tapping them just opens the app.
    }
  }

  /// Gives the server this device's token for [user] once they've allowed
  /// notifications, and keeps it current. Until the server accepts it, the
  /// app shows background updates itself as before.
  Future<void> register(AppUser user) async {
    if (!_ready) return;
    _user = user;
    try {
      final messaging = FirebaseMessaging.instance;
      final status = (await messaging.getNotificationSettings()).authorizationStatus;
      if (status != AuthorizationStatus.authorized && status != AuthorizationStatus.provisional) return;
      // iOS hands out the Firebase token only once Apple's push token is in.
      if (Platform.isIOS && !await _apnsReady(messaging)) return;
      // FCM registration tokens rather than the newer installation IDs: every
      // server SDK can send to a token.
      // ignore: deprecated_member_use
      final token = await messaging.getToken();
      if (token == null) return;
      await _send(user, token);
      // ignore: deprecated_member_use
      _refresh ??= messaging.onTokenRefresh.listen((t) {
        final current = _user;
        if (current != null) unawaited(_send(current, t).catchError((Object _) {}));
      });
    } catch (_) {
      // Notifications stay in the app until the next sign-in.
    }
  }

  Future<bool> _apnsReady(FirebaseMessaging messaging) async {
    for (var i = 0; i < 5; i++) {
      if (await messaging.getAPNSToken() != null) return true;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  Future<void> _send(AppUser user, String token) async {
    if (!identical(user, AuthService.instance.currentUser)) return;
    await NotificationsApi.registerPushToken(token, Platform.isIOS ? 'ios' : 'android');
    // Signed out meanwhile: take it back.
    if (!identical(user, AuthService.instance.currentUser)) {
      return NotificationsApi.removePushToken(token).catchError((Object _) {});
    }
    _token = token;
  }

  /// On sign-out: the server forgets this device while the session still
  /// works ([server] is false once the server has ended it), then the token
  /// itself is deleted so nothing meant for this account reaches the device
  /// even if the server couldn't be told.
  Future<void> unregister({bool server = true}) async {
    if (!_ready) return;
    final token = _token;
    _token = null;
    _user = null;
    openRequested.value = null;
    await _refresh?.cancel();
    _refresh = null;
    if (server && token != null) {
      try {
        await NotificationsApi.removePushToken(token);
      } catch (_) {
        // The token is deleted below either way.
      }
    }
    try {
      // ignore: deprecated_member_use
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {
      // A new token is made at the next sign-in either way.
    }
    try {
      // KYC signs out of Firebase after the mobile check; this is in case it couldn't.
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // Nothing to sign out of.
    }
  }
}

/// What a tapped push is about, from its `data.type` and `data.id`. A chat
/// message opens that session's chat; anything else opens Notifications.
class PushTarget {
  const PushTarget(this.type, this.id);

  factory PushTarget.of(Map<String, dynamic> data) =>
      PushTarget('${data['type'] ?? ''}', data['id'] is String ? data['id'] as String : null);

  final String type;
  final String? id;

  /// For `chat.message`, the session whose chat to open.
  String? get chatSession => type == 'chat.message' && (id?.isNotEmpty ?? false) ? id : null;
}
