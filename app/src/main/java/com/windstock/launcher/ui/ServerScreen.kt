package com.windstock.launcher.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.windstock.launcher.Launcher
import com.windstock.launcher.OnlineEndpoint
import com.windstock.launcher.onlineEndpoint
import com.windstock.launcher.Nav
import com.windstock.launcher.Route
import com.windstock.launcher.ServerMode
import com.windstock.launcher.WSLog
import com.windstock.launcher.server.GameSettingsStore
import com.windstock.launcher.server.PythonServer
import com.windstock.launcher.server.ServerState
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

@Composable
fun ServerScreen(nav: Nav) {
    val prefs by Launcher.prefs.collectAsState()
    val state by PythonServer.state.collectAsState()
    val error by PythonServer.error.collectAsState()

    val (statusText, statusColor) = when (prefs.serverMode) {
        ServerMode.REMOTE -> "remote" to Color.Gray
        ServerMode.OFF -> "unmanaged" to Color.Gray
        ServerMode.ONLINE -> when {
            prefs.onlineEndpoint == null -> "no address" to WSColors.warn
            state == ServerState.RUNNING -> "encrypted" to WSColors.accent
            state == ServerState.STARTING -> "connecting" to WSColors.warn
            state == ServerState.FAILED -> "failed" to WSColors.bad
            else -> "stopped" to Color.Gray
        }
        ServerMode.EMBEDDED -> when (state) {
            ServerState.RUNNING -> "running" to WSColors.accent
            ServerState.STARTING -> "starting" to WSColors.warn
            ServerState.FAILED -> "failed" to WSColors.bad
            ServerState.STOPPED -> "stopped" to Color.Gray
        }
    }

    Section {
        ItemRow("Status") { StatusPill(statusText, statusColor) }
        error?.let { Note(it, WSColors.bad) }
        if (prefs.serverMode == ServerMode.EMBEDDED) {
            val running = state == ServerState.RUNNING
            Button(
                onClick = { if (running) Launcher.stopServer() else Launcher.startServer() },
                colors = ButtonDefaults.buttonColors(containerColor = if (running) WSColors.bad else WSColors.accent),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            ) { Text(if (running) "Stop" else "Start") }
        }
    }

    Section("Where the server runs") {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
            val modes = listOf(ServerMode.EMBEDDED to "This phone", ServerMode.REMOTE to "On a PC", ServerMode.ONLINE to "Windstock")
            modes.forEachIndexed { i, (mode, label) ->
                SegmentedButton(
                    selected = prefs.serverMode == mode,
                    onClick = { Launcher.updatePrefs { it.copy(serverMode = mode) } },
                    shape = SegmentedButtonDefaults.itemShape(i, modes.size),
                ) { Text(label) }
            }
        }
        when (prefs.serverMode) {
            ServerMode.EMBEDDED -> {
                NumberRow("Port", prefs.serverPort) { v -> Launcher.updatePrefs { it.copy(serverPort = v) } }
                ToggleRow("Start with the launcher", prefs.startServerOnLaunch) { on ->
                    Launcher.updatePrefs { it.copy(startServerOnLaunch = on) }
                }
                Note("The game dials port 443, which an app cannot listen on. The windstock agent inside the game rewrites its connections to Niantic's hosts to 127.0.0.1 on this port (and port 80 to the plain listener, ${prefs.serverPlainPort}). Changes apply the next time the game starts.")
            }
            ServerMode.REMOTE -> {
                TextRow("Host", prefs.remoteHost, "192.168.x.y") { v -> Launcher.updatePrefs { it.copy(remoteHost = v) } }
                NumberRow("Port", prefs.remotePort) { v -> Launcher.updatePrefs { it.copy(remotePort = v) } }
                NumberRow("Plain HTTP port", prefs.remotePlainPort) { v -> Launcher.updatePrefs { it.copy(remotePlainPort = v) } }
                Note("The same in-game redirect as the embedded server, pointed at your PC — no DNS changes and no VPN. A LAN address works on the same Wi-Fi; a Tailscale address works anywhere. Leave the ports alone unless you changed PORT when you started the server.")
            }
            ServerMode.ONLINE -> OnlineSection()
            ServerMode.OFF -> Note("The agent leaves the game's networking alone, so a DNS redirect or VPN you set up yourself works exactly as it did before.")
        }
    }

    Section("Game rules", footer = "Spawns, catching, PokéStops, gyms, eggs, raids and the rest — edited here in the app rather than the web page.") {
        NavRow("Server settings") { nav.push(Route.ServerSettings(emptyList())) }
    }

    Section("Hostnames redirected in the game") {
        prefs.redirectHostnames.forEach { Note(it) }
    }

    // The log changes dozens of times a second while the game plays; redraw
    // at most twice a second (the lag lesson from LauncherModel.swift).
    var lines by remember { mutableStateOf(WSLog.lines()) }
    LaunchedEffect(Unit) {
        var seen = -1L
        while (true) {
            val rev = WSLog.revision.value
            if (rev != seen) { seen = rev; lines = WSLog.lines() }
            delay(500)
        }
    }
    Section("Live output") {
        LogList(lines.filter { it.contains("[server]") }, "Nothing yet. Start the server to see its log here.")
    }
    LaunchedEffect(Unit) { GameSettingsStore.reload() }
}

