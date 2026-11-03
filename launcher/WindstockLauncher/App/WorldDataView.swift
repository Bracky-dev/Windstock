import SwiftUI
import UniformTypeIdentifiers

/// Settings › World Data: pick a country, download its real PokeStops and gyms.
///
/// Two sources. Packs built on a Mac with tools/build_world_packs.py and
/// hosted anywhere static (the catalog), or a raw OpenStreetMap extract
/// (.osm.pbf) that the phone converts itself -- see OSMImport.swift.
struct WorldDataView: View {
    @EnvironmentObject private var model: LauncherModel
    @ObservedObject private var store = WorldPackStore.shared
    @State private var confirmRemove: InstalledPack?
    @State private var pickingFile = false

    var body: some View {
        List {
            catalogSection

            if !store.importNames.isEmpty {
                Section("Importing") {
                    ForEach(store.importNames.sorted { $0.value < $1.value }, id: \.key) {
                        importRow(id: $0.key, name: $0.value)
                    }
                }
            }

            if let suggested = store.suggested {
                Section("Your country") { row(suggested) }
            }

            if !store.catalog.isEmpty {
                Section {
                    ForEach(store.catalog.filter { $0.id != store.suggested?.id }) { row($0) }
                } header: {
                    Text("All countries")
                } footer: {
                    Text("A new country is live on the next map refresh — no restart. "
                         + "Keep several if you travel; overlapping stops are only "
                         + "shown once.")
                }
            }

            if !store.orphans.isEmpty {
                Section {
                    ForEach(store.orphans) { installedRow($0) }
                } header: {
                    Text(store.catalog.isEmpty ? "Installed" : "Installed, not in the catalog")
                }
            }

            if !store.bundledPacks.isEmpty {
                Section {
                    ForEach(store.bundledPacks) { installedRow($0) }
                } header: {
                    Text("Built into this app")
                } footer: {
                    Text("Shipped inside the launcher. It is used alongside anything "
                         + "you download, and can only be removed by building the app "
                         + "without --with-world.")
                }
            }

            Section {
                NavigationLink("Add from OpenStreetMap") { OSMLinksView() }
                Button("Import an .osm.pbf file…") { pickingFile = true }
            } header: {
                Text("OpenStreetMap")
            } footer: {
                Text("Pick a country or US state and the phone downloads its "
                     + "OpenStreetMap extract and turns it into stops and gyms. "
                     + "Or import an .osm.pbf you already saved to Files.")
            }
        }
        .navigationTitle("World Data")
        .task {
            store.rescan()
            await loadCatalog()
        }
        .refreshable {
            await loadCatalog()
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { store.importOSMFile(url) }
        }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?",
                            isPresented: Binding(get: { confirmRemove != nil },
                                                 set: { if !$0 { confirmRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let pack = confirmRemove { store.remove(id: pack.id) }
                confirmRemove = nil
            }
        } message: {
            Text("Its stops and gyms disappear from the map. You can download it again.")
        }
    }

    // MARK: - sections

    private var catalogSection: some View {
        Section {
            TextField("https://…/catalog.json", text: $model.prefs.worldCatalogURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit { Task { await loadCatalog() } }
            Button {
                Task { await loadCatalog() }
            } label: {
                HStack {
                    Text("Load countries")
                    if store.loadingCatalog {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.prefs.worldCatalogURL.trimmingCharacters(in: .whitespaces).isEmpty
                      || store.loadingCatalog)
            if let error = store.catalogError {
                Text(error).font(.footnote).foregroundStyle(Theme.bad)
            }
        } header: {
            Text("Catalog")
        } footer: {
            Text("The address of the catalog.json published with the world packs "
                 + "(tools/build_world_packs.py). An .osm.pbf link works here too: "
                 + "it is downloaded and converted on the phone.")
        }
    }

    /// The Catalog box also takes a raw .osm.pbf link: that one is imported,
    /// not read as a catalog (and not kept in the box).
    private func loadCatalog() async {
        let text = model.prefs.worldCatalogURL
        if WorldPackStore.isOSMExtract(text),
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            let (name, region) = WorldPackStore.osmNameAndRegion(for: url)
            store.importOSM(from: url, name: name, region: region)
            model.prefs.worldCatalogURL = ""
            return
        }
        await store.loadCatalog(from: text)
    }

    // MARK: - rows

    private func row(_ pack: WorldPack) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.name).font(.body)
                Text("\(pack.forts.formatted()) stops & gyms · "
                     + ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                if case .failed(let message) = store.phases[pack.id] {
                    Text(message).font(.caption).foregroundStyle(Theme.bad)
                }
                if case .downloading(let fraction) = store.phases[pack.id] {
                    ProgressView(value: fraction).tint(Theme.accent)
                }
            }
            Spacer(minLength: 8)
            action(for: pack)
        }
    }

    @ViewBuilder
    private func action(for pack: WorldPack) -> some View {
        switch store.phases[pack.id] {
        case .downloading:
            Button("Cancel") { store.cancel(pack) }
                .buttonStyle(.borderless)
        case .verifying:
            ProgressView()
        default:
            switch store.status(of: pack) {
            case .notInstalled:
                Button("Download") { store.download(pack) }
                    .buttonStyle(.bordered)
            case .updateAvailable:
                Button("Update") { store.download(pack) }
                    .buttonStyle(.borderedProminent)
            case .upToDate:
                Menu {
                    Button("Remove", role: .destructive) {
                        confirmRemove = store.installed[pack.id]
                    }
                } label: {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func importRow(id: String, name: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                OSMPhaseView(phase: store.phases[id])
            }
            Spacer(minLength: 8)
            if case .failed = store.phases[id] {
                Button("Dismiss") { store.clearImport(id: id) }
                    .buttonStyle(.borderless)
            } else {
                Button("Cancel") { store.cancel(id: id) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func installedRow(_ pack: InstalledPack) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.name)
                Text(ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !pack.bundled {
                Button("Remove", role: .destructive) { confirmRemove = pack }
                    .buttonStyle(.borderless)
            }
        }
    }
}
