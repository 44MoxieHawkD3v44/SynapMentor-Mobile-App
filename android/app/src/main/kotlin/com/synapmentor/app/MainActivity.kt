package com.synapmentor.app

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.function.Consumer

class MainActivity : FlutterActivity() {
    companion object {
        /// Capture is let through only while you share your own screen in a
        /// session; kept here so a recreated window stays the same.
        var allowCapture = false
    }

    /// Android 15+: the app is showing in a screen recording right now. Only
    /// the skill live demo reads it.
    private var recorded = false
    private val recordingCallback = Consumer<Int> { state ->
        recorded = state == WindowManager.SCREEN_RECORDING_STATE_VISIBLE
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyProtection()
    }

    override fun onStart() {
        super.onStart()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            try {
                recorded = windowManager.addScreenRecordingCallback(mainExecutor, recordingCallback) ==
                    WindowManager.SCREEN_RECORDING_STATE_VISIBLE
            } catch (_: Exception) {
                recorded = false
            }
        }
    }

    override fun onStop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            try {
                windowManager.removeScreenRecordingCallback(recordingCallback)
            } catch (_: Exception) {
            }
        }
        super.onStop()
    }

    /// Pinned to the screen (screen pinning, or lock task mode).
    private fun pinned() =
        (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).lockTaskModeState !=
            ActivityManager.LOCK_TASK_MODE_NONE

    /// Screenshots and screen recordings of the app come out black (and the
    /// recent-apps preview is blank), except while sharing your screen.
    private fun applyProtection() {
        if (allowCapture) {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Lets screen capture through while sharing your screen, and blocks it
        // again after.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "synapmentor/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "protect", "allow" -> {
                        allowCapture = call.method == "allow"
                        applyProtection()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // The skill live demo: pins the app to the screen (the phone asks
        // first), hides other apps' floating windows over it, and reports
        // split screen and screen recording.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "synapmentor/demo")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "state" -> result.success(
                        mapOf(
                            "pinned" to pinned(),
                            "multiWindow" to isInMultiWindowMode,
                            "recording" to recorded,
                        )
                    )
                    "pin" -> {
                        try {
                            if (!pinned()) startLockTask()
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "unpin" -> {
                        try {
                            if (pinned()) stopLockTask()
                        } catch (_: Exception) {
                        }
                        result.success(true)
                    }
                    "hideOverlays" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            window.setHideOverlayWindows(call.arguments == true)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // Starts, updates (screen sharing on or off) and stops the foreground
        // service that keeps a live session running in the background.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "synapmentor/meeting")
            .setMethodCallHandler { call, result ->
                val intent = Intent(this, MeetingService::class.java)
                when (call.method) {
                    "start" -> {
                        try {
                            intent.putExtra(MeetingService.EXTRA_SCREEN, call.argument<Boolean>("screen") ?: false)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("MEETING_SERVICE", e.message, null)
                        }
                    }
                    "stop" -> {
                        stopService(intent)
                        result.success(true)
                    }
                    // The back button during a meeting: the app goes to the
                    // background (like the home button) and the call goes on.
                    "background" -> {
                        moveTaskToBack(true)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
