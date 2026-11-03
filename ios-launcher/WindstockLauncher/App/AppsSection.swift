import SwiftUI
import UniformTypeIdentifiers

/// The imported-games list on the Play screen, plus the import flow.
struct AppsSection: View {
    @EnvironmentObject private var model: LauncherModel
    @State private var picking = false
    @State private var importError: String?

    var body: some View {
        Card(title: "Games") {
            VStack(alignment: .leading, spacing: 12) {
                if model.library.apps.isEmpty {
                    Text(model.guestIsInstalled
                         ? "Using the game embedded in this build. Import an IPA to "
                           + "run a different one. (if you want to)"
                         : "No game yet. Import an IPA.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(model.library.apps) { app in
                        row(app)
                        if app.id != model.library.apps.last?.id { Divider() }
                    }
                }

                if let busy = model.library.busy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(busy).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Button {
                    picking = true
                } label: {
                    Label("Import an IPA", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(model.library.busy != nil)

                // Only an IMPORTED game has to be re-signed. The embedded build
                // ships the guest inside Frameworks/, already covered by the
                // signature the sideload signer applied to the whole app, so
                // nagging for a .p12 there is wrong -- and it was doing exactly
                // that on a build that needs no certificate at all.
                if !SigningIdentityStore.hasIdentity && model.activeApp != nil {
                    Label("Import your signing certificate in Settings — iOS will "
                          + "not load an imported game unless it is signed with "
                          + "the same certificate that signed this app.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warn)
                }

                if let importError {
                    Text(importError).font(.footnote).foregroundStyle(Theme.bad)
                }
            }
        }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.ipa, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importIPA(url) }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private func importIPA(_ url: URL) async {
        importError = nil
        do {
            let app = try await model.library.importIPA(from: url)
            model.prefs.activeAppID = app.id.uuidString
            WSLog("library", "imported \(app.name) \(app.version)")
        } catch {
            importError = error.localizedDescription
            WSLog("library", "import failed: \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private func row(_ app: InstalledApp) -> some View {
        let isActive = model.activeApp?.id == app.id
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.subheadline.weight(.medium))
                Text("\(app.version) · \(ByteCountFormatter.string(fromByteCount: app.byteSize, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                if let team = app.signedTeamID {
                    Text("signed for team \(team)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("Use this one") { model.prefs.activeAppID = app.id.uuidString }
                Button("Sign again") { Task { await resign(app) } }
                Button("Delete", role: .destructive) { model.library.delete(app) }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.prefs.activeAppID = app.id.uuidString }
    }

    private func resign(_ app: InstalledApp) async {
        importError = nil
        do {
            try await model.library.resign(app)
        } catch {
            importError = error.localizedDescription
        }
    }
}

extension UTType {
    /// IPAs have no registered type; they are zips with a different extension.
    static let ipa = UTType(filenameExtension: "ipa") ?? .data
}
