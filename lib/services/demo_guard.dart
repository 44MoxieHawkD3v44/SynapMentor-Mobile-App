import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'screen_protection.dart';

/// What the device is doing right now, as far as the live demo cares.
typedef DemoDeviceState = ({bool pinned, bool split, bool captured});

/// The device side of the solver's skill-verification live demo.
///
/// Android pins the app to the screen for the demo (the phone asks first),
/// hides other apps' floating windows over it, and reports split screen and,
/// on Android 15+, screen recording. iOS can't pin an app, so the demo watches
/// for screen recording or mirroring and for iPad split view or Stage Manager
/// instead.
/// Screenshots and recordings are blocked or covered by [ScreenProtection].
class DemoGuard {
  DemoGuard._();
  static final instance = DemoGuard._();

  static const _channel = MethodChannel('synapmentor/demo');

  /// The app is pinned for the demo (Android) and is unpinned when it ends.
  bool get pinned => _pinned;
  bool _pinned = false;

  /// Null when the demo can start; otherwise what the solver has to do first.
  Future<String?> prepare() async {
    if (ScreenProtection.instance.sharing) {
      return 'Stop sharing your screen in your live session before you start the demo.';
    }
    final state = await check();
    if (state != null && state.captured) {
      return 'Stop recording or mirroring your screen before you start the demo.';
    }
    if (state != null && state.split) {
      return 'Close split screen or floating windows and use Synap Mentor full screen to start the demo.';
    }
    if (Platform.isAndroid) {
      if (await pin() == false) {
        return 'The live demo needs Synap Mentor pinned to your screen. '
            'Tap Start Demo again and allow it when your phone asks.';
      }
      await _invoke('hideOverlays', true);
    }
    return null;
  }

  /// Unpins the app and lets floating windows show again, once the demo ends.
  Future<void> release() async {
    if (!Platform.isAndroid) return;
    if (_pinned) {
      _pinned = false;
      await _invoke('unpin');
    }
    await _invoke('hideOverlays', false);
  }

  /// Asks the phone to pin the app (Android). True once it's pinned, false
  /// when the solver said no, null when the phone doesn't offer pinning (the
  /// demo still watches for leaving it).
  Future<bool?> pin() async {
    if (!Platform.isAndroid) return null;
    if ((await check())?.pinned ?? false) return _pinned = true;
    if (await _invoke('pin') != true) return null;
    final started = DateTime.now();
    // The phone's confirmation takes focus away from the app while it shows.
    var asked = false;
    while (DateTime.now().difference(started) < const Duration(seconds: 60)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if ((await check())?.pinned ?? false) return _pinned = true;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        asked = true;
      } else if (asked) {
        // Back without pinning, unless it lands a moment later.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!((await check())?.pinned ?? false)) return false;
        return _pinned = true;
      } else if (DateTime.now().difference(started) > const Duration(seconds: 3)) {
        return null; // nothing was asked
      }
    }
    return false;
  }

  /// Null when the phone couldn't be asked (on iOS, recording is still known).
  Future<DemoDeviceState?> check() async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    final state = await _invoke('state');
    if (state is! Map) {
      return Platform.isIOS ? (pinned: false, split: false, captured: ScreenProtection.instance.captured) : null;
    }
    return (pinned: state['pinned'] == true, split: state['multiWindow'] == true, captured: state['recording'] == true);
  }

  static Future<Object?> _invoke(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } catch (_) {
      return null;
    }
  }
}
