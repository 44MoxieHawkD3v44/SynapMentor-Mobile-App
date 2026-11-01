import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

/// The Firebase project's settings (`synapmentor4444`), from
/// android/app/google-services.json. Only Android is registered so far; on
/// other platforms Firebase reads GoogleService-Info.plist once it's added.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return android;
    throw UnsupportedError('Firebase has no settings for this platform yet.');
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDGwXWxiRHxjY7SFQ-O3nM2BjffRH8NpXU',
    appId: '1:1094141361113:android:a1d93bacdb5e8533a837c8',
    messagingSenderId: '1094141361113',
    projectId: 'synapmentor4444',
    storageBucket: 'synapmentor4444.firebasestorage.app',
  );
}
