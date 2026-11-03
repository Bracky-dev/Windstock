package com.windstock.launcher.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.windstock.launcher.Nav
import com.windstock.launcher.Route
import com.windstock.launcher.server.GameSettingsStore
import org.json.JSONArray
import org.json.JSONObject

/**
 * Server settings, in the app (GameSettingsView.swift). One screen per section,
 * each control chosen by the JSON type of its value, so a setting added on the
 * server appears here by itself.
 */
@Composable
fun GameSettingsScreen(nav: Nav, path: List<String>) {
    val sections by GameSettingsStore.sections.collectAsState()
    val error by GameSettingsStore.error.collectAsState()
    @Suppress("UNUSED_VARIABLE")
    val revision by GameSettingsStore.revision.collectAsState()
    LaunchedEffect(path) { if (path.isEmpty()) GameSettingsStore.reload() }

    if (path.isEmpty()) {
        error?.let { Section { Note(it, WSColors.warn) } }
        Section(footer = "Changes save as you make them and the server picks them up within a few seconds — no restart. Some only apply to Pokémon that spawn afterwards.") {
            sections.forEach { s -> NavRow(GameSettingsStore.label(s)) { nav.push(Route.ServerSettings(listOf(s))) } }
        }
        return
    }
    val keys = GameSettingsStore.keys(path)
    Section(footer = if (keys.isEmpty()) "Nothing in here." else null) {
        keys.forEach { key -> SettingRow(nav, path + key, key) }
    }
}

@Composable
private fun SettingRow(nav: Nav, full: List<String>, key: String) {
    val title = GameSettingsStore.label(key)
    val why = GameSettingsStore.explanation(full)
    val whyColor = if (why?.contains("EXPERIMENT") == true) WSColors.warn else null
    when (val v = GameSettingsStore.value(full)) {
        is Boolean -> ToggleRow(title, v, subtitle = why, subtitleColor = whyColor) { GameSettingsStore.set(full, it) }
        is Int, is Long -> NumberField(title, v.toString(), why, whyColor, decimal = false) { t ->
            t.toLongOrNull()?.let { GameSettingsStore.set(full, if (it in Int.MIN_VALUE..Int.MAX_VALUE) it.toInt() else it) }
        }
        is Double, is Float -> NumberField(title, v.toString(), why, whyColor, decimal = true) { t ->
            t.toDoubleOrNull()?.let { GameSettingsStore.set(full, it) }
        }
        is JSONObject -> NavRow(title, subtitle = why, value = GameSettingsStore.keys(full).size.toString()) {
            nav.push(Route.ServerSettings(full))
        }
        is JSONArray -> {
            // Lists here are short and numeric (species ids, egg distances), so
            // a comma-separated line is friendlier than a row editor.
            val joined = (0 until v.length()).joinToString(", ") { v.opt(it).toString() }
            var text by remember(full) { mutableStateOf(joined) }
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it; GameSettingsStore.set(full, GameSettingsStore.parseList(it, v)) },
                    label = { Text(title) },
                    modifier = Modifier.fillMaxWidth(),
                )
                why?.let { Text(it, style = androidx.compose.material3.MaterialTheme.typography.bodySmall, color = whyColor ?: androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
        else -> {
            var text by remember(full) { mutableStateOf(v?.toString()?.takeIf { v != JSONObject.NULL } ?: "") }
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it; GameSettingsStore.set(full, it) },
                    label = { Text(title) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                    modifier = Modifier.fillMaxWidth(),
                )
                why?.let { Text(it, style = androidx.compose.material3.MaterialTheme.typography.bodySmall, color = whyColor ?: androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
    }
}

@Composable
private fun NumberField(title: String, initial: String, why: String?, whyColor: androidx.compose.ui.graphics.Color?,
                        decimal: Boolean, onChange: (String) -> Unit) {
    var text by remember(title, initial) { mutableStateOf(initial) }
    ItemRow(title, why, whyColor) {
        OutlinedTextField(
            value = text,
            onValueChange = { t -> text = t; onChange(t) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = if (decimal) KeyboardType.Decimal else KeyboardType.Number),
            textStyle = androidx.compose.material3.LocalTextStyle.current.copy(textAlign = TextAlign.End),
            modifier = Modifier.widthIn(max = 120.dp),
        )
    }
}
