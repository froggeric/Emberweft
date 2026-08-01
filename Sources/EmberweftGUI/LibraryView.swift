import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EmberweftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedEntry: LibraryEntry?
    @State private var openImporter = false
    @State private var filter = LibraryFilter()
    @State private var importToast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    filterBar
                    likedSection
                    bundleSection
                    importedSection
                    directorySection
                }
                .padding(20)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers); return true
            }
            .overlay(alignment: .bottom) {
                if !model.selection.isEmpty {
                    SelectionBar()
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let toast = importToast {
                    Text(toast)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 20).transition(.opacity)
                }
            }
            .animation(.snappy, value: model.selection.isEmpty)
            .navigationTitle("Emberweft Library")
            .toolbar { toolbarContent }
            // Keyboard: ⌘A selects all (filtered); Esc clears the selection.
            .background {
                Group {
                    Button("Select All") { model.selectAll(allFiltered) }
                        .keyboardShortcut("a", modifiers: .command)
                    Button("Clear Selection") { model.clearSelection() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
                .hidden()
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
            .onChange(of: importToast) {
                let snap = importToast
                Task { try? await Task.sleep(for: .seconds(3)); if importToast == snap { importToast = nil } }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
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

    // MARK: - Filter bar

    @ViewBuilder
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name", text: $filter.searchText)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            HStack(spacing: 12) {
                Picker("Sentiment", selection: Binding(
                    get: { filter.sentiment ?? 999 },
                    set: { filter.sentiment = $0 == 999 ? nil : $0 })) {
                    Text("Any").tag(999)
                    Text("👍 Liked").tag(1)
                    Text("● Neutral").tag(0)
                    Text("👎 Disliked").tag(-1)
                }
                .labelsHidden().frame(width: 110).accessibilityLabel("Sentiment")

                if !categories.isEmpty {
                    Picker("Category", selection: Binding(
                        get: { filter.category ?? "any" },
                        set: { filter.category = $0 == "any" ? nil : $0 })) {
                        Text("Any").tag("any")
                        ForEach(categories, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden().frame(width: 110).accessibilityLabel("Category")
                }

                Picker("Palette", selection: Binding(
                    get: { filter.hueBucket ?? -1 },
                    set: { filter.hueBucket = $0 == -1 ? nil : $0 })) {
                    Text("Any").tag(-1)
                    ForEach(0..<12, id: \.self) { Text(paletteLabel($0)).tag($0) }
                }
                .labelsHidden().frame(width: 92).accessibilityLabel("Palette")

                Spacer()
                if !filter.isEmpty {
                    Button("Clear") { filter = LibraryFilter() }.buttonStyle(.borderless)
                }
            }
        }
    }

    private var categories: [String] {
        var s = Set<String>()
        for state in [model.bundleLoadState, model.dirLoadState, model.importedLoadState] {
            if case .ready(let entries) = state {
                for e in entries { if let c = e.rank?.category { s.insert(c) } }
            }
        }
        for f in model.facets.facets.values { s.insert(f.category) }
        return s.sorted()
    }

    private func paletteLabel(_ b: Int) -> String {
        let names = ["Red", "Orange", "Yellow", "Lime", "Green", "Teal",
                     "Cyan", "Azure", "Blue", "Violet", "Magenta", "Rose"]
        return names.indices.contains(b) ? names[b] : "Hue \(b)"
    }

    // MARK: - Sections

    @ViewBuilder
    private var bundleSection: some View { section("Curated", model.bundleLoadState) }

    @ViewBuilder
    private var likedSection: some View {
        let liked = model.likedEntries()
        if !liked.isEmpty { section("Liked", .ready(liked)) }
    }

    @ViewBuilder
    private var importedSection: some View {
        if case .ready(let entries) = model.importedLoadState, !entries.isEmpty {
            section("Imported", model.importedLoadState)
        }
    }

    @ViewBuilder
    private var directorySection: some View {
        if let dir = model.prefs.defaultLibraryDir {
            section("Directory — \(dir.lastPathComponent)", model.dirLoadState)
        } else if case .loading = model.dirLoadState {
            ProgressView().frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ state: LoadState) -> some View {
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
                } else {
                    LazyVGrid(columns: grid, spacing: 16) {
                        ForEach(filtered) { entry in cell(entry, in: filtered) }
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

    // MARK: - Cell (display + selection interaction)

    @ViewBuilder
    private func cell(_ entry: LibraryEntry, in filtered: [LibraryEntry]) -> some View {
        ThumbnailCell(entry: entry, selected: model.isSelected(entry))
            .contentShape(Rectangle())
            .onTapGesture {                                            // plain click → preview
                let mods = NSEvent.modifierFlags
                if mods.contains(.command) || mods.contains(.control) {
                    model.toggleInSelection(entry)                     // ⌘/ctrl → toggle select
                } else if mods.contains(.shift) {
                    model.selectRange(entry, in: filtered)             // shift → range select
                } else {
                    selectedEntry = entry                              // plain → open preview
                }
            }
            .contextMenu {
                Button("Play") { selectedEntry = entry }
                Divider()
                Button("👍 Like") { model.metadataStore.setSentiment(1, for: entry) }
                Button("● Neutral") { model.metadataStore.setSentiment(0, for: entry) }
                Button("👎 Dislike") { model.metadataStore.setSentiment(-1, for: entry) }
            }
            .accessibilityLabel(cellAccessibilityLabel(entry))
    }

    private func cellAccessibilityLabel(_ entry: LibraryEntry) -> String {
        let m = model.metadataStore.metadata(for: entry)
        let cat = (entry.rank?.category ?? model.facets.facet(for: entry)?.category)?.capitalized ?? "uncategorized"
        let sent = m.sentiment == 1 ? "liked" : (m.sentiment == -1 ? "disliked" : "neutral")
        return "Genome \(entry.displayName), \(cat), \(sent)"
    }

    // MARK: - Drag-and-drop import

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for p in providers { if let u = await Self.loadDroppedURL(p) { urls.append(u) } }
            guard !urls.isEmpty else { return }
            let r = await model.importFiles(urls)
            if r.imported == 0 { importToast = "Nothing imported (skipped \(r.skipped))" }
            else if r.skipped > 0 { importToast = "Imported \(r.imported), skipped \(r.skipped)" }
            else { importToast = "Imported \(r.imported)" }
        }
    }

    private static func loadDroppedURL(_ p: NSItemProvider) async -> URL? {
        guard p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { cont in
            p.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }

    // MARK: - Helpers

    /// All entries currently displayed (post-filter) across every section — the
    /// target of Select All.
    private var allFiltered: [LibraryEntry] {
        var out: [LibraryEntry] = []
        for state in [model.bundleLoadState, model.importedLoadState, model.dirLoadState] {
            guard case .ready(let entries) = state else { continue }
            out += applyFilter(filter, to: entries,
                               metadata: { model.metadataStore.metadata(for: $0) },
                               facet: { model.facets.facet(for: $0) })
        }
        return out
    }

    private let grid: [GridItem] = [GridItem(.adaptive(minimum: 180), spacing: 16)]

    private var thumbProgress: Double? {
        guard model.thumbTotal > 0 else { return nil }
        return Double(model.renderedThumbIDs.count) / Double(model.thumbTotal)
    }
}
