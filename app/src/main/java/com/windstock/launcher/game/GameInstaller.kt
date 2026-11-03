package com.windstock.launcher.game

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import com.windstock.launcher.BuildConfig
import com.windstock.launcher.WSLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.util.zip.ZipFile

/**
 * The game, as a second app beside the launcher.
 *
 * iOS loads the game INTO the launcher's process. Android has no way to do
 * that for a Unity/il2cpp app without a virtual-app engine, so the launcher
 * carries a patched Pokemon GO 0.35 APK in its assets instead
 * (tools/build_game_apk.sh) and installs it. What made the iOS container work
 * -- hooks in the game's own process -- comes along inside that APK: a Frida
 * gadget loads the windstock agent, which redirects the game's network to our
 * server and applies the mods (work/mods/android-035).
 *
 * The bundled APK carries assets/windstock-game.json with a build stamp; the
 * same file is read out of the INSTALLED apk (its path is world-readable), so
 * "update available" is a straight string compare.
 */
object GameInstaller {
    /**
     * The game's own app id (tools/build_game_apk.sh GAME_PACKAGE), so it sits next to
     * the Play Store's Pokemon GO instead of replacing it.
     */
    const val PACKAGE = "com.windstock.pokemongo"
    /** Windstock builds made before the rename; their agent may still ask for config. */
    const val LEGACY_PACKAGE = "com.nianticlabs.pokemongo"
    /** The 64-bit translator app (work/translator64) runs the same agent and asks too. */
    const val TRANSLATOR_PACKAGE = "com.windstock.translator64"
    private const val ASSET = "game/pokemongo.apk"
    /** Windstock 64 (w64 flavour): the game runs inside this app, in its ":game" process. */
    const val BUILT_IN = BuildConfig.GAME_BUILT_IN
    private const val GAME_ACTIVITY = "com.windstock.launcher.game.GameActivity"
    private const val ACTION_RESULT = "com.windstock.launcher.INSTALL_RESULT"

    data class GameInfo(val versionName: String, val stamp: String?, val agent: Boolean)

    sealed interface InstallPhase {
        data class Copying(val fraction: Float) : InstallPhase
        data object Waiting : InstallPhase
        data class Failed(val message: String, val conflict: Boolean = false) : InstallPhase
        data object Done : InstallPhase
    }

    private val _phase = MutableStateFlow<InstallPhase?>(null)
    val phase: StateFlow<InstallPhase?> = _phase

    fun clearPhase() { _phase.value = null }

    fun isInstalled(context: Context): Boolean = installedInfo(context) != null

    fun installedInfo(context: Context): GameInfo? {
        if (BUILT_IN) return GameInfo("0.35.0", BuildConfig.VERSION_NAME, true)
        val pm = context.packageManager
        val info = try {
            pm.getPackageInfo(PACKAGE, 0)
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        }
        val apk = info.applicationInfo?.sourceDir
        val marker = apk?.let { readMarker(it) }
        return GameInfo(info.versionName ?: "?", marker?.optString("stamp"), marker != null)
    }

    fun bundledInfo(context: Context): GameInfo? = if (BUILT_IN) installedInfo(context) else try {
        context.assets.open("game/windstock-game.json").use {
            val o = JSONObject(it.readBytes().decodeToString())
            GameInfo(o.optString("version", "0.35.0"), o.optString("stamp"), true)
        }
    } catch (_: Exception) {
        null
    }

    fun hasBundledApk(context: Context): Boolean = try {
        context.assets.openFd(ASSET).close(); true
    } catch (_: Exception) {
        // openFd fails for a compressed entry; fall back to a plain open.
        try { context.assets.open(ASSET).close(); true } catch (_: Exception) { false }
    }

    /** True when the installed game is older than (or not) the one this launcher carries. */
    fun updateAvailable(context: Context): Boolean {
        val bundled = bundledInfo(context) ?: return false
        val installed = installedInfo(context) ?: return false
        return installed.stamp != bundled.stamp
    }

