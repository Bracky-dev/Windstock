import SwiftUI
import UniformTypeIdentifiers

/// What the UI needs to know about the imported certificate.
///
/// A plain value type rather than the SigningIdentity itself: SwiftUI state
/// should not be holding Security framework references, and the type checker
/// struggles with them inside a ViewBuilder.
struct IdentitySummary: Equatable {
    var commonName: String
    var teamID: String
    var notAfter: Date?

    var isExpired: Bool {
        guard let notAfter else { return false }
        return notAfter < Date()
    }

    init(_ identity: SigningIdentity) {
        commonName = identity.commonName ?? "—"
        teamID = identity.teamID ?? "—"
        notAfter = identity.notAfter
    }

    static var current: IdentitySummary? {
        (try? SigningIdentityStore.current()).map(IdentitySummary.init)
    }
}

/// Import and inspect the certificate guests are signed with.
///
/// It has to be the same certificate that signed the launcher: iOS refuses to
/// load a library whose team differs from the process loading it. Export it
/// from AltStore or SideStore — their settings can write out a .p12 and give
/// you its password.
struct SigningView: View {
    @State private var summary: IdentitySummary?
    @State private var picking = false
    @State private var pendingURL: URL?
    @State private var password = ""
    @State private var askingPassword = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        Section("Signing certificate") {
            if let summary {
                imported(summary)
            } else {
                missing
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(failed ? Theme.bad : Theme.accent)
            }
        }
        .onAppear { summary = IdentitySummary.current }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.pkcs12, .data],
                      allowsMultipleSelection: false,
                      onCompletion: chose)
        .alert("Password for the .p12", isPresented: $askingPassword) {
            SecureField("Password", text: $password)
            Button("Import", action: load)
            Button("Cancel", role: .cancel) { pendingURL = nil }
        } message: {
            Text("AltStore and SideStore show this next to the export button.")
        }
    }

    @ViewBuilder
    private func imported(_ summary: IdentitySummary) -> some View {
        LabeledContent("Certificate", value: summary.commonName)
        LabeledContent("Team", value: summary.teamID)
        if let notAfter = summary.notAfter {
            LabeledContent("Expires",
                           value: notAfter.formatted(date: .abbreviated, time: .omitted))
        }
        if summary.isExpired {
            Label("Expired — import a fresh one, then sign your games again.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.bad)
        }
        Button("Replace it") { picking = true }
        Button("Remove it", role: .destructive) {
            SigningIdentityStore.remove()
            self.summary = nil
            message = nil
        }
    }

    @ViewBuilder
    private var missing: some View {
        Text(WSPaths.guestExecutablePath == nil
             ? "Import the .p12 you exported from AltStore or SideStore. It has to "
               + "be the certificate that signed this app, or iOS will refuse to "
               + "load the game."
             : "Not needed — the game is embedded in this build and is already "
               + "covered by the signature on the app itself. This is only for "
               + "re-signing a game you import yourself.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        Button("Import a .p12") { picking = true }
    }

    private func chose(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            pendingURL = url
            password = ""
            askingPassword = true
        case .failure(let error):
            failed = true
            message = error.localizedDescription
        }
    }

    private func load() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        do {
            let imported = try SigningIdentityStore.importP12(at: url, password: password)
            summary = IdentitySummary(imported)
            failed = false
            message = "Imported \(imported.commonName ?? "certificate")."
            WSLog("signing", "imported identity for team \(imported.teamID ?? "?")")
        } catch {
            failed = true
            message = error.localizedDescription
            WSLog("signing", "import failed: \(error.localizedDescription)")
        }
        password = ""
    }
}

extension UTType {
    static let pkcs12 = UTType(filenameExtension: "p12") ?? .data
}
