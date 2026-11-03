package com.windstock.launcher.world

import com.windstock.launcher.AtomicFile
import com.windstock.launcher.Paths
import com.windstock.launcher.WSLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Locale

/** One downloadable country, as tools/build_world_packs.py writes it into catalog.json. */
data class WorldPack(
    val id: String, val name: String, val region: String, val file: String,
    val bytes: Long, val sha256: String, val forts: Int, val gyms: Int?,
    val biomes: Boolean?, val built: String?,
) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("name", name).put("region", region)
        .put("file", file).put("bytes", bytes).put("sha256", sha256).put("forts", forts)
        .put("gyms", gyms).put("biomes", biomes).put("built", built)

    companion object {
        fun from(o: JSONObject) = WorldPack(
            o.getString("id"), o.getString("name"), o.optString("region"), o.getString("file"),
            o.optLong("bytes"), o.optString("sha256"), o.optInt("forts"),
            if (o.has("gyms") && !o.isNull("gyms")) o.optInt("gyms") else null,
            if (o.has("biomes") && !o.isNull("biomes")) o.optBoolean("biomes") else null,
            if (o.has("built") && !o.isNull("built")) o.optString("built") else null)
    }
}

/** A pack on disk, whether or not the current catalog still lists it. */
data class InstalledPack(val id: String, val name: String, val sha256: String?, val bytes: Long, val bundled: Boolean)

sealed interface PackPhase {
    data class Downloading(val fraction: Float) : PackPhase
    data object Verifying : PackPhase
    data class Converting(val fraction: Float, val text: String) : PackPhase
    data class Failed(val message: String) : PackPhase
}

enum class PackStatus { NOT_INSTALLED, UP_TO_DATE, UPDATE_AVAILABLE }

/**
 * Downloads world packs into the server's data folder, where worlddb.py picks
 * them up on the next map request. A port of WorldPackStore.
 *
 * Files land as <data>/world/<id>.sqlite with a <id>.json sidecar holding the
 * catalog entry, so "update available" needs no re-hash of 100 MB. A download
 * goes to .part, is SHA-256 checked, then renamed over the old file: the server
 * opens packs read-only and immutable, so a pack must never change in place.
 */
object WorldPacks {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val jobs = mutableMapOf<String, Job>()

    private val _catalog = MutableStateFlow<List<WorldPack>>(emptyList())
    val catalog: StateFlow<List<WorldPack>> = _catalog
    private val _catalogError = MutableStateFlow<String?>(null)
    val catalogError: StateFlow<String?> = _catalogError
    private val _loading = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = _loading
    private val _installed = MutableStateFlow<Map<String, InstalledPack>>(emptyMap())
    val installed: StateFlow<Map<String, InstalledPack>> = _installed
    private val _phases = MutableStateFlow<Map<String, PackPhase>>(emptyMap())
    val phases: StateFlow<Map<String, PackPhase>> = _phases
    /** OSM imports running or failed: pack id -> display name. */
    private val _imports = MutableStateFlow<Map<String, String>>(emptyMap())
    val imports: StateFlow<Map<String, String>> = _imports

    private var catalogURL: URL? = null

    internal fun setPhase(id: String, phase: PackPhase?) =
        _phases.update { if (phase == null) it - id else it + (id to phase) }

    internal fun setImport(id: String, name: String?) =
        _imports.update { if (name == null) it - id else it + (id to name) }

