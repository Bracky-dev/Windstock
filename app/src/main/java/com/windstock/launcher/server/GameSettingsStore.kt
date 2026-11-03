package com.windstock.launcher.server

import android.os.Handler
import android.os.Looper
import com.windstock.launcher.AtomicFile
import com.windstock.launcher.Paths
import com.windstock.launcher.WSLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The server's settings.json, edited in the app. A port of GameSettings.swift.
 *
 * Read and written straight off disk, so it works with the server stopped, and
 * the running server picks changes up by itself (settings.py re-reads the file
 * when its mtime changes). Driven by the file's own JSON types rather than a
 * hand-written screen, so a key added on the server shows up with no app change.
 */
object GameSettingsStore {
    private val main = Handler(Looper.getMainLooper())
    private var root = JSONObject()
    private var help: Map<String, String> = emptyMap()
    private val saveTask = Runnable { save() }

    private val _sections = MutableStateFlow<List<String>>(emptyList())
    val sections: StateFlow<List<String>> = _sections
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error
    /** Bumped on every change so screens redraw; the values live in [root]. */
    private val _revision = MutableStateFlow(0)
    val revision: StateFlow<Int> = _revision

    fun reload() {
        if (help.isEmpty()) loadHelp()
        val f = Paths.settingsFile
        if (!f.exists()) {
            _error.value = "No settings yet — start the server once."
            _sections.value = emptyList()
            return
        }
        try {
            root = JSONObject(f.readText())
            // "_readme" and friends are the file's own documentation.
            _sections.value = root.keys().asSequence()
                .filter { !it.startsWith("_") && root.opt(it) is JSONObject }
                .sorted().toList()
            _error.value = null
            _revision.value++
        } catch (e: Exception) {
            _error.value = e.message
        }
    }

    private fun loadHelp() {
        val f = File(Paths.pythonServerDir, "settings_help.json")
        help = try {
            val o = JSONObject(f.readText())
            o.keys().asSequence().associateWith { o.getString(it) }
        } catch (_: Exception) {
            emptyMap()
        }
    }

    /** What this setting does, if the server documents it. */
    fun explanation(path: List<String>): String? =
        if (path.size >= 2) help["${path[0]}.${path[1]}"] else null

    fun keys(path: List<String>): List<String> {
        val node = value(path) as? JSONObject ?: return emptyList()
        return node.keys().asSequence().filter { !it.startsWith("_") }.sorted().toList()
    }

    fun value(path: List<String>): Any? {
        var node: Any? = root
        for (step in path) node = (node as? JSONObject)?.opt(step) ?: return null
        return node
    }

    fun set(path: List<String>, newValue: Any) {
        if (path.isEmpty()) return
        var node: JSONObject = root
        for (step in path.dropLast(1)) node = node.optJSONObject(step) ?: return
        node.put(path.last(), newValue)
        _revision.value++
        // Typing fires a change per keystroke; don't have the server re-read
        // the file that often.
        main.removeCallbacks(saveTask)
        main.postDelayed(saveTask, 600)
    }

    fun save() {
        try {
            // Atomic: the server may read this at any moment, and a half-written
            // settings.json would be parsed as "no settings".
            AtomicFile.write(Paths.settingsFile, root.toString(2))
            _error.value = null
            WSLog("settings", "saved settings.json")
        } catch (e: Exception) {
            _error.value = "Could not save: ${e.message}"
        }
    }

    /** One value straight off disk, for screens that don't keep the store open. */
    fun readValue(section: String, key: String): Any? = try {
        JSONObject(Paths.settingsFile.readText()).optJSONObject(section)?.opt(key)
    } catch (_: Exception) {
        null
    }

    /**
     * Read-modify-write of one value, so it can't clobber an edit made on the
     * Server tab since that screen loaded. False when there is no settings.json
     * yet: the server has never run.
     */
    fun writeValue(section: String, key: String, value: Any): Boolean {
        return try {
            val obj = JSONObject(Paths.settingsFile.readText())
            val sec = obj.optJSONObject(section) ?: JSONObject().also { obj.put(section, it) }
            sec.put(key, value)
            AtomicFile.write(Paths.settingsFile, obj.toString(2))
            WSLog("settings", "saved $section.$key")
            if (root.length() > 0) reload()
            true
        } catch (e: Exception) {
            false
        }
    }

    /** "xp_per_catch" -> "XP per catch", "min_cp" -> "Min CP". */
    fun label(key: String): String {
        val acronyms = setOf("xp", "cp", "iv", "ivs", "hp", "km", "m", "ms", "id", "url")
        return key.split('_').mapIndexed { i, w ->
            when {
                w.lowercase() in acronyms -> w.uppercase()
                i == 0 -> w.replaceFirstChar { it.uppercase() }
                else -> w
            }
        }.joinToString(" ")
    }

    /** Keep a list the same shape it was: numbers stay numbers. */
    fun parseList(text: String, like: JSONArray): JSONArray {
        val parts = text.split(',').map { it.trim() }.filter { it.isNotEmpty() }
        val numeric = (0 until like.length()).all { like.opt(it) is Number }
        if (!numeric) return JSONArray(parts)
        return JSONArray(parts.mapNotNull { it.toIntOrNull() ?: it.toDoubleOrNull() })
    }
}
