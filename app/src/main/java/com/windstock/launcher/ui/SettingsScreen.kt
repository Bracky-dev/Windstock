package com.windstock.launcher.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.windstock.launcher.BuildConfig
import com.windstock.launcher.CertHelper
import com.windstock.launcher.Launcher
import com.windstock.launcher.LauncherPrefs
import com.windstock.launcher.LogExport
import com.windstock.launcher.Nav
import com.windstock.launcher.Notifier
import com.windstock.launcher.Paths
import com.windstock.launcher.Route
import com.windstock.launcher.ServerMode
import com.windstock.launcher.WindstockProfile
import com.windstock.launcher.server.PythonServer
import com.windstock.launcher.server.ServerState
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date
import java.util.Locale

@Composable
fun SettingsScreen(nav: Nav) {
    val context = LocalContext.current
    val prefs by Launcher.prefs.collectAsState()
    val serverState by PythonServer.state.collectAsState()
    var refresh by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { refresh++ }
    val notifyPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { refresh++ }

    Section("Launching") {
        ToggleRow("Start the game automatically", prefs.autoLaunch) { on -> Launcher.updatePrefs { it.copy(autoLaunch = on) } }
        if (prefs.autoLaunch) {
            ValueRow("Wait", String.format(Locale.US, "%.1f s", prefs.autoLaunchDelay))
            Slider(
                value = prefs.autoLaunchDelay.toFloat(),
                onValueChange = { v -> Launcher.updatePrefs { it.copy(autoLaunchDelay = (Math.round(v * 2) / 2.0)) } },
                valueRange = LauncherPrefs.MIN_AUTO_LAUNCH_DELAY.toFloat()..10f, steps = 18,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
        ToggleRow("Load the mods into the game", prefs.injectMods,
            subtitle = "Off gives you the plain client. The network redirect stays on either way — without it the game cannot find the server.") { on ->
            Launcher.updatePrefs { it.copy(injectMods = on) }
        }
    }

    ProfileSection()

    Section("Notifications") {
        ToggleRow("Enabled", prefs.notificationsEnabled) { on -> Launcher.updatePrefs { it.copy(notificationsEnabled = on) } }
        if (prefs.notificationsEnabled) {
            val allowed = remember(refresh) { Notifier.isAllowed }
            if (!allowed && Build.VERSION.SDK_INT >= 33) {
                TextButton(onClick = { notifyPermission.launch(Manifest.permission.POST_NOTIFICATIONS) },
                    modifier = Modifier.padding(horizontal = 8.dp)) { Text("Allow notifications") }
            }
            ToggleRow("Server started / stopped", prefs.notifyServerState) { on -> Launcher.updatePrefs { it.copy(notifyServerState = on) } }
            ToggleRow("Eggs ready to hatch", prefs.notifyEggs) { on -> Launcher.updatePrefs { it.copy(notifyEggs = on) } }
            ToggleRow("Lures running out", prefs.notifyLures) { on -> Launcher.updatePrefs { it.copy(notifyLures = on) } }
            if (prefs.notifyLures) {
                ItemRow("Warn ${prefs.lureWarningMinutes} min before") {
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        TextButton(onClick = { Launcher.updatePrefs { it.copy(lureWarningMinutes = maxOf(1, it.lureWarningMinutes - 1)) } }) { Text("−", fontSize = 20.sp) }
                        TextButton(onClick = { Launcher.updatePrefs { it.copy(lureWarningMinutes = minOf(30, it.lureWarningMinutes + 1)) } }) { Text("+", fontSize = 20.sp) }
                    }
                }
            }
            TextButton(onClick = { Notifier.post("Windstock", "Notifications are working.") },
                modifier = Modifier.padding(horizontal = 8.dp)) { Text("Send a test notification") }
        }
    }

    val trusted = remember(refresh) { CertHelper.isTrusted() }
    Section("Server certificate",
        footer = "Without it the game refuses the server's certificate and the login fails with nothing in the log. " +
            "Tap Save, then in Settings search for \"CA certificate\" (Security › More security settings › Encryption & credentials › Install a certificate › CA certificate) and pick windstock-ca.crt from Downloads. Android warns that the network may be monitored — that is this certificate, and it only vouches for the Windstock server.") {
        ItemRow("Installed", if (trusted) "Trusted by this phone" else "Not installed yet",
            if (trusted) WSColors.accent else WSColors.warn)
        if (!CertHelper.isAvailable) {
            Note("Start the server once so the certificate is unpacked.", WSColors.warn)
        } else {
            Row(Modifier.padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = {
                    val where = CertHelper.exportToDownloads(context)
                    Toast.makeText(context, where?.let { "Saved to $it" } ?: "Could not save it", Toast.LENGTH_LONG).show()
                }) { Text("Save to Downloads") }
                TextButton(onClick = {
                    try { context.startActivity(CertHelper.installIntent()) } catch (_: Exception) {}
                }) { Text("Open Settings") }
            }
        }
    }

    Section(footer = "Download your country's real PokéStops and gyms.") {
        NavRow("World Data") { nav.push(Route.WorldData) }
    }

    Section("Game Editor",
        footer = if (serverState == ServerState.RUNNING)
            "Items, candy, stardust, XP and level, PokéStops and gyms, loot tables, raids and accounts. Research and the events calendar unlock at level 5, so that is where to set it."
        else "Start the server first — the editor runs inside it.") {
        NavRow("Open the editor") { if (serverState == ServerState.RUNNING) nav.push(Route.GameEditor) }
    }

    Section("Where things are") {
        PathRow("Launcher", Paths.root.absolutePath)
        PathRow("Server", Paths.pythonServerDir.absolutePath)
        PathRow("Server data", Paths.dataDir.absolutePath)
    }

    var reporting by remember { mutableStateOf(false) }
    if (reporting) ReportProblemDialog { reporting = false }
    if (BuildConfig.GAME_BUILT_IN) Section("Credits",
        footer = "Windstock 64 runs the game's 32-bit code through Chucny's Translator (AGPL-3.0, github.com/Chucny/translator), used with his permission. Source: github.com/Chucny/translator.") {
        ItemRow("Chucny's Translator") { Text("Chucny", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        ItemRow("Original runtime code") { Text("ZailoxTT", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        ItemRow("Android guest system libraries") { Text("Android Open Source Project", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        ItemRow("ARM recompiler") { Text("Dynarmic contributors", color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
    Section("Help", footer = "If something goes wrong, report it right after it happens. Your location is rounded to about 10 km first, and passwords are never in the log.") {
        ItemRow("Version") { Text(BuildConfig.VERSION_NAME, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        TextButton(onClick = { reporting = true }, modifier = Modifier.padding(horizontal = 8.dp)) { Text("Report a problem") }
        TextButton(onClick = {
            val intent = LogExport.shareIntent(context)
            if (intent == null) Toast.makeText(context, "There is no log yet.", Toast.LENGTH_LONG).show()
            else context.startActivity(intent)
        }, modifier = Modifier.padding(horizontal = 8.dp)) { Text("Send the log to the developer") }
        TextButton(onClick = { nav.push(Route.Log) }, modifier = Modifier.padding(horizontal = 8.dp)) { Text("Open the log") }
    }
}

@Composable
private fun PathRow(title: String, path: String) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
        Text(title, style = MaterialTheme.typography.bodyMedium)
        SelectionContainer {
            Text(path, fontSize = 10.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Settings › Leaderboard (ProfileSection.swift). No sign-in: logging in to the game on Windstock is the sign-in. */
@Composable
private fun ProfileSection() {
    val context = LocalContext.current
    val prefs by Launcher.prefs.collectAsState()
    val trainer by WindstockProfile.trainer.collectAsState()
    val note by WindstockProfile.note.collectAsState()
    LaunchedEffect(prefs.serverMode) { WindstockProfile.refresh() }

    Section("Leaderboard", footer = "Your Windstock login is your place on the board: play on Windstock and your catches, spins and distance count automatically. Games on this phone's own server don't count.") {
        if (prefs.serverMode == ServerMode.ONLINE) {
            ValueRow("Trainer", trainer ?: "—")
            note?.let { Note(it) }
            TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(WindstockProfile.siteURL + "/leaderboard.html"))) },
                modifier = Modifier.padding(horizontal = 8.dp)) { Text("Open the leaderboard") }
        } else {
            Note("The leaderboard is only on Windstock.")
        }
    }
}
