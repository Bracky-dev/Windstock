import Foundation

/// Answers one question: why does the device refuse to dlopen the guest?
///
/// `code signature invalid (errno=1)` has three plausible causes and no way to
/// tell them apart from the message, so this tries them one at a time on a
/// tiny binary that is already in the bundle:
///
///   1. a Sideloadly-signed dylib, loaded from inside the app bundle
///      — the control. If this fails, nothing else means anything.
///   2. the same bytes copied into Documents and loaded from there
///      — if only this fails, the problem is *where* the file is, not its
///        signature, and no amount of signing work will fix it.
///   3. that copy re-signed by our own signer
///      — if 2 passes and this fails, the problem is our signature, and the
///        difference between the two is exactly what to go and look at.
enum LoadTest {
    static func run() -> String {
        var lines: [String] = []
        func note(_ text: String) {
            lines.append(text)
            WSLog("loadtest", text)
        }

        let frameworks = WSPaths.frameworksDir
        // A Python extension module: small, already signed by whoever signed
        // the app, and with no constructors to run if it does load.
        let name = "_bisect"
        let original = ((frameworks as NSString).appendingPathComponent("\(name).framework")
            as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: original) else {
            return "No \(name).framework in the bundle to test with."
        }

        note("1. in-bundle, signed by the installer: \(attempt(original))")

        let scratch = (WSPaths.launcherRoot as NSString).appendingPathComponent("loadtest")
        try? FileManager.default.removeItem(atPath: scratch)
        try? FileManager.default.createDirectory(atPath: scratch,
                                                 withIntermediateDirectories: true)

        guard let bytes = FileManager.default.contents(atPath: original) else {
            note("could not read the test binary")
            return lines.joined(separator: "\n")
        }

        // dlopen caches by path, so each step needs its own filename.
        let copied = (scratch as NSString).appendingPathComponent("copy.dylib")
        do {
            try bytes.write(to: URL(fileURLWithPath: copied))
            note("2. same bytes, from Documents: \(attempt(copied))")
        } catch {
            note("2. could not copy: \(error.localizedDescription)")
        }

        let resigned = (scratch as NSString).appendingPathComponent("resigned.dylib")
        do {
            let identity = try SigningIdentityStore.current()
            let signed = try MachOSigner.sign(bytes, identifier: "com.windstock.loadtest",
                                              identity: identity)
            try signed.write(to: URL(fileURLWithPath: resigned))
            note("3. re-signed by us, from Documents: \(attempt(resigned))")
        } catch {
            note("3. could not sign: \(error.localizedDescription)")
        }

        return lines.joined(separator: "\n")
    }

    private static func attempt(_ path: String) -> String {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown"
            // Only the interesting tail; the paths dyld lists are noise here.
            let short = reason.components(separatedBy: "): ").last ?? reason
            return "FAILED — \(short.prefix(200))"
        }
        dlclose(handle)
        return "loaded"
    }
}
