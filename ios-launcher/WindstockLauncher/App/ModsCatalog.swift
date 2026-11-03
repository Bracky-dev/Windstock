import Foundation

/// One switch in the mods menu.
struct ModDescriptor: Identifiable, Hashable {
    let key: String
    let title: String
    let blurb: String
    let defaultOn: Bool
    /// Keys this mod needs; shown as "needs X" and greyed out when X is off.
    let requires: [String]

    init(_ key: String, _ title: String, _ blurb: String,
         defaultOn: Bool = true, requires: [String] = []) {
        self.key = key
        self.title = title
        self.blurb = blurb
        self.defaultOn = defaultOn
        self.requires = requires
    }

    var id: String { key }
}

struct ModSection: Identifiable, Hashable {
    let title: String
    let mods: [ModDescriptor]
    var id: String { title }
}

/// The catalog mirrors the gates in work/mods/ios-tweak-035/Tweak.mm. A key
/// here with no matching ws_mod() call in the tweak does nothing, so the two
/// lists have to be changed together.
///
/// Raids and the storage IV percentage are #define'd to 0 in the tweak and
/// are deliberately absent -- a switch that cannot do anything is worse than
/// no switch. Weather (3D fog, rain, snow, wind) is shelved again since tweak
/// v150 (WEATHER_FX 0): its switches are gone, the tweak keeps its code.
enum ModsCatalog {
    static let sections: [ModSection] = [
        ModSection(title: "Gameplay", mods: [
            ModDescriptor("quick_catch", "Quick Catch",
                          "Keeps the Run button on screen for the whole throw, so you can leave the encounter mid-catch."),
            ModDescriptor("mass_transfer", "Mass Transfer",
                          "Long-press in storage to select and transfer pokemon."),
            ModDescriptor("appraisal_ivs", "IVs in Appraise",
                          "Puts the Attack/Defense/Stamina numbers in the appraisal text.",
                          requires: ["mass_transfer"]),
            ModDescriptor("shiny", "Shinies",
                          "Shiny encounters, sparkles on the map and in storage. Beta, there is a known isuue with sparkles showing up on details screens.",
                          requires: ["mass_transfer"]),
            ModDescriptor("research", "Research",
                          "Binoculars button on the map and the research screens.",
                          requires: ["mass_transfer"]),
            ModDescriptor("launcher_button", "Back to Launcher",
                          "A Back to Launcher option at the bottom of the game's Settings that pauses the game and opens the launcher.",
                          requires: ["mass_transfer"]),
        ]),
        ModSection(title: "Presentation", mods: [
            ModDescriptor("night_music", "Night Music",
                          "Swaps the map music after dark. Hours set below."),
            ModDescriptor("sound_packs", "Sound Packs",
                          "Plays your own music and effect files from the pack folder."),
            ModDescriptor("fps60", "60 FPS",
                          "Unlocks the frame rate because the game caps at 30. (normally)"),
        ]),
    ]

    static let all: [ModDescriptor] = sections.flatMap(\.mods)

    static func descriptor(for key: String) -> ModDescriptor? {
        all.first { $0.key == key }
    }

    /// Tunables the tweak reads out of the "values" section.
    static let nightStartHour = "night_start_hour"
    static let nightEndHour = "night_end_hour"
}
