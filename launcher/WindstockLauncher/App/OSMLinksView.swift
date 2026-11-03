import SwiftUI

/// Settings › World Data › Add from OpenStreetMap: every region the World
/// Manager's World Data page offers. Tapping one downloads its Geofabrik
/// extract and converts it into a pack on the phone (OSMImport.swift); the
/// raw link stays available from the long-press menu.
///
/// Regions mirror work/server/poidownload.py (COUNTRIES, US_STATES).
struct OSMLinksView: View {
    @ObservedObject private var store = WorldPackStore.shared
    @State private var confirmRemove: (id: String, name: String)?
    @State private var confirmAdd: PendingAdd?

    /// A place the user tapped, waiting for "Download and Add" -- extracts run
    /// from tens of MB to several GB, so one stray tap must not start one.
    private struct PendingAdd {
        let name: String
        let region: String
        let url: URL
        var size: Int64?
        var sizeFailed = false
    }

    private static let base = "https://download.geofabrik.de/"

    static let countries: [(name: String, region: String)] = [
        ("Canada", "north-america/canada"),
        ("Mexico", "north-america/mexico"),
        ("Great Britain", "europe/great-britain"),
        ("Ireland", "europe/ireland"),
        ("Germany", "europe/germany"),
        ("France", "europe/france"),
        ("Spain", "europe/spain"),
        ("Portugal", "europe/portugal"),
        ("Italy", "europe/italy"),
        ("Netherlands", "europe/netherlands"),
        ("Belgium", "europe/belgium"),
        ("Luxembourg", "europe/luxembourg"),
        ("Switzerland", "europe/switzerland"),
        ("Austria", "europe/austria"),
        ("Denmark", "europe/denmark"),
        ("Norway", "europe/norway"),
        ("Sweden", "europe/sweden"),
        ("Finland", "europe/finland"),
        ("Iceland", "europe/iceland"),
        ("Poland", "europe/poland"),
        ("Czechia", "europe/czech-republic"),
        ("Slovakia", "europe/slovakia"),
        ("Hungary", "europe/hungary"),
        ("Slovenia", "europe/slovenia"),
        ("Croatia", "europe/croatia"),
        ("Romania", "europe/romania"),
        ("Bulgaria", "europe/bulgaria"),
        ("Greece", "europe/greece"),
        ("Ukraine", "europe/ukraine"),
        ("Estonia", "europe/estonia"),
        ("Latvia", "europe/latvia"),
        ("Lithuania", "europe/lithuania"),
        ("Brazil", "south-america/brazil"),
        ("Argentina", "south-america/argentina"),
        ("Japan", "asia/japan"),
        ("South Korea", "asia/south-korea"),
        ("India", "asia/india"),
        ("Australia", "australia-oceania/australia"),
        ("New Zealand", "australia-oceania/new-zealand"),
        ("South Africa", "africa/south-africa"),
    ]

    static let usStates: [(name: String, region: String)] = [
        ("Alabama", "north-america/us/alabama"),
        ("Alaska", "north-america/us/alaska"),
        ("Arizona", "north-america/us/arizona"),
        ("Arkansas", "north-america/us/arkansas"),
        ("California", "north-america/us/california"),
        ("Colorado", "north-america/us/colorado"),
        ("Connecticut", "north-america/us/connecticut"),
        ("Delaware", "north-america/us/delaware"),
        ("District of Columbia", "north-america/us/district-of-columbia"),
        ("Florida", "north-america/us/florida"),
        ("Georgia", "north-america/us/georgia"),
        ("Hawaii", "north-america/us/hawaii"),
        ("Idaho", "north-america/us/idaho"),
        ("Illinois", "north-america/us/illinois"),
        ("Indiana", "north-america/us/indiana"),
        ("Iowa", "north-america/us/iowa"),
        ("Kansas", "north-america/us/kansas"),
        ("Kentucky", "north-america/us/kentucky"),
        ("Louisiana", "north-america/us/louisiana"),
        ("Maine", "north-america/us/maine"),
        ("Maryland", "north-america/us/maryland"),
        ("Massachusetts", "north-america/us/massachusetts"),
        ("Michigan", "north-america/us/michigan"),
        ("Minnesota", "north-america/us/minnesota"),
        ("Mississippi", "north-america/us/mississippi"),
        ("Missouri", "north-america/us/missouri"),
        ("Montana", "north-america/us/montana"),
        ("Nebraska", "north-america/us/nebraska"),
        ("Nevada", "north-america/us/nevada"),
        ("New Hampshire", "north-america/us/new-hampshire"),
        ("New Jersey", "north-america/us/new-jersey"),
        ("New Mexico", "north-america/us/new-mexico"),
        ("New York", "north-america/us/new-york"),
        ("North Carolina", "north-america/us/north-carolina"),
        ("North Dakota", "north-america/us/north-dakota"),
        ("Ohio", "north-america/us/ohio"),
        ("Oklahoma", "north-america/us/oklahoma"),
        ("Oregon", "north-america/us/oregon"),
        ("Pennsylvania", "north-america/us/pennsylvania"),
        ("Puerto Rico", "north-america/us/puerto-rico"),
        ("Rhode Island", "north-america/us/rhode-island"),
        ("South Carolina", "north-america/us/south-carolina"),
        ("South Dakota", "north-america/us/south-dakota"),
        ("Tennessee", "north-america/us/tennessee"),
        ("Texas", "north-america/us/texas"),
        ("Utah", "north-america/us/utah"),
        ("Vermont", "north-america/us/vermont"),
        ("Virginia", "north-america/us/virginia"),
        ("Washington", "north-america/us/washington"),
        ("West Virginia", "north-america/us/west-virginia"),
        ("Wisconsin", "north-america/us/wisconsin"),
        ("Wyoming", "north-america/us/wyoming"),
    ]

