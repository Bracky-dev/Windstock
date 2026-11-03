package com.windstock.launcher

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.windstock.launcher.game.GameInstaller
import com.windstock.launcher.mods.ModsConfig
import com.windstock.launcher.server.PythonServer
import com.windstock.launcher.server.ServerService
import com.windstock.launcher.server.ServerState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * The one object the UI talks to: prefs, mods, the embedded server and the
 * auto-launch countdown. The Android counterpart of LauncherModel.swift.
 *
 * A process-wide object rather than a ViewModel, because two things outside
 * any screen need it: ConfigProvider (the game asks it for its config, and
 * may be what woke this process up) and ServerService.
 */
object Launcher {
    /** Google Mobile Maps, where the game's map tiles come from (see recolorMapTiles). */
    const val MAP_TILE_HOST = "mobilemaps.clients.google.com"

    lateinit var app: Context
        private set

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val main = Handler(Looper.getMainLooper())

    private val _prefs = MutableStateFlow(LauncherPrefs())
    val prefs: StateFlow<LauncherPrefs> = _prefs
    private val _mods = MutableStateFlow(ModsConfig.defaults)
    val mods: StateFlow<ModsConfig> = _mods

    /** Seconds left before the game starts on its own; null when not counting. */
    private val _countdown = MutableStateFlow<Double?>(null)
    val countdown: StateFlow<Double?> = _countdown
    private val _launchError = MutableStateFlow<String?>(null)
    val launchError: StateFlow<String?> = _launchError
    /** Set when the Windstock server needs a newer launcher (server settings
     *  launcher.min_build, compared by tunnel.py): Play opens this page instead. */
    private val _updateUrl = MutableStateFlow<String?>(null)
    val updateUrl: StateFlow<String?> = _updateUrl

    private var countdownTick: Runnable? = null
    private var started = false
    private var initialised = false

    /**
     * Idempotent: Application.onCreate calls it, and so does ConfigProvider,
     * whose binder calls can arrive before Application.onCreate has finished.
     */
    @Synchronized
    fun init(context: Context) {
        if (initialised) return
        initialised = true
        app = context.applicationContext
        Paths.init(app)
        WSLog.open(Paths.logsDir)
        _prefs.value = LauncherPrefs.load()
        _mods.value = ModsConfig.load()
        // Write both out on first run so the files exist for the provider.
        LauncherPrefs.save(_prefs.value)
        ModsConfig.save(_mods.value)
        Notifier.init(app)
        Notifier.update(_prefs.value)

        scope.launch {
            var last: ServerState? = null
            PythonServer.state.collect { s ->
                if (last != null && s != last) Notifier.serverStateChanged(s, PythonServer.error.value)
                last = s
            }
        }
    }

    // ------------------------------------------------------------ prefs / mods

    fun updatePrefs(change: (LauncherPrefs) -> LauncherPrefs) {
        val old = _prefs.value
        val new = change(old)
        if (new == old) return
        _prefs.value = new
        LauncherPrefs.save(new)
        Notifier.update(new)
        if (new.serverMode != old.serverMode ||
            (new.serverMode == ServerMode.ONLINE && new.onlineEndpoint != old.onlineEndpoint)) {
            serverModeChanged(old.serverMode, new)
        }
        if (new.serverMode != old.serverMode || new.onlineEndpoint != old.onlineEndpoint) {
            WindstockProfile.refresh()
        }
    }

    fun updateMods(change: (ModsConfig) -> ModsConfig) {
        val new = change(_mods.value)
        if (new == _mods.value) return
        _mods.value = new
        ModsConfig.save(new)
    }

    // ------------------------------------------------------------ startup

