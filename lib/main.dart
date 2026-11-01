import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest.dart' as tz_data;

import 'api/api_client.dart';
import 'api/session_store.dart';
import 'core/navigation.dart';
import 'core/theme.dart';
import 'screens/app_status_gate.dart';
import 'screens/login_screen.dart';
import 'screens/review_gate.dart';
import 'screens/splash_welcome_screen.dart';
import 'services/app_status_service.dart';
import 'services/auth_service.dart';
import 'services/device_notifications.dart';
import 'services/push_notifications.dart';
import 'services/screen_protection.dart';
import 'widgets/brand_logo.dart';
import 'widgets/glass_background.dart';
import 'widgets/notification_banner.dart';
import 'widgets/screen_guard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The splash logo starts loading now, alongside the rest of the start-up.
  BrandLogo.preload();
  // Timezone rules (daylight saving included), so session times convert
  // correctly between the seeker's and solver's zones.
  tz_data.initializeTimeZones();
  _applySystemBars();
  // The saved session and device details are ready before the first request.
  await SessionStore.instance.load();
  await ApiClient.instance.init();
  await DeviceNotifications.instance.init();
  // Firebase: mobile number checks, and pushes while the app is closed.
  await PushNotifications.instance.init();
  // Maintenance mode and new versions, checked now and on every return.
  AppStatusService.instance.start();
  // No screenshots or screen recordings of the app.
  await ScreenProtection.instance.init();
  runApp(const SynapMentorApp());
}

/// Status and navigation bars follow the look: light icons on dark, dark
/// icons on light.
void _applySystemBars() {
  SystemChrome.setSystemUIOverlayStyle(
    isLightMode
        ? SystemUiOverlayStyle.dark.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.white,
            systemNavigationBarIconBrightness: Brightness.dark,
          )
        : SystemUiOverlayStyle.light.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: AppColors.primary,
          ),
  );
}

class SynapMentorApp extends StatefulWidget {
  const SynapMentorApp({super.key});

  @override
  State<SynapMentorApp> createState() => _SynapMentorAppState();
}

class _SynapMentorAppState extends State<SynapMentorApp> {
  /// Keeps the whole app (navigation, open screens, form input) alive when
  /// the light-mode filter is added or removed around it.
  final _appKey = GlobalKey();

  /// Lets the app return to Sign In from anywhere when the session ends.
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    appearance.addListener(_onAppearance);
    ApiClient.instance.sessionExpired.addListener(_onSessionExpired);
  }

  /// The session couldn't be renewed: back to Sign In with a note.
  void _onSessionExpired() {
    final auth = AuthService.instance;
    if (auth.currentUser == null) return;
    auth.signOut();
    _navigatorKey.currentState?.pushAndRemoveUntil(
      glassRoute(const LoginScreen(notice: 'Your session has expired. Please sign in again.')),
      (_) => false,
    );
  }

  @override
  void dispose() {
    appearance.removeListener(_onAppearance);
    ApiClient.instance.sessionExpired.removeListener(_onSessionExpired);
    super.dispose();
  }

  void _onAppearance() {
    _applySystemBars();
    setState(() {});
    // Status colors (errors, success) are chosen per mode while building, so
    // every screen redraws once with the new mode.
    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Synap Mentor',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // One shared background under the navigator so the glass of every route
      // frosts the same scene and transitions never flash a new backdrop.
      builder: (context, child) {
        final app = KeyedSubtree(
          key: _appKey,
          child: Stack(
            children: [
              const Positioned.fill(child: GlassBackground()),
              if (child != null) Positioned.fill(child: child),
              // Mandatory session reviews block everything underneath.
              const Positioned.fill(child: ReviewGate()),
              // New notifications show for a few seconds, then stay in Notifications.
              const Positioned.fill(child: NotificationBanner()),
              // Maintenance and required updates sit above everything.
              const Positioned.fill(child: AppStatusGate()),
              // Screen recording (iOS) hides everything, the gates included.
              const Positioned.fill(child: ScreenGuard()),
            ],
          ),
        );
        // The UI is designed dark; light mode remaps it as a whole, so every
        // screen keeps its layout and glass and only the colors change.
        return isLightMode ? ColorFiltered(colorFilter: lightModeFilter, child: app) : app;
      },
      home: const SplashWelcomeScreen(),
    );
  }
}
