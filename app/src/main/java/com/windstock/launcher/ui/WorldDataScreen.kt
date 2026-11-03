package com.windstock.launcher.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.windstock.launcher.Launcher
import com.windstock.launcher.Nav
import com.windstock.launcher.Route
import com.windstock.launcher.world.InstalledPack
import com.windstock.launcher.world.OSMImport
import com.windstock.launcher.world.PackPhase
import com.windstock.launcher.world.PackStatus
import com.windstock.launcher.world.WorldPack
import com.windstock.launcher.world.WorldPacks
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/** Settings › World Data (WorldDataView.swift). */
@Composable
fun WorldDataScreen(nav: Nav) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs by Launcher.prefs.collectAsState()
    val catalog by WorldPacks.catalog.collectAsState()
    val catalogError by WorldPacks.catalogError.collectAsState()
    val loading by WorldPacks.loading.collectAsState()
    val installed by WorldPacks.installed.collectAsState()
    val phases by WorldPacks.phases.collectAsState()
    val imports by WorldPacks.imports.collectAsState()
    var confirmRemove by remember { mutableStateOf<InstalledPack?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { OSMImport.importFromUri(context, it) }
    }

    // The Catalog box also takes a raw .osm.pbf link: that one is imported,
    // not read as a catalog (and not kept in the box).
    fun load() {
        val text = prefs.worldCatalogURL
        if (OSMImport.isOSMExtract(text)) {
            val url = try { URL(text.trim()) } catch (_: Exception) { null }
            if (url != null) {
                val (name, region) = OSMImport.nameAndRegion(url)
                OSMImport.importFromUrl(context, url, name, region)
                Launcher.updatePrefs { it.copy(worldCatalogURL = "") }
                return
            }
        }
        scope.launch { WorldPacks.loadCatalog(text) }
    }
    LaunchedEffect(Unit) { WorldPacks.rescan(); load() }

    Section("Catalog", footer = "The address of the catalog.json published with the world packs (tools/build_world_packs.py). An .osm.pbf link works here too: it is downloaded and converted on the phone.") {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
            OutlinedTextField(
                value = prefs.worldCatalogURL,
                onValueChange = { v -> Launcher.updatePrefs { it.copy(worldCatalogURL = v) } },
                placeholder = { Text("https://…/catalog.json") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, autoCorrectEnabled = false),
                keyboardActions = KeyboardActions(onGo = { load() }),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedButton(onClick = { load() }, enabled = prefs.worldCatalogURL.isNotBlank() && !loading) {
                Text(if (loading) "Loading…" else "Load countries")
            }
        }
        catalogError?.let { Note(it, WSColors.bad) }
    }

    if (imports.isNotEmpty()) {
        Section("Importing") {
            imports.entries.sortedBy { it.value }.forEach { (id, name) ->
                ItemRow(name, trailing = {
                    if (phases[id] is PackPhase.Failed) TextButton(onClick = { WorldPacks.clearImport(id) }) { Text("Dismiss") }
                    else TextButton(onClick = { WorldPacks.cancel(id) }) { Text("Cancel") }
                })
                PhaseLine(phases[id])
            }
        }
    }

    val suggested = WorldPacks.suggested
    suggested?.let { s -> Section("Your country") { PackRow(s, phases[s.id], installed) { confirmRemove = it } } }

    if (catalog.isNotEmpty()) {
        Section("All countries", footer = "A new country is live on the next map refresh — no restart. Keep several if you travel; overlapping stops are only shown once.") {
            catalog.filter { it.id != suggested?.id }.forEach { PackRow(it, phases[it.id], installed) { p -> confirmRemove = p } }
        }
    }

    val orphans = remember(installed, catalog) { WorldPacks.orphans }
    if (orphans.isNotEmpty()) {
        Section(if (catalog.isEmpty()) "Installed" else "Installed, not in the catalog") {
            orphans.forEach { p -> InstalledRow(p) { confirmRemove = p } }
        }
    }
    val bundled = remember(installed) { WorldPacks.bundledPacks }
    if (bundled.isNotEmpty()) {
        Section("Built into this app", footer = "Shipped inside the launcher. It is used alongside anything you download, and can only be removed by building the app without --with-world.") {
            bundled.forEach { InstalledRow(it, null) }
        }
    }

    Section("OpenStreetMap", footer = "Pick a country or US state and the phone downloads its OpenStreetMap extract and turns it into stops and gyms. Or import an .osm.pbf you already saved.") {
        NavRow("Add from OpenStreetMap") { nav.push(Route.OSMLinks) }
        NavRow("Import an .osm.pbf file…") { picker.launch(arrayOf("*/*")) }
    }

    confirmRemove?.let { p ->
        AlertDialog(
            onDismissRequest = { confirmRemove = null },
            title = { Text("Remove ${p.name}?") },
            text = { Text("Its stops and gyms disappear from the map. You can download it again.") },
            confirmButton = { TextButton(onClick = { WorldPacks.remove(p.id); confirmRemove = null }) { Text("Remove", color = WSColors.bad) } },
            dismissButton = { TextButton(onClick = { confirmRemove = null }) { Text("Cancel") } },
        )
    }
}

