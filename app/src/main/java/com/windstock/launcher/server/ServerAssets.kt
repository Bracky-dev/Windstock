package com.windstock.launcher.server

import android.content.Context
import com.windstock.launcher.Paths
import com.windstock.launcher.WSLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/**
 * Unpacks the server from the APK into internal storage.
 *
 * On iOS the server runs straight out of the read-only bundle. An APK is a zip,
 * and the server opens its files by path (certs, asset bundles, world.sqlite,
 * the research art), so it is copied out once per install/update. User data
 * never lives here -- that is Paths.dataDir -- so the whole folder can be
 * replaced wholesale when the APK changes.
 *
 * tools/stage_server.sh writes assets/PythonServer/MANIFEST.txt ("<bytes> <path>"
 * per line); walking that is much faster than AssetManager.list() over a few
 * thousand files, and it gives real byte progress.
 */
object ServerAssets {
    private const val ASSET_ROOT = "PythonServer"

    data class Progress(val fraction: Float, val label: String)

    private val _progress = MutableStateFlow<Progress?>(null)
    /** Non-null while unpacking; the Play screen shows it. */
    val progress: StateFlow<Progress?> = _progress

    private fun stampFor(context: Context): String {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        @Suppress("DEPRECATION")
        return "${info.versionCode}:${info.lastUpdateTime}"
    }

    fun isCurrent(context: Context): Boolean {
        val stamp = File(Paths.pythonServerDir, ".stamp")
        return stamp.exists() && stamp.readText() == stampFor(context) &&
            File(Paths.pythonServerDir, "server.py").exists()
    }

    /** True when there is a server in the APK at all (stage_server.sh ran). */
    fun isBundled(context: Context): Boolean = try {
        context.assets.open("$ASSET_ROOT/MANIFEST.txt").close(); true
    } catch (_: Exception) {
        false
    }

