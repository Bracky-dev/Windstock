package com.windstock.launcher.world

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import com.windstock.launcher.AtomicFile
import com.windstock.launcher.Paths
import com.windstock.launcher.WSLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.EOFException
import java.io.File
import java.io.InputStream
import java.net.URL
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.Inflater
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Turns a raw OpenStreetMap extract (.osm.pbf, e.g. from Geofabrik) into a
 * world pack, on the phone. A line-for-line port of OSMImport.swift, which is
 * itself the desktop pipeline (fetch_pois_pbf._extract + build_world_db.py)
 * with the rules copied, not approximated:
 *
 *   which features count   fetch_osm_pois.KEYS / BLOCK / _classify
 *   which ones are gyms    fetch_osm_pois._is_gym (LANDMARK, md5 % 6)
 *   where a way sits       centroid of its node locations; relations skipped
 *   the cell index         s2sphere CellId.from_lat_lng(...).parent(15)
 *   the file               build_world_db.build's schema and meta
 *
 * Two passes, because in a PBF the nodes come before the ways that use them.
 * The file is streamed, never loaded whole, so country extracts over 2 GB work.
 */
object OSMImport {
    data class Summary(val forts: Int, val gyms: Int, val scanned: Int)
    class Failure(message: String) : Exception(message)
    class Cancelled : Exception("cancelled")

