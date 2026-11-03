package com.windstock.launcher.server

import android.content.Context
import android.os.ParcelFileDescriptor
import com.chaquo.python.PyObject
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import com.windstock.launcher.Paths
import com.windstock.launcher.WSLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

enum class ServerState { STOPPED, STARTING, RUNNING, FAILED }

/**
 * The embedded server: CPython (Chaquopy) running the project's own server.py,
 * driven through ws_boot.py -- the SAME ws_boot the iOS launcher ships, which
 * is entirely environment-driven. The Android counterpart of WSPythonServer.m.
 *
 * Every call into Python goes through one single-thread executor, as the iOS
 * side serialises everything on one dispatch queue.
 */
object PythonServer {
    private val queue = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "windstock-python").apply { isDaemon = true }
    }
    private var boot: PyObject? = null
    private var logPipeOpen = false

    private val _state = MutableStateFlow(ServerState.STOPPED)
    val state: StateFlow<ServerState> = _state
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error

    @Volatile var port: Int = 8443
        private set

    private fun set(state: ServerState, error: String? = null) {
        _state.value = state
        _error.value = error
    }

    private fun prepare(context: Context): Boolean {
        if (boot != null) return true
        if (!ServerAssets.ensure(context)) return false
        val serverDir = Paths.pythonServerDir
        if (!File(serverDir, "server.py").exists()) {
            WSLog("server", "PythonServer/server.py missing -- run tools/stage_server.sh")
            return false
        }
        Paths.dataDir.mkdirs()
        if (!Python.isStarted()) {
            ServerAssets.resetPythonRuntimeIfStale(context)
            ServerAssets.pythonStarting(true)
            Python.start(AndroidPlatform(context.applicationContext))
            ServerAssets.pythonStarting(false)
        }
        val py = Python.getInstance()
        val os = py.getModule("os")
        val environ = os.get("environ")!!
        fun env(k: String, v: String) = environ.callAttr("__setitem__", k, v)
        env("WS_SERVER_DIR", serverDir.absolutePath)
        env("WS_DATA_DIR", Paths.dataDir.absolutePath)
        env("CERT_DIR", File(serverDir, "certs").absolutePath)
        env("BIND", "127.0.0.1")
        env("PYTHONUNBUFFERED", "1")
        openLogPipe()?.let { env("WS_LOG_FD", it.toString()) }

        val sys = py.getModule("sys")
        val path = sys.get("path")!!
        path.callAttr("insert", 0, File(serverDir, "vendor").absolutePath)
        path.callAttr("insert", 0, serverDir.absolutePath)
        // The server dir is replaced on every update; stale bytecode from the
        // previous build must never shadow the new sources.
        sys.put("dont_write_bytecode", true)
        return try {
            boot = py.getModule("ws_boot")
            WSLog("server", "CPython ${sys.get("version")} ready")
            true
        } catch (e: Exception) {
            WSLog("server", "import ws_boot raised: ${e.message}")
            false
        }
    }

    /**
     * Python writes to a pipe rather than to a file we poll: the Server tab
     * shows lines as the server prints them. ws_boot fdopen()s WS_LOG_FD.
     */
    private fun openLogPipe(): Int? {
        if (logPipeOpen) return null
        return try {
            val (read, write) = ParcelFileDescriptor.createPipe()
            Thread({
                ParcelFileDescriptor.AutoCloseInputStream(read).bufferedReader().useLines { lines ->
                    lines.forEach { if (it.isNotEmpty()) WSLog("server", it) }
                }
            }, "windstock-server-log").apply { isDaemon = true }.start()
            logPipeOpen = true
            write.detachFd()
        } catch (e: Exception) {
            WSLog("server", "no log pipe: ${e.message}")
            null
        }
    }

    private fun call(name: String): PyObject? = try {
        boot?.callAttr(name)
    } catch (e: Exception) {
        WSLog("server", "$name raised: ${e.message}")
        null
    }

    /** What is behind the ports right now: "" = the game server, "ip:port" = the Online tunnel. */
    @Volatile private var runningTunnel: String? = null

    /**
     * Starts what runs behind the two loopback ports. [tunnel] empty: the game
     * server on this phone. [tunnel] "ip:port": the encrypted tunnel to a
     * Windstock Online server (tunnel.py) -- to the game it is the same thing.
     * Calling it while the other one is up switches over.
     */
    fun start(context: Context, port: Int, plainPort: Int, adminPort: Int, tunnel: String = "") {
        val busy = _state.value == ServerState.RUNNING || _state.value == ServerState.STARTING
        if (busy && runningTunnel == tunnel) return
        runningTunnel = tunnel
        set(ServerState.STARTING)
        queue.execute {
            if (!prepare(context)) {
                set(ServerState.FAILED, "Could not start the Python runtime. See the log.")
                return@execute
            }
            this.port = port
            val environ = Python.getInstance().getModule("os").get("environ")!!
            environ.callAttr("__setitem__", "PORT", port.toString())
            environ.callAttr("__setitem__", "WS_HTTP_PORT", plainPort.toString())
            environ.callAttr("__setitem__", "WS_ADMIN_PORT", adminPort.toString())
            try {
                boot?.callAttr("configure_tunnel", tunnel)
            } catch (e: Exception) {
                WSLog("server", "configure_tunnel raised: ${e.message}")
                set(ServerState.FAILED, "This build's server files are too old for Windstock Online.")
                return@execute
            }
            if (call("start") == null) {
                set(ServerState.FAILED, "ws_boot.start() failed.")
                return@execute
            }
            // start() only spawns the thread; the listener may still fail to
            // bind, and the first import of protocol.py takes a few seconds on
            // a phone. Poll until it answers or gives up.
            pollUntilSettled(0)
        }
    }

    private fun pollUntilSettled(attempt: Int) {
        queue.schedule({
            readStatus()
            if (_state.value == ServerState.STARTING && attempt < 60) pollUntilSettled(attempt + 1)
            else if (_state.value == ServerState.STARTING) set(ServerState.FAILED, "The server did not come up. See the log.")
        }, 500, TimeUnit.MILLISECONDS)
    }

    fun stop() {
        queue.execute {
            if (boot == null) return@execute
            call("stop")
            queue.schedule({ readStatus(forceStopped = true) }, 600, TimeUnit.MILLISECONDS)
        }
    }

    /** Windstock Online: drop the certificate saved for the current server. */
    fun forgetOnlineCertificate() {
        queue.execute { if (boot != null) call("forget_online_certificate") }
    }

    fun refresh() {
        queue.execute { if (boot != null) readStatus() }
    }

    /** Rebuild any listener that died while the process was frozen. */
    fun revive() {
        queue.execute { if (boot != null) { call("revive"); readStatus() } }
    }

    /** Blocks the caller until the server answers, or [timeoutMs] passes. */
    fun awaitRunning(timeoutMs: Long): Boolean {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            when (_state.value) {
                ServerState.RUNNING -> return true
                ServerState.FAILED, ServerState.STOPPED -> return false
                else -> Thread.sleep(100)
            }
        }
        return _state.value == ServerState.RUNNING
    }

    /** Must run on [queue]. */
    private fun readStatus(forceStopped: Boolean = false) {
        val text = call("status_json")?.toString() ?: return
        val status = try { JSONObject(text) } catch (_: Exception) { return }
        val running = status.optBoolean("running")
        val err = if (status.isNull("error")) null else status.optString("error")
        when {
            running -> set(ServerState.RUNNING)
            err != null -> set(ServerState.FAILED, err)
            forceStopped || _state.value != ServerState.STARTING -> set(ServerState.STOPPED)
        }
    }
}
