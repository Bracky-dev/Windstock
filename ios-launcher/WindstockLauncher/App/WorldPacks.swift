import CryptoKit
import Foundation
import UIKit

/// One downloadable country, as tools/build_world_packs.py writes it into
/// catalog.json.
struct WorldPack: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let region: String
    /// Relative to the catalog's own URL, so a pack only has to sit next to it.
    let file: String
    let bytes: Int64
    let sha256: String
    let forts: Int
    let gyms: Int?
    let biomes: Bool?
    let built: String?
}

private struct WorldCatalog: Codable {
    let version: Int
    let packs: [WorldPack]
}

/// A pack that is on disk, whether or not the current catalog still lists it.
struct InstalledPack: Identifiable, Hashable {
    let id: String
    let name: String
    let sha256: String?
    let bytes: Int64
    /// Shipped inside the app bundle rather than downloaded; cannot be removed.
    let bundled: Bool
}

/// Downloads world packs into the server's data folder, where
/// work/server/worlddb.py picks them up on the next map request.
///
/// Files land as `<data>/world/<id>.sqlite`, with a `<id>.json` sidecar holding
/// the catalog entry so "update available" can be told from "up to date"
/// without re-hashing 100 MB on every visit. A download is written to a
/// `.part` name, SHA-256-checked, then renamed over the old file: the server
/// opens packs read-only and immutable, so a pack must never change in place.
@MainActor
final class WorldPackStore: ObservableObject {
    /// One store for the whole app, so an import keeps going (and keeps
    /// reporting) when you leave the screen that started it.
    static let shared = WorldPackStore()

    enum Phase: Equatable {
        case downloading(Double)
        case verifying
        case converting(Double, String)
        case failed(String)
    }

    /// OSM imports that are running or failed, by pack id -> display name.
    /// Listed on the World Data screen until they finish.
    @Published private(set) var importNames: [String: String] = [:]

    @Published private(set) var catalog: [WorldPack] = []
    @Published private(set) var catalogError: String?
    @Published private(set) var loadingCatalog = false
    @Published private(set) var installed: [String: InstalledPack] = [:]
    @Published private(set) var phases: [String: Phase] = [:]