private fun size(context: Context, bytes: Long) = Formatter.formatShortFileSize(context, bytes)

@Composable
private fun PackRow(pack: WorldPack, phase: PackPhase?, installed: Map<String, InstalledPack>, onRemove: (InstalledPack) -> Unit) {
    val context = LocalContext.current
    ItemRow(pack.name, "%,d stops & gyms · %s".format(pack.forts, size(context, pack.bytes)), trailing = {
        when (phase) {
            is PackPhase.Downloading -> TextButton(onClick = { WorldPacks.cancel(pack.id) }) { Text("Cancel") }
            PackPhase.Verifying -> CircularProgressIndicator(Modifier.padding(4.dp), strokeWidth = 2.dp)
            else -> when (WorldPacks.status(pack)) {
                PackStatus.NOT_INSTALLED -> OutlinedButton(onClick = { WorldPacks.download(pack) }) { Text("Download") }
                PackStatus.UPDATE_AVAILABLE -> Button(onClick = { WorldPacks.download(pack) },
                    colors = ButtonDefaults.buttonColors(containerColor = WSColors.accent)) { Text("Update") }
                PackStatus.UP_TO_DATE -> TextButton(onClick = { installed[pack.id]?.let(onRemove) }) {
                    Icon(Icons.Filled.CheckCircle, null, tint = WSColors.accent)
                    Text(" Installed", color = WSColors.accent)
                }
            }
        }
    })
    PhaseLine(phase)
}

@Composable
private fun InstalledRow(pack: InstalledPack, onRemove: (() -> Unit)?) {
    val context = LocalContext.current
    ItemRow(pack.name, size(context, pack.bytes)) {
        if (onRemove != null) TextButton(onClick = onRemove) { Text("Remove", color = WSColors.bad) }
    }
}

/** The status line under an importing or downloading pack (OSMPhaseView). */
@Composable
fun PhaseLine(phase: PackPhase?) {
    when (phase) {
        is PackPhase.Downloading -> Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
            Text("Downloading… ${(phase.fraction * 100).toInt()}%", style = MaterialTheme.typography.bodySmall)
            LinearProgressIndicator(progress = { phase.fraction }, modifier = Modifier.fillMaxWidth(), color = WSColors.accent)
        }
        is PackPhase.Converting -> Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
            Text(phase.text, style = MaterialTheme.typography.bodySmall)
            LinearProgressIndicator(progress = { phase.fraction }, modifier = Modifier.fillMaxWidth(), color = WSColors.accent)
        }
        PackPhase.Verifying -> Note("Checking…")
        is PackPhase.Failed -> Note(phase.message, WSColors.bad)
        null -> {}
    }
}

