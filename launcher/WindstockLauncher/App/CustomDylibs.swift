import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One dylib the player imported to load into the game alongside the
/// built-in tweaks.
struct CustomDylib: Codable, Identifiable, Equatable {
    var id: UUID
    /// The original filename, shown in the list.
    var name: String
    var enabled: Bool
    var byteSize: Int64
    var importedAt: Date
    /// SHA-256 of the certificate the loadable copy was signed with; nil when
    /// it is the imported bytes unchanged.
    var signedWith: String?
    /// Hard dependencies a stock (non-jailbroken) iPhone does not have, e.g.
    /// CydiaSubstrate. Shown as a warning; the load is still attempted.
    var missingDependencies: [String] = []
}

/// Imported dylibs, stored under Documents/Windstock/dylibs:
///
///   index.json             the list (order = load order)
///   original/<id>.dylib    the bytes as imported, thinned to arm64
///   <id>.dylib             what is actually dlopen'd -- re-signed with the
///                          player's certificate when one is imported
///   last-load.json         written by WSGuestLoader: filename -> result
///
/// The original is kept so a certificate refresh can sign it again from clean
/// bytes rather than re-signing a re-signed file.
@MainActor
final class CustomDylibStore: ObservableObject {
    @Published private(set) var dylibs: [CustomDylib] = []
    /// From the previous launch: "loaded", or the dlopen error.
    @Published private(set) var lastLoad: [String: String] = [:]

    enum Failure: LocalizedError {
        case notMachO
        case noArm64Slice
        case notALibrary(UInt32)

        var errorDescription: String? {
            switch self {
            case .notMachO: return "That file is not a Mach-O library."
            case .noArm64Slice: return "That library has no arm64 slice for iPhone."
            case .notALibrary(let type):
                return "That Mach-O is not a dylib (file type \(type))."
            }
        }
    }

    static var directory: String {
        (WSPaths.launcherRoot as NSString).appendingPathComponent("dylibs")
    }
    private var dir: String { Self.directory }
    private var indexFile: String { (dir as NSString).appendingPathComponent("index.json") }
    private var originalsDir: String { (dir as NSString).appendingPathComponent("original") }

    init() {
        reload()
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = FileManager.default.contents(atPath: indexFile),
           let list = try? decoder.decode([CustomDylib].self, from: data) {
            dylibs = list
        }
        let report = (dir as NSString).appendingPathComponent("last-load.json")
        if let data = FileManager.default.contents(atPath: report),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            lastLoad = map
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        try? WSPaths.ensureDirectory(dir)
        if let data = try? encoder.encode(dylibs) {
            try? data.write(to: URL(fileURLWithPath: indexFile), options: .atomic)
        }
    }

    func loadPath(for dylib: CustomDylib) -> String {
        (dir as NSString).appendingPathComponent("\(dylib.id.uuidString).dylib")
    }

    private func originalPath(for dylib: CustomDylib) -> String {
        (originalsDir as NSString).appendingPathComponent("\(dylib.id.uuidString).dylib")
    }

    /// Result of the last launch for this dylib, if it was part of it.
    func lastResult(for dylib: CustomDylib) -> String? {
        lastLoad[(loadPath(for: dylib) as NSString).lastPathComponent]
    }

    // MARK: - Import / edit

    func importDylib(from url: URL) throws {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

        let thin = try Self.thinToArm64(try Data(contentsOf: url))
        let type: UInt32 = thin.read(at: 12)
        // MH_DYLIB, MH_BUNDLE -- both dlopen.
        guard type == 6 || type == 8 else { throw Failure.notALibrary(type) }

        var entry = CustomDylib(id: UUID(), name: url.lastPathComponent, enabled: true,
                                byteSize: Int64(thin.count), importedAt: Date())
        entry.missingDependencies = Self.unavailableDependencies(of: thin)

        try WSPaths.ensureDirectory(originalsDir)
        try thin.write(to: URL(fileURLWithPath: originalPath(for: entry)))
        entry.signedWith = writeLoadable(thin, for: entry)

        dylibs.append(entry)
        save()
        WSLog("dylibs", "imported \(entry.name) (\(thin.count) bytes, "
              + (entry.signedWith != nil ? "signed" : "unsigned copy") + ")"
              + (entry.missingDependencies.isEmpty ? ""
                 : " needs \(entry.missingDependencies.joined(separator: ", "))"))
    }

