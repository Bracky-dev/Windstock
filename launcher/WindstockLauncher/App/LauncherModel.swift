import Combine
import Foundation
import SwiftUI

/// The one object the UI talks to. Owns the prefs, the mods config, the
/// embedded server and the auto-launch countdown.
@MainActor
final class LauncherModel: ObservableObject {
    @Published var prefs: LauncherPrefs {
        didSet {
            guard prefs != oldValue else { return }
            prefsStore.save(prefs)
            applyNetworkSettings()
            notifier.update(prefs: prefs)
            if prefs.serverMode != oldValue.serverMode
                || (prefs.serverMode == .online && prefs.onlineAddress != oldValue.onlineAddress) {
                serverModeChanged(from: oldValue.serverMode)
            }
            if prefs.serverMode != oldValue.serverMode || prefs.onlineAddress != oldValue.onlineAddress {
                profile.refresh()
            }
        }
    }
    @Published var mods: ModsConfig {
        didSet {
            guard mods != oldValue else { return }
            modsStore.save(mods, profile: prefs.profile)
        }
    }

    @Published private(set) var serverState: WSPythonServerState = .stopped
    @Published private(set) var serverError: String?
    @Published private(set) var logLines: [String] = []

    /// Seconds left before the game starts on its own; nil when not counting.
    @Published private(set) var countdown: Double?
    @Published private(set) var launchError: String?
    @Published private(set) var guestIsInstalled: Bool
    /// The game is loaded and paused behind the launcher (the in-game home
    /// button). Play then means "resume", never a second launch.
    @Published private(set) var gameIsPaused = false
    /// Set when the Windstock server needs a newer launcher (settings
    /// launcher.min_build on the server, compared by tunnel.py): Play opens
    /// this download page instead of the game.
    @Published private(set) var updateURL: URL?

    let notifier = Notifier()
    let library = AppLibrary()
    let profile = WindstockProfile()
    let news = WindstockNews()
    let customDylibs = CustomDylibStore()

    private let prefsStore = PrefsStore()
    private let modsStore = ModsStore()
    /// SwiftUI only watches the object a view declares. A nested
    /// ObservableObject -- the library, the notifier -- publishes to itself
    /// and nobody hears it, which is why an imported game landed on disk and
    /// the list stayed empty. Re-emit their changes as ours.
    private var cancellables = Set<AnyCancellable>()
    /// Guards against a second attempt while one is in flight -- the retry
    /// and the countdown could otherwise stack up.
    private var isLaunching = false
    private var countdownTimer: Timer?
    private var statusTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let prefsStore = self.prefsStore
        prefs = prefsStore.value
        mods = modsStore.config
        guestIsInstalled = WSPaths.guestExecutablePath != nil

        // Write both files out on first run so the tweak has something to read
        // even if the user never opens the mods screen.
        prefsStore.save(prefs)
        modsStore.save(mods, profile: prefs.profile)

