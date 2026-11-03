import SwiftUI

/// Server settings, in the app. One screen per section, controls chosen by the
/// type of each value, so a setting added on the server appears here by itself.
struct GameSettingsView: View {
    @ObservedObject var store: GameSettingsStore
    /// Empty at the top level; a section (and any nested group) as you go in.
    var path: [String] = []

    var body: some View {
        List {
            if path.isEmpty {
                if let error = store.error {
                    Section { Text(error).font(.footnote).foregroundStyle(Theme.warn) }
                }
                Section {
                    ForEach(store.sections, id: \.self) { section in
                        NavigationLink(GameSettingsStore.label(section)) {
                            GameSettingsView(store: store, path: [section])
                        }
                    }
                } footer: {
                    Text("Changes save as you make them and the server picks them "
                         + "up within a few seconds — no restart. Some only apply "
                         + "to Pokemon that spawn afterwards.")
                }
            } else {
                Section {
                    ForEach(store.keys(path), id: \.self) { key in
                        row(key)
                    }
                } footer: {
                    if store.keys(path).isEmpty {
                        Text("Nothing in here.")
                    }
                }
            }
        }
        .navigationTitle(path.isEmpty ? "Server settings"
                                      : GameSettingsStore.label(path.last!))
        .navigationBarTitleDisplayMode(path.isEmpty ? .large : .inline)
    }

    @ViewBuilder
    private func row(_ key: String) -> some View {
        let full = path + [key]
        VStack(alignment: .leading, spacing: 4) {
            control(full, key)
            // The server's own words about this setting. Worth the space: one
            // of these toggles is an experiment that stops you logging in.
            if let why = store.explanation(for: full) {
                Text(why)
                    .font(.caption)
                    .foregroundStyle(why.contains("EXPERIMENT") ? Theme.warn : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func control(_ full: [String], _ key: String) -> some View {
        let title = GameSettingsStore.label(key)
        switch SettingKind(store.value(at: full)) {
        case .flag(let on):
            Toggle(title, isOn: Binding(get: { on },
                                        set: { store.set($0, at: full) }))
        case .whole(let n):
            LabeledContent(title) {
                TextField(title, value: Binding(get: { n },
                                                set: { store.set($0, at: full) }),
                          format: .number)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
            }
        case .decimal(let d):
            LabeledContent(title) {
                TextField(title, value: Binding(get: { d },
                                                set: { store.set($0, at: full) }),
                          format: .number)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
            }
        case .text(let s):
            LabeledContent(title) {
                TextField(title, text: Binding(get: { s },
                                               set: { store.set($0, at: full) }))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        case .list(let items):
            // Lists here are short and numeric (species ids, egg distances), so
            // a comma-separated line is friendlier than a row editor.
            LabeledContent(title) {
                TextField(title, text: Binding(
                    get: { items.map { "\($0)" }.joined(separator: ", ") },
                    set: { store.set(Self.parseList($0, like: items), at: full) }))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
            }
        case .group:
            NavigationLink {
                GameSettingsView(store: store, path: full)
            } label: {
                LabeledContent(title, value: "\(store.keys(full).count)")
            }
        }
    }

    /// Keep a list the same shape it was: all-numbers stays numbers, so the
    /// server does not suddenly get strings where it wants species ids.
    private static func parseList(_ text: String, like original: [Any]) -> [Any] {
        let parts = text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let wereNumbers = original.allSatisfy { $0 is NSNumber }
        guard wereNumbers else { return parts }
        return parts.compactMap { part -> Any? in
            if let i = Int(part) { return i }
            if let d = Double(part) { return d }
            return nil
        }
    }
}