    private fun sha1(input: InputStream): String {
        val md = MessageDigest.getInstance("SHA-1")
        val buf = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            md.update(buf, 0, n)
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private val runtimeStamp get() = File(Paths.root, ".python-runtime")
    private val runtimeStarting get() = File(Paths.root, ".python-starting")

    /**
     * Chaquopy extracts its stdlib and bootstrap into files/chaquopy and skips
     * any file whose hash in its "chaquopy" SharedPreferences matches the APK.
     * Those two can disagree (prefs are written with apply(), so a kill or an
     * install at the wrong moment loses them): seen upgrading 1.0 (Python 3.13)
     * to 1.5 (3.11), where a 3.13 stdlib-common.imy stayed behind while the
     * prefs held the 3.11 hash. Py_Initialize then fails and exit(1)s inside
     * Python.start() -- no exception, no log, on every start until `pm clear`.
     *
     * So the whole runtime is thrown away and re-extracted (under half a
     * second) whenever the APK's chaquopy/build.json changes -- it lists the
     * hash of every runtime file, so it changes exactly when Python does, not
     * on every launcher update -- and again if the previous start never got
     * past Python.start(). Must run before Python.start().
     */
    fun resetPythonRuntimeIfStale(context: Context) {
        val stamp = context.assets.open("chaquopy/build.json").use { sha1(it) }
        val crashed = runtimeStarting.exists()
        val changed = !runtimeStamp.exists() || runtimeStamp.readText() != stamp
        if (!crashed && !changed) return
        WSLog("server", if (crashed) "the last Python start never finished -- re-extracting the runtime"
                        else "the Python runtime changed -- re-extracting it")
        File(context.filesDir, "chaquopy").deleteRecursively()
        File(context.cacheDir, "chaquopy").deleteRecursively()
        context.getSharedPreferences("chaquopy", Context.MODE_PRIVATE).edit().clear().commit()
        runtimeStamp.writeText(stamp)
    }

    /** Brackets Python.start(): a marker left behind means it killed the process. */
    fun pythonStarting(starting: Boolean) {
        if (starting) runtimeStarting.writeText("") else runtimeStarting.delete()
    }

    /** Blocking. Call off the main thread. Returns false if nothing could be unpacked. */
    @Synchronized
    fun ensure(context: Context): Boolean {
        if (isCurrent(context)) return true
        if (!isBundled(context)) {
            WSLog("server", "no server in this APK -- run tools/stage_server.sh before building")
            return false
        }
        val entries = context.assets.open("$ASSET_ROOT/MANIFEST.txt").bufferedReader().readLines()
            .mapNotNull(::parseEntry)
        val total = entries.sumOf { it.size }.coerceAtLeast(1)
        // What the last unpack left, by path: a file whose hash is unchanged in
        // this APK and that nobody touched since is moved into the new tree
        // instead of copied out of the APK again.
        val installed = readInstalled()
        val staging = File(Paths.root, "PythonServer.new")
        staging.deleteRecursively()
        staging.mkdirs()
        WSLog("server", "unpacking the server: ${entries.size} files, ${total / (1024 * 1024)} MB")
        var done = 0L
        var copied = 0L
        var lastShown = -1
        val buffer = ByteArray(256 * 1024)
        val record = StringBuilder()
        try {
            for (e in entries) {
                val out = File(staging, e.rel)
                out.parentFile?.mkdirs()
                if (!reuse(e, installed[e.rel], out)) {
                    context.assets.open("$ASSET_ROOT/${e.rel}").use { input ->
                        out.outputStream().use { output ->
                            while (true) {
                                val n = input.read(buffer)
                                if (n < 0) break
                                output.write(buffer, 0, n)
                            }
                        }
                    }
                    copied += e.size
                }
                if (e.sha1 != null) record.append("${e.size} ${e.sha1} ${out.lastModified()} ${e.rel}\n")
                done += e.size
                val pct = (done * 100 / total).toInt()
                if (pct != lastShown) {
                    lastShown = pct
                    _progress.value = Progress(done.toFloat() / total, "Unpacking the server… $pct%")
                }
            }
            File(staging, INSTALLED).writeText(record.toString())
            val old = File(Paths.root, "PythonServer.old")
            old.deleteRecursively()
            Paths.pythonServerDir.renameTo(old)
            if (!staging.renameTo(Paths.pythonServerDir)) error("could not move the server into place")
            old.deleteRecursively()
            File(Paths.pythonServerDir, ".stamp").writeText(stampFor(context))
            WSLog("server", "server unpacked: ${copied / (1024 * 1024)} MB copied, ${(total - copied) / (1024 * 1024)} MB unchanged and kept")
            return true
        } catch (e: Exception) {
            WSLog("server", "unpacking failed: ${e.message}")
            staging.deleteRecursively()
            return false
        } finally {
            _progress.value = null
        }
    }

    private const val INSTALLED = ".installed"

    /** sha1 is null for a MANIFEST.txt from before stage_server.sh wrote hashes. */
    private class Entry(val size: Long, val sha1: String?, val mtime: Long, val rel: String)

    /** "<bytes> <path>", "<bytes> <sha1> <path>" (APK) or "<bytes> <sha1> <mtime> <path>" (installed). */
    private fun parseEntry(line: String): Entry? {
        val parts = line.split(' ', limit = 4)
        val size = parts.getOrNull(0)?.toLongOrNull() ?: return null
        val hashed = parts.size >= 3 && parts[1].length == 40 && parts[1].all { it in "0123456789abcdef" }
        if (!hashed) return Entry(size, null, 0, line.substringAfter(' ').ifEmpty { return null })
        val mtime = if (parts.size == 4) parts[2].toLongOrNull() else null
        val rel = if (mtime != null) parts[3] else line.split(' ', limit = 3)[2]
        return Entry(size, parts[1], mtime ?: 0, rel)
    }

    private fun readInstalled(): Map<String, Entry> = try {
        File(Paths.pythonServerDir, INSTALLED).readLines().mapNotNull(::parseEntry).associateBy { it.rel }
    } catch (_: Exception) {
        emptyMap()
    }

    private fun reuse(e: Entry, was: Entry?, out: File): Boolean {
        if (e.sha1 == null || was == null || was.sha1 != e.sha1) return false
        val prev = File(Paths.pythonServerDir, e.rel)
        if (prev.length() != e.size || prev.lastModified() != was.mtime) return false
        // Moved, not linked: SELinux denies apps link() on their own files
        // (Android 9+), and the old tree is deleted after this anyway. If the
        // unpack fails half-way, the .stamp is still stale, so the next try
        // copies whatever is missing from the APK.
        return prev.renameTo(out)
    }
}