        for nested in [library.objectWillChange.eraseToAnyPublisher(),
                       notifier.objectWillChange.eraseToAnyPublisher(),
                       profile.objectWillChange.eraseToAnyPublisher(),
                       news.objectWillChange.eraseToAnyPublisher(),
                       customDylibs.objectWillChange.eraseToAnyPublisher()] {
            nested
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        observeServer()
        observeLog()
        observeGuest()
        WSNetRedirect.install()
        WSURLProtocol.install()
        applyNetworkSettings()
        notifier.update(prefs: prefs)
        profile.prefs = { [weak self] in self?.prefs ?? LauncherPrefs() }
        news.siteURL = { [weak self] in self?.profile.siteURL ?? WindstockProfile.defaultSiteURL }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - startup

    /// Called once from the app delegate, after the window is on screen.
    func start() {
        // First line of every log, so a log a tester sends says which IPA it is.
        WSLog("launcher", "Windstock \(SettingsView.versionString)")
        if (prefs.serverMode == .embedded && prefs.startServerOnLaunch)
            || prefs.serverMode == .online {
            startServer()
        }
        if prefs.serverMode == .online { checkForUpdate() }
        Task { await notifier.refreshAuthorization() }
        profile.start()
        news.refresh()

        // One-shot diagnostic: works out whether a dlopen refusal is about
        // the file's location or its signature. Cheap, and it runs before the
        // game launch so the answer is in the log either way.
        if SigningIdentityStore.hasIdentity {
            Task.detached(priority: .utility) { _ = LoadTest.run() }
        }
        // The first run never auto-launches. Landing straight in the game
        // before you have imported a certificate, picked mods or started the
        // server is not useful, so the launcher shows itself once and only
        // starts counting down from the second run onwards.
        prefs.launchCount += 1
        if prefs.autoLaunch && canPlay && prefs.launchCount >= 2 {
            beginCountdown()
        } else if prefs.autoLaunch && canPlay {
            WSLog("launcher", "first run -- not auto-launching")
        } else if !canPlay {
            WSLog("launcher", "no game imported or embedded -- staying in the launcher")
            logBundleLayout()
        }
    }

    /// What is actually in the bundle, when the launcher cannot find a game.
    /// A sideload signer that drops or renames a nested framework looks
    /// identical to "you never embedded one" without this.
    private func logBundleLayout() {
        let fm = FileManager.default
        let bundle = WSPaths.hostBundlePath
        WSLog("launcher", "bundle \(bundle)")
        for relative in ["Frameworks", "Guest"] {
            let path = (bundle as NSString).appendingPathComponent(relative)
            let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            let interesting = names.filter {
                $0.contains("pokemongo") || $0.contains("windstock") || $0.hasSuffix(".app")
            }
            WSLog("launcher", "  \(relative)/: \(names.count) entries"
                  + (interesting.isEmpty ? "" : " — \(interesting.joined(separator: ", "))"))
        }
        WSLog("launcher", "  guest executable: \(WSPaths.guestExecutablePath ?? "not found")")
        WSLog("launcher", "  guest bundle:     \(WSPaths.guestBundlePath ?? "not found")")
        WSLog("launcher", "  tweak:            \(WSPaths.tweakPath ?? "not found")")
    }

    // MARK: - server

    private func observeServer() {
        let observer = NotificationCenter.default.addObserver(
            forName: .WSPythonServerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.readServerState() }
        }
        observers.append(observer)
    }

    private func readServerState() {
        let server = WSPythonServer.shared
        let changed = server.state != serverState
        // Only assign what changed: a @Published assignment re-renders every
        // launcher screen even with the same value, and this runs every 3 s.
        if changed { serverState = server.state }
        if server.lastError != serverError { serverError = server.lastError }
        if changed {
            notifier.serverStateChanged(to: serverState, error: serverError)
            applyNetworkSettings()
        }
    }

