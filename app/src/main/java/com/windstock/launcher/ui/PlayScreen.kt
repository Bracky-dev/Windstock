package com.windstock.launcher.ui

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.windstock.launcher.CertHelper
import com.windstock.launcher.Launcher
import com.windstock.launcher.Nav
import com.windstock.launcher.Route
import com.windstock.launcher.ServerMode
import com.windstock.launcher.onlineEndpoint
import com.windstock.launcher.game.GameInstaller
import com.windstock.launcher.mods.ModsCatalog
import com.windstock.launcher.server.PythonServer
import com.windstock.launcher.server.ServerAssets
import com.windstock.launcher.server.ServerState
import java.util.Locale

/**
 * The screen the app opens on, and usually the only one anyone sees: it counts
 * down and then hands over to the game (PlayView.swift).
 */
@Composable
fun PlayScreen(nav: Nav) {
    val context = LocalContext.current
    val prefs by Launcher.prefs.collectAsState()
    val mods by Launcher.mods.collectAsState()
    val countdown by Launcher.countdown.collectAsState()
    val launchError by Launcher.launchError.collectAsState()
    val updateUrl by Launcher.updateUrl.collectAsState()
    val serverState by PythonServer.state.collectAsState()
    val serverError by PythonServer.error.collectAsState()
    val unpacking by ServerAssets.progress.collectAsState()
    val installPhase by GameInstaller.phase.collectAsState()

    // Installed-ness and the CA store change behind our back (the system
    // installer, Settings); re-read them whenever we come to the front.
    var refresh by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { refresh++ }
    LaunchedEffect(installPhase) { if (installPhase is GameInstaller.InstallPhase.Done) refresh++ }
    val installed = remember(refresh) { GameInstaller.installedInfo(context) }
    val bundled = remember(refresh) { GameInstaller.bundledInfo(context) }
    val hasApk = remember { GameInstaller.hasBundledApk(context) }
    val caTrusted = remember(refresh) { CertHelper.isTrusted() }
    var reporting by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(Icons.Filled.Public, null, tint = WSColors.accent, modifier = Modifier.size(54.dp))
        Text("Windstock, 2016 Pokémon GO", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Text("Private server on this phone", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(16.dp))
    }

    unpacking?.let {
        Section {
            Column(Modifier.padding(16.dp)) {
                Text(it.label)
                Spacer(Modifier.height(8.dp))
                LinearProgressIndicator(progress = { it.fraction }, modifier = Modifier.fillMaxWidth(), color = WSColors.accent)
            }
        }
    }

    Section {
        Column(Modifier.padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            val c = countdown
            if (c != null) {
                Text(String.format(Locale.US, "Starting in %.1fs", maxOf(0.0, c)),
                    style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(12.dp))
                LinearProgressIndicator(
                    progress = { (c / maxOf(0.1, prefs.autoLaunchDelay)).toFloat().coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth(), color = WSColors.accent)
                Spacer(Modifier.height(12.dp))
                OutlinedButton(onClick = { Launcher.cancelCountdown() }) { Text("Stay in the launcher") }
            } else {
                if (updateUrl != null) {
                    Text("A new Windstock is out. Update to keep playing on the Windstock server.",
                        fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(10.dp))
                }
                Button(
                    onClick = { Launcher.launchGame(context) },
                    enabled = installed != null || updateUrl != null,
                    colors = ButtonDefaults.buttonColors(containerColor = WSColors.accent),
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                ) { Text(if (updateUrl != null) "Update Windstock" else "Play", fontSize = 18.sp, fontWeight = FontWeight.SemiBold) }
                if (installed == null && updateUrl == null) {
                    Spacer(Modifier.height(8.dp))
                    Text("Install the game below first.", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                }
            }
        }
    }

    launchError?.let {
        Section("Launch failed") {
            Note(it)
            Row(Modifier.padding(horizontal = 8.dp)) {
                TextButton(onClick = { nav.push(Route.Log) }) { Text("Open the log") }
                TextButton(onClick = { reporting = true }) { Text("Report this problem") }
            }
        }
    }
    if (reporting) ReportProblemDialog("The game didn't start: ${launchError ?: ""}") { reporting = false }

    NewsSection()
    InviteSection()

    if (!GameInstaller.BUILT_IN) GameSection(installed, bundled, hasApk, installPhase) { refresh++ }

    Section("Before you play") {
        Readiness(installed != null,
            "Game",
            installed?.let { "Pokémon GO ${it.versionName}" + if (GameInstaller.BUILT_IN) ", built in (64-bit)" else if (it.agent) ", Windstock build" else ", not the Windstock build (no mods, no redirect)" }
                ?: "not installed")
        Readiness(caTrusted || prefs.serverMode == ServerMode.OFF || prefs.serverMode == ServerMode.ONLINE,
            "Server certificate",
            if (caTrusted) "trusted"
            else if (prefs.serverMode == ServerMode.ONLINE) "not needed for Windstock"
            else "not installed yet — the login fails without it (Settings › Server certificate)")
        Readiness(true, "Mods",
            if (!prefs.injectMods) "switched off in Settings"
            else "${ModsCatalog.all.count { mods.isEffectivelyOn(it.key) }} of ${ModsCatalog.all.size} mods on")
        val (ok, detail) = when (prefs.serverMode) {
            ServerMode.EMBEDDED -> when (serverState) {
                ServerState.RUNNING -> true to "running on 127.0.0.1:${prefs.serverPort}"
                ServerState.STARTING -> false to "starting…"
                ServerState.FAILED -> false to (serverError ?: "failed")
                ServerState.STOPPED -> false to "stopped"
            }
            ServerMode.REMOTE -> prefs.remoteHost.isNotBlank() to prefs.remoteHost.ifBlank { "no host set" }
            ServerMode.ONLINE -> prefs.onlineEndpoint.let { e ->
                when {
                    e == null -> false to "no server address set"
                    serverState == ServerState.RUNNING -> true to "Windstock, encrypted"
                    serverState == ServerState.STARTING -> false to "connecting to Windstock…"
                    serverState == ServerState.FAILED -> false to (serverError ?: "failed")
                    else -> false to "Windstock (not started)"
                }
            }
            ServerMode.OFF -> true to "not managed by the launcher"
        }
        Readiness(ok, "Server", detail)
    }
}

@Composable
private fun GameSection(
    installed: GameInstaller.GameInfo?,
    bundled: GameInstaller.GameInfo?,
    hasApk: Boolean,
    phase: GameInstaller.InstallPhase?,
    onChanged: () -> Unit,
) {
    val context = LocalContext.current
    val canInstall = GameInstaller.canRequestInstalls(context)
    val outdated = installed != null && bundled != null && installed.stamp != bundled.stamp
    Section("Game", footer = when {
        !hasApk -> "This launcher was built without the game (tools/build_game_apk.sh). Install the Windstock 0.35 APK yourself."
        installed == null -> "Installs the Windstock build of Pokémon GO 0.35 that ships inside this app, as \"Windstock GO\" — separate from the Play Store's Pokémon GO, which can stay installed. The launcher starts it for you."
        outdated -> "This launcher carries a newer Windstock build of the game. Updating keeps your trainers — they live on the server."
        else -> null
    }) {
        when (phase) {
            is GameInstaller.InstallPhase.Copying -> Column(Modifier.padding(16.dp)) {
                Text("Preparing the install… ${(phase.fraction * 100).toInt()}%")
                Spacer(Modifier.height(8.dp))
                LinearProgressIndicator(progress = { phase.fraction }, modifier = Modifier.fillMaxWidth(), color = WSColors.accent)
            }
            GameInstaller.InstallPhase.Waiting -> Note("Waiting for Android's install prompt…")
            is GameInstaller.InstallPhase.Failed -> {
                Note(phase.message, WSColors.bad)
                Row(Modifier.padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (phase.conflict) {
                        TextButton(onClick = { context.startActivity(GameInstaller.uninstallIntent()) }) { Text("Uninstall it") }
                    }
                    TextButton(onClick = { GameInstaller.clearPhase(); onChanged() }) { Text("Dismiss") }
                }
            }
            else -> {}
        }
        ItemRow(
            "Windstock GO",
            when {
                installed == null -> "Not installed"
                outdated -> "Installed ${installed.versionName} · update available"
                else -> "Installed ${installed.versionName}" + (installed.stamp?.let { " · build $it" } ?: "")
            },
        ) {
            if (hasApk && (installed == null || outdated)) {
                Button(
                    onClick = {
                        if (!canInstall) {
                            context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${context.packageName}")))
                        } else GameInstaller.install(context)
                    },
                    enabled = phase !is GameInstaller.InstallPhase.Copying && phase != GameInstaller.InstallPhase.Waiting,
                    colors = ButtonDefaults.buttonColors(containerColor = WSColors.accent),
                ) { Text(if (installed == null) "Install" else "Update") }
            }
        }
        if (hasApk && !canInstall && (installed == null || outdated)) {
            Note("Android asks you to allow installs from Windstock once. Tapping Install opens that switch.", WSColors.warn)
        }
    }
}

@Composable
private fun Readiness(ok: Boolean, title: String, detail: String) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(if (ok) Icons.Filled.CheckCircle else Icons.Filled.Warning, null,
            tint = if (ok) WSColors.accent else WSColors.warn, modifier = Modifier.size(20.dp))
        Column {
            Text(title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
