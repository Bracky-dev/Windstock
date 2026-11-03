package com.windstock.launcher

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.Process
import com.windstock.launcher.game.GameInstaller
import com.windstock.launcher.server.PythonServer
import com.windstock.launcher.server.ServerState

/**
 * How the game finds out what the launcher wants.
 *
 * On iOS the launcher writes windstock-mods.json into the guest's container and
 * the tweak reads it. Here the game is another app with its own private files,
 * so the agent inside it asks instead, once, as it loads:
 *
 *     content://com.windstock.launcher.config   call("config") -> {"json": "..."}
 *
 * The same call starts the embedded server if it is not running yet, so
 * opening the game from the home screen still finds a server. Starting a
 * provider brings this process up if Android had killed it, and the agent
 * keeps its provider client open for the life of the game, which keeps this
 * process ranked as the game's dependency rather than as idle background.
 *
 * Only the game (and adb's shell) may ask: the answer says where the server
 * is and nothing else, but there is no reason for any other app to have it.
 */
class ConfigProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        val ctx = context ?: return null
        Launcher.init(ctx)
        // By uid, not getCallingPackage(): that one asks AppOps to vouch for the
        // name and throws for some callers (adb's `content call` on Android 11).
        // adb's shell (uid 2000) may ask too: whoever runs adb already controls
        // the phone, and `adb shell content call` is how the handshake is checked.
        val uid = Binder.getCallingUid()
        val packages = ctx.packageManager.getPackagesForUid(uid)?.toList().orEmpty()
        if (uid != Process.myUid() && uid != SHELL_UID &&
            GameInstaller.PACKAGE !in packages && GameInstaller.LEGACY_PACKAGE !in packages &&
            GameInstaller.TRANSLATOR_PACKAGE !in packages) {
            WSLog("config", "refused a config request from ${packages.joinToString().ifEmpty { "uid $uid" }}")
            return null
        }
        return when (method) {
            "config" -> {
                if (Launcher.serverNeededAndDown()) {
                    WSLog("config", "the game started without the server -- starting it")
                    Launcher.startServer()
                    // Called from the game's main thread as it loads; wait a
                    // little so its first request finds a listener, but well
                    // inside the 5 s it takes Android to call that an ANR.
                    PythonServer.awaitRunning(2500)
                }
                val json = Launcher.gameConfig()
                WSLog("config", "game asked for its config (${arg ?: "agent"}): server ${json.optString("server")}, mods ${if (json.optBoolean("inject")) "on" else "off"}")
                Bundle().apply { putString("json", json.toString()) }
            }
            "log" -> {
                // The agent's own log lines, so one log covers both apps.
                arg?.let { WSLog("game", it) }
                Bundle.EMPTY
            }
            else -> null
        }
    }

    private companion object {
        const val SHELL_UID = 2000
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
                       selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?,
                        selectionArgs: Array<out String>?) = 0
}
