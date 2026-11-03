package com.windstock.launcher.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.windstock.launcher.Launcher
import com.windstock.launcher.Paths
import com.windstock.launcher.mods.ModsCatalog
import com.windstock.launcher.mods.ModsConfig
import com.windstock.launcher.mods.NameColor
import com.windstock.launcher.server.GameSettingsStore

@Composable
fun ModsScreen() {
    val mods by Launcher.mods.collectAsState()
    val prefs by Launcher.prefs.collectAsState()

    Section {
        Note("Changes apply the next time the game starts." +
            if (!prefs.injectMods) " Mods are switched off in Settings, so none of these load." else "")
    }

    ModsCatalog.sections.forEach { section ->
        Section(section.title) {
            section.mods.forEach { mod ->
                val unmet = mod.requires.filter { !mods.isEffectivelyOn(it) }
                ToggleRow(
                    mod.title,
                    mods.isOn(mod.key),
                    subtitle = mod.blurb + if (unmet.isNotEmpty())
                        "\n↳ Needs " + unmet.mapNotNull { ModsCatalog.descriptor(it)?.title }.joinToString(" + ") else "",
                ) { on -> Launcher.updateMods { it.with(mod.key, on) } }
            }
        }
    }

    NameColorsSection()

    Section("Night music hours") {
        HourPicker("Starts at", mods.values[ModsCatalog.NIGHT_START_HOUR]?.toInt() ?: 19) { h ->
            Launcher.updateMods { it.copy(values = it.values + (ModsCatalog.NIGHT_START_HOUR to h.toDouble())) }
        }
        HourPicker("Ends at", mods.values[ModsCatalog.NIGHT_END_HOUR]?.toInt() ?: 6) { h ->
            Launcher.updateMods { it.copy(values = it.values + (ModsCatalog.NIGHT_END_HOUR to h.toDouble())) }
        }
    }

    Section {
        TextButton(onClick = { Launcher.updateMods { ModsConfig.defaults } }) { Text("Reset to defaults") }
    }
}

/** 0-23, shown as "19:00" like the iOS hour picker. */
@Composable
private fun HourPicker(title: String, hour: Int, onPick: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    fun label(h: Int) = "%02d:00".format(h)
    ItemRow(title, onClick = { open = true }, trailing = {
        Box {
            Text(label(hour), color = androidx.compose.material3.MaterialTheme.colorScheme.primary)
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                (0..23).forEach { h ->
                    DropdownMenuItem(text = { Text(label(h)) }, onClick = { open = false; onPick(h) })
                }
            }
        }
    })
}

/**
 * Colours for trainer / PokeStop / Gym names. SERVER settings (settings.json
 * "names"), so they apply on the next map refresh, no game restart needed.
 */
@Composable
private fun NameColorsSection() {
    var trainer by remember { mutableStateOf("") }
    var stop by remember { mutableStateOf("") }
    var gym by remember { mutableStateOf("") }
    var noServer by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        fun read(k: String) = (GameSettingsStore.readValue("names", k) as? String ?: "").lowercase()
        noServer = !Paths.settingsFile.exists()
        trainer = read("trainer_color"); stop = read("stop_color"); gym = read("gym_color")
    }
    Section("Colored names",
        footer = "You can also color any name you type in the game — your trainer name or a Pokémon's nickname — with tags: [red]Ash, [gold]Ash[/]ketchum, [f80]Ash or [rainbow]Ash. A name with its own tags keeps them.") {
        if (noServer) Note("Start the server once, then these can be set.", WSColors.warn)
        ColorPicker("Trainer name", "Trainer", trainer, team = false, enabled = !noServer) {
            trainer = it; noServer = !GameSettingsStore.writeValue("names", "trainer_color", it)
        }
        ColorPicker("PokéStop names", "PokéStop", stop, team = false, enabled = !noServer) {
            stop = it; noServer = !GameSettingsStore.writeValue("names", "stop_color", it)
        }
        ColorPicker("Gym names", "Gym", gym, team = true, enabled = !noServer) {
            gym = it; noServer = !GameSettingsStore.writeValue("names", "gym_color", it)
        }
    }
}

private fun color(hex: Int) = Color(0xFF000000 or hex.toLong())

/** How a name looks with this setting ("" = plain, "rainbow", "team", a key). */
private fun preview(text: String, key: String): AnnotatedString = buildAnnotatedString {
    when (key) {
        "rainbow" -> {
            var i = 0
            text.forEach { ch ->
                if (ch == ' ') append(' ')
                else withStyle(SpanStyle(color = color(NameColor.rainbow[i++ % NameColor.rainbow.size]))) { append(ch) }
            }
        }
        "team" -> {
            withStyle(SpanStyle(color = color(0x3d8bff))) { append("Gym") }; append(" ")
            withStyle(SpanStyle(color = color(0xff3d3d))) { append("Gym") }; append(" ")
            withStyle(SpanStyle(color = color(0xffd000))) { append("Gym") }
        }
        else -> {
            val hex = NameColor.options.firstOrNull { it.first == key }?.third
            if (hex == null) append(text) else withStyle(SpanStyle(color = color(hex))) { append(text) }
        }
    }
}

@Composable
private fun ColorPicker(title: String, sample: String, value: String, team: Boolean,
                        enabled: Boolean, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val label = when (value) {
        "" -> "Plain"; "team" -> "Team color"; "rainbow" -> "Rainbow"
        else -> NameColor.options.firstOrNull { it.first == value }?.second ?: value
    }
    ItemRow(title, onClick = if (enabled) ({ open = true }) else null, trailing = {
        Box {
            Text(label, color = androidx.compose.material3.MaterialTheme.colorScheme.primary)
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                val choices = buildList {
                    add(Triple("", "Plain", null as Int?))
                    if (team) add(Triple("team", "Team color", null))
                    add(Triple("rainbow", "Rainbow", null))
                    NameColor.options.forEach { add(Triple(it.first, it.second, it.third)) }
                }
                choices.forEach { (key, name, hex) ->
                    DropdownMenuItem(
                        text = { Text(name) },
                        leadingIcon = hex?.let { h ->
                            {
                                Box(Modifier.size(16.dp).background(color(h), CircleShape)
                                    .border(1.dp, Color.Black.copy(alpha = 0.15f), CircleShape))
                            }
                        },
                        onClick = { open = false; onPick(key) },
                    )
                }
            }
        }
    })
    Text(preview(sample, value), fontWeight = FontWeight.Bold,
        style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
        modifier = Modifier.padding(start = 16.dp, bottom = 8.dp))
}