    /** Called once from MainActivity, after the first frame. */
    fun start(context: Context) {
        if (started) return
        started = true
        WSLog("launcher", "Windstock ${BuildConfig.VERSION_NAME} on Android ${android.os.Build.VERSION.RELEASE} (${android.os.Build.MODEL})")
        val p = _prefs.value
        if ((p.serverMode == ServerMode.EMBEDDED && p.startServerOnLaunch) ||
            p.serverMode == ServerMode.ONLINE) startServer(context)
        if (p.serverMode == ServerMode.ONLINE) checkForUpdate()
        WindstockProfile.start()
        WindstockNews.refresh()

        // The first run never auto-launches: landing straight in the game
        // before the game is installed or the certificate trusted is no use.
        updatePrefs { it.copy(launchCount = it.launchCount + 1) }
        val q = _prefs.value
        when {
            q.autoLaunch && canPlay && q.launchCount >= 2 -> beginCountdown()
            q.autoLaunch && canPlay -> WSLog("launcher", "first run -- not auto-launching")
            !canPlay -> WSLog("launcher", "the game is not installed -- staying in the launcher")
        }
    }

    // ------------------------------------------------------------ server

    /**
     * Starts what the game talks to on 127.0.0.1: the server itself, or in
     * Windstock Online the encrypted tunnel to the server on the internet.
     */
    fun startServer(context: Context = app) {
        val p = _prefs.value
        val tunnel = when (p.serverMode) {
            ServerMode.EMBEDDED -> ""
            ServerMode.ONLINE -> p.onlineEndpoint?.display ?: return
            else -> return
        }
        // The service keeps this process alive (and the server with it) while
        // the game is in front; without it Android reclaims us in minutes.
        ServerService.start(context)
        PythonServer.start(context, p.serverPort, p.serverPlainPort, p.gameEditorPort, tunnel)
    }

    /** True when this mode runs something in the launcher that the game needs. */
    private fun needsLocalServer(p: LauncherPrefs) =
        p.serverMode == ServerMode.EMBEDDED || (p.serverMode == ServerMode.ONLINE && p.onlineEndpoint != null)

    private fun serverModeChanged(old: ServerMode, new: LauncherPrefs) {
        when {
            new.serverMode == ServerMode.ONLINE ->
                if (new.onlineEndpoint != null) startServer() else stopServer()
            new.serverMode == ServerMode.EMBEDDED ->
                // Coming from Online the tunnel holds these ports; start() swaps it out.
                if (old == ServerMode.ONLINE || new.startServerOnLaunch) startServer()
            old == ServerMode.EMBEDDED || old == ServerMode.ONLINE -> stopServer()
        }
    }

    /** Server tab: is the launcher-side piece for this mode up? */
    fun serverNeededAndDown(): Boolean =
        needsLocalServer(_prefs.value) && PythonServer.state.value != ServerState.RUNNING

    fun stopServer() {
        PythonServer.stop()
        ServerService.stop(app)
    }

    /**
     * What the game's agent needs to know, handed over by ConfigProvider when
     * the game starts. The agent cannot read our files, and it has to know
     * where the server is before it can ask the server anything.
     */
    fun gameConfig(): JSONObject {
        val p = _prefs.value
        val m = _mods.value
        val net = JSONObject()
        when (p.serverMode) {
            ServerMode.EMBEDDED, ServerMode.ONLINE -> {
                // Windstock Online is the same to the game as the server on this
                // phone: the launcher's tunnel (tunnel.py) listens on the same two
                // loopback ports and carries everything to the server over TLS,
                // checked against that server's pinned certificate. Nothing leaves
                // the phone in the clear, the game's plain-HTTP login included.
                net.put("enabled", needsLocalServer(p)).put("host", "127.0.0.1")
                    .put("port", p.serverPort).put("plain_port", p.serverPlainPort)
                // The agent trusts this CA inside the game, so a CA the user never
                // installed (or Android 11+ would not install) doesn't block the login.
                if (CertHelper.isAvailable) net.put("ca", Paths.caCertificate.readText())
            }
            ServerMode.REMOTE -> {
                val host = p.remoteHost.trim()
                net.put("enabled", host.isNotEmpty()).put("host", host)
                    .put("port", p.remotePort).put("plain_port", p.remotePlainPort)
            }
            ServerMode.OFF -> net.put("enabled", false)
        }
        // The map's tiles join the list only for the server on this phone / the tunnel:
        // it fetches them from Google (it runs in the launcher, outside the game's hooks)
        // and recolours them. A remote server may not have that code, so it is left out.
        val tiles = if (p.recolorMapTiles && p.serverMode != ServerMode.REMOTE)
            listOf(MAP_TILE_HOST) else emptyList()
        net.put("hostnames", JSONArray(p.redirectHostnames + tiles))
        return JSONObject()
            .put("version", 1)
            .put("launcher", BuildConfig.VERSION_NAME)
            .put("inject", p.injectMods)
            .put("mods", m.toJson().getJSONObject("mods"))
            .put("values", m.toJson().getJSONObject("values"))
            .put("net", net)
            .put("server", PythonServer.state.value.name.lowercase())
    }