    @State private var query = ""

    var body: some View {
        List {
            // A plain field, not .searchable: that bar never appears in this
            // app's tab/navigation setup.
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Country or state", text: $query)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            section("Countries", Self.countries)
            section("United States", Self.usStates)
        }
        .navigationTitle("OpenStreetMap")
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?",
                            isPresented: Binding(get: { confirmRemove != nil },
                                                 set: { if !$0 { confirmRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let id = confirmRemove?.id { store.remove(id: id) }
                confirmRemove = nil
            }
        } message: {
            Text("Its stops and gyms disappear from the map. You can add it again.")
        }
        .confirmationDialog("Add \(confirmAdd?.name ?? "")?",
                            isPresented: Binding(get: { confirmAdd != nil },
                                                 set: { if !$0 { confirmAdd = nil } }),
                            titleVisibility: .visible) {
            Button("Download and Add") {
                if let add = confirmAdd {
                    store.importOSM(from: add.url, name: add.name, region: add.region)
                }
                confirmAdd = nil
            }
        } message: {
            Text(addMessage)
        }
    }

    private var addMessage: String {
        guard let add = confirmAdd else { return "" }
        let size: String
        if let bytes = add.size {
            size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } else {
            size = add.sizeFailed ? "an unknown amount" : "…"
        }
        return "Downloads \(size) from OpenStreetMap, then turns it into stops and "
            + "gyms on this phone. Use Wi-Fi, and keep the app open until it finishes."
    }

    /// Asks for confirmation, filling in the download size once a HEAD
    /// request answers.
    private func askToAdd(_ name: String, _ region: String, _ url: URL) {
        confirmAdd = PendingAdd(name: name, region: region, url: url)
        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            var length = try? await URLSession.shared.data(for: request).1.expectedContentLength
            if length == nil, let dated = await OSMImport.datedExtract(for: url) {
                request.url = dated
                length = try? await URLSession.shared.data(for: request).1.expectedContentLength
            }
            guard confirmAdd?.url == url else { return }
            if let length, length > 0 {
                confirmAdd?.size = length
            } else {
                confirmAdd?.sizeFailed = true
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [(name: String, region: String)]) -> some View {
        let shown = query.isEmpty ? items
            : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if !shown.isEmpty {
            Section {
                ForEach(shown, id: \.region) { row($0.name, $0.region) }
            } header: {
                Text(title)
            } footer: {
                if title == "United States" {
                    Text("Tap a place to add its stops and gyms. The phone downloads "
                         + "the whole OpenStreetMap extract first -- tens of MB for a "
                         + "small state, over 1 GB for the biggest countries -- so use "
                         + "Wi-Fi and keep the app open until it finishes. Long-press "
                         + "for the raw link.")
                }
            }
        }
    }

    private func row(_ name: String, _ region: String) -> some View {
        let url = URL(string: Self.base + region + "-latest.osm.pbf")!
        let id = OSMImport.packID(for: region)
        let phase = store.phases[id]
        let installed = store.installed[id] != nil
        let busy: Bool = {
            switch phase {
            case .downloading, .verifying, .converting: return true
            default: return false
            }
        }()
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                if phase != nil {
                    OSMPhaseView(phase: phase)
                } else {
                    Text(region + "-latest.osm.pbf")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if busy {
                Button("Cancel") { store.cancel(id: id) }
                    .buttonStyle(.borderless)
            } else if installed {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
            } else {
                Button {
                    askToAdd(name, region, url)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add \(name)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !busy && !installed { askToAdd(name, region, url) }
        }
        .contextMenu {
            if installed && !busy {
                Button {
                    askToAdd(name, region, url)
                } label: {
                    Label("Update from OpenStreetMap", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    confirmRemove = (id, name)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            Link(destination: url) {
                Label("Open Link in Safari", systemImage: "safari")
            }
            Button {
                UIPasteboard.general.url = url
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

/// The status line under an importing pack's name.
struct OSMPhaseView: View {
    let phase: WorldPackStore.Phase?

    var body: some View {
        switch phase {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 3) {
                Text("Downloading… \(Int(fraction * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: fraction).tint(Theme.accent)
            }
        case .converting(let fraction, let text):
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.caption).foregroundStyle(.secondary)
                ProgressView(value: fraction).tint(Theme.accent)
            }
        case .verifying:
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(Theme.bad)
        case nil:
            EmptyView()
        }
    }
}
