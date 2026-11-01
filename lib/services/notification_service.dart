import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/notifications_api.dart';
import '../api/realtime_client.dart';
import '../api/session_store.dart';
import '../core/html_entities.dart';
import 'auth_service.dart';
import 'community_service.dart';
import 'content_service.dart';
import 'device_notifications.dart';
import 'explore_service.dart';
import 'kyc_service.dart';
import 'push_notifications.dart';
import 'rewards_service.dart';
import 'settings_service.dart';
import 'solver_wallet_service.dart';
import 'support_service.dart';
import 'todo_service.dart';
import 'wallet_service.dart';

class AppNotification {
  AppNotification({
    required this.id,
    required this.title,
    required this.createdAt,
    this.body = '',
    this.type = '',
    this.read = false,
    this.local = false,
  });

  final String id;
  final String title;
  final String body;
  final String type;
  final DateTime createdAt;
  bool read;

  /// Kept on this device (realtime updates and TODO reminders); the others
  /// are stored on the server.
  final bool local;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'type': type,
    'created_at': createdAt.toIso8601String(),
    'read': read,
  };

  static AppNotification fromJson(Map<String, dynamic> j) => AppNotification(
    id: '${j['id']}',
    title: '${j['title']}',
    body: '${j['body'] ?? ''}',
    type: '${j['type'] ?? ''}',
    createdAt: DateTime.tryParse('${j['created_at']}') ?? DateTime.now(),
    read: j['read'] == true,
    local: true,
  );
}

/// Notifications for the signed-in user: the server's list plus the updates
/// that arrive over the realtime socket. A new one shows as a banner for
/// [bannerTime] (or as a system notification while the app is in the
/// background) and stays in the Notifications screen. The same events
/// refresh the bookings, wallet and other data they concern, so both seekers
/// and solvers see changes without reopening the app.
class NotificationService extends ChangeNotifier {
  static final NotificationService instance = NotificationService();

  static const bannerTime = Duration(seconds: 3);
  static const _maxLocal = 100;

  final _server = <AppNotification>[];
  final _local = <AppNotification>[];
  bool _serverLoaded = false;

  /// Newest first.
  List<AppNotification> get items => [..._server, ..._local]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  int get unread => items.where((n) => !n.read).length;

  String? loadError;

  /// The notification showing as a banner, if any.
  final banner = ValueNotifier<AppNotification?>(null);
  Timer? _bannerTimer;
  DateTime _lastBanner = DateTime(2000);

  AppUser? _user;
  StreamSubscription<Map<String, dynamic>>? _events;
  AppLifecycleListener? _lifecycle;
  Timer? _tick;
  bool _foreground = true;
  final _pending = <String, Timer>{};

