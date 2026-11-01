import 'package:flutter/foundation.dart';

import '../api/account_api.dart';
import 'auth_service.dart';

enum NotificationPref {
  email('Email Alerts', 'Receive important updates via email', 'email_alerts'),
  calendar('Reminder Notifications', 'Reminders before your upcoming sessions', 'calendar_reminders'),
  push('Push Notifications', 'Bookings, payments and wallet updates on this device', 'push_notifications'),
  messages('Message Notifications', 'Chat, community, content and support messages', 'message_notifications'),
  weeklyDigest('Weekly Digest', 'A summary of your week by email', 'weekly_digest'),
  anonymousPool(
    'Anonymous Pool Responses',
    'When solvers respond to your anonymous requests',
    'anonymous_pool_response',
    roles: {UserRole.seeker},
  ),
  achievements('Achievements', 'Badges, milestones and pricing tier unlocks', 'achievement', roles: {UserRole.solver}),
  community(
    'Community Notifications',
    'Activity in the communities you own and join',
    'community_notifications',
    roles: {UserRole.solver},
  );

  const NotificationPref(
    this.title,
    this.subtitle,
    this.apiName, {
    this.roles = const {UserRole.seeker, UserRole.solver},
  });
  final String title;
  final String subtitle;

  /// The setting's name in the seeker API.
  final String apiName;

  /// The roles the API keeps this setting for.
  final Set<UserRole> roles;

  /// The settings shown to [role]. Nobody sees the weekly digest,
  /// achievements or community notifications; seekers don't see reminder
  /// notifications or anonymous pool responses either. Hidden settings keep
  /// their value on the server.
  static List<NotificationPref> forRole(UserRole role) => [
    for (final p in values)
      if (p.roles.contains(role) && !_hidden.contains(p) && !(role == UserRole.seeker && _hiddenForSeekers.contains(p)))
        p,
  ];

  static const _hidden = {weeklyDigest, achievements, community};
  static const _hiddenForSeekers = {calendar, anonymousPool};

  /// The setting's name for [role]; solvers call push `browser_push`.
  String apiNameFor(UserRole role) => role == UserRole.solver && this == push ? 'browser_push' : apiName;
}

class PolicyDoc {
  const PolicyDoc(this.title, this.subtitle, this.body);

  final String title;
  final String subtitle;
  final String body;
}

/// The user's preferences. Notification settings come from and go to the API
/// for both roles; analytics sharing can only be read from it so far. Every
/// preference is on by default except analytics sharing, which the user has
/// to opt into.
class SettingsService extends ChangeNotifier {
  static final SettingsService instance = SettingsService();

  final _notifications = <String, Set<NotificationPref>>{};
  final _analytics = <String, bool>{};

  /// Loads the user's saved settings.
  Future<void> load(AppUser user) async {
    final data = await AccountApi.settings(user.role.name);
    final notifications = data['notifications'];
    if (notifications is Map) {
      _notifications[user.email] = {
        for (final pref in NotificationPref.values)
          if (notifications[pref.apiNameFor(user.role)] != false) pref,
      };
    }
    final privacy = data['privacy'];
    final analytics = privacy is Map ? privacy['share_analytics_data'] ?? privacy['share_analytics'] : null;
    if (analytics is bool) _analytics[user.email] = analytics;
    notifyListeners();
  }

  bool isEnabled(AppUser user, NotificationPref pref) =>
      _notifications.putIfAbsent(user.email, () => {...NotificationPref.values}).contains(pref);

  /// Switches at once and saves; switches back if the save fails.
  Future<void> setEnabled(AppUser user, NotificationPref pref, bool enabled) async {
    final prefs = _notifications.putIfAbsent(user.email, () => {...NotificationPref.values});
    void apply(bool on) {
      on ? prefs.add(pref) : prefs.remove(pref);
      notifyListeners();
    }

    apply(enabled);
    try {
      await AccountApi.setNotification(user.role.name, pref.apiNameFor(user.role), enabled);
    } catch (_) {
      apply(!enabled);
      rethrow;
    }
  }

  bool sharesAnalytics(AppUser user) => _analytics[user.email] ?? false;

  void setSharesAnalytics(AppUser user, bool value) {
    _analytics[user.email] = value;
    notifyListeners();
  }

  // Policy documents, loaded from the API.
  static final policies = <PolicyDoc>[];
  static final sessionPolicies = <PolicyDoc>[];

  /// Replaces the policy documents with what the API returned.
  static void setPolicies({List<PolicyDoc>? general, List<PolicyDoc>? session}) {
    if (general != null) {
      policies
        ..clear()
        ..addAll(general);
    }
    if (session != null) {
      sessionPolicies
        ..clear()
        ..addAll(session);
    }
  }
}
