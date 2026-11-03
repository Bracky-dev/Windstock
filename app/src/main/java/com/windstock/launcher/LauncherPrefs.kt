package com.windstock.launcher

import org.json.JSONArray
import org.json.JSONObject

/** Where the website packs and the site live. Mirrors Distribution in the iOS app. */
object Distribution {
    /**
     * The world-pack catalog players download countries from. Upload the
     * output of ios-launcher/tools/build_world_packs.py somewhere static and
     * put the catalog.json address here; empty makes World Data ask for it.
     */
    const val worldCatalogURL = ""
    /** The public Windstock server's "IP:port" pre-filled in Windstock Online (the Windstock VPS). */
    const val onlineAddress = "2.29.24.78:8888"
}

enum class ServerMode(val key: String) {
    EMBEDDED("embedded"),   // CPython inside this app
    REMOTE("remote"),       // a server on the PC / Mac / Tailscale
    ONLINE("online"),       // a Windstock server on the internet, by IP
    OFF("off");             // don't touch networking at all

    companion object {
        fun of(key: String?) = entries.firstOrNull { it.key == key } ?: EMBEDDED
    }
}

/**
 * Everything the launcher remembers between runs. The same keys as the iOS
 * launcher.json, minus what only exists there (signing, containers, the GPS
 * dylib), so one mental model covers both apps.
 *
 * Decoded key by key with the default for anything missing: a prefs file
 * written by an older build must still load. Adding a field means adding it to
 * both [fromJson] and [toJson].
 */
data class LauncherPrefs(
    val autoLaunch: Boolean = true,
    val autoLaunchDelay: Double = 2.0,
    /** The first run never auto-launches; see LauncherModel.start(). */
    val launchCount: Int = 0,

    val serverMode: ServerMode = ServerMode.ONLINE,
    val serverPort: Int = 8443,
    /** Plain-HTTP listener, for the client's http-patched SSO. */
    val serverPlainPort: Int = 8080,
    /** The World Manager (game editor). Not 8080: that is the plain listener's. */
    val gameEditorPort: Int = 8081,
    val startServerOnLaunch: Boolean = true,
    /** Only used when serverMode == REMOTE. */
    val remoteHost: String = "",
    /** A PC can bind the real ports, so a remote server needs no port rewrite. */
    val remotePort: Int = 443,
    val remotePlainPort: Int = 80,
    /**
     * Only used when serverMode == ONLINE: "203.0.113.7:8888". An IP, never a name -- no DNS
     * is involved. The port is the server's online_port (TLS only; the launcher's tunnel dials it).
     */
    val onlineAddress: String = Distribution.onlineAddress,

    /** Hostnames the game should reach on our server (the agent's redirect list). */
    val redirectHostnames: List<String> = listOf(
        "pgorelease.nianticlabs.com",
        "*.nianticlabs.com",
        "sso.pokemon.com",
        "*.pokemon.com",
        "pokemongo.zendesk.com",
        "*.zendesk.com",
    ),

    /**
     * Send the map's tile requests to the server on this phone (or the Online tunnel),
     * which fetches them from Google and swaps the mint "vegetation" shading the 2016
     * client paints solid -- otherwise whole cities draw as one park (gmm.py recolor).
     * Parks keep their own green. Same switch as iOS LauncherPrefs.recolorMapTiles.
     */
    val recolorMapTiles: Boolean = true,

    val worldCatalogURL: String = Distribution.worldCatalogURL,

    val notificationsEnabled: Boolean = true,
    val notifyServerState: Boolean = true,
    val notifyEggs: Boolean = true,
    val notifyLures: Boolean = true,
    /** Minutes of warning before a lure runs out. */
    val lureWarningMinutes: Int = 5,

    /** Load the windstock agent (mods) into the game. Off = stock client behaviour. */
    val injectMods: Boolean = true,

    /** Website leaderboard reporting. OFF until the player signs in and turns it on. */
    val reportStats: Boolean = false,
    val reportTrainer: String = "",
    val profileSiteURL: String = "",
    /** Shows the Windstock profile section; 7 taps on Version toggle it. */
    val profileUnlocked: Boolean = false,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("autoLaunch", autoLaunch)
        put("autoLaunchDelay", autoLaunchDelay)
        put("launchCount", launchCount)
        put("serverMode", serverMode.key)
        put("serverPort", serverPort)
        put("serverPlainPort", serverPlainPort)
        put("gameEditorPort", gameEditorPort)
        put("startServerOnLaunch", startServerOnLaunch)
        put("remoteHost", remoteHost)
        put("remotePort", remotePort)
        put("remotePlainPort", remotePlainPort)
        put("onlineAddress", onlineAddress)
        put("redirectHostnames", JSONArray(redirectHostnames))
        put("recolorMapTiles", recolorMapTiles)
        put("worldCatalogURL", worldCatalogURL)
        put("notificationsEnabled", notificationsEnabled)
        put("notifyServerState", notifyServerState)
        put("notifyEggs", notifyEggs)
        put("notifyLures", notifyLures)
        put("lureWarningMinutes", lureWarningMinutes)
        put("injectMods", injectMods)
        put("reportStats", reportStats)
        put("reportTrainer", reportTrainer)
        put("profileSiteURL", profileSiteURL)
        put("profileUnlocked", profileUnlocked)
    }

    companion object {
        /** The shortest autostart wait the Settings slider allows. */
        const val MIN_AUTO_LAUNCH_DELAY = 0.5

        fun fromJson(o: JSONObject): LauncherPrefs {
            val d = LauncherPrefs()
            fun b(k: String, f: Boolean) = if (o.has(k)) o.optBoolean(k, f) else f
            fun i(k: String, f: Int) = if (o.has(k)) o.optInt(k, f) else f
            fun n(k: String, f: Double) = if (o.has(k)) o.optDouble(k, f) else f
            fun s(k: String, f: String) = if (o.has(k)) o.optString(k, f) else f
            val hosts = o.optJSONArray("redirectHostnames")?.let { a ->
                (0 until a.length()).map { a.getString(it) }
            } ?: d.redirectHostnames
            return LauncherPrefs(
                autoLaunch = b("autoLaunch", d.autoLaunch),
                autoLaunchDelay = n("autoLaunchDelay", d.autoLaunchDelay).coerceAtLeast(MIN_AUTO_LAUNCH_DELAY),
                launchCount = i("launchCount", d.launchCount),
                serverMode = ServerMode.of(o.optString("serverMode", d.serverMode.key)),
                serverPort = i("serverPort", d.serverPort),
                serverPlainPort = i("serverPlainPort", d.serverPlainPort),
                gameEditorPort = i("gameEditorPort", d.gameEditorPort),
                startServerOnLaunch = b("startServerOnLaunch", d.startServerOnLaunch),
                remoteHost = s("remoteHost", d.remoteHost),
                remotePort = i("remotePort", d.remotePort),
                remotePlainPort = i("remotePlainPort", d.remotePlainPort),
                // Built in: a saved address from an older launcher is ignored.
                onlineAddress = d.onlineAddress,
                redirectHostnames = hosts,
                recolorMapTiles = b("recolorMapTiles", d.recolorMapTiles),
                worldCatalogURL = s("worldCatalogURL", d.worldCatalogURL),
                notificationsEnabled = b("notificationsEnabled", d.notificationsEnabled),
                notifyServerState = b("notifyServerState", d.notifyServerState),
                notifyEggs = b("notifyEggs", d.notifyEggs),
                notifyLures = b("notifyLures", d.notifyLures),
                lureWarningMinutes = i("lureWarningMinutes", d.lureWarningMinutes),
                injectMods = b("injectMods", d.injectMods),
                reportStats = b("reportStats", d.reportStats),
                reportTrainer = s("reportTrainer", d.reportTrainer),
                profileSiteURL = s("profileSiteURL", d.profileSiteURL),
                profileUnlocked = b("profileUnlocked", d.profileUnlocked),
            )
        }

        fun load(): LauncherPrefs {
            val f = Paths.prefsFile
            if (!f.exists()) return LauncherPrefs()
            return try {
                fromJson(JSONObject(f.readText()))
            } catch (e: Exception) {
                // A prefs file written by an older build shouldn't brick the app.
                WSLog("prefs", "could not read launcher.json (${e.message}) -- using defaults")
                LauncherPrefs()
            }
        }

        fun save(prefs: LauncherPrefs) {
            try {
                AtomicFile.write(Paths.prefsFile, prefs.toJson().toString(2))
            } catch (e: Exception) {
                WSLog("prefs", "could not save launcher.json: ${e.message}")
            }
        }
    }
}

