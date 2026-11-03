package com.windstock.launcher

import android.Manifest
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.windstock.launcher.server.PythonServer
import com.windstock.launcher.ui.GameEditorScreen
import com.windstock.launcher.ui.GameSettingsScreen
import com.windstock.launcher.ui.LogScreen
import com.windstock.launcher.ui.ModsScreen
import com.windstock.launcher.ui.OSMLinksScreen
import com.windstock.launcher.ui.PlayScreen
import com.windstock.launcher.ui.ServerScreen
import com.windstock.launcher.ui.SettingsScreen
import com.windstock.launcher.ui.TutorialScreen
import com.windstock.launcher.ui.WindstockTheme
import com.windstock.launcher.ui.WorldDataScreen

/** Where a tab can go. Each tab keeps its own back stack, as on iOS. */
sealed interface Route {
    data object Play : Route
    data object Mods : Route
    data object Server : Route
    data class ServerSettings(val path: List<String>) : Route
    data object Tutorial : Route
    data object Settings : Route
    data object WorldData : Route
    data object OSMLinks : Route
    data object GameEditor : Route
    data object Log : Route
}

enum class Tab(val label: String, val icon: ImageVector, val root: Route) {
    PLAY("Play", Icons.Filled.PlayCircle, Route.Play),
    MODS("Mods", Icons.Filled.Tune, Route.Mods),
    SERVER("Server", Icons.Filled.Dns, Route.Server),
    SETTINGS("Settings", Icons.Filled.Settings, Route.Settings),
}

/** Handed to every screen: push a route onto the current tab's stack. */
class Nav(private val stack: SnapshotStateList<Route>) {
    fun push(route: Route) { stack.add(route) }
    fun pop() { if (stack.size > 1) stack.removeAt(stack.lastIndex) }
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { WindstockTheme { Root() } }
        fadeInFromSplash()
    }

    /** The start window's picture on top of the first frame, fading out, so the launcher doesn't cut in from it. */
    private fun fadeInFromSplash() {
        window.setBackgroundDrawable(ColorDrawable(Color.WHITE))
        val splash = View(this).apply { setBackgroundResource(R.drawable.splash) }
        addContentView(splash, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        splash.animate().alpha(0f).setStartDelay(150).setDuration(350)
            .withEndAction { (splash.parent as? ViewGroup)?.removeView(splash) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Root() {
    var tab by rememberSaveable { mutableStateOf(Tab.PLAY) }
    val stacks = remember { Tab.entries.associateWith { mutableStateListOf(it.root) } }
    val stack = stacks.getValue(tab)
    val nav = remember(tab) { Nav(stack) }
    val context = androidx.compose.ui.platform.LocalContext.current

    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(Unit) {
        Launcher.start(context)
        if (Build.VERSION.SDK_INT >= 33 && !Notifier.isAllowed && Launcher.prefs.value.notificationsEnabled) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
    // Coming back from the game: make sure the listeners survived.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        lifecycle.addObserver(LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) PythonServer.revive()
        })
    }

    BackHandler(enabled = stack.size > 1) { nav.pop() }

    val route = stack.last()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(titleFor(route)) },
                navigationIcon = {
                    if (stack.size > 1) {
                        IconButton(onClick = { nav.pop() }) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
        bottomBar = {
            NavigationBar {
                Tab.entries.forEach { t ->
                    NavigationBarItem(
                        selected = t == tab,
                        onClick = {
                            // Leaving Play during the countdown plainly means "not yet".
                            if (t != Tab.PLAY) Launcher.cancelCountdown()
                            if (t == tab) stacks.getValue(t).let { s -> while (s.size > 1) s.removeAt(s.lastIndex) }
                            tab = t
                        },
                        icon = { Icon(t.icon, null) },
                        label = { Text(t.label) },
                    )
                }
            }
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
      // Keyed, so every screen gets its own scroll position.
      androidx.compose.runtime.key(tab, stack.size) {
        when (route) {
            // The editor is a full-bleed web view, not a scrolling list.
            Route.GameEditor -> Column(Modifier.padding(padding).fillMaxSize()) { GameEditorScreen() }
            else -> ScrollPage(padding) {
                when (route) {
                    Route.Play -> PlayScreen(nav)
                    Route.Mods -> ModsScreen()
                    Route.Server -> ServerScreen(nav)
                    is Route.ServerSettings -> GameSettingsScreen(nav, route.path)
                    Route.Tutorial -> TutorialScreen()
                    Route.Settings -> SettingsScreen(nav)
                    Route.WorldData -> WorldDataScreen(nav)
                    Route.OSMLinks -> OSMLinksScreen()
                    Route.Log -> LogScreen()
                    Route.GameEditor -> {}
                }
            }
        }
      }
    }
}

@Composable
private fun ScrollPage(padding: PaddingValues, content: @Composable () -> Unit) {
    Column(
        Modifier
            .padding(padding)
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) { content() }
}

private fun titleFor(route: Route): String = when (route) {
    Route.Play -> "Windstock"
    Route.Mods -> "Mods"
    Route.Server -> "Server"
    is Route.ServerSettings -> if (route.path.isEmpty()) "Server settings"
        else com.windstock.launcher.server.GameSettingsStore.label(route.path.last())
    Route.Tutorial -> "How to use it"
    Route.Settings -> "Settings"
    Route.WorldData -> "World Data"
    Route.OSMLinks -> "OpenStreetMap"
    Route.GameEditor -> "Game Editor"
    Route.Log -> "Log"
}
