import SwiftUI
import UniformTypeIdentifiers
import EmberweftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedEntry: LibraryEntry?
    @State private var openImporter = false
    @State private var filter = LibraryFilter()
    @State private var displayMode: DisplayMode = .grid

    enum DisplayMode { case grid, list }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    filterBar
                    favoritesSection
                    bundleSection
                    directorySection
                }
                .padding(20)
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
                            ThumbnailCell(entry: entry).onTapGesture { selectedEntry = entry }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            listRow(entry); Divider()
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
        .contentShape(Rectangle())
        .onTapGesture { selectedEntry = entry }
        .accessibilityLabel("Genome \(entry.displayName)")
    }

    private let grid: [GridItem] = [GridItem(.adaptive(minimum: 180), spacing: 16)]

    private var thumbProgress: Double? {
        guard model.thumbTotal > 0 else { return nil }
        return Double(model.renderedThumbIDs.count) / Double(model.thumbTotal)
    }
}
