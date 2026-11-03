package com.windstock.launcher.server

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.windstock.launcher.Launcher
import com.windstock.launcher.MainActivity
import com.windstock.launcher.Notifier
import com.windstock.launcher.R
import com.windstock.launcher.WSLog

/**
 * Keeps the launcher's process -- and the Python server inside it -- alive
 * while the game has the screen.
 *
 * On iOS the server lives in the same process as the game, so it runs exactly
 * as long as the game does. On Android they are two apps, and a background app
 * with no foreground service is killed within minutes, which from the game's
 * side looks like the server vanishing mid-catch. The service owns nothing but
 * the notification and a partial wake lock; the server itself is PythonServer.
 */
class ServerService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Launcher.stopServer()
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(ID, notification)
            }
        } catch (e: Exception) {
            WSLog("server", "could not go foreground: ${e.message}")
        }
        if (wakeLock == null) {
            // The phone is often locked mid-walk while the game waits for eggs;
            // the server must keep answering the moment it wakes.
            wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "windstock:server")
                .apply { setReferenceCounted(false); acquire(6 * 60 * 60 * 1000L) }
        }
        PythonServer.revive()
        return START_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(
            this, 1, Intent(this, ServerService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val prefs = Launcher.prefs.value
        val port = prefs.serverPort
        val online = prefs.serverMode == com.windstock.launcher.ServerMode.ONLINE
        return NotificationCompat.Builder(this, Notifier.CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(if (online) "Windstock" else "Windstock server")
            .setContentText(if (online) "Encrypted connection to Windstock"
                            else "Running on this phone, port $port")
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, "Stop", stop)
            .build()
    }

    companion object {
        private const val ID = 7001
        private const val ACTION_STOP = "com.windstock.launcher.STOP_SERVER"

        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, ServerService::class.java))
            } catch (e: Exception) {
                // Android 12+ refuses a foreground-service start from the
                // background (e.g. when the game's config request woke us).
                // The server still runs; it just has no keep-alive until the
                // launcher is next opened.
                WSLog("server", "keep-alive service not started: ${e.message}")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ServerService::class.java))
        }
    }
}
