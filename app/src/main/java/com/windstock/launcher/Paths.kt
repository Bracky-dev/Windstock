package com.windstock.launcher

import android.content.Context
import java.io.File

/**
 * Every place the launcher reads or writes. The Android counterpart of WSPaths.
 *
 *   files/Windstock/launcher.json      prefs
 *   files/Windstock/mods.json          the mods switches (master copy)
 *   files/Windstock/logs/launcher.log  the log Settings > Testing sends
 *   files/Windstock/PythonServer/      the server, unpacked from the APK's assets
 *   files/Windstock/Server/data/       what the server writes: saves, settings.json,
 *                                      places, gyms, world packs (WS_DATA_DIR)
 *
 * Internal storage throughout: the server's data folder holds every trainer's
 * save, and nothing else on the phone needs to see it.
 */
object Paths {
    lateinit var root: File
        private set

    fun init(context: Context) {
        root = File(context.filesDir, "Windstock").apply { mkdirs() }
    }

    val prefsFile get() = File(root, "launcher.json")
    val modsFile get() = File(root, "mods.json")
    val logsDir get() = File(root, "logs")

    /** The unpacked server (read-only as far as the server is concerned). */
    val pythonServerDir get() = File(root, "PythonServer")

    /** Parent of the data folder; datadir.base_dir() answers this. */
    val serverDataDir get() = File(root, "Server")

    /** WS_DATA_DIR: settings.json, saves/, places.json, world/ ... */
    val dataDir get() = File(serverDataDir, "data")

    val settingsFile get() = File(dataDir, "settings.json")

    /** World packs downloaded in Settings > World Data. */
    val worldDir get() = File(dataDir, "world")

    /** Packs that shipped inside the APK (tools/stage_server.sh --with-world). */
    val bundledWorldDir get() = File(pythonServerDir, "world")

    val caCertificate get() = File(pythonServerDir, "certs/ca.crt")
}
