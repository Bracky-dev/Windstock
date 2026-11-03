import Foundation

/// The server's settings.json, edited in the app instead of the web page.
///
/// Read and written straight off disk rather than through an API, which means
/// it works with the server stopped, and the running server picks changes up on
/// its own: settings.py re-reads the file when its modification time changes.
///
/// Deliberately driven by the file's own contents rather than a hand-written
/// screen per section. There are 19 sections and about 160 keys, and the server
/// gains more; a typed screen would be stale the week after it was written.
/// Every value is rendered from its JSON type, so a key added on the server
/// shows up here with no app change at all.
@MainActor
final class GameSettingsStore: ObservableObject {
    @Published private(set) var sections: [String] = []
    @Published private(set) var error: String?
    /// Bumped on every save so views refresh; the values live in `root`.
    @Published private(set) var revision = 0

    private var root: [String: Any] = [:]
    private var saveWork: DispatchWorkItem?
    /// "section.key" -> what it does, built at staging time from the server's
    /// own comments (tools/extract_settings_help.py).
    private var help: [String: String] = [:]

    nonisolated static var url: URL {
        URL(fileURLWithPath: WSPaths.serverDataDir)
            .appendingPathComponent("data/settings.json")
    }

    init() {
        loadHelp()
        reload()
    }

    private func loadHelp() {
        let url = URL(fileURLWithPath: WSPaths.pythonServerDir)
            .appendingPathComponent("settings_help.json")
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        help = map
    }

    /// What this setting does, if the server documents it.
    func explanation(for path: [String]) -> String? {
        // Nested groups (pokestops.loot.poke_ball.chance) document the group.
        guard path.count >= 2 else { return nil }
        return help["\(path[0]).\(path[1])"]
    }

    func reload() {
        do {
            let data = try Data(contentsOf: Self.url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                error = "settings.json is not what we expected."
                return
            }
            root = obj
            // "_readme" and friends are the file's own documentation.
            sections = obj.keys.filter { !$0.hasPrefix("_") }
                              .filter { obj[$0] is [String: Any] }
                              .sorted()
            error = nil
        } catch CocoaError.fileNoSuchFile {
            error = "No settings yet — start the server once."
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Keys of a section (or of a nested group inside one), in a stable order.
    func keys(_ path: [String]) -> [String] {
        guard let dict = value(at: path) as? [String: Any] else { return [] }
        return dict.keys.filter { !$0.hasPrefix("_") }.sorted()
    }

    func value(at path: [String]) -> Any? {
        var node: Any? = root
        for step in path {
            guard let dict = node as? [String: Any] else { return nil }
            node = dict[step]
        }
        return node
    }

    func set(_ newValue: Any, at path: [String]) {
        guard !path.isEmpty else { return }
        root = Self.setting(newValue, at: path, in: root)
        revision += 1
        scheduleSave()
    }

    private static func setting(_ newValue: Any, at path: [String],
                                in dict: [String: Any]) -> [String: Any] {
        var copy = dict
        let head = path[0]
        if path.count == 1 {
            copy[head] = newValue
        } else if let child = copy[head] as? [String: Any] {
            copy[head] = setting(newValue, at: Array(path.dropFirst()), in: child)
        }
        return copy
    }

    /// Typing in a field fires a change per keystroke; writing the file that
    /// often would have the server re-reading it constantly.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func save() {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            // Atomic: the server may read this file at any moment, and a
            // half-written settings.json would be parsed as "no settings".
            try data.write(to: Self.url, options: .atomic)
            error = nil
            WSLog("settings", "saved settings.json")
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }

    /// One value straight off disk, for screens (the Mods tab) that don't keep
    /// a whole store open.
    nonisolated static func readValue(_ section: String, _ key: String) -> Any? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (obj[section] as? [String: Any])?[key]
    }

    /// Read-modify-write of one value, so it can't clobber an edit made on the
    /// Server tab since that screen last loaded. Creates the section when the
    /// file predates it (the server tops it up with the rest on its next read).
    /// False when there is no settings.json yet: the server has never run.
    @discardableResult
    nonisolated static func writeValue(_ value: Any, _ section: String, _ key: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        var sec = obj[section] as? [String: Any] ?? [:]
        sec[key] = value
        obj[section] = sec
        guard let out = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try out.write(to: url, options: .atomic)
            WSLog("settings", "saved \(section).\(key)")
            return true
        } catch {
            WSLog("settings", "could not save \(section).\(key): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - display

    /// "xp_per_catch" -> "XP per catch", "min_cp" -> "Min CP".
    static func label(_ key: String) -> String {
        let acronyms: Set<String> = ["xp", "cp", "iv", "ivs", "hp", "km", "m", "ms", "id", "url"]
        let words = key.split(separator: "_").map(String.init)
        return words.enumerated().map { index, word -> String in
            if acronyms.contains(word.lowercased()) { return word.uppercased() }
            return index == 0 ? word.capitalized : word
        }.joined(separator: " ")
    }
}

/// What kind of control a value needs. Worked out from the JSON type, because
/// that is the only thing the file tells us.
enum SettingKind {
    case flag(Bool)
    case whole(Int)
    case decimal(Double)
    case text(String)
    case group          // a nested object: another screen
    case list([Any])

    init(_ value: Any?) {
        // JSONSerialization hands back BOTH booleans and numbers as NSNumber,
        // so `as? Bool` would turn every 0/1 setting into a switch. Only
        // CFBoolean is really a boolean, and only CFNumber knows whether it
        // was written as 5 or 5.0.
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .flag(n.boolValue); return }
            self = CFNumberIsFloatType(n) ? .decimal(n.doubleValue) : .whole(n.intValue)
            return
        }
        switch value {
        case let s as String: self = .text(s)
        case let a as [Any]: self = .list(a)
        case is [String: Any]: self = .group
        default: self = .text("")
        }
    }
}