    /// Starts what runs behind the two loopback ports: the game server
    /// ("On this phone"), or in Windstock Online the encrypted tunnel to the
    /// server on the internet. Either way the game is pointed at 127.0.0.1.
    func startServer() {
        switch prefs.serverMode {
        case .embedded:
            WSPythonServer.shared.start(onPort: prefs.serverPort)
        case .online:
            guard let endpoint = prefs.onlineEndpoint else { return }
            WSPythonServer.shared.start(onPort: prefs.serverPort, tunnelTarget: endpoint.display)
        case .remote, .off:
            return
        }
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            WSPythonServer.shared.refreshState()
        }
    }

    func stopServer() {
        WSPythonServer.shared.stop()
    }

    /// The mode (or the Online address) changed: the same ports now need
    /// something else behind them, or nothing.
    private func serverModeChanged(from old: LauncherPrefs.ServerMode) {
        switch prefs.serverMode {
        case .online:
            if prefs.onlineEndpoint != nil { startServer(); checkForUpdate() } else { stopServer() }
        case .embedded:
            // Coming from Online the tunnel is on these ports; start() swaps it
            // for the server. Otherwise respect "Start with the launcher".
            if old == .online || prefs.startServerOnLaunch { startServer() }
        case .remote, .off:
            if old == .embedded || old == .online { stopServer() }
        }
    }

    /// Windstock Online: forget the certificate saved for this server.
    func forgetOnlineCertificate() {
        WSPythonServer.shared.forgetOnlineCertificate()
    }

    /// Point the DNS/port hooks at whatever the current settings say.
    private func applyNetworkSettings() {
        // Tile requests go to the server on this phone when it recolours them
        // (or serves them); otherwise straight to Google, and we just report
        // the outcome. Only the URL protocol takes them: the DNS hooks must
        // leave the host alone, because that server is in this same process
        // and has to reach the real Google to fetch the tiles it fixes. Not
        // in Remote mode: a server on a Mac may predate the recolouring and
        // would answer with an empty tile (no roads at all).
        let viaServer = (prefs.recolorMapTiles && prefs.serverMode != .remote)
            || prefs.serveMapTiles
        let tileHosts = viaServer ? prefs.observeHostnames : []
        WSNetRedirect.hostnames = prefs.redirectHostnames
        WSURLProtocol.hostnames = prefs.redirectHostnames + tileHosts
        WSURLProtocol.observeHostnames = viaServer ? [] : prefs.observeHostnames
        // nil = the tweak's web views use 127.0.0.1:8080, which is right for
        // both modes that run something on this phone.
        let web: String? = nil
        defer {
            if mods.web != web { mods.web = web }
        }
        switch prefs.serverMode {
        case .embedded, .online:
            // Windstock Online looks exactly like the server-on-this-phone to
            // the game: the tunnel (tunnel.py) listens on the same two loopback
            // ports and carries everything to the server over TLS, checked
            // against that server's pinned certificate. Nothing leaves the
            // phone in the clear -- the game's plain-HTTP login included.
            WSNetRedirect.targetHost = "127.0.0.1"
            WSNetRedirect.localPort = prefs.serverPort
            WSNetRedirect.localPlainPort = prefs.serverPlainPort
            WSNetRedirect.isEnabled = (serverState == .running)
            WSURLProtocol.targetHost = "127.0.0.1"
            WSURLProtocol.localPort = prefs.serverPort
            WSURLProtocol.localPlainPort = prefs.serverPlainPort
            WSURLProtocol.isEnabled = (serverState == .running)
        case .remote:
            // This used to switch the hooks OFF and rely on a DNS redirect or
            // a VPN, which is how it works on Android. On iOS there is
            // neither, so the client just kept resolving Niantic's real
            // servers and hosting on a Mac never worked. Same interception as
            // the embedded case, pointed at the Mac instead of loopback.
            let host = prefs.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let usable = !host.isEmpty
            WSNetRedirect.targetHost = host
            WSNetRedirect.localPort = prefs.remotePort
            WSNetRedirect.localPlainPort = prefs.remotePlainPort
            WSNetRedirect.isEnabled = usable
            WSURLProtocol.targetHost = host
            WSURLProtocol.localPort = prefs.remotePort
            WSURLProtocol.localPlainPort = prefs.remotePlainPort
            WSURLProtocol.isEnabled = usable
            if !usable {
                WSLog("net", "remote mode selected but no host set")
            }
        case .off:
            WSNetRedirect.localPort = 0
            WSNetRedirect.isEnabled = false
            WSURLProtocol.isEnabled = false
        }
    }

    // MARK: - log

    /// True while the game owns the screen. The launcher's views still exist
    /// behind it and still re-render on every change to this model -- on the
    /// main thread, which is the game's render thread.
    private var gameOnScreen: Bool { WSGuestLoader.hasLaunched && !gameIsPaused }
    private var logRefreshPending = false

    private func observeLog() {
        logLines = WSLogStore.shared.lines()
        let observer = NotificationCenter.default.addObserver(
            forName: .WSLogDidAppend,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleLogRefresh() }
        }
        observers.append(observer)
    }

    /// The game and server log dozens of lines a second. Publishing each one
    /// copied the whole 2000-line log and redrew the launcher's screens (the
    /// Server tab filters and lays out 200 rows) per line, while playing --
    /// the "sometimes it lags" after coming back from the launcher. Now: not
    /// at all while the game is on screen (caught up when the launcher shows),
    /// and at most twice a second otherwise.
    private func scheduleLogRefresh() {
        guard !gameOnScreen, !logRefreshPending else { return }
        logRefreshPending = true
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.logRefreshPending = false
                if !self.gameOnScreen { self.logLines = WSLogStore.shared.lines() }
            }
        }
    }

    // MARK: - launching

    func beginCountdown() {
        guard countdown == nil else { return }
        let delay = max(LauncherPrefs.minAutoLaunchDelay, prefs.autoLaunchDelay)
        countdown = delay
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                guard let remaining = self.countdown else { timer.invalidate(); return }
                let next = remaining - 0.1
                if next <= 0 {
                    timer.invalidate()
                    self.countdown = nil
                    self.launchGame()
                } else {
                    self.countdown = next
                }
            }
        }
    }

    /// Tear the timer down without judging why. performHandover calls this on
    /// its way INTO the game, where refunding the run would be wrong.
    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
    }

    /// The user chose to stay in the launcher -- by tapping the button or by
    /// leaving the Play tab. Only meaningful while a countdown is actually
    /// running, so tab changes at any other time cost nothing.
    func cancelCountdown() {
        guard countdown != nil else { return }
        stopCountdown()
        // Give the run back. Cancelling means "not this time", so the next
        // start behaves like the one just interrupted rather than immediately
        // counting down again.
        prefs.launchCount = max(1, prefs.launchCount - 1)
        WSLog("launcher", "auto-launch cancelled -- next start will wait too")
    }

    /// The app the Play button starts: the chosen import, else the first
    /// import, else nil for the build-time embed.
    var activeApp: InstalledApp? {
        if let id = prefs.activeAppID, let match = library.apps.first(where: {
            $0.id.uuidString == id
        }) { return match }
        return library.apps.first
    }

    var canPlay: Bool { activeApp != nil || guestIsInstalled }

    private func observeGuest() {
        for (name, paused) in [(NSNotification.Name.WSGuestLoaderDidShowLauncher, true),
                               (NSNotification.Name.WSGuestLoaderDidResumeGuest, false)] {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.gameIsPaused = paused
                    if paused { self.logLines = WSLogStore.shared.lines() }   // catch up
                }
            }
            observers.append(observer)
        }
    }

    /// Straight back into the paused game. From a run-loop timer for the same
    /// reason as the handover: the button's own window is taken off screen.
    func resumeGame() {
        guard WSGuestLoader.hasLaunched else { return }
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            WSGuestLoader.resumeGuest()
        }
    }

    /// Asks the launcher's tunnel whether the Windstock server takes this
    /// build ("updateRequired" in /windstock/tunnel). Retries while the tunnel
    /// is still starting.
    func checkForUpdate(attempt: Int = 0) {
        guard prefs.serverMode == .online,
              let url = URL(string: "http://127.0.0.1:\(prefs.serverPlainPort)/windstock/tunnel")
        else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            Task { @MainActor in
                guard let self else { return }
                guard json?["tunnel"] as? Bool == true, json?["ok"] as? Bool == true else {
                    if attempt < 8 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.checkForUpdate(attempt: attempt + 1)
                        }
                    }
                    return
                }
                if json?["updateRequired"] as? Bool == true {
                    let link = URL(string: json?["updateURL"] as? String ?? "")
                        ?? URL(string: "https://windstock.org/downloads.html")!
                    WSLog("launcher", "the Windstock server needs a newer launcher "
                          + "(this is build \(json?["launcherBuild"] ?? "?"), it needs "
                          + "\(json?["minBuild"] ?? "?")) -- Play opens \(link.absoluteString)")
                    self.updateURL = link
                    self.stopCountdown()
                } else {
                    self.updateURL = nil
                }
            }
        }.resume()
    }

    /// The download page, in Safari.
    func openUpdate() {
        guard let url = updateURL else { return }
        UIApplication.shared.open(url)
    }

    /// Hands the process to the game. Does not return when it works.
    func launchGame() {
        if WSGuestLoader.hasLaunched {
            resumeGame()
            return
        }
        if updateURL != nil {
            openUpdate()
            return
        }
        guard !isLaunching else { return }
        isLaunching = true
        scheduleHandover(retryAfterResigning: true)
    }

    /// Hand the process over from a run-loop timer, never from a main-queue
    /// block.
    ///
    /// The guest's UIApplicationMain never returns -- it parks in
    /// CFRunLoopRun() -- and libdispatch will not re-enter the main queue
    /// while it is already draining one block. Launching from a Task (which
    /// is a main-queue block) therefore wedges the main queue for the rest of
    /// the process: run-loop timers keep firing, so the game renders, but
    /// everything UIKit dispatches to the main queue silently never runs, and
    /// text input is the visible casualty. A timer callback comes from
    /// __CFRunLoopDoTimer instead, leaving the main queue free to drain
    /// inside the nested loop.
    private func scheduleHandover(retryAfterResigning: Bool) {
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performHandover(retryAfterResigning: retryAfterResigning)
            }
        }
    }

    /// A free certificate lasts a week, so a game signed under the previous
    /// one is the normal state of things after a refresh -- and it fails with
    /// "code signature invalid", which reads like a bug rather than a chore.
    /// Sign it again and try once more instead of making the user work it out.
    private func performHandover(retryAfterResigning: Bool) {
        stopCountdown()
        launchError = nil

        // Last chance to get the mods file in front of the tweak: it is read
        // once, in the tweak's constructor, which runs a few lines from here.
        modsStore.save(mods, profile: prefs.profile)

        var injected: [String] = []
        if prefs.injectTweak, let tweak = WSPaths.tweakPath {
            injected.append(tweak)
        }
        if prefs.injectGPS, let gps = WSPaths.gpsTweakPath {
            injected.append(gps)
        }
        injected += customDylibs.pathsForLaunch()
        WSGuestLoader.setInjectedDylibs(injected)

        WSLog("signing", "host signature: \(HostSignature.describe())")
        WSLog("launcher", "launching the game (profile \(prefs.profile), "
              + "\(injected.count) tweak\(injected.count == 1 ? "" : "s"))")

        do {
            if let app = activeApp {
                guard let bundlePath = library.bundlePath(for: app) else {
                    launchError = "\(app.name) has no resource bundle on disk. Import it again."
                    return
                }
                try WSGuestLoader.launchExecutable(library.executablePath(for: app),
                                                   bundlePath: bundlePath)
            } else {
                try WSGuestLoader.launch()
            }
        } catch {
            let message = error.localizedDescription
            WSLog("launcher", "launch failed: \(message)")

            if retryAfterResigning, let app = activeApp,
               message.localizedCaseInsensitiveContains("code signature") {
                WSLog("launcher", "signature rejected — signing \(app.name) again "
                      + "with the current certificate and retrying")
                Task {
                    do {
                        try await self.library.resign(app)
                        self.scheduleHandover(retryAfterResigning: false)
                    } catch {
                        self.launchError = "Could not sign \(app.name) again: "
                            + error.localizedDescription
                        self.isLaunching = false
                    }
                }
                return
            }
            launchError = message
            isLaunching = false
        }
    }
}
