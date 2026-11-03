import SwiftUI
import UIKit

/// The launcher log, made safe to send to whoever is running the test.
///
/// A tester's phone is not plugged into your Mac, so `devicectl` cannot fetch
/// its log -- the only way you find out what broke is if they send it. But the
/// raw log pinpoints them: the server logs the player's position to five
/// decimals (about a metre) in `[loc]` and `[map]` lines, the raw request dumps
/// carry the same position as `fixed64=` integers that decode exactly, and the
/// map-tile lines give z17 tile numbers (a few hundred metres). All of that is
/// rounded or removed here before anything leaves the device. Passwords are
/// never logged in the first place; trainer names are kept, because "which
/// account" is usually the first question.
enum LogExport {
    /// Writes a redacted copy to a temporary file and returns its URL.
    static func make() -> URL? {
        let source = URL(fileURLWithPath: WSPaths.logsDir)
            .appendingPathComponent("launcher.log")
        guard let raw = try? String(contentsOf: source, encoding: .utf8) else { return nil }

        let info = Bundle(path: WSPaths.hostBundlePath)?.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        let header = """
            Windstock \(version) (build \(build))
            \(device.model), \(device.systemName) \(device.systemVersion)
            Exported \(ISO8601DateFormatter().string(from: Date()))
            Locations in this file are rounded to about 10 km.
            ----------------------------------------------------------------

            """

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("windstock-log-\(build).txt")
        do {
            try (header + redact(raw)).write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }

    static func redact(_ text: String) -> String {
        var s = text
        // "lat,lng" pairs, however they are spaced: round to one decimal.
        s = replace(s, #"(-?\d{1,3}\.\d{2,})(\s*,\s*)(-?\d{1,3}\.\d{2,})"#) { m, str in
            "\(round1(group(m, 1, str)))\(group(m, 2, str))\(round1(group(m, 3, str)))"
        }
        // Raw envelope dumps: the fixed64 IS the double, bit for bit.
        s = replace(s, #"fixed64=\d+"#) { _, _ in "fixed64=<redacted>" }
        s = replace(s, #"double~-?\d+\.\d+"#) { _, _ in "double~<redacted>" }
        // Map-tile requests: z17 tile numbers locate you to a few hundred metres.
        s = replace(s, #"x \d+-\d+ y \d+-\d+"#) { _, _ in "x <redacted> y <redacted>" }
        return s
    }

    private static func round1(_ value: String) -> String {
        guard let d = Double(value) else { return value }
        return String(format: "%.1f", d)
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
        guard let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }

    private static func replace(_ s: String, _ pattern: String,
                                _ make: (NSTextCheckingResult, String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var result = ""
        var last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            result += s[last..<r.lowerBound]
            result += make(m, s)
            last = r.upperBound
        }
        result += s[last...]
        return result
    }
}

/// UIActivityViewController, so a tester can AirDrop, Mail or Message the file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// "Report a problem": what went wrong, plus the logs, straight to the Windstock website
/// (POST /api/report), where an admin reads it on admin.html. The logs are redacted
/// exactly like "Send the log" (LogExport.redact) before they leave the phone.
enum ProblemReport {
    /// The newest `maxBytes` of a text file, cut at a line start.
    static func tail(_ path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text
    }

    /// The launcher's log and the game tweak's own log, newest part of each, redacted.
    static func logs(profile: String) -> String {
        var out = ""
        let launcher = URL(fileURLWithPath: WSPaths.logsDir).appendingPathComponent("launcher.log").path
        if let t = tail(launcher, maxBytes: 900_000) {
            out += "==== launcher.log ====\n" + LogExport.redact(t) + "\n"
        }
        let tweak = URL(fileURLWithPath: WSPaths.container(forProfile: profile))
            .appendingPathComponent("Documents/windstock_log.txt").path
        if let t = tail(tweak, maxBytes: 400_000) {
            out += "\n==== windstock_log.txt (game) ====\n" + LogExport.redact(t) + "\n"
        }
        return out
    }

    /// "iPhone14,2", the exact model.
    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Sends it. Returns the report's short id, or throws a message to show.
    static func send(site: URL, what: String, contact: String, includeLogs: Bool,
                     trainer: String?, server: String, profile: String) async throws -> String {
        let device = UIDevice.current
        var body: [String: Any] = [
            "what": what, "contact": contact, "platform": "ios",
            "app": SettingsView.versionString,
            "device": "\(machine), \(device.systemName) \(device.systemVersion)",
            "trainer": trainer ?? "", "server": server,
        ]
        if includeLogs { body["log"] = logs(profile: profile) }
        var request = URLRequest(url: site.appendingPathComponent("api/report"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ReportError("Couldn't reach windstock.org. Check your connection and try again.")
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, json["ok"] as? Bool == true else {
            throw ReportError(json["error"] as? String ?? "The website didn't take the report. Try again later.")
        }
        return json["id"] as? String ?? ""
    }

    struct ReportError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

struct ReportProblemView: View {
    @EnvironmentObject private var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    var prefill = ""
    @State private var what = ""
    @State private var contact = ""
    @State private var includeLogs = true
    @State private var sending = false
    @State private var error: String?
    @State private var sentID: String?

    var body: some View {
        NavigationStack {
            Form {
                if let id = sentID {
                    Section {
                        Label("Sent. Thanks!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                        Text("Report \(id). If you left a way to reach you, you'll hear back there.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextEditor(text: $what)
                            .frame(minHeight: 120)
                    } header: {
                        Text("What went wrong?")
                    } footer: {
                        Text("What you were doing, and what happened instead. Send it right after it happens if you can.")
                    }
                    Section {
                        TextField("Discord name or email (optional)", text: $contact)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("Include the logs", isOn: $includeLogs)
                    } footer: {
                        Text("The logs show what the launcher and the game were doing. Your location "
                             + "in them is rounded to about 10 km first, and passwords are never in them.")
                    }
                    if let error {
                        Section { Text(error).foregroundStyle(Theme.bad) }
                    }
                }
            }
            .navigationTitle("Report a problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sentID == nil ? "Cancel" : "Done") { dismiss() }
                }
                if sentID == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if sending {
                            ProgressView()
                        } else {
                            Button("Send") { send() }
                                .disabled(what.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                        }
                    }
                }
            }
            .onAppear { if what.isEmpty { what = prefill } }
        }
    }

    private func send() {
        sending = true
        error = nil
        let prefs = model.prefs
        let site = model.profile.siteURL
        let trainer = model.profile.trainer
        let text = what.trimmingCharacters(in: .whitespacesAndNewlines)
        let reach = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        let logs = includeLogs
        Task {
            do {
                let id = try await ProblemReport.send(site: site, what: text, contact: reach, includeLogs: logs,
                                                      trainer: trainer, server: prefs.serverMode.rawValue,
                                                      profile: prefs.profile)
                WSLog("launcher", "problem report \(id) sent")
                sentID = id
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
