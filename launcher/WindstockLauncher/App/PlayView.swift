import SwiftUI

/// The screen the app opens on, and usually the only one anyone sees: it counts
/// down and then hands the process to the game.
struct PlayView: View {
    @EnvironmentObject private var model: LauncherModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if model.gameIsPaused {
                        pausedCard
                    } else if let countdown = model.countdown {
                        countdownCard(countdown)
                    } else {
                        launchCard
                    }
                    if let error = model.launchError {
                        Card(title: "Launch failed") {
                            Text(error).font(.callout)
                            Text("The full cause is in Settings › Log.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button {
                                showingReport = true
                            } label: {
                                Label("Report this problem", systemImage: "exclamationmark.bubble")
                            }
                        }
                    }
                    NewsCard()
                    InviteCard()
                    AppsSection()
                    readiness
                }
                .padding(16)
            }
            .navigationTitle("Windstock")
            .background(Color(UIColor.systemGroupedBackground))
            .onAppear { model.news.refresh() }
            .sheet(isPresented: $showingReport) {
                ReportProblemView(prefill: model.launchError.map { "The game didn't start: \($0)" } ?? "")
            }
        }
    }

    @State private var showingReport = false

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 54))
                .foregroundStyle(Theme.accent)
            Text("Pokémon GO 0.35")
                .font(.title2.weight(.semibold))
            Text("Profile: \(model.prefs.profile)")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func countdownCard(_ remaining: Double) -> some View {
        Card {
            VStack(spacing: 14) {
                Text("Starting in \(String(format: "%.1f", max(0, remaining)))s")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                ProgressView(value: max(0, remaining),
                             total: max(0.1, model.prefs.autoLaunchDelay))
                    .tint(Theme.accent)
                Button("Stay in the launcher") { model.cancelCountdown() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @State private var confirmQuit = false

    private var pausedCard: some View {
        Card {
            VStack(spacing: 12) {
                Button {
                    model.resumeGame()
                } label: {
                    Label("Resume game", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Text("The game is paused. Server settings apply right away; "
                     + "mods and profile changes need a restart.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Quit Windstock", role: .destructive) { confirmQuit = true }
                    .font(.footnote)
                    .confirmationDialog("Quit Windstock?", isPresented: $confirmQuit,
                                        titleVisibility: .visible) {
                        Button("Quit", role: .destructive) {
                            WSLog("launcher", "quit from the launcher")
                            exit(0)
                        }
                    } message: {
                        Text("Your progress is saved. Open Windstock again to "
                             + "start fresh with your new mod settings.")
                    }
            }
        }
    }

    private var launchCard: some View {
        Card {
            VStack(spacing: 12) {
                if model.updateURL != nil {
                    Text("A new Windstock is out. Update to keep playing on the Windstock server.")
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                Button {
                    model.launchGame()
                } label: {
                    Label(model.updateURL != nil ? "Update Windstock" : "Play",
                          systemImage: model.updateURL != nil ? "arrow.down.circle.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!model.canPlay && model.updateURL == nil)

                if !model.canPlay {
                    Text("Import an IPA below, or build the launcher with one "
                         + "embedded using tools/embed_guest.sh.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var readiness: some View {
        Card(title: "Before you play") {
            VStack(alignment: .leading, spacing: 10) {
                readinessRow(
                    ok: model.canPlay,
                    title: "Game",
                    detail: model.activeApp.map { "\($0.name) \($0.version), imported" }
                        ?? (model.guestIsInstalled ? "embedded in this build" : "none"))
                readinessRow(
                    ok: SigningIdentityStore.hasIdentity || model.activeApp == nil,
                    title: "Signing certificate",
                    detail: signingDetail)
                readinessRow(
                    ok: WSPaths.tweakPath != nil,
                    title: "Mods tweak",
                    detail: WSPaths.tweakPath != nil
                        ? "\(enabledModCount) of \(ModsCatalog.all.count) mods on"
                        : "windstock.dylib not embedded")
                readinessRow(
                    ok: WSPaths.gpsTweakPath != nil,
                    title: "Location spoofing",
                    detail: WSPaths.gpsTweakPath != nil
                        ? (model.prefs.injectGPS
                            ? "joystick panel loaded — spoofing off until you switch it on"
                            : "embedded, not injected")
                        : "windstockgps.dylib not embedded")
                readinessRow(
                    ok: serverReady,
                    title: "Server",
                    detail: serverDetail)
            }
        }
    }

    private var signingDetail: String {
        if let identity = try? SigningIdentityStore.current() {
            return "\(identity.commonName ?? "imported") · team \(identity.teamID ?? "?")"
        }
        return model.activeApp == nil
            ? "not needed for the embedded build"
            : "none imported — the game will not load"
    }

    private var enabledModCount: Int {
        ModsCatalog.all.filter { model.mods.isEffectivelyOn($0.key) }.count
    }

    private var serverReady: Bool {
        switch model.prefs.serverMode {
        case .embedded: return model.serverState == .running
        case .remote: return !model.prefs.remoteHost.isEmpty
        case .online: return model.prefs.onlineEndpoint != nil && model.serverState == .running
        case .off: return true
        }
    }

    private var serverDetail: String {
        switch model.prefs.serverMode {
        case .embedded:
            switch model.serverState {
            case .running: return "running on 127.0.0.1:\(model.prefs.serverPort)"
            case .starting: return "starting…"
            case .failed: return model.serverError ?? "failed"
            case .stopped: return "stopped"
            @unknown default: return "unknown"
            }
        case .remote:
            return model.prefs.remoteHost.isEmpty ? "no host set" : model.prefs.remoteHost
        case .online:
            switch model.serverState {
            case .running: return "Windstock, encrypted"
            case .starting: return "connecting to Windstock…"
            case .failed: return model.serverError ?? "failed"
            default: return "Windstock (not started)"
            }
        case .off:
            return "not managed by the launcher"
        }
    }

    private func readinessRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Theme.accent : Theme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// What's new on Windstock: the newest two items from the website, the rest a tap away.
struct NewsCard: View {
    @EnvironmentObject private var model: LauncherModel
    @State private var showingAll = false

    private var news: WindstockNews { model.news }

    var body: some View {
        if !news.items.isEmpty {
            Card(title: "What's new") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(news.items.prefix(2)) { item in
                        NewsRow(item: item, isNew: news.isNew(item), lines: 3)
                    }
                    if news.items.count > 2 || news.unread > 0 {
                        Button(news.items.count > 2 ? "All news" : "Got it") {
                            if news.items.count > 2 { showingAll = true } else { news.markSeen() }
                        }
                        .font(.footnote.weight(.medium))
                    }
                }
            }
            .sheet(isPresented: $showingAll, onDismiss: { news.markSeen() }) {
                NavigationStack {
                    List(news.items) { item in
                        NewsRow(item: item, isNew: news.isNew(item), lines: nil)
                            .padding(.vertical, 4)
                    }
                    .navigationTitle("What's new")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingAll = false }
                        }
                    }
                }
            }
        }
    }
}

/// Invite friends: the trainer's own invite link from the website, shared from the
/// launcher. Shown on Windstock only, once the server knows who plays here and that
/// trainer has a website profile.
struct InviteCard: View {
    @EnvironmentObject private var model: LauncherModel

    var body: some View {
        if let invite = model.profile.invite {
            Card(title: "Invite friends") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bring a friend to Windstock. When they reach level \(invite.level), you get "
                         + "\(invite.coins) PokéCoins, and your \(ordinal(invite.masterBallAt)) friend "
                         + "also brings a Master Ball.")
                        .font(.footnote)
                    ShareLink(item: invite.url,
                              subject: Text("Play Windstock with me"),
                              message: Text("Catch 'em like it's 2016 -- join me on Windstock:")) {
                        Label("Share my invite", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    if invite.invited > 0 {
                        Text("\(invite.invited) joined with your link, \(invite.counted) reached level \(invite.level).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func ordinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)th"
    }
}

private struct NewsRow: View {
    let item: WindstockNews.Item
    let isNew: Bool
    let lines: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.title).font(.subheadline.weight(.semibold))
                if isNew {
                    Text("NEW")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent.opacity(0.2)))
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Text(item.date, format: .dateTime.day().month(.abbreviated))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(item.body)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(lines)
        }
    }
}
