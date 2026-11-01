# Release builds are shrunk and optimised by R8. These libraries reach their
# classes through reflection and native code, so R8 must leave them intact;
# otherwise they fail only in release builds (e.g. ML Kit's
# "NullPointerException ... getClass() on a null object reference").

# Google ML Kit face detection (KYC live face check).
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_face.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_face_bundled.** { *; }
-keep class com.google_mlkit_commons.** { *; }
-keep class com.google_mlkit_face_detection.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.internal.mlkit_vision_**

# Razorpay checkout (its WebView calls back through JavaScript interfaces).
-keepattributes *Annotation*
-keepattributes JavascriptInterface
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-keep class com.razorpay.** { *; }
-dontwarn com.razorpay.**
-keepclasseswithmembers class * {
    public void onPayment*(...);
}

# WebRTC, used by LiveKit for live sessions.
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**
