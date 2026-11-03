import SwiftUI

struct ServerView: View {
    @EnvironmentObject private var model: LauncherModel
    @StateObject private var settings = GameSettingsStore()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        StatusPill(text: statusText, color: statusColor)
                    }
                    if let error = model.serverError {
                        Text(error).font(.footnote).foregroundStyle(Theme.bad)
                    }
                    if model.prefs.serverMode == .embedded {
                        HStack {
                            Button(model.serverState == .running ? "Stop" : "Start") {
                                model.serverState == .running ? model.stopServer()
                                                              : model.startServer()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(model.serverState == .running ? Theme.bad : Theme.accent)
                            Spacer()
                        }
                    }
                }

                Section("Where the server runs") {
                    Picker("Mode", selection: $model.prefs.serverMode) {
                        Text("On this phone").tag(LauncherPrefs.ServerMode.embedded)
                        Text("On PC, Localhost").tag(LauncherPrefs.ServerMode.remote)
                        Text("Windstock").tag(LauncherPrefs.ServerMode.online)
                    }
                    .pickerStyle(.segmented)

                    switch model.prefs.serverMode {
                    case .embedded:
                        LabeledContent("Port") {
                            TextField("8443", value: $model.prefs.serverPort,
                                      format: .number.grouping(.never))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        Toggle("Start with the launcher", isOn: $model.prefs.startServerOnLaunch)
                        Text("The game dials port 443, which an app cannot connect. "
                             + "Loopback connections to 443 are rewritten to this port.")
                            .font(.footnote).foregroundStyle(.secondary)
                    case .remote:
                        LabeledContent("Host") {
                            TextField("192.168.y.z", text: $model.prefs.remoteHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Port") {
                            TextField("443", value: $model.prefs.remotePort,
                                      format: .number.grouping(.never))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Plain HTTP port") {
                            TextField("80", value: $model.prefs.remotePlainPort,
                                      format: .number.grouping(.never))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        Text("The same in-app redirect as the embedded server, "
                             + "pointed at your Mac — no DNS profile and no VPN "
                             + "needed. A LAN address works on the same Wi-Fi; "
                             + "a Tailscale address works anywhere. LEAVE the "
                             + "ports alone unless you changed PORT when you "
                             + "started the server, have fun!")
                            .font(.footnote).foregroundStyle(.secondary)
                    case .online:
                        OnlineServerSection()
                    case .off:
                        Text("The launcher leaves the game's networking alone, so a "
                             + "DNS redirect or VPN you set up yourself applies.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    NavigationLink {
                        GameSettingsView(store: settings)
                    } label: {
                        Label("Server settings", systemImage: "slider.horizontal.3")
                    }
                } header: {
                    Text("Game rules")
                } footer: {
                    Text("Spawns, catching, PokeStops, gyms, eggs, raids and the "
                         + "rest — edited here in the app rather than the web page.")
                }

                if model.prefs.serverMode == .embedded {
                    Section("Hostname redirect") {
                        LabeledContent("Lookups redirected",
                                       value: "\(WSNetRedirect.redirectedLookups)")
                        LabeledContent("Connections repointed",
                                       value: "\(WSNetRedirect.redirectedConnections)")
                        ForEach(model.prefs.redirectHostnames, id: \.self) { host in
                            Text(host).font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Live output") {
                    LogList(lines: model.logLines.filter { $0.contains("[server]") },
                            empty: "Nothing yet. Start the server to see its log here.")
                }
            }
            .navigationTitle("Server")
            // The server rewrites this file when it starts (it back-fills keys
            // added since), so re-read rather than trusting what we loaded.
            .onAppear { settings.reload() }
        }
    }

    private var statusText: String {
        switch model.prefs.serverMode {
        case .remote: return "remote"
        case .online where model.prefs.onlineEndpoint == nil: return "no address"
        case .online:
            switch model.serverState {
            case .running: return "encrypted"
            case .starting: return "connecting"
            case .failed: return "failed"
            default: return "stopped"
            }
        case .off: return "unmanaged"
        case .embedded:
            switch model.serverState {
            case .stopped: return "stopped"
            case .starting: return "starting"
            case .running: return "running"
            case .failed: return "failed"
            @unknown default: return "unknown"
            }
        }
    }

    private var statusColor: Color {
        switch model.prefs.serverMode {
        case .online where model.prefs.onlineEndpoint == nil: return Theme.warn
        case .remote, .off: return .secondary
        case .embedded, .online:
            switch model.serverState {
            case .running: return Theme.accent
            case .starting: return Theme.warn
            case .failed: return Theme.bad
            default: return .secondary
            }
        }
    }
}

struct LogList: View {
    let lines: [String]
    var empty: String = "Nothing logged yet."

    var body: some View {
        if lines.isEmpty {
            Text(empty).font(.footnote).foregroundStyle(.secondary)
        } else {
            ForEach(Array(lines.suffix(200).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}

/// Server > Windstock: a connection test. The server's address is built in
/// (Distribution.onlineAddress); everything else about the mode is in
/// LauncherModel.applyNetworkSettings.
private struct OnlineServerSection: View {
    @EnvironmentObject private var model: LauncherModel
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        HStack {
            Button(testing ? "Testing…" : "Test connection") { test() }
                .disabled(testing || model.prefs.onlineEndpoint == nil)
            Spacer()
            if let result {
                Text(result.text).font(.footnote)
                    .foregroundStyle(result.ok ? Theme.accent : Theme.bad)
                    .multilineTextAlignment(.trailing)
            }
        }
        Text("Play on Windstock with everyone else: no DNS profile, no VPN and "
             + "no certificate to install. Log in with the email and password "
             + "you registered at windstock.org. Everything the game sends — "
             + "your password included — travels encrypted, and only to the "
             + "Windstock server, whose certificate is built into the launcher.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    /// Asks the launcher's own tunnel (tunnel.py, on loopback) to make one
    /// real request to the server. So a pass means what playing needs: the
    /// address answers as a Windstock server, over TLS, with the certificate
    /// pinned for it. Nothing here talks to the server directly.
    private func test(attempt: Int = 0) {
        guard let endpoint = model.prefs.onlineEndpoint,
              let url = URL(string: "http://127.0.0.1:\(model.prefs.serverPlainPort)/windstock/tunnel")
        else { return }
        testing = true
        if attempt == 0 && model.serverState != .running { model.startServer() }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            // Not our tunnel, or still the tunnel for the previous address:
            // it is (re)starting. Give it a few seconds.
            guard json?["tunnel"] as? Bool == true,
                  json?["target"] as? String == endpoint.display else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    if attempt < 10 {
                        test(attempt: attempt + 1)
                    } else {
                        testing = false
                        result = (false, "The launcher's encrypted connection did not start. See the log below.")
                    }
                }
                return
            }
            let outcome: (Bool, String)
            if json?["ok"] as? Bool == true {
                let shown = String((json?["fingerprint"] as? String ?? "").prefix(23))
                let pinned = json?["pinned"] as? String ?? "pinned"
                outcome = (true, "Connected to windstock.org, encrypted.\nCertificate \(shown)… (\(pinned))")
            } else {
                outcome = (false, json?["message"] as? String ?? "No answer")
            }
            WSLog("net", "online test \(endpoint.display): \(outcome.1)")
            DispatchQueue.main.async {
                testing = false
                result = outcome
            }
        }.resume()
    }
}
