package com.windstock.launcher.ui

import android.annotation.SuppressLint
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Help
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.windstock.launcher.Launcher
import com.windstock.launcher.WSLog
import kotlinx.coroutines.delay
import java.util.Locale

/**
 * The World Manager in a web view (GameEditorView.swift). admin.py is already
 * a complete game editor; ws_boot starts it on the editor port, and this only
 * wraps it. A literal loopback URL, never a redirected hostname.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun GameEditorScreen() {
    val prefs by Launcher.prefs.collectAsState()
    val url = "http://127.0.0.1:${prefs.gameEditorPort}/"
    var view by remember { mutableStateOf<WebView?>(null) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = { view?.loadUrl(url) }) { Text("Reload") }
        }
        AndroidView(
            factory = { ctx ->
                WebView(ctx).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    webViewClient = WebViewClient()
                    loadUrl(url)
                    view = this
                }
            },
            modifier = Modifier.fillMaxSize(),
        )
    }
}

@Composable
fun LogScreen() {
    var lines by remember { mutableStateOf(WSLog.lines()) }
    LaunchedEffect(Unit) {
        var seen = -1L
        while (true) {
            val rev = WSLog.revision.value
            if (rev != seen) { seen = rev; lines = WSLog.lines() }
            delay(500)
        }
    }
    Section { LogList(lines) }
}

/** How to use it (TutorialView.swift), rewritten for how Android does things. */
@Composable
fun TutorialScreen() {
    val prefs by Launcher.prefs.collectAsState()
    Section("Installing it") {
        Step(1, "Install the launcher APK", "Copy it to the phone and open it. Android asks once to allow installs from your file manager or browser. There is no root involved.")
        Step(2, "Install the game from the Play tab", "The launcher carries a Windstock build of Pokémon GO 0.35 and installs it for you as \"Windstock GO\" — its own app, so the Play Store's Pokémon GO can stay on the phone next to it.")
        Step(3, "The phone must run 32-bit apps", "Pokémon GO 0.35 only exists for 32-bit ARM. Most phones still run it; some recent flagships are 64-bit only and cannot.")
    }
    Section("First run") {
        Step(1, "Start the server", "It starts with the launcher. The first start unpacks the server from the app, which takes a little while once.")
        Step(2, "Install the server's certificate", "Settings tab › Server certificate › Save to Downloads, then Open Settings and install it as a CA certificate. The game refuses the server without it, and the login fails with nothing in the log.")
        Step(3, "Allow notifications", "So you hear about eggs finishing and lures running out, and so the server can keep running while the game has the screen.")
    }
    Section("Playing") {
        Step(1, "Just open Windstock", "The server starts, then the game starts on its own after " +
            String.format(Locale.US, "%.1f", prefs.autoLaunchDelay) +
            " seconds. Tap \"Stay in the launcher\" during the countdown if you wanted the menus.")
        Step(2, "Or open the game directly", "The game asks the launcher for its settings as it loads, and that starts the server if it isn't running.")
        Step(3, "Mods apply at launch", "The agent reads the mods once, as the game loads, so a change takes effect the next time the game starts. Swipe the game away from Recents to restart it.")
        Step(4, "The server can live either place", "\"This phone\" needs nothing else running. \"On a PC\" points the game at a server on your computer instead — a LAN or Tailscale address.")
    }
    Section("When it goes wrong") {
        Trouble("Login fails with an empty log", "The certificate is not installed. Settings › Server certificate shows whether this phone trusts it.")
        Trouble("The game never reaches the server", "Settings › Open the log. Lines tagged [config] mean the game asked the launcher for its settings; if there are none, the installed game is not the Windstock build.")
        Trouble("\"Unable to authenticate\" after it worked", "Server tab › Server settings › Server: switch custom_login_page off. It is an experiment that breaks this client's login.")
        Trouble("The server stops while I play", "Android killed the launcher in the background. Allow notifications, and in Android's battery settings set Windstock to Unrestricted.")
    }
}

@Composable
private fun Step(number: Int, title: String, detail: String) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(24.dp).background(WSColors.accent.copy(alpha = 0.18f), CircleShape), contentAlignment = Alignment.Center) {
            Text("$number", color = WSColors.accent, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        }
        Column {
            Text(title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun Trouble(symptom: String, fix: String) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        @Suppress("DEPRECATION")
        Icon(Icons.Filled.Help, null, tint = WSColors.warn, modifier = Modifier.size(22.dp))
        Column {
            Text(symptom, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
            Text(fix, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
