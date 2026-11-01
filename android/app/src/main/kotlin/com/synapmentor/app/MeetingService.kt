package com.synapmentor.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps a live session running while the app is in the background: the
 * microphone (and camera) keep working and the app isn't stopped, so the call
 * carries on. While the screen is shared it also covers screen capture, which
 * Android requires a media-projection foreground service for.
 */
class MeetingService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Keeps the processor running with the screen off, so the session clock
     * keeps ticking and the meeting is ended on time in the background.
     */
    private var wakeLock: PowerManager.WakeLock? = null

    private fun holdWakeLock() {
        if (wakeLock?.isHeld == true) return
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "synapmentor:meeting")
            .apply {
                setReferenceCounted(false)
                // Released when the meeting ends; the timeout is only a safety net.
                acquire(WAKE_LOCK_TIMEOUT_MS)
            }
    }

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val sharing = intent?.getBooleanExtra(EXTRA_SCREEN, false) ?: false
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Live sessions", NotificationManager.IMPORTANCE_LOW),
            )
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("Synap Mentor")
            .setContentText(if (sharing) "You're sharing your screen in a session" else "You're in a live session")
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setOngoing(true)
            .build()
        if (startInForeground(notification, types(sharing))) holdWakeLock() else stopSelf()
        return START_NOT_STICKY
    }

    /**
     * Declares only the kinds of access that are allowed right now. If Android
     * refuses one (e.g. screen capture without consent, or the camera while
     * the app is in the background), it tries again without it rather than
     * crashing the app, which would end the call. False when none is allowed.
     */
    private fun startInForeground(notification: Notification, types: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification)
            return true
        }
        // Without explicit types Android would use every type in the manifest,
        // screen capture included, which it refuses unless sharing.
        val fallbacks = listOf(
            types,
            types and ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION.inv(),
            types and FOREGROUND_SERVICE_TYPE_MICROPHONE_ONLY,
        ).filter { it != 0 }.distinct()
        for (candidate in fallbacks) {
            try {
                startForeground(NOTIFICATION_ID, notification, candidate)
                return true
            } catch (e: Exception) {
                // Not allowed right now; try with less.
            }
        }
        // Before Android 14 the declared types aren't checked when starting,
        // so the service can still keep the app running (e.g. Android 10, which
        // has no microphone or camera type).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            try {
                startForeground(NOTIFICATION_ID, notification)
                return true
            } catch (e: Exception) {
                // Nothing more to try.
            }
        }
        return false
    }

    /** Only the kinds of access the user has granted can be declared. */
    private fun types(sharing: Boolean): Int {
        var types = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (granted(Manifest.permission.RECORD_AUDIO)) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (granted(Manifest.permission.CAMERA)) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        if (sharing && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        }
        return types
    }

    private fun granted(permission: String) = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    companion object {
        const val EXTRA_SCREEN = "screen"
        private const val CHANNEL = "live_session"
        private const val NOTIFICATION_ID = 7301
        private const val WAKE_LOCK_TIMEOUT_MS = 4 * 60 * 60 * 1000L

        /** The microphone type, or nothing before Android 11. */
        private val FOREGROUND_SERVICE_TYPE_MICROPHONE_ONLY =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
    }
}