@Composable
fun NumberRow(title: String, value: Int, onChange: (Int) -> Unit) {
    var text by remember(value) { mutableStateOf(value.toString()) }
    ItemRow(title) {
        OutlinedTextField(
            value = text,
            onValueChange = { t -> text = t.filter { it.isDigit() }.take(5); text.toIntOrNull()?.let { if (it in 1..65535) onChange(it) } },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            textStyle = androidx.compose.material3.LocalTextStyle.current.copy(textAlign = TextAlign.End),
            modifier = Modifier.widthIn(max = 110.dp),
        )
    }
}

@Composable
fun TextRow(title: String, value: String, placeholder: String, onChange: (String) -> Unit) {
    var text by remember(value) { mutableStateOf(value) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedTextField(
            value = text,
            onValueChange = { text = it.trim(); onChange(text) },
            label = { Text(title) },
            placeholder = { Text(placeholder) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** Server > Windstock: a test made through the encrypted tunnel. The address is built in. */
@Composable
private fun OnlineSection() {
    val prefs by Launcher.prefs.collectAsState()
    val scope = rememberCoroutineScope()
    var testing by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<Pair<Boolean, String>?>(null) }
    val endpoint = prefs.onlineEndpoint

    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Button(
            enabled = endpoint != null && !testing,
            onClick = {
                val e = endpoint ?: return@Button
                testing = true
                scope.launch {
                    val (ok, text) = withContext(Dispatchers.IO) { testOnline(e, prefs.serverPlainPort) }
                    WSLog("net", "online test ${e.display}: $text")
                    result = ok to text
                    testing = false
                }
            },
        ) { Text(if (testing) "Testing…" else "Test connection") }
    }
    result?.let { (ok, text) -> Note(text, if (ok) WSColors.accent else WSColors.bad) }
    Note("Play on Windstock with everyone else: no DNS changes, no VPN and no certificate to install. Log in with the email and password you registered at windstock.org. Everything the game sends, your password included, travels encrypted, and only to the Windstock server, whose certificate is built into the launcher.")
}

/**
 * Asks the launcher's own tunnel (tunnel.py, on loopback) to make one real
 * request to the server. So a pass means what playing needs: the address
 * answers as a Windstock server, over TLS, with the certificate pinned for it.
 * Nothing here talks to the server directly.
 */
private fun testOnline(e: OnlineEndpoint, plainPort: Int): Pair<Boolean, String> {
    fun ask(): JSONObject? = try {
        val conn = URL("http://127.0.0.1:$plainPort/windstock/tunnel").openConnection() as HttpURLConnection
        conn.connectTimeout = 3000
        conn.readTimeout = 30000
        try {
            JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
        } finally {
            conn.disconnect()
        }
    } catch (_: Exception) {
        null
    }
    if (Launcher.serverNeededAndDown()) Launcher.startServer()
    // Not our tunnel yet, or still the one for the previous address: it is
    // (re)starting. Give it a few seconds.
    repeat(12) {
        val j = ask()
        if (j != null && j.optBoolean("tunnel") && j.optString("target") == e.display) {
            return if (j.optBoolean("ok")) {
                true to "Connected to windstock.org, encrypted.\nCertificate ${j.optString("fingerprint").take(23)}… (${j.optString("pinned")})"
            } else {
                false to j.optString("message").ifBlank { "No answer" }
            }
        }
        Thread.sleep(700)
    }
    return false to "The launcher's encrypted connection did not start. See the log below."
}
