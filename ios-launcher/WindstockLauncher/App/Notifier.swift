import Foundation
import UserNotifications

/// Local notifications for things worth knowing while the phone is in a pocket.
///
/// Remote push is not an option here: aps-environment is not in a free
/// development profile. It is also not needed -- the server runs in this same
/// process and its state lives in files we own, so the launcher can watch them
/// directly and post local notifications.
///
/// Two sources, both read straight from the server's data directory:
///   * lures.json  -- expires_ms per lured stop
///   * save.json   -- eggs + incubators + stats.km_walked
/// plus the embedded server's own lifecycle.
@MainActor
final class Notifier: ObservableObject {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastPosted: String?

    private var timer: Timer?
    private var prefs: LauncherPrefs = .empty
    /// Identifiers already notified, so a 30-second poll doesn't nag.
    private var announced = Set<String>()

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
    }

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            WSLog("notify", "authorization \(granted ? "granted" : "denied")")
        } catch {
            WSLog("notify", "authorization failed: \(error.localizedDescription)")
        }
        await refreshAuthorization()
    }

    func update(prefs: LauncherPrefs) {
        self.prefs = prefs
        timer?.invalidate()
        guard prefs.notificationsEnabled else {
            timer = nil
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = 10
        self.timer = timer
        poll()
    }

    func post(title: String, body: String, id: String = UUID().uuidString) {
        guard prefs.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                WSLog("notify", "post failed: \(error.localizedDescription)")
            }
        }
        lastPosted = "\(title) — \(body)"
        WSLog("notify", "\(title): \(body)")
    }

    // MARK: - server lifecycle

    func serverStateChanged(to state: WSPythonServerState, error: String?) {
        guard prefs.notifyServerState else { return }
        // On Windstock the "server" is only the tunnel to it: its start is not news,
        // and a failure means the connection, not a server on this phone.
        let online = prefs.serverMode == .online
        switch state {
        case .running:
            if !online {
                post(title: "Server running", body: "Listening on port \(prefs.serverPort).",
                     id: "server.running")
            }
        case .failed:
            post(title: online ? "Lost the connection to Windstock" : "Server stopped with an error",
                 body: error ?? "See the log for details.", id: "server.failed")
        case .stopped, .starting:
            break
        @unknown default:
            break
        }
    }

    // MARK: - polling the server's own files

    private var dataDir: String {
        (WSPaths.serverDataDir as NSString).appendingPathComponent("data")
    }

    private func poll() {
        if prefs.notifyLures { pollLures() }
        if prefs.notifyEggs { pollEggs() }
    }

    private func json(_ name: String) -> [String: Any]? {
        let path = (dataDir as NSString).appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private func pollLures() {
        guard let lures = json("lures.json")?["lures"] as? [String: Any] else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let warning = Double(prefs.lureWarningMinutes) * 60_000

        for (fortID, raw) in lures {
            guard let lure = raw as? [String: Any],
                  let expires = lure["expires_ms"] as? Double else { continue }
            let remaining = expires - now
            guard remaining > 0, remaining <= warning else { continue }
            let id = "lure.\(fortID).\(Int(expires))"
            guard !announced.contains(id) else { continue }
            announced.insert(id)
            let minutes = max(1, Int((remaining / 60_000).rounded()))
            post(title: "Lure running out",
                 body: "A lure has about \(minutes) minute\(minutes == 1 ? "" : "s") left.",
                 id: id)
        }
    }

    private func pollEggs() {
        guard let save = json("save.json") else { return }
        let walked = ((save["stats"] as? [String: Any])?["km_walked"] as? Double) ?? 0
        guard let incubators = save["incubators"] as? [[String: Any]] else { return }

        for incubator in incubators {
            guard let egg = incubator["egg"] as? String, !egg.isEmpty,
                  let target = incubator["target_km"] as? Double else { continue }
            guard walked >= target else { continue }
            let id = "egg.\(egg)"
            guard !announced.contains(id) else { continue }
            announced.insert(id)
            post(title: "Egg ready to hatch",
                 body: "One of your eggs has finished its distance.", id: id)
        }
    }
}
