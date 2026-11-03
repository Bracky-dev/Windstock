package com.windstock.launcher

import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL

/**
 * Launcher news for the Play screen (a port of WindstockNews in WindstockProfile.swift):
 * the short, player-worded "what's new" an admin posts on the website's admin page
 * (GET /api/news). The last answer is kept on disk so the card shows offline too.
 */
object WindstockNews {
    data class Item(val id: String, val at: Long, val title: String, val body: String)

    private val _items = MutableStateFlow<List<Item>>(emptyList())
    val items: StateFlow<List<Item>> = _items
    /** The newest item the player has seen (its `at`); newer ones are marked New. */
    private val _seenAt = MutableStateFlow(0L)
    val seenAt: StateFlow<Long> = _seenAt

    private val cacheFile get() = File(Paths.root, "news.json")
    private val seenFile get() = File(Paths.root, "news-seen.txt")
    private var fetchedAt = 0L
    private var loaded = false

    private fun parse(arr: JSONArray?): List<Item> {
        if (arr == null) return emptyList()
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val id = o.optString("id"); val title = o.optString("title"); val body = o.optString("body")
            if (id.isEmpty() || title.isEmpty()) null else Item(id, o.optLong("at"), title, body)
        }.sortedByDescending { it.at }
    }

    private fun loadCache() {
        if (loaded) return
        loaded = true
        try { _items.value = parse(JSONArray(cacheFile.readText())) } catch (_: Exception) {}
        _seenAt.value = try { seenFile.readText().trim().toLong() } catch (_: Exception) { 0L }
    }

    private fun saveSeen(at: Long) {
        _seenAt.value = at
        try { seenFile.writeText(at.toString()) } catch (_: Exception) {}
    }

    fun isNew(item: Item) = item.at > _seenAt.value

    /** The player has looked at the list: nothing is New any more. */
    fun markSeen() {
        val newest = _items.value.maxOfOrNull { it.at } ?: return
        if (newest > _seenAt.value) saveSeen(newest)
    }

    /** Asks the website, at most every few minutes. A failure keeps what we had. */
    fun refresh(force: Boolean = false) {
        loadCache()
        val now = System.currentTimeMillis()
        if (!force && now - fetchedAt < 300_000) return
        fetchedAt = now
        Launcher.scope.launch {
            val fresh = withContext(Dispatchers.IO) {
                try {
                    val c = URL(WindstockProfile.siteURL + "/api/news").openConnection() as HttpURLConnection
                    c.connectTimeout = 10000
                    c.readTimeout = 10000
                    c.useCaches = false
                    val ok = c.responseCode == 200
                    val text = if (ok) c.inputStream.use { it.readBytes().decodeToString() } else ""
                    c.disconnect()
                    if (!ok) null else JSONObject(text).optJSONArray("items")
                } catch (_: Exception) {
                    null
                }
            } ?: return@launch
            val list = parse(fresh)
            if (list != _items.value) {
                _items.value = list
                try {
                    cacheFile.writeText(JSONArray(list.map {
                        JSONObject().put("id", it.id).put("at", it.at).put("title", it.title).put("body", it.body)
                    }).toString())
                } catch (_: Exception) {}
            }
            // A first install has seen nothing: only the newest counts as New, not the whole history.
            if (_seenAt.value == 0L && list.size > 1) saveSeen(list[1].at)
        }
    }
}

/**
 * "Report a problem" (ProblemReport in LogExport.swift): what went wrong plus the
 * launcher log -- which carries the game agent's lines too -- redacted like "Send the
 * log", straight to the website (POST /api/report), where an admin reads it.
 */
object ProblemReport {
    /** The newest [maxBytes] of a text file, cut at a line start. */
    fun tail(file: File, maxBytes: Int): String? = try {
        RandomAccessFile(file, "r").use { f ->
            val start = maxOf(0L, f.length() - maxBytes)
            f.seek(start)
            val buf = ByteArray((f.length() - start).toInt())
            f.readFully(buf)
            var text = buf.decodeToString()
            if (start > 0) text.indexOf('\n').takeIf { it >= 0 }?.let { text = text.substring(it + 1) }
            text
        }
    } catch (_: Exception) {
        null
    }

    fun logs(): String {
        val t = tail(File(Paths.logsDir, "launcher.log"), 1_200_000) ?: return ""
        return "==== launcher.log (launcher + game agent) ====\n" + LogExport.redact(t) + "\n"
    }

    class Failed(message: String) : Exception(message)

    /** Sends it; returns the report's short id or throws [Failed] with a message to show. */
    suspend fun send(what: String, contact: String, includeLogs: Boolean): String = withContext(Dispatchers.IO) {
        val p = Launcher.prefs.value
        val body = JSONObject()
            .put("what", what).put("contact", contact).put("platform", "android")
            .put("app", "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
            .put("device", "${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            .put("trainer", WindstockProfile.trainer.value ?: "")
            .put("server", p.serverMode.name.lowercase())
        if (includeLogs) body.put("log", logs())
        val bytes = body.toString().toByteArray()
        val (status, json) = try {
            val c = URL(WindstockProfile.siteURL + "/api/report").openConnection() as HttpURLConnection
            c.connectTimeout = 15000
            c.readTimeout = 30000
            c.requestMethod = "POST"
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            c.setFixedLengthStreamingMode(bytes.size)
            c.outputStream.use { it.write(bytes) }
            val code = c.responseCode
            val text = (if (code >= 400) c.errorStream else c.inputStream)?.use { it.readBytes().decodeToString() } ?: ""
            c.disconnect()
            code to (try { JSONObject(text) } catch (_: Exception) { JSONObject() })
        } catch (_: Exception) {
            throw Failed("Couldn't reach windstock.org. Check your connection and try again.")
        }
        if (status != 200 || !json.optBoolean("ok"))
            throw Failed(json.optString("error").ifEmpty { "The website didn't take the report. Try again later." })
        json.optString("id")
    }
}
