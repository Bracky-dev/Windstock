package com.windstock.launcher

import android.app.Application
import android.content.res.Resources

class WindstockApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // Windstock 64 runs the game in this app's ":game" process (GameActivity, w64 flavour):
        // nothing of the launcher (log, prefs, notifications, the server) belongs there.
        if (isGameProcess()) return
        Launcher.init(this)
    }

    /** Windstock 64's game process: the game's own resources (GameResources), once loaded. */
    override fun getResources(): Resources = gameResources ?: super.getResources()

    private fun isGameProcess(): Boolean {
        if (!BuildConfig.GAME_BUILT_IN) return false
        val name = if (android.os.Build.VERSION.SDK_INT >= 28) getProcessName()
            else try { java.io.File("/proc/self/cmdline").readText().trimEnd('\u0000') } catch (_: Exception) { "" }
        return name.endsWith(":game")
    }

    companion object {
        @JvmStatic @Volatile var gameResources: Resources? = null
    }
}
