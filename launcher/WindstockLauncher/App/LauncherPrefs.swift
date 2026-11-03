import Foundation

/// Everything the launcher remembers between runs.
///
/// Stored as JSON at a path derived from the *real* sandbox home, not from
/// NSHomeDirectory(): by the time any of this runs the process home has already
/// been redirected into the guest's container. UserDefaults is avoided for the
/// same reason -- one file, one place, readable from the Files app when
/// something needs debugging on the phone.
struct LauncherPrefs: Codable, Equatable {
    enum ServerMode: String, Codable, CaseIterable {
        case embedded       // CPython inside this app
        case remote         // a server on the Mac / Tailscale
        case online         // a Windstock server on the internet, by IP
        case off            // don't touch networking at all
    }

    var profile: String = "default"

    /// The imported app to launch, or nil to use whatever was embedded at
    /// build time.
    var activeAppID: String?

    var autoLaunch: Bool = true
    var autoLaunchDelay: Double = 2.0
    /// The shortest autostart wait the Settings slider allows.
    static let minAutoLaunchDelay: Double = 0.5
    /// How many times the launcher has been started. The FIRST run never
    /// auto-launches -- you land in the launcher with time to set things up --
    /// and a run where the countdown gets cancelled does not count towards it
    /// either, so leaving the Play tab reliably buys you one more quiet start.
    var launchCount: Int = 0

    var serverMode: ServerMode = .online
    var serverPort: UInt16 = 8443
    /// Plain-HTTP listener, for the client's http-patched SSO.
    var serverPlainPort: UInt16 = 8080
    /// The World Manager (game editor), which Settings opens in a web view.
    /// Not 8080: that is the plain-HTTP listener's.
    var gameEditorPort: UInt16 = 8081
    var startServerOnLaunch: Bool = true
    /// Only used when serverMode == .remote.
    var remoteHost: String = ""
    /// A Mac can bind the real ports, so a remote server normally needs no
    /// port rewrite at all -- run.py defaults to 443.
    var remotePort: UInt16 = 443
    var remotePlainPort: UInt16 = 80
    /// Only used when serverMode == .online: "203.0.113.7:8888". An IP, not a
    /// name -- the whole point is that no DNS is involved. The port is the
    /// server's online_port (run.py opens it; TLS only -- the launcher's tunnel dials it).
    var onlineAddress: String = Distribution.onlineAddress

    /// Hostnames the client should reach on the embedded server.
    var redirectHostnames: [String] = [
        "pgorelease.nianticlabs.com",
        "*.nianticlabs.com",
        "sso.pokemon.com",
        "*.pokemon.com",
        "pokemongo.zendesk.com",
        "*.zendesk.com",
    ]

    /// Hosts we pass through UNCHANGED but log the outcome of.
    ///
    /// The map's roads come from Google Mobile Maps. That request works under
    /// LiveContainer with this same client and server, so it is not ours to
    /// answer -- an earlier build put this host in `redirectHostnames`, which
    /// made the launcher hijack it and reply with an empty tile, guaranteeing
    /// no roads. Observing tells us what Google actually says inside our app,
    /// which is the one thing the logs never showed.
    var observeHostnames: [String] = [
        "mobilemaps.clients.google.com",
    ]

    /// Answer tile requests from our own server instead of Google. Off: there
    /// is nothing to serve yet (see work/server/GMM-TILES.md) and hijacking
    /// only breaks a fetch that may well be working.
    var serveMapTiles: Bool = false

    /// Send the map's tile requests through the server on this phone (or the
    /// Online tunnel), which fetches them from Google and swaps the mint
    /// "vegetation" shading the 2016 client paints solid -- otherwise whole
    /// cities like Santa Monica draw as one park (gmm.py recolor). Parks keep
    /// their own green. On by default; off = straight to Google as before.
    var recolorMapTiles: Bool = true

    /// Where the World Data screen finds the country packs (catalog.json from
    /// tools/build_world_packs.py). Defaults to the one this build ships with,
    /// so players never have to type it.
    var worldCatalogURL: String = Distribution.worldCatalogURL

    var notificationsEnabled: Bool = true
    var notifyServerState: Bool = true
    var notifyEggs: Bool = true
    var notifyLures: Bool = true
    /// Minutes of warning before a lure runs out.
    var lureWarningMinutes: Int = 5

    var injectTweak: Bool = true
    /// Location spoofing (the joystick panel). Its own switch, because it is a
    /// separate dylib and plenty of sessions want the mods without it.
    ///
    /// OFF by default, so a fresh install behaves exactly as it did before the
    /// dylib existed: it is carried in the bundle but not loaded, and nothing
    /// about location changes until it is turned on here AND switched on in the
    /// panel it then puts on screen.
    var injectGPS: Bool = false

    /// Unused since 2026-10-03 (the leaderboard only counts the Windstock
    /// server's own numbers, see WindstockProfile.swift); kept so old prefs decode.
    var reportStats: Bool = false
    var reportTrainer: String = ""
    /// Website for the profile; "" = the Windstock VPS (WindstockProfile.defaultSiteURL). For testing
    /// against a copy on a Mac, e.g. "192.168.1.20:8787".
    var profileSiteURL: String = ""
    /// Shows the Windstock profile section before the website opens it to
    /// everyone (PROFILES_PUBLIC). Set by tapping Version in Settings 7 times.
    var profileUnlocked: Bool = false

    static let empty = LauncherPrefs()

