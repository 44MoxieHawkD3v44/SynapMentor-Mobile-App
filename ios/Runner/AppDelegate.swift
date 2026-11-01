import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    ScreenCapture.shared.attach(messenger: engineBridge.applicationRegistrar.messenger())
    DemoState.shared.attach(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// The skill live demo asks whether the screen is recorded or mirrored and
/// whether the app shares the screen with another one (iPad split view or
/// Stage Manager). iOS can't pin an app.
final class DemoState {
  static let shared = DemoState()

  private var channel: FlutterMethodChannel?

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "synapmentor/demo", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "state":
        result(["pinned": false, "multiWindow": DemoState.windowed(), "recording": UIScreen.main.isCaptured])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// The app's window is noticeably smaller than the screen.
  private static func windowed() -> Bool {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
      return false
    }
    let screen = scene.screen.bounds.size
    let window = scene.coordinateSpace.bounds.size
    return window.width * window.height < screen.width * screen.height * 0.9
  }
}

/// iOS doesn't let an app block screenshots or recordings, so the app is told
/// when the screen is being recorded or mirrored (it covers itself then) and
/// when a screenshot was taken.
final class ScreenCapture {
  static let shared = ScreenCapture()

  private var channel: FlutterMethodChannel?

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "synapmentor/screen", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isCaptured":
        result(UIScreen.main.isCaptured)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    let center = NotificationCenter.default
    center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      self?.channel?.invokeMethod("captured", arguments: UIScreen.main.isCaptured)
    }
    center.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) {
      [weak self] _ in
      self?.channel?.invokeMethod("screenshot", arguments: nil)
    }
  }
}