    private var catalogURL: URL?
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]
    private var cancelFlags: [String: CancelFlag] = [:]
    private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]

    /// Checked by the converter between blocks, from its own thread.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    // nonisolated: plain path arithmetic, and verifyAndInstall runs off the
    // main actor and needs it.
    nonisolated static var worldDir: URL {
        URL(fileURLWithPath: WSPaths.serverDataDir)
            .appendingPathComponent("data/world", isDirectory: true)
    }

    nonisolated private static var bundledDir: URL {
        URL(fileURLWithPath: WSPaths.pythonServerDir)
            .appendingPathComponent("world", isDirectory: true)
    }

    init() {
        rescan()
    }

    // MARK: - catalog

    func loadCatalog(from text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            catalog = []
            catalogError = nil
            return
        }
        guard let url = URL(string: trimmed), url.scheme != nil else {
            catalogError = "That isn't a URL."
            return
        }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                catalogError = "The server answered \(http.statusCode)."
                return
            }
            let decoded = try JSONDecoder().decode(WorldCatalog.self, from: data)
            catalog = decoded.packs.sorted { $0.name < $1.name }
            catalogURL = url
            catalogError = nil
            WSLog("world", "catalog: \(catalog.count) pack(s) from \(url.host ?? "?")")
        } catch is DecodingError {
            catalogError = "That file isn't a world catalog."
        } catch {
            catalogError = error.localizedDescription
        }
    }

    /// The catalog entry for the device's own country, if there is one --
    /// matched by English country name, which is what the packs are named.
    var suggested: WorldPack? {
        guard let code = Locale.current.region?.identifier,
              let name = Locale(identifier: "en_US").localizedString(forRegionCode: code)
        else { return nil }
        return catalog.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - installed

    func rescan() {
        var found: [String: InstalledPack] = [:]
        let fm = FileManager.default
        for (dir, bundled) in [(Self.bundledDir, true), (Self.worldDir, false)] {
            let files = (try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files where file.pathExtension == "sqlite" {
                let id = file.deletingPathExtension().lastPathComponent
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let sidecar = dir.appendingPathComponent("\(id).json")
                let entry = (try? Data(contentsOf: sidecar))
                    .flatMap { try? JSONDecoder().decode(WorldPack.self, from: $0) }
                found[bundled ? "bundled:\(id)" : id] = InstalledPack(
                    id: id,
                    name: entry?.name ?? (bundled ? "Built-in world" : id),
                    sha256: entry?.sha256,
                    bytes: Int64(size),
                    bundled: bundled)
            }
        }
        installed = found
    }

    enum Status: Equatable {
        case notInstalled, upToDate, updateAvailable
    }

    func status(of pack: WorldPack) -> Status {
        guard let have = installed[pack.id] else { return .notInstalled }
        return have.sha256 == pack.sha256 ? .upToDate : .updateAvailable
    }

    var bundledPacks: [InstalledPack] {
        installed.values.filter(\.bundled).sorted { $0.name < $1.name }
    }

    /// Downloaded packs the current catalog no longer lists -- still used by
    /// the server, so they have to stay visible and removable.
    var orphans: [InstalledPack] {
        let listed = Set(catalog.map(\.id))
        return installed.values
            .filter { !$0.bundled && !listed.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - download

    func download(_ pack: WorldPack) {
        guard tasks[pack.id] == nil else { return }
        guard let base = catalogURL,
              let url = URL(string: pack.file, relativeTo: base)?.absoluteURL else {
            phases[pack.id] = .failed("Load the catalog first.")
            return
        }
        let part = Self.worldDir.appendingPathComponent("\(pack.id).sqlite.part")
        do {
            try FileManager.default.createDirectory(at: Self.worldDir,
                                                    withIntermediateDirectories: true)
        } catch {
            phases[pack.id] = .failed(error.localizedDescription)
            return
        }
        phases[pack.id] = .downloading(0)
        WSLog("world", "downloading \(pack.name) (\(pack.bytes) bytes) from \(url.host ?? "?")")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] temp, response, error in
            // `temp` only exists until this closure returns, so it is moved
            // aside synchronously here, off the main thread.
            var moveError: Error?
            if let temp, error == nil {
                try? FileManager.default.removeItem(at: part)
                do { try FileManager.default.moveItem(at: temp, to: part) } catch { moveError = error }
            }
            let status = (response as? HTTPURLResponse)?.statusCode
            Task { @MainActor in
                self?.finished(pack, part: part, status: status, error: error ?? moveError)
            }
        }
        observations[pack.id] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading = self?.phases[pack.id] {
                    self?.phases[pack.id] = .downloading(fraction)
                }
            }
        }
        tasks[pack.id] = task
        task.resume()
    }

    func cancel(_ pack: WorldPack) {
        cancel(id: pack.id)
    }

    func cancel(id: String) {
        tasks[id]?.cancel()
        cancelFlags[id]?.set()
    }

    private func finished(_ pack: WorldPack, part: URL, status: Int?, error: Error?) {
        tasks[pack.id] = nil
        observations[pack.id] = nil
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            phases[pack.id] = cancelled ? nil : .failed(error.localizedDescription)
            try? FileManager.default.removeItem(at: part)
            return
        }
        if let status, status != 200 {
            phases[pack.id] = .failed("The server answered \(status).")
            try? FileManager.default.removeItem(at: part)
            return
        }
        phases[pack.id] = .verifying
        Task.detached(priority: .userInitiated) {
            let result = Self.verifyAndInstall(pack, part: part)
            await MainActor.run {
                switch result {
                case .success:
                    self.phases[pack.id] = nil
                    WSLog("world", "installed \(pack.name): \(pack.forts) stops and gyms")
                case .failure(let error):
                    self.phases[pack.id] = .failed(error.localizedDescription)
                    WSLog("world", "\(pack.name) failed: \(error.localizedDescription)")
                }
                self.rescan()
            }
        }
    }

    private struct InstallError: LocalizedError {
        let errorDescription: String?
    }

    nonisolated private static func verifyAndInstall(_ pack: WorldPack,
                                                     part: URL) -> Result<Void, Error> {
        let fm = FileManager.default
        do {
            // Hash in chunks: packs run to 100+ MB and must not be read whole.
            let handle = try FileHandle(forReadingFrom: part)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == pack.sha256.lowercased() else {
                try? fm.removeItem(at: part)
                return .failure(InstallError(errorDescription:
                    "The download was damaged (checksum mismatch). Try again."))
            }
            let dest = worldDir.appendingPathComponent("\(pack.id).sqlite")
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: part)
            } else {
                try fm.moveItem(at: part, to: dest)
            }
            let sidecar = worldDir.appendingPathComponent("\(pack.id).json")
            try JSONEncoder().encode(pack).write(to: sidecar, options: .atomic)
            return .success(())
        } catch {
            try? fm.removeItem(at: part)
            return .failure(error)
        }
    }

    // MARK: - OpenStreetMap import

    /// Downloads a raw .osm.pbf (e.g. a Geofabrik extract) and converts it
    /// into a pack on the phone -- see OSMImport.swift.
    func importOSM(from url: URL, name: String, region: String, datedFallback: Bool = true) {
        let id = OSMImport.packID(for: region.isEmpty ? name : region)
        guard tasks[id] == nil, cancelFlags[id] == nil else { return }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("osm-import", isDirectory: true)
        let local = cache.appendingPathComponent("\(id).osm.pbf")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        importNames[id] = name
        phases[id] = .downloading(0)
        holdAwake(id)
        WSLog("world", "OSM import: downloading \(name) from \(url.host ?? "?")")

        var request = URLRequest(url: url)
        request.setValue("Windstock-launcher/1.0", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.downloadTask(with: request) { [weak self] temp, response, error in
            var moveError: Error?
            if let temp, error == nil {
                try? FileManager.default.removeItem(at: local)
                do { try FileManager.default.moveItem(at: temp, to: local) } catch { moveError = error }
            }
            let status = (response as? HTTPURLResponse)?.statusCode
            Task { @MainActor in
                guard let self else { return }
                self.tasks[id] = nil
                self.observations[id] = nil
                if let error = error ?? moveError {
                    try? FileManager.default.removeItem(at: local)
                    if (error as NSError).code == NSURLErrorCancelled {
                        self.endImport(id, failure: nil)
                    } else {
                        self.retryDated(url, name: name, region: region, id: id,
                                        allowed: datedFallback, failure: error.localizedDescription)
                    }
                    return
                }
                if let status, status != 200 {
                    try? FileManager.default.removeItem(at: local)
                    self.retryDated(url, name: name, region: region, id: id,
                                    allowed: datedFallback, failure: "The server answered \(status).")
                    return
                }
                self.convertOSM(local, id: id, name: name, region: region,
                                source: url.absoluteString, deleteAfter: true)
            }
        }
        observations[id] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading = self?.phases[id] {
                    self?.phases[id] = .downloading(fraction)
                }
            }
        }
        tasks[id] = task
        task.resume()
    }

    /// Geofabrik's "-latest" alias sometimes disappears (the server then
    /// answers with an endless redirect); the dated file behind it is still
    /// there, so a failed download is retried once with the newest of those.
    private func retryDated(_ url: URL, name: String, region: String, id: String,
                            allowed: Bool, failure: String) {
        guard allowed, url.lastPathComponent.hasSuffix(OSMImport.latestSuffix) else {
            endImport(id, failure: failure)
            return
        }
        Task {
            let dated = await OSMImport.datedExtract(for: url)
            endImport(id, failure: dated == nil ? failure : nil)
            if let dated {
                WSLog("world", "OSM import: \(failure) -- using \(dated.lastPathComponent)")
                importOSM(from: dated, name: name, region: region, datedFallback: false)
            }
        }
    }

    /// Converts an .osm.pbf the user picked in Files. `url` may be
    /// security-scoped; access is held for the whole conversion.
    func importOSMFile(_ url: URL) {
        let name = OSMImport.displayName(forFile: url)
        let id = OSMImport.packID(for: name)
        guard cancelFlags[id] == nil else { return }
        importNames[id] = name
        holdAwake(id)
        convertOSM(url, id: id, name: name, region: "", source: url.lastPathComponent,
                   deleteAfter: false, securityScoped: true)
    }

    /// True for links the Catalog box should hand to importOSM instead.
    static func isOSMExtract(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasSuffix(".pbf") || t.hasSuffix(".osm.pbf")
    }

    /// "…/north-america/us/texas-latest.osm.pbf" -> ("Texas", "north-america/us/texas")
    static func osmNameAndRegion(for url: URL) -> (String, String) {
        let name = OSMImport.displayName(forFile: url)
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        for suffix in ["-latest.osm.pbf", ".osm.pbf", ".pbf"] where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
            break
        }
        return (name, url.host == "download.geofabrik.de" ? path : "")
    }

    private func convertOSM(_ file: URL, id: String, name: String, region: String,
                            source: String, deleteAfter: Bool, securityScoped: Bool = false) {
        let flag = CancelFlag()
        cancelFlags[id] = flag
        phases[id] = .converting(0, "Starting…")
        let dest = Self.worldDir.appendingPathComponent("\(id).sqlite")
        WSLog("world", "OSM import: converting \(name)")

        Task.detached(priority: .userInitiated) {
            let scoped = securityScoped && file.startAccessingSecurityScopedResource()
            defer {
                if scoped { file.stopAccessingSecurityScopedResource() }
                if deleteAfter { try? FileManager.default.removeItem(at: file) }
            }
            var lastSent = -1.0
            let result = Result { () throws -> OSMImport.Summary in
                try OSMImport.convert(pbf: file, to: dest, name: name, region: region,
                                      progress: { fraction, text in
                    guard fraction - lastSent >= 0.01 || fraction >= 0.97 else { return }
                    lastSent = fraction
                    Task { @MainActor in
                        if case .converting = self.phases[id] {
                            self.phases[id] = .converting(fraction, text)
                        }
                    }
                }, isCancelled: { flag.isSet })
            }
            let pack: WorldPack? = {
                guard case .success(let s) = result else { return nil }
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size]
                            as? NSNumber)?.int64Value ?? 0
                return WorldPack(id: id, name: name, region: region, file: source, bytes: size,
                                 sha256: Self.sha256(of: dest) ?? "", forts: s.forts,
                                 gyms: s.gyms, biomes: false,
                                 built: ISO8601DateFormatter().string(from: Date()))
            }()
            if let pack {
                let sidecar = Self.worldDir.appendingPathComponent("\(id).json")
                try? JSONEncoder().encode(pack).write(to: sidecar, options: .atomic)
            }
            await MainActor.run {
                switch result {
                case .success(let s):
                    WSLog("world", "OSM import: \(name) -> \(s.forts) stops and gyms "
                          + "(\(s.gyms) gyms) from \(s.scanned) features")
                    self.endImport(id, failure: s.forts == 0
                        ? "No stops or gyms found in that file." : nil)
                    if s.forts == 0 { self.remove(id: id) }
                case .failure(let error):
                    if error is CancellationError {
                        self.endImport(id, failure: nil)
                    } else {
                        WSLog("world", "OSM import: \(name) failed: \(error.localizedDescription)")
                        self.endImport(id, failure: error.localizedDescription)
                    }
                }
                self.rescan()
            }
        }
    }

    private func endImport(_ id: String, failure: String?) {
        cancelFlags[id] = nil
        if let failure {
            phases[id] = .failed(failure)
        } else {
            phases[id] = nil
            importNames[id] = nil
        }
        releaseAwake(id)
    }

    /// Dismisses a failed import's row.
    func clearImport(id: String) {
        guard cancelFlags[id] == nil, tasks[id] == nil else { return }
        phases[id] = nil
        importNames[id] = nil
    }

    /// Big extracts take minutes: keep the screen on, and ask iOS for the
    /// usual grace period if the user switches away mid-import.
    private func holdAwake(_ id: String) {
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTasks[id] = UIApplication.shared.beginBackgroundTask(withName: "osm-\(id)") {
            [weak self] in
            Task { @MainActor in self?.releaseAwake(id) }
        }
    }

    private func releaseAwake(_ id: String) {
        if let task = backgroundTasks.removeValue(forKey: id) {
            UIApplication.shared.endBackgroundTask(task)
        }
        if backgroundTasks.isEmpty {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - remove

    func remove(id: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.worldDir.appendingPathComponent("\(id).sqlite"))
        try? fm.removeItem(at: Self.worldDir.appendingPathComponent("\(id).json"))
        WSLog("world", "removed \(id)")
        rescan()
    }
}