    func setEnabled(_ dylib: CustomDylib, _ on: Bool) {
        guard let i = dylibs.firstIndex(where: { $0.id == dylib.id }) else { return }
        dylibs[i].enabled = on
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        dylibs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func delete(_ dylib: CustomDylib) {
        try? FileManager.default.removeItem(atPath: loadPath(for: dylib))
        try? FileManager.default.removeItem(atPath: originalPath(for: dylib))
        dylibs.removeAll { $0.id == dylib.id }
        save()
    }

    // MARK: - Launch

    /// Paths to inject, in order, re-signing any copy made under a different
    /// certificate first (free certificates rotate every week).
    func pathsForLaunch() -> [String] {
        let current = Self.currentCertificateHash()
        var changed = false
        var paths: [String] = []
        for i in dylibs.indices where dylibs[i].enabled {
            let entry = dylibs[i]
            if current != nil, entry.signedWith != current,
               let original = FileManager.default.contents(atPath: originalPath(for: entry)) {
                dylibs[i].signedWith = writeLoadable(original, for: entry)
                changed = true
            }
            paths.append(loadPath(for: dylibs[i]))
        }
        if changed { save() }
        return paths
    }

    /// Writes the copy that gets dlopen'd. Returns the certificate hash it
    /// was signed with, or nil if it is the bytes unchanged (no certificate
    /// imported, or the signer could not handle this file).
    private func writeLoadable(_ bytes: Data, for entry: CustomDylib) -> String? {
        var out = bytes
        var signedWith: String?
        if SigningIdentityStore.hasIdentity {
            do {
                let identity = try SigningIdentityStore.current()
                let ident = "com.windstock.dylib."
                    + entry.id.uuidString.prefix(8).lowercased()
                out = try MachOSigner.sign(bytes, identifier: ident, identity: identity)
                signedWith = Self.hash(of: identity.certificate)
            } catch {
                WSLog("dylibs", "could not sign \(entry.name): \(error.localizedDescription)"
                      + " -- keeping it as imported")
            }
        }
        try? out.write(to: URL(fileURLWithPath: loadPath(for: entry)), options: .atomic)
        return signedWith
    }

    private static func currentCertificateHash() -> String? {
        guard SigningIdentityStore.hasIdentity,
              let identity = try? SigningIdentityStore.current() else { return nil }
        return hash(of: identity.certificate)
    }

    private static func hash(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Mach-O

    /// Returns a thin arm64 Mach-O, extracting the slice from a universal
    /// binary. Prefers plain arm64 over arm64e, which a sideloaded app's
    /// process does not use.
    static func thinToArm64(_ data: Data) throws -> Data {
        guard data.count > 32 else { throw Failure.notMachO }
        let magic: UInt32 = data.read(at: 0)
        if magic == 0xFEED_FACF {
            let cpu: UInt32 = data.read(at: 4)
            guard cpu == 0x0100_000C else { throw Failure.noArm64Slice }
            return data
        }
        // Fat headers are big-endian: CAFEBABE reads back as BEBAFECA.
        let fat32 = magic == 0xBEBA_FECA, fat64 = magic == 0xBFBA_FECA
        guard fat32 || fat64 else { throw Failure.notMachO }
        let count = Int(UInt32(bigEndian: data.read(at: 4)))
        let stride = fat64 ? 32 : 20
        var best: (offset: Int, size: Int, subtype: UInt32)?
        for i in 0..<count {
            let at = 8 + i * stride
            guard at + stride <= data.count else { break }
            let cpu = UInt32(bigEndian: data.read(at: at))
            let sub = UInt32(bigEndian: data.read(at: at + 4)) & 0x00FF_FFFF
            guard cpu == 0x0100_000C else { continue }
            let offset: Int, size: Int
            if fat64 {
                offset = Int(UInt64(bigEndian: data.read(at: at + 8)))
                size = Int(UInt64(bigEndian: data.read(at: at + 16)))
            } else {
                offset = Int(UInt32(bigEndian: data.read(at: at + 8)))
                size = Int(UInt32(bigEndian: data.read(at: at + 12)))
            }
            // CPU_SUBTYPE_ARM64E = 2; anything else wins over it.
            if best == nil || (best!.subtype == 2 && sub != 2) {
                best = (offset, size, sub)
            }
        }
        guard let best, best.offset + best.size <= data.count else {
            throw Failure.noArm64Slice
        }
        return data.subdata(in: best.offset..<(best.offset + best.size))
    }

    /// Non-weak LC_LOAD_DYLIBs that only exist on a jailbroken device.
    static func unavailableDependencies(of data: Data) -> [String] {
        let ncmds: UInt32 = data.read(at: 16)
        var at = 32
        var out: [String] = []
        for _ in 0..<ncmds {
            guard at + 8 <= data.count else { break }
            let cmd: UInt32 = data.read(at: at)
            let size = Int(data.read(at: at + 4) as UInt32)
            guard size >= 8 else { break }
            // LC_LOAD_DYLIB, LC_REEXPORT_DYLIB (weak loads are optional).
            if cmd == 0xC || cmd == 0x8000_001F {
                let nameOffset = Int(data.read(at: at + 8) as UInt32)
                let start = at + nameOffset, end = min(at + size, data.count)
                if start < end {
                    let raw = data.subdata(in: start..<end).prefix { $0 != 0 }
                    let path = String(decoding: raw, as: UTF8.self)
                    let lower = path.lowercased()
                    if path.hasPrefix("/Library/") || path.hasPrefix("/var/jb/")
                        || lower.contains("substrate") || lower.contains("substitute")
                        || lower.contains("ellekit") || lower.contains("libhooker") {
                        out.append((path as NSString).lastPathComponent)
                    }
                }
            }
            at += size
        }
        return out
    }
}

extension UTType {
    static let dylib = UTType(filenameExtension: "dylib") ?? .data
}

/// Mods tab: import, toggle, reorder and delete custom dylibs.
struct CustomDylibsSection: View {
    @EnvironmentObject private var model: LauncherModel
    @State private var picking = false
    @State private var importError: String?

    private var store: CustomDylibStore { model.customDylibs }

    var body: some View {
        Section {
            ForEach(store.dylibs) { dylib in
                row(dylib)
            }
            .onMove { store.move(from: $0, to: $1) }
            .onDelete { offsets in
                offsets.map { store.dylibs[$0] }.forEach(store.delete)
            }

            Button {
                picking = true
            } label: {
                Label("Import a dylib", systemImage: "square.and.arrow.down")
            }
            .fileImporter(isPresented: $picking,
                          allowedContentTypes: [.dylib, .data],
                          allowsMultipleSelection: true) { result in
                importError = nil
                switch result {
                case .success(let urls):
                    for url in urls {
                        do { try store.importDylib(from: url) }
                        catch {
                            importError = "\(url.lastPathComponent): "
                                + error.localizedDescription
                            WSLog("dylibs", "import failed: \(importError!)")
                        }
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }

            if let importError {
                Text(importError).font(.footnote).foregroundStyle(Theme.bad)
            }
        } header: {
            Text("Custom dylibs")
        } footer: {
            Text("Loaded into the game after the built-in tweaks, top to bottom. "
                 + (SigningIdentityStore.hasIdentity
                    ? "Each one is signed with your certificate."
                    : "Import your signing certificate in Settings first — iOS "
                      + "will not load a library that is not signed with the "
                      + "certificate that signed this app."))
        }
    }

    @ViewBuilder
    private func row(_ dylib: CustomDylib) -> some View {
        Toggle(isOn: Binding(get: { dylib.enabled },
                             set: { store.setEnabled(dylib, $0) })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(dylib.name)
                Text(ByteCountFormatter.string(fromByteCount: dylib.byteSize,
                                               countStyle: .file)
                     + (dylib.signedWith != nil ? " · signed" : " · unsigned"))
                    .font(.caption).foregroundStyle(.secondary)
                if !dylib.missingDependencies.isEmpty {
                    Text("Needs \(dylib.missingDependencies.joined(separator: ", ")), "
                         + "which only jailbroken phones have — it will probably not load.")
                        .font(.caption).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let result = store.lastResult(for: dylib) {
                    Text(result == "loaded" ? "Loaded last launch"
                                            : "Last launch: \(result)")
                        .font(.caption)
                        .foregroundStyle(result == "loaded" ? Theme.accent : Theme.bad)
                        .lineLimit(3)
                }
            }
        }
    }
}

private extension Data {
    func read<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { raw in
            copyBytes(to: raw, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }
}
