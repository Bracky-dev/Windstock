package com.windstock.launcher.game

import android.content.Context
import android.content.res.Resources
import android.util.Log
import java.io.File

/**
 * The game's own Android resources, as a Resources of their own.
 *
 * The game's Java code (Unity, Niantic, Upsight) refers to its resources by the numeric ids its
 * aapt gave them, and this APK's resources.arsc is the launcher's: the same 0x7f ids mean
 * other things here. So tools/make_w64_apk.sh packs the game's AndroidManifest.xml +
 * resources.arsc + res/ into assets/w64/game-res.apk, and the game's activities answer
 * getResources() with that table instead (loaded through the public
 * PackageManager.getResourcesForApplication, as for any APK on disk).
 */
object GameResources {
    private const val TAG = "wst64"
    private const val ASSET = "w64/game-res.apk"
    private var res: Resources? = null
    private var failed = false

    @Synchronized
    fun get(context: Context): Resources? {
        res?.let { return it }
        if (failed) return null
        return try {
            val file = File(context.filesDir, "t64/game-res.apk")
            val stamp = File(context.filesDir, "t64/game-res.stamp")
            val want = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
            if (!file.exists() || stamp.takeIf { it.exists() }?.readText() != want) {
                file.parentFile?.mkdirs()
                val tmp = File(file.path + ".tmp")
                context.assets.open(ASSET).use { i -> tmp.outputStream().use { i.copyTo(it) } }
                tmp.renameTo(file)
                stamp.writeText(want)
            }
            val pm = context.packageManager
            val ai = pm.getPackageArchiveInfo(file.path, 0)?.applicationInfo
                ?: error("not an APK: $file")
            ai.sourceDir = file.path
            ai.publicSourceDir = file.path
            pm.getResourcesForApplication(ai).also {
                res = it
                Log.i(TAG, "[app] game resources from $file")
            }
        } catch (e: Exception) {
            failed = true
            Log.e(TAG, "[app] game resources unavailable -- the game sees the launcher's", e)
            null
        }
    }
}