    // Lazy, so the pure conversion below also runs in a JVM unit test.
    private val scope by lazy { CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate) }
    private val running = mutableMapOf<String, Pair<Job, AtomicBoolean>>()

    fun isRunning(id: String) = running[id]?.first?.isActive == true
    fun cancel(id: String) { running[id]?.let { it.second.set(true); it.first.cancel() } }

    // ------------------------------------------------------------ driving it

    /** Downloads an .osm.pbf, then converts it. */
    fun importFromUrl(context: Context, url: URL, name: String, region: String) {
        val id = packID(region.ifEmpty { name })
        if (isRunning(id)) return
        val local = File(context.cacheDir, "osm-import/$id.osm.pbf").apply { parentFile?.mkdirs() }
        WorldPacks.setImport(id, name)
        WorldPacks.setPhase(id, PackPhase.Downloading(0f))
        WSLog("world", "OSM import: downloading $name from ${url.host}")
        val flag = AtomicBoolean(false)
        running[id] = scope.launch {
            try {
                val source = withContext(Dispatchers.IO) {
                    val progress = { it: Float -> WorldPacks.setPhase(id, PackPhase.Downloading(it)) }
                    try {
                        WorldPacks.fetch(url, local, USER_AGENT, progress)
                        url
                    } catch (e: Exception) {
                        if (e is kotlinx.coroutines.CancellationException) throw e
                        val dated = datedExtract(url) ?: throw e
                        WSLog("world", "OSM import: ${e.message} -- using ${dated.path.substringAfterLast('/')}")
                        WorldPacks.fetch(dated, local, USER_AGENT, progress)
                        dated
                    }
                }
                convertInto(id, name, region, source.toString(), flag) { local.inputStream() to local.length() }
            } catch (e: Exception) {
                finish(id, name, e)
            } finally {
                local.delete()
                running.remove(id)
                WorldPacks.rescan()
            }
        } to flag
    }

    private const val USER_AGENT = "Windstock-launcher/1.0"
    private const val LATEST_SUFFIX = "-latest.osm.pbf"

    /**
     * Geofabrik's "-latest" alias sometimes disappears (the server then answers
     * with an endless redirect); this finds the newest dated copy
     * ("texas-261001.osm.pbf") from the last two weeks, or null. Blocking.
     */
    fun datedExtract(latest: URL): URL? {
        val text = latest.toString()
        if (!text.endsWith(LATEST_SUFFIX)) return null
        val stem = text.removeSuffix(LATEST_SUFFIX)
        val stamp = SimpleDateFormat("yyMMdd", Locale.US).apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
        for (daysAgo in 0 until 14) {
            val url = URL("$stem-${stamp.format(Date(System.currentTimeMillis() - daysAgo * 86400000L))}.osm.pbf")
            val c = url.openConnection() as java.net.HttpURLConnection
            try {
                c.requestMethod = "HEAD"
                c.instanceFollowRedirects = false   // a missing file redirects to itself
                c.connectTimeout = 10000
                c.readTimeout = 10000
                c.setRequestProperty("User-Agent", USER_AGENT)
                if (c.responseCode == 200) return url
            } catch (_: Exception) {
            } finally {
                c.disconnect()
            }
        }
        return null
    }

    /** Converts an .osm.pbf the user picked with the system file picker. */
    fun importFromUri(context: Context, uri: Uri) {
        val file = uri.lastPathSegment?.substringAfterLast('/') ?: "import.osm.pbf"
        val name = displayName(file)
        val id = packID(name)
        if (isRunning(id)) return
        WorldPacks.setImport(id, name)
        val size = context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
        val flag = AtomicBoolean(false)
        running[id] = scope.launch {
            try {
                convertInto(id, name, "", file, flag) {
                    (context.contentResolver.openInputStream(uri) ?: throw Failure("Could not open the file.")) to size
                }
            } catch (e: Exception) {
                finish(id, name, e)
            } finally {
                running.remove(id)
                WorldPacks.rescan()
            }
        } to flag
    }

    private suspend fun convertInto(id: String, name: String, region: String, source: String,
                                    flag: AtomicBoolean, open: () -> Pair<InputStream, Long>) {
        WorldPacks.setPhase(id, PackPhase.Converting(0f, "Starting…"))
        WSLog("world", "OSM import: converting $name")
        val dest = File(Paths.worldDir, "$id.sqlite")
        var lastSent = -1f
        val summary = withContext(Dispatchers.IO) {
            convert(open, dest, name, region, { fraction, text ->
                if (fraction - lastSent >= 0.01f || fraction >= 0.97f) {
                    lastSent = fraction
                    WorldPacks.setPhase(id, PackPhase.Converting(fraction, text))
                }
            }, { flag.get() })
        }
        withContext(Dispatchers.IO) {
            val pack = WorldPack(id, name, region, source, dest.length(), WorldPacks.sha256(dest),
                summary.forts, summary.gyms, false,
                SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).format(Date()))
            AtomicFile.write(File(Paths.worldDir, "$id.json"), pack.toJson().toString())
        }
        WSLog("world", "OSM import: $name -> ${summary.forts} stops and gyms (${summary.gyms} gyms) from ${summary.scanned} features")
        if (summary.forts == 0) {
            WorldPacks.remove(id)
            WorldPacks.setPhase(id, PackPhase.Failed("No stops or gyms found in that file."))
        } else {
            WorldPacks.setPhase(id, null)
            WorldPacks.setImport(id, null)
        }
    }

    private fun finish(id: String, name: String, e: Exception) {
        if (e is Cancelled || e is kotlinx.coroutines.CancellationException) {
            WorldPacks.setPhase(id, null)
            WorldPacks.setImport(id, null)
        } else {
            WSLog("world", "OSM import: $name failed: ${e.message}")
            WorldPacks.setPhase(id, PackPhase.Failed(e.message ?: "Import failed."))
        }
    }

    // ------------------------------------------------------------ naming

    /** "texas-latest.osm.pbf" -> "Texas". */
    fun displayName(file: String): String {
        var base = file
        for (suffix in listOf(".osm.pbf", ".pbf")) if (base.lowercase().endsWith(suffix)) { base = base.dropLast(suffix.length); break }
        base = base.removeSuffix("-latest")
        val name = base.split('-', '_').filter { it.isNotEmpty() }
            .joinToString(" ") { it.replaceFirstChar { c -> c.uppercase() } }
        return name.ifEmpty { "OpenStreetMap import" }
    }

    /** Kept apart from catalog ids so an import never overwrites a downloaded pack. */
    fun packID(key: String): String {
        val slug = key.lowercase().map { if (it.code < 128 && it.isLetterOrDigit()) it else '-' }.joinToString("")
        val collapsed = slug.split('-').filter { it.isNotEmpty() }.joinToString("-")
        return "osm-" + collapsed.ifEmpty { "import" }
    }

    fun isOSMExtract(text: String): Boolean = text.trim().lowercase().endsWith(".pbf")

    /** ".../north-america/us/texas-latest.osm.pbf" -> ("Texas", "north-america/us/texas") */
    fun nameAndRegion(url: URL): Pair<String, String> {
        val name = displayName(url.path.substringAfterLast('/'))
        var path = url.path.removePrefix("/")
        for (suffix in listOf("-latest.osm.pbf", ".osm.pbf", ".pbf")) if (path.endsWith(suffix)) { path = path.dropLast(suffix.length); break }
        return name to if (url.host == "download.geofabrik.de") path else ""
    }

    // ------------------------------------------------------------ POI rules

    val KEYS = listOf("amenity", "shop", "tourism", "leisure", "historic", "office", "craft", "club", "man_made")
    private val BLOCK = setOf(
        "parking", "parking_space", "parking_entrance", "bench", "waste_basket",
        "recycling", "bicycle_parking", "vending_machine", "drinking_water",
        "toilets", "fountain", "grit_bin", "hunting_stand", "shelter",
        "street_lamp", "clock", "telephone", "post_box", "atm", "bbq",
        "motorcycle_parking", "charging_station")
    private val LANDMARK = setOf(
        "stadium", "townhall", "park", "monument", "memorial", "museum",
        "castle", "attraction", "sports_centre", "recreation_ground")
    private const val GYM_EVERY = 6

    data class Fort(val id: String, val lat: Double, val lng: Double, val gym: Boolean, val name: String)

    /** _classify: (gym, name) or null to drop. */
    fun classify(oid: String, rawName: String?, values: List<String>): Pair<Boolean, String>? {
        val name = (rawName ?: "").trim()
        if (name.isEmpty()) return null
        val vals = values.filter { it.isNotEmpty() }.toSet()
        if (vals.any { it in BLOCK }) return null
        val gym = vals.any { it in LANDMARK } || md5Mod(oid, GYM_EVERY) == 0
        // Python's name[:40] counts code points.
        val cps = name.codePoints().limit(40).toArray()
        return gym to String(cps, 0, cps.size)
    }

    /** int(md5(s).hexdigest(), 16) % m, without a 128-bit integer. */
    fun md5Mod(s: String, m: Int): Int {
        var r = 0
        for (b in MessageDigest.getInstance("MD5").digest(s.toByteArray())) r = (r * 256 + (b.toInt() and 0xff)) % m
        return r
    }

    // ------------------------------------------------------------ conversion

    /** Reads the PBF (opened twice, one pass each), writes the pack to [out] via a temp file. */
    fun convert(open: () -> Pair<InputStream, Long>, out: File, name: String, region: String,
                progress: (Float, String) -> Unit, isCancelled: () -> Boolean): Summary {
        val (forts, scanned) = extract(open, progress, isCancelled)
        progress(0.97f, "Writing the pack…")
        PackWriter.write(forts, out, name, region)
        return Summary(forts.size, forts.count { it.gym }, scanned)
    }

    /** The two passes without the SQLite step: (forts, features scanned). */
    internal fun extract(open: () -> Pair<InputStream, Long>, progress: (Float, String) -> Unit = { _, _ -> },
                         isCancelled: () -> Boolean = { false }): Pair<List<Fort>, Int> {
        val ex = Extractor()
        ex.run(open, progress, isCancelled)
        return ex.forts to ex.scanned
    }

    /** A cursor over protobuf bytes; never reads past [end]. */
    class PB(val b: ByteArray, var p: Int, val end: Int) {
        val more get() = p < end
        val count get() = end - p
        fun varint(): Long {
            var result = 0L
            var shift = 0
            while (p < end) {
                val x = b[p++].toInt() and 0xff
                result = result or ((x and 0x7f).toLong() shl shift)
                if (x < 0x80) return result
                shift += 7
            }
            return result
        }
        fun sint(): Long { val v = varint(); return (v ushr 1) xor -(v and 1) }
        fun int(): Long = varint()
        fun tag(): Pair<Int, Int> { val t = varint(); return (t ushr 3).toInt() to (t and 7).toInt() }
        fun sub(): PB {
            val n = varint().toInt()
            val len = if (n < 0) count else minOf(n, count)
            val r = PB(b, p, p + len)
            p += len
            return r
        }
        fun skip(wire: Int) {
            when (wire) {
                0 -> varint()
                1 -> p = minOf(p + 8, end)
                2 -> { val n = varint().toInt(); p = if (n < 0) end else minOf(p + n, end) }
                5 -> p = minOf(p + 4, end)
                else -> p = end
            }
        }
        fun string(): String { val s = sub(); return String(b, s.p, s.count, Charsets.UTF_8) }
    }

    /** One decompressed block of the file and how far into the file it ends. */
    class Block(val type: String, val offset: Long, val raw: ByteArray)

    /** The blob stream: [4-byte length][BlobHeader][Blob] repeated. */
    private fun forEachBlock(input: InputStream, body: (Block) -> Boolean) {
        val s = BufferedInputStream(input, 1 shl 20)
        var pos = 0L
        val lenBuf = ByteArray(4)
        s.use {
            while (true) {
                if (!readFully(s, lenBuf, 4, allowEof = true)) return
                pos += 4
                val hlen = ((lenBuf[0].toInt() and 0xff) shl 24) or ((lenBuf[1].toInt() and 0xff) shl 16) or
                    ((lenBuf[2].toInt() and 0xff) shl 8) or (lenBuf[3].toInt() and 0xff)
                if (hlen <= 0 || hlen >= 64 * 1024) throw Failure("This isn't an .osm.pbf file (bad block header).")
                val hb = ByteArray(hlen)
                if (!readFully(s, hb, hlen)) throw Failure("The file is cut short -- was the download finished?")
                pos += hlen
                val header = PB(hb, 0, hlen)
                var type = ""
                var size = 0
                while (header.more) {
                    val (field, wire) = header.tag()
                    when {
                        field == 1 && wire == 2 -> type = header.string()
                        field == 3 && wire == 0 -> size = header.varint().toInt()
                        else -> header.skip(wire)
                    }
                }
                if (size < 0 || size > 64 * 1024 * 1024) throw Failure("This isn't an .osm.pbf file (bad block size).")
                val blob = ByteArray(size)
                if (!readFully(s, blob, size)) throw Failure("The file is cut short -- was the download finished?")
                pos += size
                if (!body(Block(type, pos, decodeBlob(blob)))) return
            }
        }
    }

    private fun readFully(s: InputStream, buf: ByteArray, n: Int, allowEof: Boolean = false): Boolean {
        var got = 0
        while (got < n) {
            val r = s.read(buf, got, n - got)
            if (r < 0) {
                if (got == 0 && allowEof) return false
                if (allowEof) throw EOFException()
                return false
            }
            got += r
        }
        return true
    }

    private fun decodeBlob(bytes: ByteArray): ByteArray {
        val blob = PB(bytes, 0, bytes.size)
        var rawSize = 0
        var plain: PB? = null
        var zlib: PB? = null
        while (blob.more) {
            val (field, wire) = blob.tag()
            when {
                field == 1 && wire == 2 -> plain = blob.sub()
                field == 2 && wire == 0 -> rawSize = blob.varint().toInt()
                field == 3 && wire == 2 -> zlib = blob.sub()
                wire == 2 && (field == 4 || field == 6 || field == 7) ->
                    throw Failure("This file uses a compression the app can't read (only zlib is supported, which Geofabrik uses).")
                else -> blob.skip(wire)
            }
        }
        plain?.let { return it.b.copyOfRange(it.p, it.end) }
        val z = zlib
        if (z == null || z.count <= 2 || rawSize <= 0 || rawSize >= 64 * 1024 * 1024) {
            throw Failure("This isn't an .osm.pbf file (empty block).")
        }
        val out = ByteArray(rawSize)
        val inf = Inflater()
        try {
            inf.setInput(z.b, z.p, z.count)
            var got = 0
            while (got < rawSize && !inf.finished()) {
                val n = inf.inflate(out, got, rawSize - got)
                if (n == 0 && (inf.needsInput() || inf.needsDictionary())) break
                got += n
            }
            if (got != rawSize) throw Failure("A block of the file is damaged -- try downloading it again.")
        } catch (e: java.util.zip.DataFormatException) {
            throw Failure("A block of the file is damaged -- try downloading it again.")
        } finally {
            inf.end()
        }
        return out
    }

    /** Open-addressing Long -> Long map; boxed HashMaps cost ~5x the memory at a million nodes. */
    class LongMap(capacity: Int = 1024) {
        private var keys = LongArray(tableSize(capacity))
        private var vals = LongArray(keys.size)
        private var used = BooleanArray(keys.size)
        var size = 0; private set

        private fun tableSize(n: Int): Int { var s = 16; while (s < n * 2) s = s shl 1; return s }
        private fun slot(k: Long, mask: Int): Int {
            var h = k * -0x61c8864680b583ebL
            h = h xor (h ushr 29)
            return (h.toInt()) and mask
        }
        fun put(k: Long, v: Long) {
            if ((size + 1) * 2 > keys.size) grow()
            val mask = keys.size - 1
            var i = slot(k, mask)
            while (used[i]) {
                if (keys[i] == k) { vals[i] = v; return }
                i = (i + 1) and mask
            }
            used[i] = true; keys[i] = k; vals[i] = v; size++
        }
        fun containsKey(k: Long): Boolean {
            val mask = keys.size - 1
            var i = slot(k, mask)
            while (used[i]) { if (keys[i] == k) return true; i = (i + 1) and mask }
            return false
        }
        fun get(k: Long): Long? {
            val mask = keys.size - 1
            var i = slot(k, mask)
            while (used[i]) { if (keys[i] == k) return vals[i]; i = (i + 1) and mask }
            return null
        }
        private fun grow() {
            val ok = keys; val ov = vals; val ou = used
            keys = LongArray(ok.size * 2); vals = LongArray(ok.size * 2); used = BooleanArray(ok.size * 2)
            size = 0
            for (i in ok.indices) if (ou[i]) put(ok[i], ov[i])
        }
    }

    private class BlockInfo {
        val strings = ArrayList<IntArray>()     // [offset, length] into raw
        val role = ArrayList<Int>()             // 0..8 = KEYS index, 9 = "name", -1 other
        var raw: ByteArray = ByteArray(0)
        var granularity = 100L
        var latOffset = 0L
        var lonOffset = 0L
        fun string(i: Int): String {
            if (i < 0 || i >= strings.size) return ""
            val (o, n) = strings[i].let { it[0] to it[1] }
            return String(raw, o, n, Charsets.UTF_8)
        }
        fun role(i: Int) = if (i >= 0 && i < role.size) role[i] else -1
        /** Fixed 1e-7 degrees, as osmium stores a Location. */
        fun fixedLat(v: Long) = (latOffset + granularity * v) / 100
        fun fixedLon(v: Long) = (lonOffset + granularity * v) / 100
    }

    private val keyBytes = KEYS.map { it.toByteArray() }
    private val nameBytes = "name".toByteArray()

    private fun roleOf(b: ByteArray, p: Int, n: Int): Int {
        fun eq(k: ByteArray): Boolean {
            if (k.size != n) return false
            for (i in 0 until n) if (b[p + i] != k[i]) return false
            return true
        }
        if (eq(nameBytes)) return 9
        keyBytes.forEachIndexed { i, k -> if (eq(k)) return i }
        return -1
    }

    private fun parseBlock(raw: ByteArray): Pair<BlockInfo, List<PB>> {
        val r = PB(raw, 0, raw.size)
        val info = BlockInfo().apply { this.raw = raw }
        val groups = ArrayList<PB>()
        while (r.more) {
            val (field, wire) = r.tag()
            when {
                field == 1 && wire == 2 -> {
                    val st = r.sub()
                    while (st.more) {
                        val (f, w) = st.tag()
                        if (f == 1 && w == 2) {
                            val s = st.sub()
                            info.strings.add(intArrayOf(s.p, s.count))
                            info.role.add(roleOf(raw, s.p, s.count))
                        } else st.skip(w)
                    }
                }
                field == 2 && wire == 2 -> groups.add(r.sub())
                field == 17 && wire == 0 -> info.granularity = r.int()
                field == 19 && wire == 0 -> info.latOffset = r.int()
                field == 20 && wire == 0 -> info.lonOffset = r.int()
                else -> r.skip(wire)
            }
        }
        return info to groups
    }

    private class PendingWay(val oid: String, val gym: Boolean, val name: String, val refs: LongArray)

    private class Extractor {
        val forts = ArrayList<Fort>()
        /** Features that carried one of KEYS -- what osmium's KeyFilter passes. */
        var scanned = 0
        private val ways = ArrayList<PendingWay>()
        private var needed = LongMap()
        private var located = LongMap()
        private var sortedByType = false

        fun run(open: () -> Pair<InputStream, Long>, progress: (Float, String) -> Unit, isCancelled: () -> Boolean) {
            var sawData = false
            var last = -1f
            val (in1, size) = open()
            val total = size.coerceAtLeast(1).toFloat()
            // Pass 1: tagged nodes and ways (0..55%).
            forEachBlock(in1) { block ->
                if (isCancelled()) throw Cancelled()
                val f = if (size > 0) block.offset / total else 0f
                if (f - last > 0.005f) { last = f; progress(f * 0.55f, "Reading places… ${forts.size + ways.size} found") }
                if (block.type == "OSMHeader") sortedByType = headerSaysSorted(block.raw)
                else if (block.type == "OSMData") { sawData = true; pass1(block.raw) }
                true
            }
            if (!sawData) throw Failure("This isn't an .osm.pbf file (no map data in it).")
            if (ways.isEmpty()) return

            // Pass 2: locations of the nodes the kept ways use.
            var need = 0
            needed = LongMap(ways.sumOf { it.refs.size })
            for (w in ways) for (r in w.refs) if (!needed.containsKey(r)) { needed.put(r, 0); need++ }
            located = LongMap(need)
            last = -1f
            val (in2, _) = open()
            forEachBlock(in2) { block ->
                if (isCancelled()) throw Cancelled()
                val f = if (size > 0) block.offset / total else 0f
                if (f - last > 0.005f) { last = f; progress(0.55f + f * 0.4f, "Placing parks and buildings…") }
                if (block.type != "OSMData") return@forEachBlock true
                val sawWays = pass2(block.raw)
                // Sorted files put every node before the first way.
                !(sortedByType && sawWays) && located.size < need
            }
            for (w in ways) {
                var lat = 0.0; var lng = 0.0; var n = 0
                for (ref in w.refs) {
                    val packed = located.get(ref) ?: continue
                    lat += (packed shr 32).toInt() / 1e7
                    lng += packed.toInt() / 1e7
                    n++
                }
                if (n == 0) continue
                forts.add(Fort("OSM" + w.oid, round7(lat / n), round7(lng / n), w.gym, w.name))
            }
            ways.clear()
        }

        /** Halves away from zero, like Swift's rounded() -- rint's half-to-even moved ~0.5% of centroids. */
        private fun round7(x: Double): Double {
            val y = x * 1e7
            return (if (y >= 0) floor(y + 0.5) else -floor(-y + 0.5)) / 1e7
        }

        private fun headerSaysSorted(raw: ByteArray): Boolean {
            val r = PB(raw, 0, raw.size)
            while (r.more) {
                val (field, wire) = r.tag()
                if (field == 5 && wire == 2) { if (r.string() == "Sort.Type_then_ID") return true } else r.skip(wire)
            }
            return false
        }

        private fun judge(oid: String, keys: IntArray, vals: IntArray, n: Int, info: BlockInfo): Pair<Boolean, String>? {
            var hasKey = false
            var name: String? = null
            val values = ArrayList<String>()
            for (i in 0 until n) {
                val role = info.role(keys[i])
                if (role == 9) name = info.string(vals[i])
                else if (role >= 0) { hasKey = true; values.add(info.string(vals[i])) }
            }
            if (!hasKey) return null
            return classify(oid, name, values)
        }

        private fun hasKey(keys: IntArray, n: Int, info: BlockInfo): Boolean {
            for (i in 0 until n) { val r = info.role(keys[i]); if (r in 0..8) return true }
            return false
        }

        private fun packed(r: PB): IntArray {
            val s = r.sub()
            val out = IntArrayBuilder()
            while (s.more) out.add(s.varint().toInt())
            return out.toArray()
        }

        private fun pass1(raw: ByteArray) {
            val (info, groups) = parseBlock(raw)
            // Nothing in this block names a KEYS key: no feature here can pass.
            if (info.role.none { it in 0..8 }) return
            for (g in groups) {
                while (g.more) {
                    val (field, wire) = g.tag()
                    when {
                        field == 1 && wire == 2 -> node(g.sub(), info)
                        field == 2 && wire == 2 -> dense(g.sub(), info)
                        field == 3 && wire == 2 -> way(g.sub(), info)
                        field == 4 && wire == 2 -> {
                            // Relations pass osmium's KeyFilter but have no location.
                            val rel = g.sub()
                            var keys = IntArray(0); var vals = IntArray(0)
                            while (rel.more) {
                                val (f, w) = rel.tag()
                                when {
                                    f == 2 && w == 2 -> keys = packed(rel)
                                    f == 3 && w == 2 -> vals = packed(rel)
                                    else -> rel.skip(w)
                                }
                            }
                            if (hasKey(keys, minOf(keys.size, vals.size), info)) scanned++
                        }
                        else -> g.skip(wire)
                    }
                }
            }
        }

        private fun node(r: PB, info: BlockInfo) {
            var id = 0L; var lat = 0L; var lon = 0L
            var keys = IntArray(0); var vals = IntArray(0)
            while (r.more) {
                val (field, wire) = r.tag()
                when {
                    field == 1 && wire == 0 -> id = r.sint()
                    field == 2 && wire == 2 -> keys = packed(r)
                    field == 3 && wire == 2 -> vals = packed(r)
                    field == 8 && wire == 0 -> lat = r.sint()
                    field == 9 && wire == 0 -> lon = r.sint()
                    else -> r.skip(wire)
                }
            }
            addNode(id, info.fixedLat(lat), info.fixedLon(lon), keys, vals, minOf(keys.size, vals.size), info)
        }

        private fun addNode(id: Long, lat: Long, lon: Long, keys: IntArray, vals: IntArray, n: Int, info: BlockInfo) {
            if (!hasKey(keys, n, info)) return
            scanned++
            val oid = "n$id"
            val (gym, name) = judge(oid, keys, vals, n, info) ?: return
            forts.add(Fort("OSM$oid", round7(lat / 1e7), round7(lon / 1e7), gym, name))
        }

        private fun deltas(r: PB): LongArray {
            val s = r.sub()
            val out = LongArrayBuilder()
            var acc = 0L
            while (s.more) { acc += s.sint(); out.add(acc) }
            return out.toArray()
        }

        private fun dense(r: PB, info: BlockInfo) {
            var ids = LongArray(0); var lats = LongArray(0); var lons = LongArray(0)
            var kv: PB? = null
            while (r.more) {
                val (field, wire) = r.tag()
                when {
                    field == 1 && wire == 2 -> ids = deltas(r)
                    field == 8 && wire == 2 -> lats = deltas(r)
                    field == 9 && wire == 2 -> lons = deltas(r)
                    field == 10 && wire == 2 -> kv = r.sub()
                    else -> r.skip(wire)
                }
            }
            val k = kv ?: return
            if (ids.size != lats.size || ids.size != lons.size) return
            // keys_vals: k v k v ... 0 per node, in node order.
            val keys = IntArrayBuilder(); val vals = IntArrayBuilder()
            var i = 0
            while (k.more && i < ids.size) {
                val key = k.varint().toInt()
                if (key == 0) {
                    if (keys.size > 0) {
                        addNode(ids[i], info.fixedLat(lats[i]), info.fixedLon(lons[i]),
                            keys.array, vals.array, keys.size, info)
                        keys.clear(); vals.clear()
                    }
                    i++
                } else {
                    keys.add(key); vals.add(k.varint().toInt())
                }
            }
        }

        private fun way(r: PB, info: BlockInfo) {
            var id = 0L
            var keys = IntArray(0); var vals = IntArray(0)
            var refs: PB? = null
            while (r.more) {
                val (field, wire) = r.tag()
                when {
                    field == 1 && wire == 0 -> id = r.int()
                    field == 2 && wire == 2 -> keys = packed(r)
                    field == 3 && wire == 2 -> vals = packed(r)
                    field == 8 && wire == 2 -> refs = r.sub()
                    else -> r.skip(wire)
                }
            }
            val n = minOf(keys.size, vals.size)
            if (!hasKey(keys, n, info)) return
            scanned++
            val oid = "w$id"
            val (gym, name) = judge(oid, keys, vals, n, info) ?: return
            val rr = refs ?: return
            val list = LongArrayBuilder()
            var acc = 0L
            while (rr.more) { acc += rr.sint(); list.add(acc) }
            if (list.size == 0) return
            ways.add(PendingWay(oid, gym, name, list.toArray()))
        }

        /** Records needed node locations. True if the block had ways or relations. */
        private fun pass2(raw: ByteArray): Boolean {
            val (info, groups) = parseBlock(raw)
            var sawWays = false
            fun record(id: Long, lat: Long, lon: Long) {
                if (needed.containsKey(id)) {
                    located.put(id, (info.fixedLat(lat) shl 32) or (info.fixedLon(lon) and 0xffffffffL))
                }
            }
            for (g in groups) {
                while (g.more) {
                    val (field, wire) = g.tag()
                    when {
                        field == 1 && wire == 2 -> {
                            val r = g.sub()
                            var id = 0L; var lat = 0L; var lon = 0L
                            while (r.more) {
                                val (f, w) = r.tag()
                                when {
                                    f == 1 && w == 0 -> id = r.sint()
                                    f == 8 && w == 0 -> lat = r.sint()
                                    f == 9 && w == 0 -> lon = r.sint()
                                    else -> r.skip(w)
                                }
                            }
                            record(id, lat, lon)
                        }
                        field == 2 && wire == 2 -> {
                            val r = g.sub()
                            var ids: PB? = null; var lats: PB? = null; var lons: PB? = null
                            while (r.more) {
                                val (f, w) = r.tag()
                                when {
                                    f == 1 && w == 2 -> ids = r.sub()
                                    f == 8 && w == 2 -> lats = r.sub()
                                    f == 9 && w == 2 -> lons = r.sub()
                                    else -> r.skip(w)
                                }
                            }
                            if (ids != null && lats != null && lons != null) {
                                var id = 0L; var lat = 0L; var lon = 0L
                                while (ids.more && lats.more && lons.more) {
                                    id += ids.sint(); lat += lats.sint(); lon += lons.sint()
                                    record(id, lat, lon)
                                }
                            }
                        }
                        (field == 3 || field == 4) && wire == 2 -> { sawWays = true; g.skip(wire) }
                        else -> g.skip(wire)
                    }
                }
            }
            return sawWays
        }
    }

    private class IntArrayBuilder(cap: Int = 16) {
        var array = IntArray(cap); var size = 0
        fun add(v: Int) { if (size == array.size) array = array.copyOf(size * 2); array[size++] = v }
        fun clear() { size = 0 }
        fun toArray() = array.copyOf(size)
    }

    private class LongArrayBuilder(cap: Int = 16) {
        var array = LongArray(cap); var size = 0
        fun add(v: Long) { if (size == array.size) array = array.copyOf(size * 2); array[size++] = v }
        fun toArray() = array.copyOf(size)
    }
}

