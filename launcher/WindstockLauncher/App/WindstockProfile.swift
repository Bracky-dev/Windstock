import Foundation

/// The leaderboard, as the trainer playing on this phone sees it.
///
/// Only in Windstock Online mode, and with no sign-in of its own: the launcher
/// asks the Windstock server through its tunnel (GET /windstock/standing on the
/// tunnel's plain loopback port). The tunnel marks the request with this
/// phone's device id, and the server answers for whoever last logged in to the
/// game from this phone. The board itself only holds what the Windstock server
/// reported from its own saves, so the server on this phone (or anyone
/// else's) never feeds it, and with that server there is no leaderboard.
///
/// The standing (global position + the top of each board) is written into the
/// game's container as Documents/windstock-leaderboard.json, where the tweak's
/// research box reads it for its Leaderboard tab and the "Global position moved
/// up!" toast. No file means no tab.
@MainActor
final class WindstockProfile: ObservableObject {
    // The website runs on the Windstock VPS, behind Caddy's HTTPS.
    static let defaultSiteURL = URL(string: "https://windstock.org")!

    /// The website, for the "Open the leaderboard" link: Settings' "Website
    /// address" when filled in (testing), else the real site.
    var siteURL: URL {
        let typed = prefs().profileSiteURL.trimmingCharacters(in: .whitespaces)
        // The VPS's bare IP (saved by the 2026-09-30 launchers) is the same site: use its name.
        guard !typed.isEmpty, !typed.contains("2.29.24.78") else { return Self.defaultSiteURL }
        let withScheme = typed.contains("://") ? typed : "http://" + typed
        return URL(string: withScheme) ?? Self.defaultSiteURL
    }

    /// The trainer the server says plays on this phone (their name on the board).
    @Published private(set) var trainer: String?
    /// Global position on the "most caught" board; nil = not on it (yet).
    @Published private(set) var rank: Int?
    @Published private(set) var boardSize = 0
    /// Why there is no standing, for Settings ("Log in to the game first.").
    @Published private(set) var note: String?
    @Published private(set) var lastUpdate: Date?
    /// This trainer's invite link and how far their friends got; nil for a
    /// trainer without a website profile (name logins have no invite).
    @Published private(set) var invite: Invite?

    struct Invite: Equatable {
        let url: URL
        let invited: Int        // signed up with the link
        let counted: Int        // reached `level` and paid out
        let coins: Int          // PokeCoins per counted friend
        let level: Int
        let masterBallAt: Int
    }

    /// The launcher's prefs, read fresh each time (server mode, ports).
    var prefs: () -> LauncherPrefs = { LauncherPrefs() }

    /// Whether this phone can have a leaderboard at all.
    var isAvailable: Bool { prefs().serverMode == .online }

    private var timer: Timer?
    private static let every: TimeInterval = 15

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Asks the Windstock server (through the tunnel) where this phone's trainer
    /// stands. Off Online mode it only clears what an earlier session left.
    func refresh() {
        guard isAvailable else {
            clear(note: nil)
            return
        }
        let url = URL(string: "http://127.0.0.1:\(prefs().serverPlainPort)/windstock/standing")!
        Task {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                return              // tunnel not up yet / offline: keep the last one
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard isAvailable else { return clear(note: nil) }
            guard status == 200, body["ok"] as? Bool == true else {
                // 404: a server with no leaderboard. Otherwise not logged in yet
                // or not on the board (nothing caught or spun so far).
                clear(note: status == 404 ? "This server has no leaderboard."
                                          : body["error"] as? String ?? "No leaderboard right now.")
                return
            }
            trainer = body["username"] as? String
            rank = body["rank"] as? Int
            boardSize = body["total"] as? Int ?? 0
            note = nil
            lastUpdate = Date()
            invite = Self.invite(from: body["referral"] as? [String: Any], site: siteURL)
            writeStanding(body)
        }
    }