/** Settings › World Data › Add from OpenStreetMap (OSMLinksView.swift). */
@Composable
fun OSMLinksScreen() {
    val context = LocalContext.current
    val phases by WorldPacks.phases.collectAsState()
    val installed by WorldPacks.installed.collectAsState()
    var query by remember { mutableStateOf("") }
    var confirmAdd by remember { mutableStateOf<Triple<String, String, URL>?>(null) }
    var addSize by remember { mutableStateOf<String?>(null) }
    var confirmRemove by remember { mutableStateOf<Pair<String, String>?>(null) }

    LaunchedEffect(confirmAdd) {
        addSize = null
        val url = confirmAdd?.third ?: return@LaunchedEffect
        addSize = withContext(Dispatchers.IO) {
            fun length(u: URL): Long = try {
                val c = u.openConnection() as HttpURLConnection
                c.requestMethod = "HEAD"
                c.connectTimeout = 10000
                val n = if (c.responseCode == 200) c.contentLengthLong else -1L
                c.disconnect()
                n
            } catch (_: Exception) {
                -1L
            }
            var n = length(url)
            if (n <= 0) n = OSMImport.datedExtract(url)?.let(::length) ?: -1L
            if (n > 0) size(context, n) else "an unknown amount"
        }
    }

    Section {
        OutlinedTextField(query, { query = it }, placeholder = { Text("Country or state") }, singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp))
    }
    for ((title, items) in listOf("Countries" to OSMRegions.countries, "United States" to OSMRegions.usStates)) {
        val shown = if (query.isBlank()) items else items.filter { it.first.contains(query.trim(), ignoreCase = true) }
        if (shown.isEmpty()) continue
        Section(title, footer = if (title == "United States") "Tap a place to add its stops and gyms. The phone downloads the whole OpenStreetMap extract first — tens of MB for a small state, over 1 GB for the biggest countries — so use Wi-Fi and keep the app open until it finishes." else null) {
            shown.forEach { (name, region) ->
                val url = URL(OSMRegions.BASE + region + "-latest.osm.pbf")
                val id = OSMImport.packID(region)
                val phase = phases[id]
                val isInstalled = installed.containsKey(id)
                val busy = phase is PackPhase.Downloading || phase is PackPhase.Converting || phase == PackPhase.Verifying
                var menu by remember { mutableStateOf(false) }
                ItemRow(name, if (phase == null) "$region-latest.osm.pbf" else null,
                    onClick = if (!busy && !isInstalled) ({ confirmAdd = Triple(name, region, url) }) else null) {
                    when {
                        busy -> TextButton(onClick = { WorldPacks.cancel(id) }) { Text("Cancel") }
                        isInstalled -> Text("Added", color = WSColors.accent, fontSize = 14.sp)
                        else -> IconButton(onClick = { confirmAdd = Triple(name, region, url) }) {
                            Icon(Icons.Filled.Download, "Add $name", tint = WSColors.accent)
                        }
                    }
                    Box {
                        IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, "More") }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            if (isInstalled && !busy) {
                                DropdownMenuItem(text = { Text("Update from OpenStreetMap") },
                                    onClick = { menu = false; confirmAdd = Triple(name, region, url) })
                                DropdownMenuItem(text = { Text("Remove", color = WSColors.bad) },
                                    onClick = { menu = false; confirmRemove = id to name })
                            }
                            DropdownMenuItem(text = { Text("Open link in browser") }, onClick = {
                                menu = false
                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url.toString())))
                            })
                            DropdownMenuItem(text = { Text("Copy link") }, onClick = {
                                menu = false
                                (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                                    .setPrimaryClip(ClipData.newPlainText("OSM extract", url.toString()))
                            })
                        }
                    }
                }
                PhaseLine(phase)
            }
        }
    }

    confirmAdd?.let { (name, region, url) ->
        AlertDialog(
            onDismissRequest = { confirmAdd = null },
            title = { Text("Add $name?") },
            text = { Text("Downloads ${addSize ?: "…"} from OpenStreetMap, then turns it into stops and gyms on this phone. Use Wi-Fi, and keep the app open until it finishes.") },
            confirmButton = { TextButton(onClick = { OSMImport.importFromUrl(context, url, name, region); confirmAdd = null }) { Text("Download and Add") } },
            dismissButton = { TextButton(onClick = { confirmAdd = null }) { Text("Cancel") } },
        )
    }
    confirmRemove?.let { (id, name) ->
        AlertDialog(
            onDismissRequest = { confirmRemove = null },
            title = { Text("Remove $name?") },
            text = { Text("Its stops and gyms disappear from the map. You can add it again.") },
            confirmButton = { TextButton(onClick = { WorldPacks.remove(id); confirmRemove = null }) { Text("Remove", color = WSColors.bad) } },
            dismissButton = { TextButton(onClick = { confirmRemove = null }) { Text("Cancel") } },
        )
    }
}