/** s2sphere's CellId.from_lat_lng(...).parent(level), quadratic projection. */
object S2Cell {
    private const val LOOKUP_BITS = 4
    private const val SWAP = 1
    private const val INVERT = 2
    private const val MAX_LEVEL = 30
    private val posToIJ = arrayOf(intArrayOf(0, 1, 3, 2), intArrayOf(0, 2, 3, 1), intArrayOf(3, 2, 0, 1), intArrayOf(3, 1, 0, 2))
    private val posToOrientation = intArrayOf(1, 0, 0, 3)

    private val lookupPos: IntArray by lazy {
        val table = IntArray(1 shl (2 * LOOKUP_BITS + 2))
        fun fill(level: Int, i: Int, j: Int, orig: Int, pos: Int, orientation: Int) {
            if (level == LOOKUP_BITS) {
                val ij = (i shl LOOKUP_BITS) + j
                table[(ij shl 2) + orig] = (pos shl 2) + orientation
                return
            }
            val r = posToIJ[orientation]
            for (index in 0 until 4) {
                fill(level + 1, (i shl 1) + (r[index] shr 1), (j shl 1) + (r[index] and 1),
                    orig, (pos shl 2) + index, orientation xor posToOrientation[index])
            }
        }
        for (o in intArrayOf(0, SWAP, INVERT, SWAP or INVERT)) fill(0, 0, 0, o, 0, o)
        table
    }

