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
    @State private var showFilterPopover = false
    @State private var showKeyboardHelp = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    activeFilterChips
                    likedSection
                    bundleSection
                    importedSection
                    directorySection
                }
                .padding(20)
            }
            .searchable(text: $filter.searchText, prompt: "Search genomes")
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
            .animation(.snappy, value: filter)
            .navigationTitle("Emberweft Library")
            .toolbar { toolbarContent }
            // Keyboard: ⌘A selects all (filtered); Esc clears the selection;
            // ⌘? opens the keyboard cheat-sheet.
            .background {
                Group {
                    Button("Select All") { model.selectAll(allFiltered) }
                        .keyboardShortcut("a", modifiers: .command)
                    Button("Clear Selection") { model.clearSelection() }
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("Keyboard Shortcuts") { showKeyboardHelp = true }
                        .keyboardShortcut("?", modifiers: .command)
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
        ToolbarItemGroup(placement: .primaryAction) {
            filterButton
            Button("Open Directory…") { openImporter = true }
            keyboardHelpButton
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

    private var filterButton: some View {
        Button {
            showFilterPopover.toggle()
        } label: {
            filterButtonLabel
        }
        .popover(isPresented: $showFilterPopover) {
            filterPopover
        }
        .accessibilityLabel("Filter")
    }

    private var keyboardHelpButton: some View {
        Button {
            showKeyboardHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .popover(isPresented: $showKeyboardHelp) {
            KeyboardHelpView()
        }
        .accessibilityLabel("Keyboard shortcuts")
    }

    @ViewBuilder
    private var filterButtonLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "line.3.horizontal.decrease")
            if activeFilterCount > 0 {
                Text("\(activeFilterCount)")
                    .font(.caption2).bold().monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
            }
        }
    }

    // MARK: - Filter popover (A3)

    @ViewBuilder
    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter").font(.headline)
            Picker("Sentiment", selection: Binding(
                get: { filter.sentiment ?? 999 },
                set: { filter.sentiment = $0 == 999 ? nil : $0 })) {
                Text("Any").tag(999)
                Text("👍 Liked").tag(1)
                Text("● Neutral").tag(0)
                Text("👎 Disliked").tag(-1)
            }
            .pickerStyle(.menu)

            if !categories.isEmpty {
                Picker("Category", selection: Binding(
                    get: { filter.category ?? "any" },
                    set: { filter.category = $0 == "any" ? nil : $0 })) {
                    Text("Any").tag("any")
                    ForEach(categories, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.menu)
            }

            Picker("Palette", selection: Binding(
                get: { filter.hueBucket ?? -1 },
                set: { filter.hueBucket = $0 == -1 ? nil : $0 })) {
                Text("Any").tag(-1)
                ForEach(0..<12, id: \.self) { Text(paletteLabel($0)).tag($0) }
            }
            .pickerStyle(.menu)

            if !filter.isEmpty {
                HStack {
                    Spacer()
                    Button("Clear all") { filter = LibraryFilter() }
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 240)
    }

    // MARK: - Active-filter chips (A3)

    /// The active facets in a fixed, deterministic order (search, sentiment,
    /// category, palette). Iterates `CaseIterable.allCases` (a stable array),
    /// never a `Set`/`Dictionary` — rule #2 safe.
    private var activeFacets: [FilterFacet] {
        FilterFacet.allCases.filter {
            switch $0 {
            case .searchText: return !filter.searchText.isEmpty
            case .sentiment:  return filter.sentiment != nil
            case .category:   return filter.category != nil
            case .hueBucket:  return filter.hueBucket != nil
            }
        }
    }

    private var activeFilterCount: Int { activeFacets.count }

    @ViewBuilder
    private var activeFilterChips: some View {
        let facets = activeFacets
        if !facets.isEmpty {
            HStack(spacing: 6) {
                ForEach(facets) { facet in
                    chipButton(for: facet)
                        .transition(.scale.combined(with: .opacity))
                }
                Spacer(minLength: 8)
                Button("Clear all") { filter = LibraryFilter() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .animation(.snappy, value: facets)
        }
    }

    @ViewBuilder
    private func chipButton(for facet: FilterFacet) -> some View {
        let info = chipLabel(for: facet)
        Button {
            clearFacet(facet)
        } label: {
            HStack(spacing: 4) {
                if let img = info.icon { Image(systemName: img).imageScale(.small) }
                Text(info.text).lineLimit(1)
                Image(systemName: "xmark").imageScale(.small).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(info.text), remove filter")
    }

    private func chipLabel(for facet: FilterFacet) -> ChipInfo {
        switch facet {
        case .searchText:
            return ChipInfo(text: "“\(filter.searchText)”", icon: "magnifyingglass")
        case .sentiment:
            switch filter.sentiment {
            case 1:   return ChipInfo(text: "Liked", icon: "hand.thumbsup")
            case 0:   return ChipInfo(text: "Neutral", icon: "circle")
            case -1:  return ChipInfo(text: "Disliked", icon: "hand.thumbsdown")
            default:  return ChipInfo(text: "Sentiment", icon: nil)
            }
        case .category:
            return ChipInfo(text: filter.category?.capitalized ?? "Category", icon: "tag")
        case .hueBucket:
            return ChipInfo(text: paletteLabel(filter.hueBucket ?? -1), icon: "paintpalette")
        }
    }

    private func clearFacet(_ facet: FilterFacet) {
        switch facet {
        case .searchText: filter.searchText = ""
        case .sentiment:  filter.sentiment = nil
        case .category:   filter.category = nil
        case .hueBucket:  filter.hueBucket = nil
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
        if !liked.isEmpty {
            section("Liked", .ready(liked))
        } else if anySourceHasGenomes {
            VStack(alignment: .leading, spacing: 12) {
                Text("Liked").font(.headline)
                ContentUnavailableView(
                    "Nothing liked yet",
                    systemImage: "hand.thumbsup",
                    description: Text("Mark flames with 👍 to build your favorites.")
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
            skeletonSection("Directory")
        } else {
            ContentUnavailableView {
                Label("Open a directory", systemImage: "sparkles")
            } description: {
                Text("Choose a folder of .flam3 files, or drag some in.")
            } actions: {
                Button("Open Directory…") { openImporter = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ state: LoadState) -> some View {
        switch state {
        case .loading:
            skeletonSection(title)
        case .empty:
            ContentUnavailableView(
                "No genomes in \(title)",
                systemImage: "tray",
                description: Text("This section is empty.")
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't load \(title)",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// A titled grid of skeleton placeholder cards shown while a section loads
    /// (A4 — perceived-faster, calmer than a spinner).
    @ViewBuilder
    private func skeletonSection(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            LazyVGrid(columns: grid, spacing: 16) {
                ForEach(0..<6, id: \.self) { _ in skeletonCell() }
            }
        }
    }

    private func skeletonCell() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .redacted(reason: .placeholder)
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(height: 10)
                .redacted(reason: .placeholder)
        }
    }

    @ViewBuilder
    private func filteredEmptyState(hadEntries: Bool) -> some View {
        if !hadEntries {
            ContentUnavailableView(
                "No genomes here",
                systemImage: "tray",
                description: Text("This section has no genomes to show.")
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if filter.requireFacet && model.facets.facets.isEmpty {
            ContentUnavailableView(
                "No palette data yet",
                systemImage: "paintpalette",
                description: Text("Render thumbnails or open the curated set to filter by palette.")
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView {
                Label("No genomes match", systemImage: "line.3.horizontal.decrease")
            } description: {
                Text("Adjust your search or filters to see more.")
            } actions: {
                Button("Clear filters") { filter = LibraryFilter() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// True when any source has at least one ready entry — gates the "Liked"
    /// teaching card so it only appears once the library is populated.
    /// Iterates a fixed array (rule #2 safe).
    private var anySourceHasGenomes: Bool {
        for state in [model.bundleLoadState, model.importedLoadState, model.dirLoadState] {
            if case .ready(let entries) = state, !entries.isEmpty { return true }
        }
        return false
    }

    private let grid: [GridItem] = [GridItem(.adaptive(minimum: 180), spacing: 16)]

    private var thumbProgress: Double? {
        guard model.thumbTotal > 0 else { return nil }
        return Double(model.renderedThumbIDs.count) / Double(model.thumbTotal)
    }
}

// MARK: - Filter chip support (private to file)

/// The four facets of `LibraryFilter` that can appear as an active chip.
/// `CaseIterable` gives a stable, deterministic chip order (rule #2).
private enum FilterFacet: String, CaseIterable, Identifiable {
    case searchText, sentiment, category, hueBucket
    var id: String { rawValue }
}

private struct ChipInfo {
    let text: String
    let icon: String?
}
