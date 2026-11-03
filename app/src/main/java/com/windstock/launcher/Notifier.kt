package com.windstock.launcher

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.windstock.launcher.server.ServerState
import org.json.JSONObject
import java.io.File

/**
 * Local notifications for things worth knowing while the phone is in a pocket.
 * A straight port of Notifier.swift: the server's state lives in files this app
 * owns, so they are watched directly --
 *   lures.json  -- expires_ms per lured stop
 *   save.json   -- eggs + incubators + stats.km_walked
 * plus the embedded server's own lifecycle.
 */
object Notifier {
    const val CHANNEL_EVENTS = "windstock.events"
    const val CHANNEL_SERVICE = "windstock.server"

    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())
    private var prefs = LauncherPrefs()
    /** Identifiers already notified, so a 30-second poll doesn't nag. */
    private val announced = mutableSetOf<String>()
    private val poller = object : Runnable {
        override fun run() {
            poll()
            main.postDelayed(this, 30_000)
        }
    }

    fun init(context: Context) {
        app = context.applicationContext
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = app.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(
                CHANNEL_EVENTS, "Eggs, lures and the server", NotificationManager.IMPORTANCE_DEFAULT))
            nm.createNotificationChannel(NotificationChannel(
                CHANNEL_SERVICE, "Server running", NotificationManager.IMPORTANCE_LOW))
        }
    }

    val isAllowed: Boolean
        get() = Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    fun update(prefs: LauncherPrefs) {
        this.prefs = prefs
        main.removeCallbacks(poller)
        if (prefs.notificationsEnabled) main.post(poller)
    }

    fun post(title: String, body: String, id: String = System.nanoTime().toString()) {
        if (!prefs.notificationsEnabled) return
        WSLog("notify", "$title: $body")
        if (!isAllowed) return
        val n = NotificationCompat.Builder(app, CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(app).notify(id.hashCode(), n)
        } catch (e: SecurityException) {
            WSLog("notify", "post failed: ${e.message}")
        }
    }

    fun serverStateChanged(state: ServerState, error: String?) {
        if (!prefs.notifyServerState) return
        // On Windstock the "server" is only the tunnel to it: its start is not news,
        // and a failure means the connection, not a server on this phone.
        val online = prefs.serverMode == ServerMode.ONLINE
        when (state) {
            ServerState.RUNNING -> if (!online) post("Server running", "Listening on port ${prefs.serverPort}.", "server.running")
            ServerState.FAILED -> post(if (online) "Lost the connection to Windstock" else "Server stopped with an error",
                error ?: "See the log for details.", "server.failed")
            else -> {}
        }
    }

    private fun json(name: String): JSONObject? = try {
        JSONObject(File(Paths.dataDir, name).readText())
    } catch (_: Exception) {
        null
    }

    private fun poll() {
        if (prefs.notifyLures) pollLures()
        if (prefs.notifyEggs) pollEggs()
    }

    private fun pollLures() {
        val lures = json("lures.json")?.optJSONObject("lures") ?: return
        val now = System.currentTimeMillis().toDouble()
        val warning = prefs.lureWarningMinutes * 60_000.0
        for (fortId in lures.keys()) {
            val expires = lures.optJSONObject(fortId)?.optDouble("expires_ms") ?: continue
            if (expires.isNaN()) continue
            val remaining = expires - now
            if (remaining <= 0 || remaining > warning) continue
            val id = "lure.$fortId.${expires.toLong()}"
            if (!announced.add(id)) continue
            val minutes = maxOf(1, Math.round(remaining / 60_000).toInt())
            post("Lure running out", "A lure has about $minutes minute${if (minutes == 1) "" else "s"} left.", id)
        }
    }

    private fun pollEggs() {
        val save = json("save.json") ?: return
        val walked = save.optJSONObject("stats")?.optDouble("km_walked", 0.0) ?: 0.0
        val incubators = save.optJSONArray("incubators") ?: return
        for (i in 0 until incubators.length()) {
            val inc = incubators.optJSONObject(i) ?: continue
            val egg = inc.optString("egg")
            val target = inc.optDouble("target_km")
            if (egg.isEmpty() || target.isNaN() || walked < target) continue
            val id = "egg.$egg"
            if (!announced.add(id)) continue
            post("Egg ready to hatch", "One of your eggs has finished its distance.", id)
        }
    }
}
