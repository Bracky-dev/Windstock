import Foundation

/// One imported game, on disk under Documents/Windstock/Applications/<id>/.
struct InstalledApp: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var bundleIdentifier: String
    var version: String
    /// The guest's CFBundleExecutable, kept verbatim. It is load-bearing: the
    /// windstock tweak finds the game by looking for a loaded image whose path
    /// ends in "/pokemongo".
    var executableName: String
    var importedAt: Date
    var signedAt: Date?
    /// The team the executable was signed with, so the UI can say when it no
    /// longer matches the certificate currently imported.
    var signedTeamID: String?
    var byteSize: Int64

    var isSigned: Bool { signedAt != nil }
}

@MainActor
final class AppLibrary: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var busy: String?
    @Published private(set) var progress: Double = 0

    private let root: String
    private let fm = FileManager.default

    init() {
        root = (WSPaths.launcherRoot as NSString).appendingPathComponent("Applications")
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - paths

    func directory(for app: InstalledApp) -> String {
        (root as NSString).appendingPathComponent(app.id.uuidString)
    }

    /// The resource bundle NSBundle.mainBundle is swizzled onto.
    func bundlePath(for app: InstalledApp) -> String? {
        let payload = (directory(for: app) as NSString).appendingPathComponent("Payload")
        let names = (try? fm.contentsOfDirectory(atPath: payload)) ?? []
        guard let appDir = names.first(where: { $0.hasSuffix(".app") }) else { return nil }
        return (payload as NSString).appendingPathComponent(appDir)
    }

    /// The patched, signed Mach-O the loader dlopens.
    func executablePath(for app: InstalledApp) -> String {
        ((directory(for: app) as NSString).appendingPathComponent("Executable")
            as NSString).appendingPathComponent(app.executableName)
    }

    private func metadataPath(for id: UUID) -> String {
        (((root as NSString).appendingPathComponent(id.uuidString)) as NSString)
            .appendingPathComponent("app.json")
    }

    // MARK: - loading

    /// The decoder has to match the encoder in save(): dates go out as
    /// ISO-8601, and a plain JSONDecoder expects seconds-since-1970, so every
    /// app.json failed to parse and the list came back empty however many
    /// games were actually on disk.
    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    func reload() {
        let (_, decoder) = Self.coder()
        let ids = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        var found: [InstalledApp] = []
        for name in ids {
            guard let id = UUID(uuidString: name) else { continue }
            guard let data = fm.contents(atPath: metadataPath(for: id)) else { continue }
            do {
                found.append(try decoder.decode(InstalledApp.self, from: data))
            } catch {
                WSLog("library", "ignoring \(name): \(error)")
            }
        }
        apps = found.sorted { $0.importedAt > $1.importedAt }
    }

    private func save(_ app: InstalledApp) throws {
        let (encoder, _) = Self.coder()
        try encoder.encode(app).write(to: URL(fileURLWithPath: metadataPath(for: app.id)),
                                      options: .atomic)
    }

    // MARK: - import

    enum ImportError: LocalizedError {
        case notAnIPA
        case noPayload
        case noExecutable
        case noEntryPoint

        var errorDescription: String? {
            switch self {
            case .notAnIPA: return "That file could not be read as an IPA."
            case .noPayload: return "No Payload/<name>.app inside that IPA."
            case .noExecutable: return "The app in that IPA has no executable."
            case .noEntryPoint:
                return "That executable has no LC_MAIN, so there is nothing to start."
            }
        }
    }

    /// Unpacks an IPA, converts its executable to a loadable dylib and signs
    /// it. Runs off the main actor -- a 170 MB IPA takes a while.
    func importIPA(from url: URL) async throws -> InstalledApp {
        busy = "Reading the IPA…"
        progress = 0
        defer { busy = nil; progress = 0 }

        let identity = try SigningIdentityStore.current()
        let id = UUID()
        let destination = (root as NSString).appendingPathComponent(id.uuidString)

        do {
            let app = try await Task.detached(priority: .userInitiated) {
                try Self.unpack(url: url, into: destination, id: id, identity: identity)
            }.value
            try save(app)
            reload()
            return app
        } catch {
            try? fm.removeItem(atPath: destination)
            throw error
        }
    }

    /// The whole pipeline, off the main thread.
    private nonisolated static func unpack(url: URL, into destination: String, id: UUID,
                                           identity: SigningIdentity) throws -> InstalledApp {
        let fm = FileManager.default
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

        let staging = (destination as NSString).appendingPathComponent("Payload")
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)

        // Unzip with the system's own archive support rather than shelling
        // out; there is no unzip on iOS.
        try Zip.extract(at: url, to: URL(fileURLWithPath: destination))

        // The archive contains Payload/<name>.app; some tools nest it deeper.
        guard let appDir = findAppBundle(under: destination) else {
            throw ImportError.noPayload
        }
        // Normalise to <destination>/Payload/<name>.app
        let wanted = (staging as NSString).appendingPathComponent(
            (appDir as NSString).lastPathComponent)
        if appDir != wanted {
            try? fm.removeItem(atPath: wanted)
            try fm.moveItem(atPath: appDir, toPath: wanted)
        }

        let infoPath = (wanted as NSString).appendingPathComponent("Info.plist")
        let info = NSDictionary(contentsOfFile: infoPath) as? [String: Any] ?? [:]
        guard let executableName = info["CFBundleExecutable"] as? String else {
            throw ImportError.noExecutable
        }
        let executableSource = (wanted as NSString).appendingPathComponent(executableName)
        guard let raw = fm.contents(atPath: executableSource) else {
            throw ImportError.noExecutable
        }

        // The Mach-O moves out of the .app: it is loaded by path, and keeping
        // a second 30 MB copy inside the resource bundle serves nothing.
        let executableDir = (destination as NSString).appendingPathComponent("Executable")
        try fm.createDirectory(atPath: executableDir, withIntermediateDirectories: true)
        let executableDestination =
            (executableDir as NSString).appendingPathComponent(executableName)

        let prepared = try MachOPatcher.prepare(
            raw, installName: "@rpath/\(executableName)")
        guard prepared.hasEntryPoint else { throw ImportError.noEntryPoint }

        let bundleID = info["CFBundleIdentifier"] as? String ?? "unknown"
        let signed = try MachOSigner.sign(prepared.data, identifier: bundleID,
                                          identity: identity)
        try signed.write(to: URL(fileURLWithPath: executableDestination))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableDestination)
        try? fm.removeItem(atPath: executableSource)

        // A signature and provisioning profile from whoever built the IPA are
        // both invalid now and only confuse things.
        for stale in ["_CodeSignature", "embedded.mobileprovision",
                      "archived-expanded-entitlements.xcent"] {
            try? fm.removeItem(atPath: (wanted as NSString).appendingPathComponent(stale))
        }

        let size = directorySize(destination)
        return InstalledApp(
            id: id,
            name: (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String) ?? executableName,
            bundleIdentifier: bundleID,
            version: (info["CFBundleShortVersionString"] as? String) ?? "?",
            executableName: executableName,
            importedAt: Date(),
            signedAt: Date(),
            signedTeamID: identity.teamID,
            byteSize: size)
    }

    private nonisolated static func findAppBundle(under path: String) -> String? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: path) else { return nil }
        for case let entry as String in walker where entry.hasSuffix(".app") {
            let full = (path as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue {
                return full
            }
        }
        return nil
    }

    private nonisolated static func directorySize(_ path: String) -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let entry as String in walker {
            let full = (path as NSString).appendingPathComponent(entry)
            let attrs = try? fm.attributesOfItem(atPath: full)
            total += (attrs?[.size] as? Int64) ?? 0
        }
        return total
    }

    // MARK: - re-signing and removal

    /// Free certificates expire weekly; after a re-sideload the old signature
    /// is from a certificate this process no longer matches, and the guest
    /// will not load until it is signed again.
    func resign(_ app: InstalledApp) async throws {
        busy = "Signing \(app.name)…"
        defer { busy = nil }

        let identity = try SigningIdentityStore.current()
        let path = executablePath(for: app)
        let bundleID = app.bundleIdentifier
        try await Task.detached(priority: .userInitiated) {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw ImportError.noExecutable
            }
            let signed = try MachOSigner.sign(data, identifier: bundleID, identity: identity)
            try signed.write(to: URL(fileURLWithPath: path), options: .atomic)
        }.value

        var updated = app
        updated.signedAt = Date()
        updated.signedTeamID = identity.teamID
        try save(updated)
        reload()
    }

    func delete(_ app: InstalledApp) {
        try? fm.removeItem(atPath: directory(for: app))
        reload()
    }
}
