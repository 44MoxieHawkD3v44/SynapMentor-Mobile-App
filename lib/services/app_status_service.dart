import 'dart:async';

import 'package:flutter/widgets.dart';

import '../api/api_client.dart';
import '../api/app_status_api.dart';

/// A newer release of the app.
class AppUpdate {
  const AppUpdate({required this.version, required this.mandatory, required this.downloadUrl, required this.notes});

  final String version;

  /// This install must update before it can be used.
  final bool mandatory;

  /// The App Store or Play Store page; empty until the admin sets it.
  final String downloadUrl;
  final String notes;
}

/// Whether the app is under maintenance (set by the admin) and whether a newer
/// version is out. Checked at launch and whenever the app comes back to the
/// foreground; while under maintenance it's checked every minute until the
/// admin turns it off, and the app works normally again.
class AppStatusService extends ChangeNotifier with WidgetsBindingObserver {
  AppStatusService._();
  static final instance = AppStatusService._();

  /// Shown when the admin hasn't written a message.
  static const defaultMessage = 'The app is under maintenance. Please try again shortly.';

  /// The admin's message while the app is under maintenance; null otherwise.
  String? maintenance;
  AppUpdate? update;

  /// An optional update the user chose to see later, for this run of the app.
  bool updateDismissed = false;

  /// The "Update to the Latest Version" prompt is open.
  bool prompt = false;

  /// The update card (or its prompt) is showing.
  bool get showingUpdate {
    final u = update;
    return maintenance == null && u != null && (u.mandatory || !updateDismissed);
  }

  Timer? _poll;
  AppLifecycleListener? _lifecycle;

  /// Starts checking. Call once at startup.
  void start() {
    if (_lifecycle != null) return;
    _lifecycle = AppLifecycleListener(onResume: check);
    // Added before the app's own navigation, so it's asked about the back
    // button first.
    WidgetsBinding.instance.addObserver(this);
    // A request refused for maintenance switches to the maintenance view.
    ApiClient.instance.maintenanceNotice.addListener(() {
      final message = ApiClient.instance.maintenanceNotice.value;
      if (message != null) _setMaintenance(message.isEmpty ? defaultMessage : message);
    });
    check();
  }

  /// Fetches both states. Failures (e.g. no connection) keep what's shown.
  Future<void> check() => Future.wait([checkMaintenance(), _checkVersion()]);

  Future<void> checkMaintenance() async {
    try {
      final r = await AppStatusApi.maintenance();
      final message = '${r['message'] ?? ''}'.trim();
      _setMaintenance(r['maintenance_enabled'] == true ? (message.isEmpty ? defaultMessage : message) : null);
    } catch (_) {
      // Kept as it was; checked again shortly.
    }
  }

  Future<void> _checkVersion() async {
    try {
      final r = await AppStatusApi.versionCheck();
      final type = '${r['update_type'] ?? 'none'}';
      final next = type == 'none' || r['update_available'] != true
          ? null
          : AppUpdate(
              version: '${r['latest_version'] ?? ''}',
              mandatory: type == 'mandatory' || r['is_mandatory'] == true,
              downloadUrl: '${r['download_url'] ?? ''}'.trim(),
              notes: '${r['release_notes'] ?? ''}'.trim(),
            );
      if (next?.version != update?.version || next?.mandatory != update?.mandatory) updateDismissed = false;
      update = next;
      notifyListeners();
    } catch (_) {
      // No prompt when it can't be checked.
    }
  }

  void _setMaintenance(String? message) {
    final changed = message != maintenance;
    maintenance = message;
    _poll?.cancel();
    _poll = message == null ? null : Timer.periodic(const Duration(seconds: 60), (_) => checkMaintenance());
    if (message == null) ApiClient.instance.maintenanceNotice.value = null;
    if (changed) notifyListeners();
  }

  void dismissUpdate() {
    updateDismissed = true;
    prompt = false;
    notifyListeners();
  }

  void showPrompt(bool open) {
    prompt = open;
    notifyListeners();
  }

  /// The system back button can't get around a card (it would change the
  /// screens underneath). On an optional update it closes the prompt, then
  /// means "Later".
  @override
  Future<bool> didPopRoute() async {
    if (maintenance != null) return true;
    if (!showingUpdate) return false;
    if (!update!.mandatory) prompt ? showPrompt(false) : dismissUpdate();
    return true;
  }
}
