import SwiftUI

/// Settings › Leaderboard: who is playing on this phone and a link to the board. No
/// sign-in -- logging in to the game on Windstock is the sign-in.
struct ProfileSection: View {
    @EnvironmentObject private var model: LauncherModel

    private var profile: WindstockProfile { model.profile }

    var body: some View {
        Section {
            if profile.isAvailable {
                LabeledContent("Trainer", value: profile.trainer ?? "—")
                if let note = profile.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                Link(destination: profile.siteURL.appendingPathComponent("leaderboard.html")) {
                    Label("Open the leaderboard", systemImage: "trophy")
                }
            } else {
                Text("The leaderboard is only on Windstock.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Leaderboard")
        } footer: {
            Text("Your Windstock login is your place on the board: play on Windstock "
                 + "and your catches, spins and distance count automatically. Games on this "
                 + "phone's own server don't count.")
        }
        .onAppear { profile.refresh() }
    }
}
