package com.windstock.launcher.game

import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.PermissionInfo
import android.content.res.Resources
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import android.util.Log
import com.windstock.launcher.WindstockApp
import com.windstock.translator64.WsNet
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch

/**
 * Windstock 64: the game, inside this app. The host Activity (work/translator64/zb-app,
 * com.windstock.translator64.ZbActivity) runs the 32-bit game's libunity/libil2cpp under
 * Chucny's Translator (AGPL-3.0; credits in Settings) and hosts the real UnityPlayer; this
 * subclass only fits it into the launcher:
 *  - its files go to files/t64, next to the launcher's own (files/Windstock, files/chaquopy);
 *  - the game's network goes where the launcher's config says (its tunnel or embedded server
 *    on 127.0.0.1, checked against the launcher's CA), asked from ConfigProvider just like the
 *    agent asks it -- which also starts the server if it is not up yet;
 *  - every runtime permission the app lists (location) is asked for HERE, before the engine
 *    starts: Unity 5.3 asks for missing ones through an anonymous Fragment that current Android
 *    refuses ("Fragment null must be a public static class"), and then never renders a frame;
 *  - the game's Java code finds its OWN Android resources (layouts, strings, icons it uses by
 *    id) instead of the launcher's: see [GameResources].
 *
 * Runs in the ":game" process (AndroidManifest, w64), so a translator crash leaves the
 * launcher and its server running.
 */
class GameActivity : com.windstock.translator64.ZbActivity() {
    private var gameRes: Resources? = null
    private val permissions = CountDownLatch(1)

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        val missing = missingPermissions()
        if (missing.isEmpty()) permissions.countDown()
        else requestPermissions(missing.toTypedArray(), REQUEST_PERMISSIONS)
    }

    /** The dangerous permissions in our manifest that are not granted yet. */
    private fun missingPermissions(): List<String> {
        val info: PackageInfo = packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
        return info.requestedPermissions.orEmpty().filter { name ->
            val dangerous = try {
                packageManager.getPermissionInfo(name, 0).protection == PermissionInfo.PROTECTION_DANGEROUS
            } catch (_: Exception) { false }
            dangerous && checkSelfPermission(name) != PackageManager.PERMISSION_GRANTED
        }
    }

    override fun onRequestPermissionsResult(code: Int, perms: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, perms, results)
        if (code != REQUEST_PERMISSIONS) return
        val missing = missingPermissions()
        if (missing.isEmpty()) {
            permissions.countDown()
            return
        }
        // The engine would hang on its own request (see above): back to the launcher instead.
        Log.w(TAG, "[app] permissions refused: $missing")
        Toast.makeText(this, "Pokémon GO needs your location to play.", Toast.LENGTH_LONG).show()
        finishAndRemoveTask()
        window.decorView.postDelayed({ android.os.Process.killProcess(android.os.Process.myPid()) }, 1500)
    }

    override fun baseDir(): File = File(filesDir, "t64")

    override fun getResources(): Resources {
        gameRes?.let { return it }
        if (baseContext != null) GameResources.get(this)?.let { gameRes = it; WindstockApp.gameResources = it; return it }
        return super.getResources()
    }

    override fun configureNet() {
        // runs on the start-up thread the translator waits for: hold it until the permissions are in
        permissions.await()
        val b = try {
            contentResolver.call(Uri.parse("content://$packageName.config"), "config", "game", null)
        } catch (e: Exception) {
            Log.e(TAG, "[app] launcher config failed: $e"); null
        }
        val json = b?.getString("json") ?: return
        val net = JSONObject(json).optJSONObject("net") ?: return
        WsNet.configure(net.optBoolean("enabled"), net.optString("host"), net.optInt("port"),
            net.optString("ca", ""))
        Log.i(TAG, "[app] launcher config: server ${JSONObject(json).optString("server")}, net " +
            (if (net.optBoolean("enabled")) "${net.optString("host")}:${net.optInt("port")}" else "off"))
    }

    private companion object {
        const val TAG = "wst64"
        const val REQUEST_PERMISSIONS = 64
    }
}