  /// Starts following the user's notifications; called once signed in.
  Future<void> start(AppUser user) async {
    if (identical(_user, user)) return;
    stop();
    _user = user;
    _foreground = true;
    await _restoreLocal(user);
    unawaited(RealtimeClient.instance.acquire());
    _events = RealtimeClient.instance.events.listen(_onEvent);
    _lifecycle = AppLifecycleListener(onResume: _onResume, onHide: _onHide);
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => _onTick());
    // TODO reminders come from the app while it's open, from the system
    // once it's in the background or closed.
    unawaited(DeviceNotifications.instance.cancelTodoReminders());
    unawaited(load());
    unawaited(_askPermission(user));
  }

  /// Loads the push setting, then asks once for permission to notify.
  Future<void> _askPermission(AppUser user) async {
    try {
      await SettingsService.instance.load(user);
    } catch (_) {
      // The defaults apply.
    }
    if (!identical(user, _user)) return;
    final wanted =
        SettingsService.instance.isEnabled(user, NotificationPref.push) || DeviceNotifications.instance.todoRemindersOn;
    if (wanted) await DeviceNotifications.instance.requestPermission();
    // Pushes from the server while the app is closed; the server checks the
    // push setting before sending.
    if (identical(user, _user)) await PushNotifications.instance.register(user);
  }

  /// Stops on sign-out and drops what was loaded.
  void stop() {
    if (_user == null) return;
    _events?.cancel();
    _events = null;
    RealtimeClient.instance.release();
    _lifecycle?.dispose();
    _lifecycle = null;
    _tick?.cancel();
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
    _bannerTimer?.cancel();
    banner.value = null;
    _server.clear();
    _local.clear();
    _serverLoaded = false;
    _user = null;
    unawaited(DeviceNotifications.instance.cancelTodoReminders());
    notifyListeners();
  }

  /// Loads the server's notifications; any new unread one is announced.
  Future<void> load() async {
    final user = _user;
    if (user == null) return;
    try {
      final list = await NotificationsApi.list();
      if (!identical(user, _user)) return;
      final known = {for (final n in _server) n.id};
      final fresh = [for (final n in list) _fromApi(n)];
      final announce = _serverLoaded;
      _server
        ..clear()
        ..addAll(fresh);
      _serverLoaded = true;
      loadError = null;
      if (announce && DateTime.now().difference(_lastBanner) > const Duration(seconds: 4)) {
        final added = fresh.where((n) => !n.read && !known.contains(n.id)).firstOrNull;
        if (added != null) _announce(added);
      }
    } on AuthException catch (e) {
      loadError = e.message;
    }
    notifyListeners();
  }

  Future<void> markRead(AppNotification n) async {
    if (n.read) return;
    n.read = true;
    notifyListeners();
    if (n.local) return _saveLocal();
    try {
      await NotificationsApi.markRead(n.id);
    } on AuthException {
      // Shown as read here; the server catches up on the next one.
    }
  }

  Future<void> markAllRead() async {
    for (final n in items) {
      n.read = true;
    }
    notifyListeners();
    await _saveLocal();
    if (_server.isEmpty) return;
    try {
      await NotificationsApi.markAllRead();
    } on AuthException catch (e) {
      loadError = e.message;
      notifyListeners();
    }
  }

  Future<void> clearAll() async {
    final hadServer = _server.isNotEmpty;
    _server.clear();
    _local.clear();
    notifyListeners();
    await _saveLocal();
    if (!hadServer) return;
    try {
      await NotificationsApi.clearAll();
    } on AuthException catch (e) {
      loadError = e.message;
      notifyListeners();
      unawaited(load());
    }
  }

  /// Adds a notification made on this device, such as a TODO reminder.
  void notifyLocal(String title, String body, {String type = 'local'}) => _addLocal(
    AppNotification(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      body: body,
      type: type,
      createdAt: DateTime.now(),
      local: true,
    ),
  );

  /// A push arrived while the app is open: fetch it, once with any realtime
  /// event for the same notification.
  void refreshFromPush() {
    if (_user != null) _later('notifications', load, const Duration(milliseconds: 800));
  }

  // ---- Realtime ------------------------------------------------------------------

  void _onEvent(Map<String, dynamic> e) {
    final type = '${e['type'] ?? ''}';
    _refreshFor(type);
    if (type == 'notification.created') {
      // A server notification was stored; fetch it.
      return _later('notifications', load, const Duration(milliseconds: 800));
    }
    final title = _titles[type];
    if (title == null) return;
    final data = e['data'] is Map ? Map<String, dynamic>.from(e['data'] as Map) : const <String, dynamic>{};
    // Messages in the thread on screen appear there; no banner for them.
    final thread = '${data['thread_id'] ?? data['threadId'] ?? ''}';
    if (type.startsWith('community.message.') && CommunityService.instance.openThread?.discussion.id == thread) return;
    // Nor for what the user did themselves.
    final actor = data['sender_id'] ?? data['actor_id'];
    if (actor != null && actor == SessionStore.instance.userId && type.startsWith('community.')) return;
    final id = '${e['id'] ?? ''}';
    if (id.isNotEmpty && _local.any((n) => n.id == id)) return;
    _addLocal(
      AppNotification(
        id: id.isEmpty ? 'rt-${DateTime.now().microsecondsSinceEpoch}' : id,
        title: _text(data['title']) ?? title,
        body: _text(data['message']) ?? _text(data['body']) ?? _text(data['subject']) ?? '',
        type: type,
        createdAt: (DateTime.tryParse('${e['timestamp']}') ?? DateTime.now()).toLocal(),
        local: true,
      ),
    );
  }

  void _addLocal(AppNotification n) {
    _local.insert(0, n);
    if (_local.length > _maxLocal) _local.removeRange(_maxLocal, _local.length);
    notifyListeners();
    unawaited(_saveLocal());
    _announce(n);
  }

  /// A banner while the app is open; a system notification (if push is on)
  /// while it's in the background, unless the server pushes it to this device.
  void _announce(AppNotification n) {
    final user = _user;
    if (user == null) return;
    if (_foreground) {
      _lastBanner = DateTime.now();
      banner.value = n;
      _bannerTimer?.cancel();
      _bannerTimer = Timer(bannerTime, () => banner.value = null);
    } else if (SettingsService.instance.isEnabled(user, NotificationPref.push) &&
        n.type != 'todo.reminder' &&
        !PushNotifications.instance.active) {
      unawaited(DeviceNotifications.instance.show(n.title, n.body));
    }
  }

  void dismissBanner() {
    _bannerTimer?.cancel();
    banner.value = null;
  }

  /// Reloads what an event changed, once per burst of events.
  void _refreshFor(String type) {
    final user = _user;
    if (user == null) return;
    // Per-second timers, typing and presence don't change anything stored.
    if (type.contains('timer') ||
        type.contains('typing') ||
        type.startsWith('presence') ||
        type.startsWith('chat.') ||
        type.startsWith('lobby.') ||
        type.startsWith('meeting.')) {
      return;
    }
    final solver = user.role == UserRole.solver;
    bool has(List<String> words) => words.any(type.contains);
    if (has(['booking', 'session', 'slot', 'extension', 'review'])) {
      _later(
        'bookings',
        () => solver ? ExploreService.instance.loadSolverBookings(user) : ExploreService.instance.loadBookings(user),
      );
    }
    if (has(['wallet', 'payment', 'minute_pack', 'subscription', 'refund', 'earning', 'withdrawal'])) {
      _later('wallet', () => solver ? SolverWalletService.instance.load(user) : WalletService.instance.load(user));
    }
    if (type.startsWith('kyc.')) _later('kyc', () => KycService.instance.refresh(user));
    // Completed sessions and rewards can move the seeker's day streak.
    if (!solver && has(['session', 'reward', 'streak', 'points'])) {
      _later('streak', () => RewardsService.instance.loadStreak(user));
    }
    if (type.startsWith('ticket.')) _later('support', () => SupportService.instance.load(user));
    if (type.startsWith('community.') && !type.startsWith('community.message.')) {
      _later('community', () => CommunityService.instance.load(user));
    }
    if (type.startsWith('community.message.')) {
      _later('thread', CommunityService.instance.refreshOpenThread, const Duration(milliseconds: 400));
    }
    // An auto-recorded podcast draft is ready, expiring or gone.
    if (type.startsWith('content.') && type != 'content.view_count_updated' ||
        type == 'channel.new_follower' ||
        type.startsWith('podcast_draft')) {
      _later('content', () => solver ? ContentService.instance.loadMine(user) : ContentService.instance.load(user));
    }
  }

  void _later(String key, Future<void> Function() run, [Duration delay = const Duration(milliseconds: 1500)]) {
    _pending[key]?.cancel();
    _pending[key] = Timer(delay, () {
      _pending.remove(key);
      run().catchError((Object _) {});
    });
  }

  void _onResume() {
    _foreground = true;
    unawaited(DeviceNotifications.instance.cancelTodoReminders());
    _catchUp();
  }

  void _onHide() {
    _foreground = false;
    final user = _user;
    if (user != null) unawaited(DeviceNotifications.instance.scheduleTodoReminders(TodoService.instance.tasks(user)));
  }

  /// Every 30 seconds: TODO reminders, and a refresh when the socket is down.
  void _onTick() {
    final user = _user;
    if (user == null) return;
    if (_foreground) TodoService.instance.sendReminders(user);
    if (!RealtimeClient.instance.connected) _catchUp();
  }

  /// Reloads what may have changed while updates couldn't arrive.
  void _catchUp() {
    final user = _user;
    if (user == null) return;
    final solver = user.role == UserRole.solver;
    _later('notifications', load, Duration.zero);
    _later(
      'bookings',
      () => solver ? ExploreService.instance.loadSolverBookings(user) : ExploreService.instance.loadBookings(user),
      Duration.zero,
    );
    _later('wallet', () => solver ? SolverWalletService.instance.load(user) : WalletService.instance.load(user));
    _later('kyc', () => KycService.instance.refresh(user));
  }

  // ---- Storage --------------------------------------------------------------------

  String _key(AppUser user) => 'notifications:${user.role.name}:${user.email}';

  Future<void> _restoreLocal(AppUser user) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key(user));
      if (raw == null) return;
      final list = jsonDecode(raw);
      if (list is List) {
        _local
          ..clear()
          ..addAll([
            for (final j in list)
              if (j is Map) AppNotification.fromJson(Map<String, dynamic>.from(j)),
          ]);
      }
    } catch (_) {
      // Starts empty.
    }
  }

  Future<void> _saveLocal() async {
    final user = _user;
    if (user == null) return;
    try {
      await (await SharedPreferences.getInstance()).setString(
        _key(user),
        jsonEncode([for (final n in _local) n.toJson()]),
      );
    } catch (_) {
      // Kept for this run only.
    }
  }

  // ---- Mapping --------------------------------------------------------------------

  static AppNotification _fromApi(Map<String, dynamic> n) => AppNotification(
    id: '${n['id']}',
    title: _text(n['title']) ?? 'Notification',
    body: _text(n['body']) ?? '',
    type: '${n['event_type'] ?? ''}',
    createdAt: (DateTime.tryParse('${n['created_at']}') ?? DateTime.now()).toLocal(),
    read: n['is_read'] == true,
  );

  static String? _text(Object? v) => v is String && v.trim().isNotEmpty ? decodeHtmlEntities(v.trim()) : null;

  /// Realtime updates worth telling the user about, and their titles.
  static const _titles = {
    'booking_created': 'Booking created',
    'booking_confirmed': 'Booking confirmed',
    'booking_cancelled': 'Booking cancelled',
    'booking_declined': 'Booking declined',
    'booking_expired': 'Booking expired',
    'booking_rescheduled': 'Booking rescheduled',
    'payment_success': 'Payment successful',
    'payment_failed': 'Payment failed',
    'session_completed': 'Session completed',
    'session_reminder': 'Your session starts soon',
    'session_ready': 'Your session is ready to join',
    'wallet_topup': 'Minutes added to your wallet',
    'wallet_refund': 'Minutes refunded',
    'face_verify_refund': 'Minutes refunded',
    'minute_pack_purchased': 'Minute pack purchased',
    'subscription_activated': 'Subscription activated',
    'solver_booking_received': 'New booking received',
    'solver_booking_accepted': 'Booking accepted',
    'solver_booking_rejected': 'Booking rejected',
    'solver_earning_credit': 'Earnings credited',
    'solver_withdrawal': 'Withdrawal update',
    'solver_review_submitted': 'New review received',
    'extension_requested': 'Extension requested',
    'extension.approved': 'Extension approved',
    'extension.declined': 'Extension declined',
    'session.end_requested': 'Early end requested',
    'session.end_approved': 'Early end approved',
    'session.end_declined': 'Early end declined',
    'ticket.reply': 'New reply from support',
    'ticket.status_update': 'Support ticket updated',
    'kyc.approved': 'Verification approved',
    'kyc.rejected': 'Verification needs attention',
    'solver.warned': 'Account warning',
    'subscription.expiring': 'Subscription expiring soon',
    'subscription.renewed': 'Subscription renewed',
    'subscription.refunded': 'Subscription refunded',
    'content.new_comment': 'New comment on your content',
    'content.new_reaction': 'New reaction on your content',
    'content.new_feedback': 'New feedback on your content',
    'content.new_follower': 'New follower',
    'channel.new_follower': 'New follower',
    'content.new_from_followed_solver': 'New content from a solver you follow',
    'content.moderation_action': 'Update on your content',
    'content.report.resolved': 'Your report was reviewed',
    'community.thread.created': 'New discussion in your community',
    'community.message.posted': 'New message in your community',
    'community.member.joined': 'New member joined your community',
    'community.event.updated': 'Community event updated',
    'community.event.deleted': 'Community event cancelled',
    'community.request.approved': 'Community request approved',
    'community.request.rejected': 'Community request rejected',
    'community.message.mentioned': 'You were mentioned',
    'community.warning.issued': 'Community warning',
    'community.member.banned': 'Removed from a community',
    'community.member.removed': 'Removed from a community',
    'community.ownership.transferred': 'Community ownership transferred',
    'community.event.created': 'New community event',
  };
}
