package com.windstock.launcher.mods

import com.windstock.launcher.AtomicFile
import com.windstock.launcher.Paths
import com.windstock.launcher.WSLog
import org.json.JSONObject

/** One switch in the mods menu. */
data class ModDescriptor(
    val key: String,
    val title: String,
    val blurb: String,
    val defaultOn: Boolean = true,
    /** Keys this mod needs; shown as "needs X" when X is off. */
    val requires: List<String> = emptyList(),
)

data class ModSection(val title: String, val mods: List<ModDescriptor>)

/**
 * Mirrors the gates in work/mods/android-035/index.js, the way the iOS catalog
 * mirrors Tweak.mm. A key here that the agent never reads does nothing, so the
 * two lists change together.
 *
 * Same keys as iOS. Since 2026-10-11 the agent has every iOS game mod except the
 * map's water/park colours (native code, no il2cpp name to hook). Keep Ball is
 * switched in the game's own Settings, coloured names and the GPS joystick's
 * camera steering are always on -- the same as iOS, which has no switch for them.
 * Unlike iOS the IV line and the launcher row don't need Mass Transfer: on iOS
 * they share its hand-verified call table, here everything is found by name.
 */
object ModsCatalog {
    val sections = listOf(
        ModSection("Gameplay", listOf(
            ModDescriptor("quick_catch", "Quick Catch",
                "Keeps the Run button on screen for the whole throw, so you can leave the encounter mid-catch."),
            ModDescriptor("mass_transfer", "Mass Transfer",
                "Long-press in storage to select and transfer pokemon."),
            ModDescriptor("appraisal_ivs", "IVs in Appraise",
                "Puts the Attack/Defense/Stamina numbers in the appraisal text."),
            ModDescriptor("shiny", "Shinies",
                "Shiny encounters with their recoloured models, and \"Shiny\" after the name in storage."),
            ModDescriptor("research", "Research",
                "Binoculars button on the map, the research screens and the All Events calendar. Unlocks at trainer level 5."),
            ModDescriptor("launcher_button", "Back to Launcher",
                "A Back to Launcher option at the bottom of the game's Settings that brings the launcher to the front."),
        )),
        ModSection("Movement", listOf(
            ModDescriptor("gps", "Location spoofing",
                "A joystick on the map: switch GPS on, then hold an arrow to walk, bike or drive from where you are.",
                defaultOn = false),
        )),
        ModSection("Presentation", listOf(
            ModDescriptor("night_music", "Night Music",
                "Swaps the map music after dark. Hours set below."),
            ModDescriptor("sound_packs", "Sound Packs",
                "Plays your own music and effect files from the pack folder. Pick a pack in the game's Settings > About."),
            ModDescriptor("fps60", "60 FPS",
                "Unlocks the frame rate, because the game caps at 30."),
            ModDescriptor("weather", "Weather",
                "Real local weather in the 3D scene: fog and haze on the map and in catches."),
            ModDescriptor("weather_rain3d", "Rain, Snow and Wind",
                "Falling rain with ripples, snow and gusts drawn in the 3D world, on the map and in catches.",
                requires = listOf("weather")),
        )),
    )

    val all = sections.flatMap { it.mods }

    fun descriptor(key: String) = all.firstOrNull { it.key == key }

    /** Tunables the agent reads out of the "values" section. */
    const val NIGHT_START_HOUR = "night_start_hour"
    const val NIGHT_END_HOUR = "night_end_hour"
}

/**
 * The file the agent reads, same shape as the iOS windstock-mods.json:
 *
 *     { "version": 1, "mods": { "<key>": bool }, "values": { "<key>": number } }
 *
 * The agent cannot read the launcher's files, so it asks for this through
 * ConfigProvider when the game starts.
 */
data class ModsConfig(
    val version: Int = 1,
    val mods: Map<String, Boolean> = emptyMap(),
    val values: Map<String, Double> = emptyMap(),
) {
    fun isOn(key: String) = mods[key] == true

    /** On, and everything it depends on is on. */
    fun isEffectivelyOn(key: String): Boolean {
        if (mods[key] != true) return false
        val d = ModsCatalog.descriptor(key) ?: return true
        return d.requires.all { isEffectivelyOn(it) }
    }

    fun with(key: String, on: Boolean) = copy(mods = mods + (key to on))

    fun toJson(): JSONObject = JSONObject().apply {
        put("version", version)
        put("mods", JSONObject().apply { mods.toSortedMap().forEach { (k, v) -> put(k, v) } })
        put("values", JSONObject().apply { values.toSortedMap().forEach { (k, v) -> put(k, v) } })
    }

    companion object {
        val defaults: ModsConfig
            get() = ModsConfig(mods = ModsCatalog.all.associate { it.key to it.defaultOn })

        fun load(): ModsConfig {
            val f = Paths.modsFile
            if (!f.exists()) return defaults
            return try {
                val o = JSONObject(f.readText())
                val mods = mutableMapOf<String, Boolean>()
                o.optJSONObject("mods")?.let { m -> m.keys().forEach { mods[it] = m.optBoolean(it) } }
                // Merge: a mod added in a later build shows up with its default;
                // a mod that no longer exists is dropped from the file.
                val known = ModsCatalog.all.map { it.key }.toSet()
                ModsCatalog.all.forEach { if (it.key !in mods) mods[it.key] = it.defaultOn }
                val values = mutableMapOf<String, Double>()
                o.optJSONObject("values")?.let { v -> v.keys().forEach { values[it] = v.optDouble(it) } }
                ModsConfig(o.optInt("version", 1), mods.filterKeys { it in known }, values)
            } catch (e: Exception) {
                WSLog("mods", "could not read mods.json (${e.message}) -- defaults")
                defaults
            }
        }

        fun save(config: ModsConfig) {
            try {
                AtomicFile.write(Paths.modsFile, config.toJson().toString(2))
            } catch (e: Exception) {
                WSLog("mods", "could not write mods.json: ${e.message}")
            }
        }
    }
}

/** The colours the server knows (work/server/colortags.py COLORS). */
object NameColor {
    val options = listOf(
        Triple("red", "Red", 0xff4040), Triple("orange", "Orange", 0xff9a1f),
        Triple("yellow", "Yellow", 0xffe14d), Triple("gold", "Gold", 0xf2b705),
        Triple("green", "Green", 0x3ccf5a), Triple("lime", "Lime", 0xa6f03c),
        Triple("teal", "Teal", 0x1fbfa6), Triple("cyan", "Cyan", 0x3de0ff),
        Triple("blue", "Blue", 0x3d8bff), Triple("navy", "Navy", 0x2340a0),
        Triple("purple", "Purple", 0xa55cff), Triple("pink", "Pink", 0xff6fcf),
        Triple("magenta", "Magenta", 0xff3dd6), Triple("brown", "Brown", 0xa0632d),
        Triple("white", "White", 0xffffff), Triple("gray", "Gray", 0x9aa4ad),
        Triple("black", "Black", 0x111111),
        Triple("mystic", "Mystic", 0x3d8bff), Triple("valor", "Valor", 0xff3d3d),
        Triple("instinct", "Instinct", 0xffd000),
    )
    val rainbow = listOf(0xff4040, 0xff9a1f, 0xffe14d, 0x3ccf5a, 0x3d8bff, 0xa55cff)
}
