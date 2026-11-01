import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'todo_service.dart';

/// System notifications on this device: account updates that arrive while
/// the app is in the background, and TODO reminders scheduled so they go off
/// even when the app is closed.
class DeviceNotifications {
  DeviceNotifications._();

  static final DeviceNotifications instance = DeviceNotifications._();

  final _plugin = FlutterLocalNotificationsPlugin();
  SharedPreferences? _prefs;
  bool _ready = false;
  int _nextId = 1;

  static const _todoKey = 'todo_reminders';
  static const _scheduledKey = 'todo_reminder_ids';

  static const _updates = NotificationDetails(
    android: AndroidNotificationDetails(
      'updates',
      'Updates',
      channelDescription: 'Bookings, payments, messages and other account updates',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
  );

  static const _reminders = NotificationDetails(
    android: AndroidNotificationDetails(
      'todo_reminders',
      'TODO reminders',
      channelDescription: 'Reminders for your TODO tasks',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
  );

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_stat_notify'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      // Server pushes use the same channel (the manifest names it), so it has
      // to exist before the first one arrives with the app closed.
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(
              const AndroidNotificationChannel(
                'updates',
                'Updates',
                description: 'Bookings, payments, messages and other account updates',
                importance: Importance.high,
              ),
            );
      }
      _ready = true;
    } catch (_) {
      // Notifications stay in the app only.
    }
  }

  /// Asks for permission to show notifications (Android 13+, iOS).
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    try {
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
                ?.requestNotificationsPermission() ??
            true;
      }
      if (Platform.isIOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
    } catch (_) {
      // Treated as not allowed.
    }
    return false;
  }

  /// Shows an update now.
  Future<void> show(String title, String body) async {
    if (!_ready) return;
    try {
      await _plugin.show(id: _nextId++, title: title, body: body, notificationDetails: _updates);
    } catch (_) {
      // Still listed in the app's notifications.
    }
  }

  /// Whether TODO reminders go off on this device (on unless turned off).
  bool get todoRemindersOn => _prefs?.getBool(_todoKey) ?? true;

  Future<void> setTodoRemindersOn(bool on) async {
    await _prefs?.setBool(_todoKey, on);
    if (!on) await cancelTodoReminders();
  }

  /// Schedules a reminder an hour before each open task is due and one when
  /// it's due, replacing those scheduled before.
  Future<void> scheduleTodoReminders(List<Task> tasks) async {
    await cancelTodoReminders();
    if (!_ready || !todoRemindersOn) return;
    final now = DateTime.now();
    final ids = <String>[];
    // iOS keeps at most 64 pending notifications; the soonest go first.
    final open = tasks.where((t) => !t.completed && t.due.isAfter(now)).toList()
      ..sort((a, b) => a.due.compareTo(b.due));
    for (final t in open.take(30)) {
      final soon = t.due.subtract(TodoService.reminderWindow);
      if (soon.isAfter(now)) {
        ids.add(
          '${await _schedule('${t.id}:soon', soon, 'Reminder: ${t.title}', 'Due in 1 hour. Open TODO to get started.')}',
        );
      }
      ids.add(
        '${await _schedule('${t.id}:due', t.due, 'Due now: ${t.title}', 'Mark it done or reschedule it in TODO.')}',
      );
    }
    await _prefs?.setStringList(_scheduledKey, ids);
  }

  Future<void> cancelTodoReminders() async {
    final ids = _prefs?.getStringList(_scheduledKey) ?? const [];
    for (final id in ids) {
      try {
        await _plugin.cancel(id: int.parse(id));
      } catch (_) {
        // Already gone.
      }
    }
    await _prefs?.remove(_scheduledKey);
  }

  Future<int> _schedule(String key, DateTime at, String title, String body) async {
    final id = key.hashCode & 0x7fffffff;
    try {
      await _plugin.zonedSchedule(
        id: id,
        scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
        notificationDetails: _reminders,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        title: title,
        body: body,
      );
    } catch (_) {
      // Shown in the app when it's open instead.
    }
    return id;
  }
}
