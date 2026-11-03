import SwiftUI

/// Where the launcher's public links point.
enum Distribution {
    /// The world-pack catalog players download countries from. Upload the
    /// output of tools/build_world_packs.py somewhere static and put the
    /// catalog.json address here; empty makes the World Data screen ask for it.
    static let worldCatalogURL = ""
    /// The public Windstock server's "IP:port" pre-filled in Server > Windstock
    /// Online (the Windstock VPS). Players can always type their own.
    static let onlineAddress = "2.29.24.78:8888"
}

struct TutorialView: View {
    @EnvironmentObject private var model: LauncherModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    install
                    firstRun
                    playing
                    whenItGoesWrong
                }
                .padding(16)
            }
            .navigationTitle("How to use it")
            .background(Color(UIColor.systemGroupedBackground))
        }
    }

    // MARK: - steps

    private var install: some View {
        Card(title: "Installing it") {
            VStack(alignment: .leading, spacing: 14) {
                Step(1, "Sideload the .ipa",
                     "On a computer, with Sideloadly or AltStore, signed in with "
                     + "your own Apple ID. There is no jailbreak and no "
                     + "TrollStore involved.")
                Step(2, "Trust the developer",
                     "Settings › General › VPN & Device Management, tap your "
                     + "Apple ID, Trust. iOS will not open the app until you do.")
                Step(3, "It lasts seven days",
                     "A free Apple ID signs for a week. Re-sideloading replaces "
                     + "the app but keeps Documents, so saves, settings and "
                     + "imported games survive — you do not start over.")
                Step(4, "After each refresh, sign again",
                     "Only for games you imported yourself — the built-in game "
                     + "is re-signed along with the app. A new certificate means "
                     + "imported games are signed by the old one, so import the "
                     + "fresh .p12, then Sign again on each game in the Play tab.")
            }
        }
    }

    private var firstRun: some View {
        Card(title: "First run") {
            VStack(alignment: .leading, spacing: 14) {
                Step(1, "Nothing to install",
                     "The game is built into Windstock and was signed along "
                     + "with the app when you sideloaded it, and the server's "
                     + "certificate is trusted inside the app. No .p12, no "
                     + "profile, no Certificate Trust Settings.")
                Step(2, "Allow notifications",
                     "So you hear about eggs finishing and lures running out "
                     + "while the phone is in your pocket.")
                Step(3, "Only if you import a different game",
                     "Settings tab › Signing certificate: import a .p12 "
                     + "exported from AltStore or SideStore, then Play tab › "
                     + "Import an IPA. iOS refuses to load an imported game "
                     + "signed by anyone other than whoever signed this app.")
            }
        }
    }

    private var playing: some View {
        Card(title: "Playing") {
            VStack(alignment: .leading, spacing: 14) {
                Step(1, "Just open Windstock",
                     "The server starts, then the game starts on its own after "
                     + String(format: "%.1f", model.prefs.autoLaunchDelay)
                     + " seconds. Tap \"Stay in the launcher\" during the "
                     + "countdown if you wanted the menus.")
                Step(2, "Mods apply at launch",
                     "The tweak reads the mods file once, as it loads, so a "
                     + "change takes effect the next time the game starts — "
                     + "not while you are in it.")
                Step(3, "The server can live either place",
                     "\"On this phone\" needs nothing else running. \"On PC\" "
                     + "sends the same traffic to your computer instead. A PC "
                     + "server started from this project uses the same "
                     + "certificate, so it needs no setup on the phone either.")
                Step(4, "Profiles are separate saves",
                     "Change the profile in Settings and fully quit the app. "
                     + "The container is picked before the app's first line "
                     + "runs, so it takes a cold start.")
            }
        }
    }

    private var whenItGoesWrong: some View {
        Card(title: "When it goes wrong") {
            VStack(alignment: .leading, spacing: 14) {
                Trouble("The game opens and closes again",
                        "Settings › Open the log. The lines tagged [guest] say "
                        + "how far the container got.")
                Trouble("Login fails",
                        "Settings › Open the log and look for \"refused ... "
                        + "certificate\". That means a PC server with its own "
                        + "certificates: copy this project's certs/ folder to it, "
                        + "or install its ca.crt as a profile and switch it on in "
                        + "Certificate Trust Settings.")
                Trouble("The game runs but never reaches the server",
                        "Server tab › Hostname redirect. If \"Lookups redirected\" "
                        + "stays at 0 the client is not asking for the hostnames "
                        + "being watched.")
                Trouble("The game will not load after a re-sideload",
                        "Its signature is from the previous certificate. Import "
                        + "the new .p12 in Settings, then Sign again on the game.")
                Trouble("The launcher itself will not start",
                        "Create an empty file at Documents/Windstock/safe-mode "
                        + "through the Files app. The container redirect is then "
                        + "skipped and the launcher opens normally.")
            }
        }
    }
}

// MARK: - pieces

private struct Step: View {
    let number: Int
    let title: String
    let detail: String

    init(_ number: Int, _ title: String, _ detail: String) {
        self.number = number
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.accent.opacity(0.18)))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Trouble: View {
    let symptom: String
    let fix: String

    init(_ symptom: String, _ fix: String) {
        self.symptom = symptom
        self.fix = fix
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(Theme.warn)
            VStack(alignment: .leading, spacing: 3) {
                Text(symptom).font(.subheadline.weight(.semibold))
                Text(fix)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
