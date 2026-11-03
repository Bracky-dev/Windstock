import Foundation

/// The file the tweak reads. Shape matches WSConfig.inc.mm:
///
///     { "version": 1, "mods": { "<key>": bool }, "values": { "<key>": number },
///       "web": "http://ip:port" (optional) }
struct ModsConfig: Codable, Equatable {
    var version: Int = 1
    var mods: [String: Bool] = [:]
    var values: [String: Double] = [:]
    /// Where the tweak's web views go (the Radar map, the Help Center), e.g.
    /// "http://203.0.113.7:8888". nil = the embedded server on loopback. Web
    /// views network out of process, so the in-app redirect never sees them
    /// and they need the real address. Set by LauncherModel from the server mode.
    var web: String?

    static var defaults: ModsConfig {
        var config = ModsConfig()
        for mod in ModsCatalog.all {
            config.mods[mod.key] = mod.defaultOn
        }
        config.values[ModsCatalog.nightStartHour] = 19
        config.values[ModsCatalog.nightEndHour] = 6
        return config
    }

    /// Whether a mod is on *and* everything it depends on is on. The tweak
    /// enforces the same thing (install_shinies needs the mass-transfer tables);
    /// duplicating it here is what lets the UI explain why a row is inert.
    func isEffectivelyOn(_ key: String) -> Bool {
        guard mods[key] == true else { return false }
        guard let descriptor = ModsCatalog.descriptor(for: key) else { return true }
        return descriptor.requires.allSatisfy { isEffectivelyOn($0) }
    }
}

/// Writes the mods config to the two places it has to exist: the launcher's own
/// copy (the master, survives a container wipe) and the guest container, which
/// is the only one the tweak can see -- it reads
/// NSHomeDirectory()/Documents/windstock-mods.json from inside the game.
final class ModsStore {
    private(set) var config: ModsConfig
    private let masterURL: URL

    init() {
        masterURL = URL(fileURLWithPath: WSPaths.modsConfigFile)
        if let data = try? Data(contentsOf: masterURL),
           let decoded = try? JSONDecoder().decode(ModsConfig.self, from: data) {
            // Merge, so a mod added in a later build shows up with its default
            // rather than silently missing.
            var merged = decoded
            for mod in ModsCatalog.all where merged.mods[mod.key] == nil {
                merged.mods[mod.key] = mod.defaultOn
            }
            // Drop keys from mods that no longer exist, so a config written by
            // an older build does not keep a dropped mod alive in the file the
            // tweak reads.
            let known = Set(ModsCatalog.all.map(\.key))
            merged.mods = merged.mods.filter { known.contains($0.key) }
            for (key, value) in ModsConfig.defaults.values where merged.values[key] == nil {
                merged.values[key] = value
            }
            config = merged
        } else {
            config = .defaults
        }
    }

    @discardableResult
    func save(_ config: ModsConfig, profile: String) -> Bool {
        self.config = config
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return false }

        var ok = true
        try? FileManager.default.createDirectory(
            atPath: WSPaths.launcherRoot, withIntermediateDirectories: true)
        do {
            try data.write(to: masterURL, options: .atomic)
        } catch {
            WSLog("mods", "could not write mods.json: \(error.localizedDescription)")
            ok = false
        }

        let container = WSPaths.container(forProfile: profile)
        let guestDocs = (container as NSString).appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(
            atPath: guestDocs, withIntermediateDirectories: true)
        let guestURL = URL(fileURLWithPath:
            (guestDocs as NSString).appendingPathComponent("windstock-mods.json"))
        do {
            try data.write(to: guestURL, options: .atomic)
        } catch {
            WSLog("mods", "could not write the guest copy: \(error.localizedDescription)")
            ok = false
        }
        return ok
    }
}
