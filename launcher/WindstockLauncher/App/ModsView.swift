import SwiftUI

struct ModsView: View {
    @EnvironmentObject private var model: LauncherModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Changes apply the next time the game starts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(ModsCatalog.sections) { section in
                    Section(section.title) {
                        ForEach(section.mods) { mod in
                            row(for: mod)
                        }
                    }
                }

                Section("Location") {
                    Toggle(isOn: $model.prefs.injectGPS) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Location spoofing")
                            Text("Adds the joystick panel to the game. Nothing moves until you switch it on in that panel.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                NameColorsSection()

                CustomDylibsSection()

                Section("Night music hours") {
                    hourPicker("Starts at", key: ModsCatalog.nightStartHour, fallback: 19)
                    hourPicker("Ends at", key: ModsCatalog.nightEndHour, fallback: 6)
                }

                Section {
                    Button("Reset to defaults") {
                        model.mods = .defaults
                    }
                }
            }
            .navigationTitle("Mods")
        }
    }

    @ViewBuilder
    private func row(for mod: ModDescriptor) -> some View {
        let unmet = mod.requires.filter { !model.mods.isEffectivelyOn($0) }
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: binding(for: mod.key)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mod.title)
                    Text(mod.blurb)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !unmet.isEmpty {
                Label("Needs \(titles(of: unmet))", systemImage: "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
        }
        .padding(.vertical, 2)
    }

    private func titles(of keys: [String]) -> String {
        keys.compactMap { ModsCatalog.descriptor(for: $0)?.title }
            .joined(separator: " + ")
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { model.mods.mods[key] ?? false },
            set: { model.mods.mods[key] = $0 }
        )
    }

    private func hourPicker(_ label: String, key: String, fallback: Double) -> some View {
        Picker(label, selection: Binding(
            get: { Int(model.mods.values[key] ?? fallback) },
            set: { model.mods.values[key] = Double($0) }
        )) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).tag(hour)
            }
        }
    }
}

// MARK: - colored names

/// The colours the server knows (work/server/colortags.py COLORS). The two
/// lists have to change together: a key the server doesn't know is ignored.
enum NameColor {
    static let options: [(key: String, label: String, hex: String)] = [
        ("red", "Red", "ff4040"), ("orange", "Orange", "ff9a1f"),
        ("yellow", "Yellow", "ffe14d"), ("gold", "Gold", "f2b705"),
        ("green", "Green", "3ccf5a"), ("lime", "Lime", "a6f03c"),
        ("teal", "Teal", "1fbfa6"), ("cyan", "Cyan", "3de0ff"),
        ("blue", "Blue", "3d8bff"), ("navy", "Navy", "2340a0"),
        ("purple", "Purple", "a55cff"), ("pink", "Pink", "ff6fcf"),
        ("magenta", "Magenta", "ff3dd6"), ("brown", "Brown", "a0632d"),
        ("white", "White", "ffffff"), ("gray", "Gray", "9aa4ad"),
        ("black", "Black", "111111"),
        ("mystic", "Mystic", "3d8bff"), ("valor", "Valor", "ff3d3d"),
        ("instinct", "Instinct", "ffd000"),
    ]
    static let rainbow = ["ff4040", "ff9a1f", "ffe14d", "3ccf5a", "3d8bff", "a55cff"]

    static func color(_ hex: String) -> Color {
        let v = UInt32(hex, radix: 16) ?? 0xffffff
        return Color(red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255)
    }

    /// A pre-coloured dot. Menus redraw SF Symbols in the tint colour, so a
    /// foregroundStyle on one comes out as a column of identical green dots.
    static func swatch(_ hex: String) -> UIImage {
        let size = CGSize(width: 18, height: 18)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(color(hex)).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
            UIColor.black.withAlphaComponent(0.15).setStroke()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// How a name looks with this setting ("" = plain, "rainbow", "team", a key).
    static func preview(_ text: String, _ key: String) -> Text {
        if key == "rainbow" {
            var out = Text("")
            var i = 0
            for ch in text {
                if ch == " " { out = out + Text(" "); continue }
                out = out + Text(String(ch)).foregroundColor(color(rainbow[i % rainbow.count]))
                i += 1
            }
            return out
        }
        if key == "team" {
            return Text("Gym").foregroundColor(color("3d8bff")) + Text(" ")
                + Text("Gym").foregroundColor(color("ff3d3d")) + Text(" ")
                + Text("Gym").foregroundColor(color("ffd000"))
        }
        guard let hex = options.first(where: { $0.key == key })?.hex else { return Text(text) }
        return Text(text).foregroundColor(color(hex))
    }
}

/// Colours for trainer / PokeStop / Gym names. Unlike the switches above these
/// are SERVER settings (settings.json "names"), so they apply on the next map
/// refresh or login, no game restart needed.
struct NameColorsSection: View {
    @State private var trainer = ""
    @State private var stop = ""
    @State private var gym = ""
    @State private var noServer = false

    var body: some View {
        Section {
            if noServer {
                Label("Start the server once, then these can be set.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(Theme.warn)
            }
            picker("Trainer name", "Trainer", key: "trainer_color", value: $trainer, team: false)
            picker("PokéStop names", "PokéStop", key: "stop_color", value: $stop, team: false)
            picker("Gym names", "Gym", key: "gym_color", value: $gym, team: true)
        } header: {
            Text("Colored names")
        } footer: {
            Text("You can also color any name you type in the game — your trainer name or a Pokémon's nickname — with tags: [red]Ash, [gold]Ash[/]ketchum, [f80]Ash or [rainbow]Ash. A name with its own tags keeps them.")
        }
        .onAppear(perform: load)
        .disabled(noServer)
    }

    private func picker(_ title: String, _ sample: String, key: String,
                        value: Binding<String>, team: Bool) -> some View {
        Picker(selection: Binding(
            get: { value.wrappedValue },
            set: { new in
                value.wrappedValue = new
                noServer = !GameSettingsStore.writeValue(new, "names", key)
            }
        )) {
            Text("Plain").tag("")
            if team { Text("Team color").tag("team") }
            Text("Rainbow").tag("rainbow")
            ForEach(NameColor.options, id: \.key) { opt in
                Label {
                    Text(opt.label)
                } icon: {
                    Image(uiImage: NameColor.swatch(opt.hex))
                }
                .tag(opt.key)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                NameColor.preview(sample, value.wrappedValue).font(.footnote.bold())
            }
        }
    }

    private func load() {
        let read = { (k: String) in
            (GameSettingsStore.readValue("names", k) as? String ?? "").lowercased()
        }
        noServer = !FileManager.default.fileExists(atPath: GameSettingsStore.url.path)
        trainer = read("trainer_color")
        stop = read("stop_color")
        gym = read("gym_color")
    }
}