    suspend fun loadCatalog(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            _catalog.value = emptyList(); _catalogError.value = null; return
        }
        val url = try { URL(trimmed) } catch (_: Exception) {
            _catalogError.value = "That isn't a URL."; return
        }
        _loading.value = true
        try {
            val body = withContext(Dispatchers.IO) {
                val c = url.openConnection() as HttpURLConnection
                c.useCaches = false
                c.connectTimeout = 15000
                c.readTimeout = 30000
                try {
                    if (c.responseCode != 200) throw IllegalStateException("The server answered ${c.responseCode}.")
                    c.inputStream.readBytes().decodeToString()
                } finally {
                    c.disconnect()
                }
            }
            val packs = try {
                val arr = JSONObject(body).getJSONArray("packs")
                (0 until arr.length()).map { WorldPack.from(arr.getJSONObject(it)) }
            } catch (_: Exception) {
                throw IllegalStateException("That file isn't a world catalog.")
            }
            _catalog.value = packs.sortedBy { it.name }
            catalogURL = url
            _catalogError.value = null
            WSLog("world", "catalog: ${packs.size} pack(s) from ${url.host}")
        } catch (e: Exception) {
            _catalogError.value = e.message
        } finally {
            _loading.value = false
        }
    }

    /** The catalog entry for the phone's own country, matched by English name. */
    val suggested: WorldPack?
        get() {
            val name = Locale.getDefault().getDisplayCountry(Locale.US)
            return _catalog.value.firstOrNull { it.name.equals(name, ignoreCase = true) }
        }

    fun rescan() {
        val found = mutableMapOf<String, InstalledPack>()
        for ((dir, bundled) in listOf(Paths.bundledWorldDir to true, Paths.worldDir to false)) {
            dir.listFiles { f -> f.extension == "sqlite" }?.forEach { f ->
                val id = f.nameWithoutExtension
                val entry = try { WorldPack.from(JSONObject(File(dir, "$id.json").readText())) } catch (_: Exception) { null }
                found[if (bundled) "bundled:$id" else id] = InstalledPack(
                    id, entry?.name ?: if (bundled) "Built-in world" else id, entry?.sha256, f.length(), bundled)
            }
        }
        _installed.value = found
    }

    fun status(pack: WorldPack): PackStatus {
        val have = _installed.value[pack.id] ?: return PackStatus.NOT_INSTALLED
        return if (have.sha256 == pack.sha256) PackStatus.UP_TO_DATE else PackStatus.UPDATE_AVAILABLE
    }

    val bundledPacks get() = _installed.value.values.filter { it.bundled }.sortedBy { it.name }

    /** Downloaded packs the catalog no longer lists -- still used, so still shown. */
    val orphans: List<InstalledPack>
        get() {
            val listed = _catalog.value.map { it.id }.toSet()
            return _installed.value.values.filter { !it.bundled && it.id !in listed }.sortedBy { it.name }
        }

    fun download(pack: WorldPack) {
        if (jobs[pack.id]?.isActive == true) return
        val base = catalogURL ?: run { setPhase(pack.id, PackPhase.Failed("Load the catalog first.")); return }
        val url = URL(base, pack.file)
        Paths.worldDir.mkdirs()
        val part = File(Paths.worldDir, "${pack.id}.sqlite.part")
        setPhase(pack.id, PackPhase.Downloading(0f))
        WSLog("world", "downloading ${pack.name} (${pack.bytes} bytes) from ${url.host}")
        jobs[pack.id] = scope.launch {
            try {
                withContext(Dispatchers.IO) { fetch(url, part) { setPhase(pack.id, PackPhase.Downloading(it)) } }
                setPhase(pack.id, PackPhase.Verifying)
                withContext(Dispatchers.IO) {
                    val digest = sha256(part)
                    if (!digest.equals(pack.sha256, ignoreCase = true)) {
                        part.delete()
                        throw IllegalStateException("The download was damaged (checksum mismatch). Try again.")
                    }
                    val dest = File(Paths.worldDir, "${pack.id}.sqlite")
                    dest.delete()
                    if (!part.renameTo(dest)) throw IllegalStateException("Could not move the pack into place.")
                    AtomicFile.write(File(Paths.worldDir, "${pack.id}.json"), pack.toJson().toString())
                }
                setPhase(pack.id, null)
                WSLog("world", "installed ${pack.name}: ${pack.forts} stops and gyms")
            } catch (e: kotlinx.coroutines.CancellationException) {
                part.delete()
                setPhase(pack.id, null)
            } catch (e: Exception) {
                part.delete()
                setPhase(pack.id, PackPhase.Failed(e.message ?: "Download failed."))
                WSLog("world", "${pack.name} failed: ${e.message}")
            } finally {
                jobs.remove(pack.id)
                rescan()
            }
        }
    }

    fun cancel(id: String) {
        jobs[id]?.cancel()
        OSMImport.cancel(id)
    }

    fun remove(id: String) {
        File(Paths.worldDir, "$id.sqlite").delete()
        File(Paths.worldDir, "$id.json").delete()
        WSLog("world", "removed $id")
        rescan()
    }

    fun clearImport(id: String) {
        if (jobs[id]?.isActive == true || OSMImport.isRunning(id)) return
        setPhase(id, null)
        setImport(id, null)
    }

    // ------------------------------------------------------------ helpers

    /** GET [url] into [dest], reporting 0..1. Throws on anything but 200. */
    internal suspend fun fetch(url: URL, dest: File, userAgent: String? = null, progress: (Float) -> Unit) {
        val c = url.openConnection() as HttpURLConnection
        c.connectTimeout = 20000
        c.readTimeout = 60000
        userAgent?.let { c.setRequestProperty("User-Agent", it) }
        try {
            if (c.responseCode != 200) throw IllegalStateException("The server answered ${c.responseCode}.")
            val total = c.contentLengthLong
            c.inputStream.use { input ->
                dest.outputStream().use { out ->
                    val buf = ByteArray(256 * 1024)
                    var done = 0L
                    var last = -1
                    while (kotlinx.coroutines.currentCoroutineContext().isActive) {
                        val n = input.read(buf)
                        if (n < 0) return
                        out.write(buf, 0, n)
                        done += n
                        if (total > 0) {
                            val pct = (done * 100 / total).toInt()
                            if (pct != last) { last = pct; progress(done.toFloat() / total) }
                        }
                    }
                    throw kotlinx.coroutines.CancellationException()
                }
            }
        } finally {
            c.disconnect()
        }
    }

    internal fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(1 shl 20)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