/** Mirrors work/server/poidownload.py (COUNTRIES, US_STATES), as the iOS list does. */
object OSMRegions {
    const val BASE = "https://download.geofabrik.de/"
    val countries = listOf(
        "Canada" to "north-america/canada", "Mexico" to "north-america/mexico",
        "Great Britain" to "europe/great-britain", "Ireland" to "europe/ireland",
        "Germany" to "europe/germany", "France" to "europe/france", "Spain" to "europe/spain",
        "Portugal" to "europe/portugal", "Italy" to "europe/italy", "Netherlands" to "europe/netherlands",
        "Belgium" to "europe/belgium", "Luxembourg" to "europe/luxembourg", "Switzerland" to "europe/switzerland",
        "Austria" to "europe/austria", "Denmark" to "europe/denmark", "Norway" to "europe/norway",
        "Sweden" to "europe/sweden", "Finland" to "europe/finland", "Iceland" to "europe/iceland",
        "Poland" to "europe/poland", "Czechia" to "europe/czech-republic", "Slovakia" to "europe/slovakia",
        "Hungary" to "europe/hungary", "Slovenia" to "europe/slovenia", "Croatia" to "europe/croatia",
        "Romania" to "europe/romania", "Bulgaria" to "europe/bulgaria", "Greece" to "europe/greece",
        "Ukraine" to "europe/ukraine", "Estonia" to "europe/estonia", "Latvia" to "europe/latvia",
        "Lithuania" to "europe/lithuania", "Brazil" to "south-america/brazil", "Argentina" to "south-america/argentina",
        "Japan" to "asia/japan", "South Korea" to "asia/south-korea", "India" to "asia/india",
        "Australia" to "australia-oceania/australia", "New Zealand" to "australia-oceania/new-zealand",
        "South Africa" to "africa/south-africa",
    )
    val usStates = listOf(
        "Alabama", "Alaska", "Arizona", "Arkansas", "California", "Colorado", "Connecticut", "Delaware",
        "District of Columbia", "Florida", "Georgia", "Hawaii", "Idaho", "Illinois", "Indiana", "Iowa",
        "Kansas", "Kentucky", "Louisiana", "Maine", "Maryland", "Massachusetts", "Michigan", "Minnesota",
        "Mississippi", "Missouri", "Montana", "Nebraska", "Nevada", "New Hampshire", "New Jersey",
        "New Mexico", "New York", "North Carolina", "North Dakota", "Ohio", "Oklahoma", "Oregon",
        "Pennsylvania", "Puerto Rico", "Rhode Island", "South Carolina", "South Dakota", "Tennessee",
        "Texas", "Utah", "Vermont", "Virginia", "Washington", "West Virginia", "Wisconsin", "Wyoming",
    ).map { it to "north-america/us/" + it.lowercase().replace(' ', '-') }
}