    // Decoded key by key, every one optional, so a prefs file written by an
    // OLDER build still loads. The synthesised decoder throws on the first key
    // it cannot find, and PrefsStore reads that as "unreadable" and falls back
    // to defaults -- so adding one field here would silently reset the server
    // mode, the ports, the notification switches and everything else. Each new
    // field must be added to this list as well, taking its default from the
    // property above when the file has nothing to say about it.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LauncherPrefs()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        profile            = v(.profile, d.profile)
        activeAppID        = try? c.decodeIfPresent(String.self, forKey: .activeAppID)
        autoLaunch         = v(.autoLaunch, d.autoLaunch)
        autoLaunchDelay    = v(.autoLaunchDelay, d.autoLaunchDelay)
        autoLaunchDelay    = max(Self.minAutoLaunchDelay, autoLaunchDelay)
        launchCount        = v(.launchCount, d.launchCount)
        serverMode         = v(.serverMode, d.serverMode)
        serverPort         = v(.serverPort, d.serverPort)
        serverPlainPort    = v(.serverPlainPort, d.serverPlainPort)
        gameEditorPort     = v(.gameEditorPort, d.gameEditorPort)
        startServerOnLaunch = v(.startServerOnLaunch, d.startServerOnLaunch)
        remoteHost         = v(.remoteHost, d.remoteHost)
        remotePort         = v(.remotePort, d.remotePort)
        remotePlainPort    = v(.remotePlainPort, d.remotePlainPort)
        // Built in (Distribution.onlineAddress): a saved address from an older
        // launcher is ignored, so Windstock always means the Windstock server.
        onlineAddress      = d.onlineAddress
        redirectHostnames  = v(.redirectHostnames, d.redirectHostnames)
        observeHostnames   = v(.observeHostnames, d.observeHostnames)
        serveMapTiles      = v(.serveMapTiles, d.serveMapTiles)
        recolorMapTiles    = v(.recolorMapTiles, d.recolorMapTiles)
        worldCatalogURL    = v(.worldCatalogURL, d.worldCatalogURL)
        notificationsEnabled = v(.notificationsEnabled, d.notificationsEnabled)
        notifyServerState  = v(.notifyServerState, d.notifyServerState)
        notifyEggs         = v(.notifyEggs, d.notifyEggs)
        notifyLures        = v(.notifyLures, d.notifyLures)
        lureWarningMinutes = v(.lureWarningMinutes, d.lureWarningMinutes)
        injectTweak        = v(.injectTweak, d.injectTweak)
        injectGPS          = v(.injectGPS, d.injectGPS)
        reportStats        = v(.reportStats, d.reportStats)
        reportTrainer      = v(.reportTrainer, d.reportTrainer)
        profileSiteURL     = v(.profileSiteURL, d.profileSiteURL)
        profileUnlocked    = v(.profileUnlocked, d.profileUnlocked)
    }
}

/// A parsed "Windstock Online" address.
struct OnlineEndpoint: Equatable {
    static let defaultPort: UInt16 = 8888

    let host: String
    let port: UInt16

    /// "ip", "ip:port", or either with http:// in front and a / after (pasted
    /// from a browser). nil for anything that is not a dotted IPv4 address --
    /// a hostname would need the very DNS lookup this mode exists to avoid,
    /// and the connect() hook can only recognise an address it can compare.
    init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["http://", "https://"] where t.hasPrefix(scheme) {
            t.removeFirst(scheme.count)
        }
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber)
                                  && (Int($0) ?? 256) <= 255 }) else { return nil }
        host = octets.map { String(Int($0)!) }.joined(separator: ".")
        if parts.count == 2 {
            guard let p = UInt16(parts[1]), p > 0 else { return nil }
            port = p
        } else {
            port = Self.defaultPort
        }
    }

    var display: String { "\(host):\(port)" }
}

extension LauncherPrefs {
    /// The Windstock server. Built into the launcher; players can't change it.
    var onlineEndpoint: OnlineEndpoint? { OnlineEndpoint(Distribution.onlineAddress) }
}

/// Loads, saves and publishes the prefs. One instance, owned by LauncherModel.
final class PrefsStore {
    private let url: URL
    private(set) var value: LauncherPrefs

    init() {
        url = URL(fileURLWithPath: WSPaths.launcherPrefsFile)
        value = PrefsStore.read(from: url) ?? LauncherPrefs()
    }

    private static func read(from url: URL) -> LauncherPrefs? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(LauncherPrefs.self, from: data)
        } catch {
            // A prefs file written by an older build shouldn't brick the app;
            // fall back to defaults and say so.
            WSLog("prefs", "could not read launcher.json (\(error.localizedDescription)) -- using defaults")
            return nil
        }
    }

    func save(_ prefs: LauncherPrefs) {
        value = prefs
        do {
            try? FileManager.default.createDirectory(
                atPath: WSPaths.launcherRoot, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(prefs).write(to: url, options: .atomic)
            writeProfileMarker(prefs.profile)
        } catch {
            WSLog("prefs", "could not save launcher.json: \(error.localizedDescription)")
        }
    }

    /// The container bootstrap in main() runs long before Swift does and can't
    /// parse JSON, so the active profile is also mirrored to a one-line file it
    /// can read with fgets.
    private func writeProfileMarker(_ profile: String) {
        let path = (WSPaths.launcherRoot as NSString).appendingPathComponent("profile")
        try? profile.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