    private static func invite(from ref: [String: Any]?, site: URL) -> Invite? {
        guard let ref, let code = ref["code"] as? String, !code.isEmpty,
              var parts = URLComponents(url: site.appendingPathComponent("register.html"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [URLQueryItem(name: "ref", value: code)]
        guard let url = parts.url else { return nil }
        return Invite(url: url,
                      invited: ref["invited"] as? Int ?? 0,
                      counted: ref["counted"] as? Int ?? 0,
                      coins: ref["coinsPerFriend"] as? Int ?? 500,
                      level: ref["level"] as? Int ?? 5,
                      masterBallAt: ref["masterBallAt"] as? Int ?? 5)
    }

    private var standingFile: URL {
        URL(fileURLWithPath: WSPaths.container(forProfile: prefs().profile))
            .appendingPathComponent("Documents/windstock-leaderboard.json")
    }

    private func writeStanding(_ body: [String: Any]) {
        var out = body
        out.removeValue(forKey: "ok")
        out.removeValue(forKey: "login")
        out.removeValue(forKey: "referral")
        out["updatedAt"] = Int(Date().timeIntervalSince1970)
        do {
            try FileManager.default.createDirectory(
                at: standingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: out).write(to: standingFile, options: .atomic)
        } catch {
            WSLog("profile", "could not write the standing for the game: \(error.localizedDescription)")
        }
    }

    private func clear(note: String?) {
        trainer = nil
        rank = nil
        boardSize = 0
        invite = nil
        self.note = note
        if FileManager.default.fileExists(atPath: standingFile.path) {
            try? FileManager.default.removeItem(at: standingFile)
        }
    }
}

/// Launcher news for the Play screen: the short, player-worded "what's new" an admin
/// posts on the website's admin page (GET /api/news). The last answer is kept on disk,
/// so the card has something to show offline and the moment the app opens.
@MainActor
final class WindstockNews: ObservableObject {
    struct Item: Identifiable, Codable, Equatable {
        let id: String
        let at: Double          // ms since 1970
        let title: String
        let body: String

        var date: Date { Date(timeIntervalSince1970: at / 1000) }
    }

    @Published private(set) var items: [Item] = []
    /// The newest item the player has seen (its `at`); newer ones are marked New.
    @Published private(set) var seenAt: Double = 0

    /// The website (Settings' "Website address" when filled in).
    var siteURL: () -> URL = { WindstockProfile.defaultSiteURL }

    private var cacheFile: URL {
        URL(fileURLWithPath: WSPaths.launcherRoot).appendingPathComponent("news.json")
    }
    private var seenFile: URL {
        URL(fileURLWithPath: WSPaths.launcherRoot).appendingPathComponent("news-seen.txt")
    }
    private var fetchedAt: Date?

    init() {
        if let data = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode([Item].self, from: data) {
            items = cached
        }
        seenAt = Double((try? String(contentsOf: seenFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    func isNew(_ item: Item) -> Bool { item.at > seenAt }
    var unread: Int { items.filter(isNew).count }

    /// The player has looked at the list: nothing is New any more.
    func markSeen() {
        guard let newest = items.map(\.at).max(), newest > seenAt else { return }
        seenAt = newest
        try? String(Int(newest)).write(to: seenFile, atomically: true, encoding: .utf8)
    }

    /// Asks the website, at most every few minutes. A failure keeps what we had.
    func refresh(force: Bool = false) {
        if !force, let last = fetchedAt, Date().timeIntervalSince(last) < 300 { return }
        fetchedAt = Date()
        let url = siteURL().appendingPathComponent("api/news")
        Task {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = body["items"] as? [[String: Any]] else { return }
            let fresh = raw.compactMap { d -> Item? in
                guard let id = d["id"] as? String, let title = d["title"] as? String,
                      let text = d["body"] as? String else { return nil }
                return Item(id: id, at: (d["at"] as? NSNumber)?.doubleValue ?? 0, title: title, body: text)
            }.sorted { $0.at > $1.at }
            if fresh != items {
                items = fresh
                if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: cacheFile, options: .atomic) }
            }
            // A first install has seen nothing: only the newest counts as New, not the whole history.
            if seenAt == 0, fresh.count > 1 {
                seenAt = fresh[1].at
                try? String(Int(seenAt)).write(to: seenFile, atomically: true, encoding: .utf8)
            }
        }
    }
}