/** A parsed Windstock Online address. Same rules as OnlineEndpoint in the iOS launcher. */
data class OnlineEndpoint(val host: String, val port: Int) {
    val display get() = "$host:$port"

    companion object {
        const val DEFAULT_PORT = 8888

        /** "ip" or "ip:port", optionally pasted with http:// and a path; null unless IPv4. */
        fun parse(text: String): OnlineEndpoint? {
            var t = text.trim().lowercase()
            for (scheme in listOf("http://", "https://")) if (t.startsWith(scheme)) t = t.removePrefix(scheme)
            t = t.substringBefore('/')
            val parts = t.split(':')
            if (parts.size !in 1..2) return null
            val octets = parts[0].split('.')
            if (octets.size != 4 || octets.any { o -> o.isEmpty() || o.length > 3 || !o.all { it.isDigit() } || o.toInt() > 255 }) return null
            val port = if (parts.size == 2) parts[1].toIntOrNull()?.takeIf { it in 1..65535 } ?: return null else DEFAULT_PORT
            return OnlineEndpoint(octets.joinToString(".") { it.toInt().toString() }, port)
        }
    }
}

/** The Windstock server. Built into the launcher; players can't change it. */
val LauncherPrefs.onlineEndpoint: OnlineEndpoint? get() = OnlineEndpoint.parse(Distribution.onlineAddress)

/** Write-to-temp-then-rename, so a reader never sees half a file. */
object AtomicFile {
    fun write(target: java.io.File, text: String) {
        target.parentFile?.mkdirs()
        val tmp = java.io.File(target.parentFile, ".${target.name}.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(target)) {
            target.delete()
            tmp.renameTo(target)
        }
    }
}
