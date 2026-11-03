import SwiftUI

struct SettingsView: View {
    @AppStorage("WSDuoSplit") private var duoSplit = false
    @EnvironmentObject private var model: LauncherModel
    @State private var showingLog = false
    @State private var showingEditor = false
    @State private var exportedLog: URL?
    @State private var exportFailed = false
    @State private var showingReport = false
    /// Taps on Version; 7 in a row toggles the hidden Windstock profile section.

    var body: some View {
        NavigationStack {
            List {
                Section("Launching") {
                    Toggle("Start the game automatically", isOn: $model.prefs.autoLaunch)
                    if model.prefs.autoLaunch {
                        VStack(alignment: .leading) {
                            LabeledContent("Wait",
                                value: String(format: "%.1f s", model.prefs.autoLaunchDelay))
                            Slider(value: $model.prefs.autoLaunchDelay, in: LauncherPrefs.minAutoLaunchDelay...10, step: 0.5)
                        }
                    }
                    Toggle("Inject the mods tweak", isOn: $model.prefs.injectTweak)
                }

                ProfileSection()

                Section("Notifications") {
                    Toggle("Enabled", isOn: $model.prefs.notificationsEnabled)
                    if model.prefs.notificationsEnabled {
                        if model.notifier.authorization != .authorized {
                            Button("Allow notifications") {
                                Task { await model.notifier.requestAuthorization() }
                            }
                        }
                        Toggle("Server started / stopped", isOn: $model.prefs.notifyServerState)
                        Toggle("Eggs ready to hatch", isOn: $model.prefs.notifyEggs)
                        Toggle("Lures running out", isOn: $model.prefs.notifyLures)
                        if model.prefs.notifyLures {
                            Stepper("Warn \(model.prefs.lureWarningMinutes) min before",
                                    value: $model.prefs.lureWarningMinutes, in: 1...30)
                        }
                        Button("Send a test notification") {
                            model.notifier.post(title: "Windstock",
                                                body: "Notifications are working.")
                        }
                    }
                }

                Section("Profile") {
                    LabeledContent("Active") {
                        TextField("default", text: $model.prefs.profile)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Text("Each profile is a separate save and settings container. "
                         + "Switching takes effect the next time the launcher starts, "
                         + "because the container is chosen before the app's first line runs.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                SigningView()

                Section("Server certificate") {
                    if let ca = caCertificateURL {
                        ShareLink(item: ca) {
                            Label("Share the server's CA", systemImage: "lock.doc")
                        }
                        Text("Built in and trusted inside the app — you do not "
                             + "need to install it. Share it only for a PC server "
                             + "that uses different certificates, or for tools "
                             + "outside Windstock: install the profile, then switch "
                             + "it on in Settings › General › About › Certificate "
                             + "Trust Settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("No ca.crt in the bundle — run tools/stage_server.sh.")
                            .font(.footnote).foregroundStyle(Theme.warn)
                    }
                }

                Section {
                    NavigationLink {
                        WorldDataView()
                    } label: {
                        Label("World Data", systemImage: "globe.americas")
                    }
                } footer: {
                    Text("Download your country's real PokeStops and gyms.")
                }

                Section("Game Editor") {
                    Button {
                        showingEditor = true
                    } label: {
                        Label("Open the editor", systemImage: "slider.horizontal.3")
                    }
                    // The editor belongs to the server on THIS phone; in Windstock
                    // Online the same ports hold a tunnel, and there is nothing to edit.
                    .disabled(model.serverState != .running || model.prefs.serverMode != .embedded)
                    if model.serverState == .running && model.prefs.serverMode == .embedded {
                        Text("Items, candy, stardust, XP and level, PokeStops and "
                             + "gyms, loot tables, raids and accounts. Research and "
                             + "the events calendar unlock at level 5, so that is "
                             + "where to set it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Start the server first — the editor runs inside it.")
                            .font(.footnote).foregroundStyle(Theme.warn)
                    }
                }

                Section("Where things are") {
                    pathRow("Launcher", WSPaths.launcherRoot)
                    pathRow("Container", WSPaths.container(forProfile: model.prefs.profile))
                    pathRow("Server data", WSPaths.serverDataDir)
                }

                Section {
                    LabeledContent("Version", value: Self.versionString)
                    Button {
                        showingReport = true
                    } label: {
                        Label("Report a problem", systemImage: "exclamationmark.bubble")
                    }
                    Button {
                        exportedLog = LogExport.make()
                        exportFailed = exportedLog == nil
                    } label: {
                        Label("Send the log to the developer", systemImage: "square.and.arrow.up")
                    }
                    Button("Open the log") { showingLog = true }
                    if exportFailed {
                        Text("There is no log yet — open the game once first.")
                            .font(.footnote).foregroundStyle(Theme.warn)
                    }
                } header: {
                    Text("Help")
                } footer: {
                    Text("If something goes wrong, report it right after it happens. "
                         + "Your location is rounded to about 10 km first, and passwords "
                         + "are never in the log.")
                }

                Section {
                    Toggle("Split screen (launcher | game)", isOn: $duoSplit)
                } header: {
                    Text("iPhone Duo")
                } footer: {
                    Text("On a wide window (the unfolded Duo, an iPad, a resized iPhone Mirroring window) "
                         + "the launcher keeps the left half and the game runs in the right half. "
                         + "Start the game after turning it on.")
                }
            }
            .navigationTitle("Settings")
            .onAppear { model.profile.refresh() }
            .sheet(isPresented: $showingReport) { ReportProblemView() }
            .sheet(item: $exportedLog) { url in
                ShareSheet(url: url)
            }
            .sheet(isPresented: $showingEditor) {
                GameEditorView(port: model.prefs.gameEditorPort)
            }
            .sheet(isPresented: $showingLog) {
                NavigationStack {
                    List { LogList(lines: model.logLines) }
                        .navigationTitle("Log")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingLog = false }
                            }
                        }
                }
            }
        }
    }

    /// "1.0 (20260921.1830)" -- the build is stamped by make_ipa.sh, so a
    /// tester can tell you exactly which IPA they are on. Read from the HOST
    /// bundle: mainBundle is the game's while it runs.
    static var versionString: String {
        let info = Bundle(path: WSPaths.hostBundlePath)?.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// The CA the embedded server's leaf certificate is signed by, shipped
    /// read-only inside the bundle.
    private var caCertificateURL: URL? {
        let path = (WSPaths.pythonServerDir as NSString)
            .appendingPathComponent("certs/ca.crt")
        return FileManager.default.fileExists(atPath: path)
            ? URL(fileURLWithPath: path) : nil
    }

    private func pathRow(_ title: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
