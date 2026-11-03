import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: LauncherModel
    /// Which tab is showing. Bound rather than left to TabView so that leaving
    /// Play while the game is counting down can call off the launch -- going
    /// to Mods or Settings two seconds before handover plainly means "not yet".
    @State private var tab: Tab = .play

    private enum Tab: Hashable {
        case play, mods, server, settings
    }

    var body: some View {
        TabView(selection: $tab) {
            PlayView()
                .tabItem { Label("Play", systemImage: "play.circle.fill") }
                .tag(Tab.play)
            ModsView()
                .tabItem { Label("Mods", systemImage: "slider.horizontal.3") }
                .tag(Tab.mods)
            ServerView()
                .tabItem { Label("Server", systemImage: "server.rack") }
                .tag(Tab.server)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.accent)
        // The two-parameter onChange is iOS 17; the deployment target is 16.
        .onChange(of: tab) { new in
            if new != .play { model.cancelCountdown() }
        }
    }
}
