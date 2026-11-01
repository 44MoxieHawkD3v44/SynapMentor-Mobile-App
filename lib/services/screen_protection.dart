import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps screenshots and screen recordings out of the whole app.
///
/// Android blocks them outright: the capture comes out black. iOS can't block
/// them, so the app is covered while the screen is being recorded or
/// mirrored, and a note shows after a screenshot.
///
/// While you share your own screen in a session capture is let through, so
/// the other person sees it; it's blocked again as soon as sharing stops.
class ScreenProtection extends ChangeNotifier {
  ScreenProtection._();
  static final instance = ScreenProtection._();

  static const _channel = MethodChannel('synapmentor/screen');

  /// How long the note after a screenshot stays up.
  static const noticeFor = Duration(seconds: 4);

  bool _recording = false;
  bool _sharing = false;
  bool _screenshotTaken = false;
  Timer? _noticeTimer;

  /// iOS: the screen is being recorded or mirrored by something other than
  /// your own screen share, so the app is covered.
  bool get covered => _recording && !_sharing;

  /// iOS: a screenshot was just taken.
  bool get screenshotTaken => _screenshotTaken;

  /// iOS: the screen is being recorded or mirrored right now, by anything.
  bool get captured => _recording;

  /// You're sharing your screen in a session right now, so capture is let
  /// through.
  bool get sharing => _sharing;

  Future<void> init() async {
    if (!Platform.isIOS) return; // Android is protected from launch.
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'captured':
          _recording = call.arguments == true;
          notifyListeners();
        case 'screenshot':
          if (!_sharing) _showScreenshotNote();
      }
    });
    try {
      _recording = await _channel.invokeMethod<bool>('isCaptured') ?? false;
    } catch (_) {
      // Not known yet; the next change reports it.
    }
  }

  void _showScreenshotNote() {
    _noticeTimer?.cancel();
    _screenshotTaken = true;
    notifyListeners();
    _noticeTimer = Timer(noticeFor, () {
      _screenshotTaken = false;
      notifyListeners();
    });
  }

  /// Lets capture through while you share your screen ([sharing] true), and
  /// blocks it again after. Called before sharing starts so the very first
  /// frames go out.
  Future<void> allowCapture(bool sharing) async {
    if (_sharing == sharing) return;
    _sharing = sharing;
    notifyListeners();
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>(sharing ? 'allow' : 'protect');
    } catch (_) {
      // The window keeps its last setting.
    }
  }
}
