import SwiftUI
import UniformTypeIdentifiers
import EmberweftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedEntry: LibraryEntry?
    @State private var editingEntry: LibraryEntry?
    @State private var openImporter = false
    @State private var filter = LibraryFilter()
    @State private var displayMode: DisplayMode = .grid
    @State private var importToast: String?

    enum DisplayMode { case grid, list }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    filterBar
                    favoritesSection
                    bundleSection
                    importedSection
                    directorySection
                }
                .padding(20)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
            .overlay(alignment: .bottom) {
                if let toast = importToast {
                    Text(toast)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
            .navigationTitle("Emberweft Library")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("View", selection: $displayMode) {
                        Image(systemName: "square.grid.2x2").tag(DisplayMode.grid)
                        Image(systemName: "list.bullet").tag(DisplayMode.list)
                    }
                    .pickerStyle(.segmented)
                    .help("Grid or list view")
                    Button("Open Directory…") { openImporter = true }
                }
                if let progress = thumbProgress, progress < 1.0 {
                    ToolbarItem(placement: .navigation) {
                        HStack(spacing: 6) {
                            ProgressView(value: progress).frame(width: 120)
                            Text("\(model.renderedThumbIDs.count)/\(model.thumbTotal)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            .fileImporter(isPresented: $openImporter, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): Task { await model.openDirectory(url) }
                case .failure: break
                }
            }
            .sheet(item: $selectedEntry) { entry in
                PlaybackWindow(entry: entry).environment(model)
            }
            .sheet(item: $editingEntry) { entry in
                MetadataEditorView(entry: entry, model: model)
            }
            .onChange(of: importToast) {
                let snapshot = importToast
                Task { try? await Task.sleep(for: .seconds(3)); if importToast == snapshot { importToast = nil } }
            }
        }
    }

    // MARK: - Filter bar

    @ViewBuilder
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name", text: $filter.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
            HStack(spacing: 12) {
                Button { filter.favoritesOnly.toggle() } label: {
                    Label("Favorites", systemImage: filter.favoritesOnly ? "heart.fill" : "heart")
                        .foregroundStyle(filter.favoritesOnly ? .pink : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Favorites only")

                Picker("Rating", selection: $filter.minRating) {
                    Text("Any").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0)★+").tag($0) }
                }
                .labelsHidden()
                .frame(width: 72)
                .accessibilityLabel("Minimum rating")

                if !categories.isEmpty {
                    Picker("Category", selection: Binding(
                        get: { filter.category ?? "any" },
                        set: { filter.category = $0 == "any" ? nil : $0 })) {
                        Text("Any").tag("any")
                        ForEach(categories, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .accessibilityLabel("Category")
                }

                Picker("Palette", selection: Binding(
                    get: { filter.hueBucket ?? -1 },
                    set: { filter.hueBucket = $0 == -1 ? nil : $0 })) {
                    Text("Any").tag(-1)
                    ForEach(0..<12, id: \.self) { Text(paletteLabel($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 92)
                .accessibilityLabel("Palette")

                tagMenu
                Spacer()
                if !filter.isEmpty {
                    Button("Clear") { filter = LibraryFilter() }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private var tagMenu: some View {
        let tags = model.metadataStore.allTags()
        if !tags.isEmpty {
            Menu {
                ForEach(tags, id: \.self) { tag in
                    Button {
                        if filter.selectedTags.contains(tag) { filter.selectedTags.remove(tag) }
                        else { filter.selectedTags.insert(tag) }
                    } label: {
                        Label(tag, systemImage: filter.selectedTags.contains(tag) ? "checkmark" : "")
                    }
                }
            } label: {
                Label(filter.selectedTags.isEmpty ? "Tags" : "\(filter.selectedTags.count) tags",
                      systemImage: "tag")
            }
            .accessibilityLabel("Tags filter")
        }
    }

    private var categories: [String] {
        guard case .ready(let entries) = model.bundleLoadState else { return [] }
        return Set(entries.compactMap { $0.rank?.category }).sorted()
    }

    private func paletteLabel(_ b: Int) -> String {
        let names = ["Red", "Orange", "Yellow", "Lime", "Green", "Teal",
                     "Cyan", "Azure", "Blue", "Violet", "Magenta", "Rose"]
        return names.indices.contains(b) ? names[b] : "Hue \(b)"
    }

    // MARK: - Sections

    @ViewBuilder
    private var bundleSection: some View { section(title: "Curated", state: model.bundleLoadState) }

    @ViewBuilder
    private var favoritesSection: some View {
        let favs = model.favoriteEntries()
        if !favs.isEmpty { section(title: "Favorites", state: .ready(favs)) }
    }

    @ViewBuilder
    private var directorySection: some View {
        if let dir = model.prefs.defaultLibraryDir {
            section(title: "Directory — \(dir.lastPathComponent)", state: model.dirLoadState)
        } else {
            switch model.dirLoadState {
            case .ready, .empty, .failed: EmptyView()
            case .loading: ProgressView().frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private var importedSection: some View {
        if case .ready(let entries) = model.importedLoadState, !entries.isEmpty {
            section(title: "Imported", state: model.importedLoadState)
        }
    }

    // MARK: - Drag-and-drop import

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let u = await Self.loadDroppedURL(p) { urls.append(u) }
            }
            guard !urls.isEmpty else { return }
            let r = await model.importFiles(urls)
            if r.imported == 0 {
                importToast = "Nothing imported (skipped \(r.skipped))"
            } else if r.skipped > 0 {
                importToast = "Imported \(r.imported), skipped \(r.skipped)"
            } else {
                importToast = "Imported \(r.imported)"
            }
        }
    }

    private static func loadDroppedURL(_ p: NSItemProvider) async -> URL? {
        guard p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { cont in
            p.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }

    @ViewBuilder
    private func section(title: String, state: LoadState) -> some View {
        switch state {
        case .loading:
            ProgressView("Loading \(title)…").frame(maxWidth: .infinity, alignment: .leading)
        case .empty:
            Text("No genomes in \(title).").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .ready(let entries):
            let filtered = applyFilter(filter, to: entries,
                                       metadata: { model.metadataStore.metadata(for: $0) },
                                       facet: { model.facets.facet(for: $0) })
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if !filter.isEmpty && filtered.count != entries.count {
                        Text("\(filtered.count)/\(entries.count)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if filtered.isEmpty {
                    filteredEmptyState(hadEntries: !entries.isEmpty)
                } else if displayMode == .grid {
                    LazyVGrid(columns: grid, spacing: 16) {
                        ForEach(filtered) { entry in
                            cell(entry, in: .grid)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            cell(entry, in: .list); Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func filteredEmptyState(hadEntries: Bool) -> some View {
        if !hadEntries {
            Text("No genomes here.").foregroundStyle(.secondary)
        } else if filter.requireFacet && model.facets.facets.isEmpty {
            Text("Render thumbnails or open the curated set to filter by palette.")
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Text("No genomes match.").foregroundStyle(.secondary)
                Button("Clear filters") { filter = LibraryFilter() }.buttonStyle(.borderless)
            }
        }
    }

    private func cellAccessibilityLabel(_ entry: LibraryEntry) -> String {
        let m = model.metadataStore.metadata(for: entry)
        let cat = entry.rank?.category.capitalized ?? "uncategorized"
        let fav = m.favorite ? "favorite" : "not favorite"
        return "Genome \(entry.displayName), \(cat), \(m.rating) of 5 stars, \(fav)"
    }

    @ViewBuilder
    private func cell(_ entry: LibraryEntry, in mode: DisplayMode) -> some View {
        Group {
            switch mode {
            case .grid: ThumbnailCell(entry: entry)
            case .list: listRow(entry)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedEntry = entry }
        .contextMenu {
            Button("Play") { selectedEntry = entry }
            Button("Edit metadata…") { editingEntry = entry }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cellAccessibilityLabel(entry))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens playback")
    }

    @ViewBuilder
    private func listRow(_ entry: LibraryEntry) -> some View {
        let m = model.metadataStore.metadata(for: entry)
        HStack(spacing: 10) {
            Image(systemName: m.favorite ? "heart.fill" : "heart")
                .foregroundStyle(m.favorite ? .pink : .secondary).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.body)
                HStack(spacing: 6) {
                    if let cat = entry.rank?.category {
                        Text(cat.capitalized).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(m.tags, id: \.self) { tag in
                        Text(tag).font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            Spacer()
            if m.rating > 0 {
                Text(String(repeating: "★", count: m.rating))
                    .foregroundStyle(.yellow).font(.caption)
            }
        }
        .padding(.vertical, 4)
        .accessibilityLabel("Genome \(entry.displayName)")
    }

    private let grid: [GridItem] = [GridItem(.adaptive(minimum: 180), spacing: 16)]

    private var thumbProgress: Double? {
        guard model.thumbTotal > 0 else { return nil }
        return Double(model.renderedThumbIDs.count) / Double(model.thumbTotal)
    }
}