    /** The level-[level] cell containing (lat, lng), as signed 64-bit (build_world_db.s64). */
    fun id(lat: Double, lng: Double, level: Int = 15): Long {
        val phi = Math.toRadians(lat)
        val theta = Math.toRadians(lng)
        val cosphi = cos(phi)
        val x = cos(theta) * cosphi; val y = sin(theta) * cosphi; val z = sin(phi)
        val ax = abs(x); val ay = abs(y); val az = abs(z)
        var face = if (ax > ay) (if (ax > az) 0 else 2) else (if (ay > az) 1 else 2)
        if (doubleArrayOf(x, y, z)[face] < 0) face += 3
        val (u, v) = when (face) {
            0 -> y / x to z / x
            1 -> -x / y to z / y
            2 -> -x / z to -y / z
            3 -> z / x to y / x
            4 -> z / y to -x / y
            else -> -y / z to -x / z
        }
        val i = stToIJ(uvToST(u)); val j = stToIJ(uvToST(v))
        var n = face.toLong() shl (2 * MAX_LEVEL)
        var bits = face and SWAP
        val mask = (1 shl LOOKUP_BITS) - 1
        for (k in 7 downTo 0) {
            bits += ((i shr (k * LOOKUP_BITS)) and mask) shl (LOOKUP_BITS + 2)
            bits += ((j shr (k * LOOKUP_BITS)) and mask) shl 2
            bits = lookupPos[bits]
            n = n or ((bits shr 2).toLong() shl (k * 2 * LOOKUP_BITS))
            bits = bits and (SWAP or INVERT)
        }
        val leaf = n * 2 + 1
        val lsb = 1L shl (2 * (MAX_LEVEL - level))
        return (leaf and -lsb) or lsb
    }

