package com.windstock.launcher

import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The launcher log: one ring of recent lines for the screens, plus a file that
 * survives the process, which is what Settings > Testing sends.
 *
 * Same line format as the iOS WSLog ("12:34:56.789 [tag] message"), so a log
 * from either platform reads the same and the server-side filters (the Server
 * tab shows only "[server]" lines) carry over unchanged.
 */
object WSLog {
    private const val MAX_LINES = 2000
    private val lines = ArrayDeque<String>(MAX_LINES)
    private var file: FileOutputStream? = null
    private val stamp = ThreadLocal.withInitial { SimpleDateFormat("HH:mm:ss.SSS", Locale.US) }

    /** Bumped on every append; screens throttle on it rather than on the list. */
    private val _revision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = _revision

    fun open(logsDir: File) {
        synchronized(this) {
            if (file != null) return
            logsDir.mkdirs()
            val path = File(logsDir, "launcher.log")
            // Keep one previous run around; a crash loop otherwise erases the evidence.
            if (path.length() > 4L * 1024 * 1024) {
                val old = File(logsDir, "launcher.previous.log")
                old.delete()
                path.renameTo(old)
            }
            file = try { FileOutputStream(path, true) } catch (e: Exception) { null }
        }
    }

    operator fun invoke(tag: String, message: String) {
        val line = "${stamp.get()!!.format(Date())} [$tag] $message"
        Log.i("Windstock", "[$tag] $message")
        synchronized(this) {
            if (lines.size >= MAX_LINES) lines.removeFirst()
            lines.addLast(line)
            try {
                file?.write((line + "\n").toByteArray())
            } catch (_: Exception) {
                // disk full; keep going
            }
        }
        _revision.value = _revision.value + 1
    }

    fun lines(): List<String> = synchronized(this) { lines.toList() }

    fun clear() {
        synchronized(this) { lines.clear() }
        _revision.value = _revision.value + 1
    }
}