    // ------------------------------------------------------------ launching

    val canPlay: Boolean get() = GameInstaller.isInstalled(app)

    fun beginCountdown() {
        if (_countdown.value != null) return
        val delay = _prefs.value.autoLaunchDelay.coerceAtLeast(LauncherPrefs.MIN_AUTO_LAUNCH_DELAY)
        _countdown.value = delay
        val tick = object : Runnable {
            override fun run() {
                val remaining = _countdown.value ?: return
                val next = remaining - 0.1
                if (next <= 0) {
                    stopCountdown()
                    launchGame(app)
                } else {
                    _countdown.value = next
                    main.postDelayed(this, 100)
                }
            }
        }
        countdownTick = tick
        main.postDelayed(tick, 100)
    }

    private fun stopCountdown() {
        countdownTick?.let { main.removeCallbacks(it) }
        countdownTick = null
        _countdown.value = null
    }

    /** The user chose to stay in the launcher. Gives the run back, as on iOS. */
    fun cancelCountdown() {
        if (_countdown.value == null) return
        stopCountdown()
        updatePrefs { it.copy(launchCount = maxOf(1, it.launchCount - 1)) }
        WSLog("launcher", "auto-launch cancelled -- next start will wait too")
    }

    /** Asks the launcher's tunnel whether the Windstock server takes this build. */
    fun checkForUpdate() {
        if (_prefs.value.serverMode != ServerMode.ONLINE) return
        val port = _prefs.value.serverPlainPort
        Thread {
            repeat(10) {
                val j = try {
                    val conn = java.net.URL("http://127.0.0.1:$port/windstock/tunnel").openConnection() as java.net.HttpURLConnection
                    conn.connectTimeout = 3000
                    conn.readTimeout = 20000
                    try { JSONObject(conn.inputStream.bufferedReader().use { it.readText() }) } finally { conn.disconnect() }
                } catch (_: Exception) { null }
                if (j != null && j.optBoolean("tunnel") && j.optBoolean("ok")) {
                    val url = if (j.optBoolean("updateRequired"))
                        j.optString("updateURL").ifBlank { "https://windstock.org/downloads.html" } else null
                    if (url != null) WSLog("launcher", "the Windstock server needs a newer launcher (build " +
                        "${j.optInt("launcherBuild")}, needs ${j.optInt("minBuild")}) -- Play opens $url")
                    main.post {
                        _updateUrl.value = url
                        if (url != null) stopCountdown()
                    }
                    return@Thread
                }
                Thread.sleep(1500)
            }
        }.start()
    }

    fun launchGame(context: Context) {
        _updateUrl.value?.let { url ->
            stopCountdown()
            val open = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            try { context.startActivity(open) } catch (e: Exception) { _launchError.value = "Open $url to update." }
            return
        }
        stopCountdown()
        _launchError.value = null
        val p = _prefs.value
        if (serverNeededAndDown()) startServer(context)
        WSLog("launcher", "launching the game (mods ${if (p.injectMods) "on" else "off"}, server ${p.serverMode.key})")
        GameInstaller.launch(context)?.let {
            WSLog("launcher", "launch failed: $it")
            _launchError.value = it
        }
    }
}