    private fun readMarker(apkPath: String): JSONObject? = try {
        ZipFile(apkPath).use { zip ->
            val entry = zip.getEntry("assets/windstock-game.json") ?: return null
            JSONObject(zip.getInputStream(entry).readBytes().decodeToString())
        }
    } catch (_: Exception) {
        null
    }

    /** Null on success, else why not. */
    fun launch(context: Context): String? {
        val intent = if (BUILT_IN) Intent().setClassName(context, GAME_ACTIVITY)
            else context.packageManager.getLaunchIntentForPackage(PACKAGE)
            ?: return "Pokémon GO isn't installed. Install it from the Play tab."
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            null
        } catch (e: Exception) {
            e.message ?: "Could not start the game."
        }
    }

    fun canRequestInstalls(context: Context): Boolean =
        Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls()

    /** Installs (or updates) the bundled game through a PackageInstaller session. */
    fun install(context: Context) {
        if (_phase.value is InstallPhase.Copying || _phase.value is InstallPhase.Waiting) return
        val app = context.applicationContext
        _phase.value = InstallPhase.Copying(0f)
        Thread({
            try {
                val installer = app.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                    .apply { setAppPackageName(PACKAGE) }
                val sessionId = installer.createSession(params)
                installer.openSession(sessionId).use { session ->
                    val total = try { app.assets.openFd(ASSET).use { it.length } } catch (_: Exception) { -1L }
                    app.assets.open(ASSET).use { input ->
                        session.openWrite("base.apk", 0, total).use { out ->
                            val buf = ByteArray(512 * 1024)
                            var done = 0L
                            while (true) {
                                val n = input.read(buf)
                                if (n < 0) break
                                out.write(buf, 0, n)
                                done += n
                                if (total > 0) _phase.value = InstallPhase.Copying(done.toFloat() / total)
                            }
                            session.fsync(out)
                        }
                    }
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    val pending = PendingIntent.getBroadcast(
                        app, sessionId, Intent(app, ResultReceiver::class.java).setAction(ACTION_RESULT), flags)
                    _phase.value = InstallPhase.Waiting
                    session.commit(pending.intentSender)
                }
                WSLog("game", "install session committed")
            } catch (e: Exception) {
                WSLog("game", "install failed: ${e.message}")
                _phase.value = InstallPhase.Failed(e.message ?: "Install failed.")
            }
        }, "windstock-install").start()
    }

    /** The system uninstall prompt, for a Pokemon GO signed by someone else. */
    fun uninstallIntent(): Intent =
        Intent(Intent.ACTION_DELETE, Uri.parse("package:$PACKAGE")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** Receives the PackageInstaller status for [install]. */
    class ResultReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
            val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
            when (status) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    @Suppress("DEPRECATION")
                    val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        context.startActivity(confirm)
                    } catch (e: Exception) {
                        _phase.value = InstallPhase.Failed("Could not show the install prompt: ${e.message}")
                    }
                }
                PackageInstaller.STATUS_SUCCESS -> {
                    WSLog("game", "Pokémon GO installed")
                    _phase.value = InstallPhase.Done
                }
                PackageInstaller.STATUS_FAILURE_CONFLICT -> {
                    WSLog("game", "install conflict: $message")
                    _phase.value = InstallPhase.Failed(
                        "A Windstock GO signed with a different key is already installed. " +
                            "Uninstall it first (your trainers are on the server, not in the game).",
                        conflict = true)
                }
                PackageInstaller.STATUS_FAILURE_ABORTED -> _phase.value = null
                PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> {
                    WSLog("game", "install incompatible: $message")
                    _phase.value = InstallPhase.Failed(
                        if (message?.contains("ABI", ignoreCase = true) == true)
                            "This phone cannot run 32-bit apps, and Pokémon GO 0.35 only exists as a 32-bit (armeabi-v7a) build."
                        else message ?: "This phone cannot install this build.")
                }
                else -> {
                    WSLog("game", "install failed ($status): $message")
                    _phase.value = InstallPhase.Failed(message ?: "Install failed ($status).")
                }
            }
        }
    }
}