    private fun uvToST(u: Double) = if (u >= 0) 0.5 * sqrt(1 + 3 * u) else 1 - 0.5 * sqrt(1 - 3 * u)
    private fun stToIJ(s: Double): Int {
        val size = 1 shl MAX_LEVEL
        return floor(size * s).toInt().coerceIn(0, size - 1)
    }
}

/** The pack file, exactly as tools/build_world_db.py writes it. */
object PackWriter {
    fun write(forts: List<OSMImport.Fort>, out: File, name: String, region: String) {
        out.parentFile?.mkdirs()
        val tmp = File(out.path + ".tmp")
        tmp.delete()
        // NO_LOCALIZED_COLLATORS: otherwise Android adds its android_metadata
        // table, and the file would differ from a Mac-built pack.
        val db = SQLiteDatabase.openDatabase(tmp.path, null,
            SQLiteDatabase.CREATE_IF_NECESSARY or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
        try {
            db.disableWriteAheadLogging()
            db.execSQL("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
            db.execSQL("CREATE TABLE forts (cell INTEGER NOT NULL, id TEXT, lat REAL, lng REAL, kind INTEGER, name TEXT, image TEXT)")
            db.execSQL("CREATE TABLE biome_cells (cell INTEGER PRIMARY KEY, biome TEXT) WITHOUT ROWID")
            db.beginTransaction()
            try {
                val st = db.compileStatement("INSERT INTO forts VALUES (?,?,?,?,?,?,NULL)")
                for (f in forts) {
                    st.bindLong(1, S2Cell.id(f.lat, f.lng))
                    st.bindString(2, f.id)
                    st.bindDouble(3, f.lat)
                    st.bindDouble(4, f.lng)
                    st.bindLong(5, if (f.gym) 1 else 0)
                    st.bindString(6, f.name)
                    st.executeInsert()
                    st.clearBindings()
                }
                st.close()
                db.execSQL("CREATE INDEX forts_cell ON forts(cell)")
                val built = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
                for ((k, v) in listOf(
                    "name" to name, "region" to region, "fort_count" to forts.size.toString(),
                    "biome_count" to "0", "biome_level" to "12", "terrain_points" to "[]",
                    "built" to built, "source" to "osm.pbf, converted on device")) {
                    db.insert("meta", null, ContentValues().apply { put("key", k); put("value", v) })
                }
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
            db.execSQL("VACUUM")
        } catch (e: Exception) {
            throw OSMImport.Failure("Writing the pack failed: ${e.message}")
        } finally {
            db.close()
        }
        // Android's SQLite may leave a journal beside it; the server opens packs immutable.
        File(tmp.path + "-journal").delete()
        // The server opens packs immutable: replace, never rewrite in place.
        out.delete()
        if (!tmp.renameTo(out)) throw OSMImport.Failure("Could not move the pack into place.")
    }
}
