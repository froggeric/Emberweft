import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EmberweftUI

/// Three-column studio shell (B7/B8): a `NavigationSplitView` sidebar of
/// destinations (All / Library / Liked / Imported / Directory) drives a single
/// detail grid (one section at a time — calmer than stacked sections), with a
/// collapsible right `.inspector` (B8) for the selected genome's metadata.
///
/// Reuses unchanged: the filter popover + active-filter chips + `.searchable`
/// (A3), `ContentUnavailableView`/skeleton states (A4), `SelectionBar` +
/// selection model, the drop handler, and the `?`/`⌘?` keyboard help.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedEntry: LibraryEntry?
    @State private var openImporter = false
    @State private var filter = LibraryFilter()
    @State private var importToast: String?
    @State private var showFilterPopover = false
    @State private var showKeyboardHelp = false

    /// Sidebar destination (B7). `List(selection:)` drives which entries the
    /// detail grid shows. Defaults to `.all` (the unified grid landing).
    @State private var destination: SidebarDestination = .all
    /// Inspector visibility (B8). Toggled with ⌘\.
    @State private var inspectorShown = true
    /// Last genome opened (clicked) in the grid — the inspector's fallback
    /// subject when nothing is selected.
    @State private var lastOpened: LibraryEntry?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailGrid
        }
        .inspector(isPresented: $inspectorShown) {
            // Shows the first selected genome (deterministic by id), else the
            // last-opened one; falls back to a placeholder (B8).
            InspectorPane(subject: inspectorSubject)
                .environment(model)
        }
        // Persist prefs (density etc.) on any change — spec §5.7 ("no extra
        // plumbing": the onChange save is the persistence hook).
        .onChange(of: model.prefs) { _, _ in
            try? model.prefs.save()
        }
    }

    // MARK: - Sidebar (B7)

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $destination) {
            Section("Library") {
                ForEach(visibleDestinations) { d in
                    Label {
                        Text(sidebarTitle(for: d))
                    } icon: {
                        Image(systemName: d.icon)
                    }
                    .badge(badgeCount(for: d))
                    .tag(d)
                    .accessibilityLabel("\(d.title) genomes")
                }
            }
            Section {
                Button {
                    openImporter = true
                } label: {
                    Label("Open Directory…", systemImage: "plus")
                }
                .buttonStyle(.plain)
            } footer: {
                densityControl
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
    }

    /// Destinations always shown, plus `.directory` only when a dir is set.
    private var visibleDestinations: [SidebarDestination] {
        SidebarDestination.allCases.filter {
            $0 != .directory || model.prefs.defaultLibraryDir != nil
        }
    }

    private func sidebarTitle(for d: SidebarDestination) -> String {
        switch d {
        case .directory:
            return model.prefs.defaultLibraryDir?.lastPathComponent ?? "Directory"
        default:
            return d.title
        }
    }

    /// Live count badge per destination (P6 — visible payoff of sentiment etc.).
    /// Integer counts only (rule #2 safe).
    private func badgeCount(for d: SidebarDestination) -> Int {
        switch d {
        case .all:
            return readyCount(model.bundleLoadState)
                + readyCount(model.dirLoadState)
                + readyCount(model.importedLoadState)
        case .library:   return readyCount(model.bundleLoadState)
        case .liked:     return model.likedEntries().count
        case .imported:  return readyCount(model.importedLoadState)
        case .directory: return readyCount(model.dirLoadState)
        }
    }

    private func readyCount(_ s: LoadState) -> Int {
        if case .ready(let entries) = s { return entries.count }
        return 0
    }

    // MARK: - Density control (B11)

    private var densityControl: some View {
        // `@Bindable` projects `$model.prefs.density` for an `@Observable`
        // environment object (the `@Environment` property has no `$` itself).
        @Bindable var model = model
        return HStack {
            Text("Density").font(.caption).foregroundStyle(.secondary)
            Picker("Density", selection: $model.prefs.density) {
                ForEach(AppPreferences.Density.allCases, id: \.self) { d in
                    Text(d.glyph).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            .help("Grid thumbnail size")
        }
    }

    // MARK: - Detail grid (one section at a time)

    @ViewBuilder
    private var detailGrid: some View {
        let state = currentLoadState
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                activeFilterChips
                gridBody(for: state)
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
        .animation(.snappy, value: destination)
        .navigationTitle(destination.title)
        .navigationSubtitle(countSubtitle(for: state))
        .toolbar { toolbarContent }
        // Keyboard: ⌘A selects all (filtered); Esc clears the selection;
        // ⌘? opens the keyboard cheat-sheet; ⌘\ toggles the inspector;
        // ⌘1…⌘5 jump to sidebar destinations.
        .background { keyboardShortcuts }
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

    /// The `LoadState` for the selected destination.
    private var currentLoadState: LoadState {
        switch destination {
        case .all:
            let unified = model.unifiedEntries()
            return unified.isEmpty ? .empty : .ready(unified)
        case .library:
            return model.bundleLoadState
        case .liked:
            let liked = model.likedEntries()
            return liked.isEmpty ? .empty : .ready(liked)
        case .imported:
            return model.importedLoadState
        case .directory:
            guard model.prefs.defaultLibraryDir != nil else { return .empty }
            return model.dirLoadState
        }
    }

    @ViewBuilder
    private func gridBody(for state: LoadState) -> some View {
        switch state {
        case .loading:
            skeletonGrid()
        case .empty:
            emptyStateView
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't load \(destination.title)",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .ready(let entries):
            let filtered = applyFilter(filter, to: entries,
                                       metadata: { model.metadataStore.metadata(for: $0) },
                                       facet: { model.facets.facet(for: $0) })
            if filtered.isEmpty {
                filteredEmptyState(hadEntries: !entries.isEmpty)
            } else {
                LazyVGrid(columns: grid, spacing: 16) {
                    ForEach(filtered) { entry in cell(entry, in: filtered) }
                }
            }
        }
    }

    /// Empty state is destination-aware (Liked teaches sentiment; All/Directory
    /// offer the open-directory CTA).
    @ViewBuilder
    private var emptyStateView: some View {
        switch destination {
        case .liked:
            ContentUnavailableView(
                "Nothing liked yet",
                systemImage: "hand.thumbsup",
                description: Text("Mark flames with 👍 to build your favorites.")
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .all:
            ContentUnavailableView {
                Label("No genomes yet", systemImage: "sparkles")
            } description: {
                Text("Open a directory of .flam3 files, or drag some in.")
            } actions: {
                Button("Open Directory…") { openImporter = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .directory where model.prefs.defaultLibraryDir == nil:
            ContentUnavailableView {
                Label("Open a directory", systemImage: "sparkles")
            } description: {
                Text("Choose a folder of .flam3 files, or drag some in.")
            } actions: {
                Button("Open Directory…") { openImporter = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            ContentUnavailableView(
                "No genomes in \(destination.title)",
                systemImage: "tray",
                description: Text("This section is empty.")
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A skeleton placeholder grid shown while a section loads (A4 —
    /// perceived-faster, calmer than a spinner).
    @ViewBuilder
    private func skeletonGrid() -> some View {
        LazyVGrid(columns: grid, spacing: 16) {
            ForEach(0..<6, id: \.self) { _ in skeletonCell() }
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

    /// Subtle live count caption in the title bar: "N" or "filtered/total".
    private func countSubtitle(for state: LoadState) -> String {
        guard case .ready(let entries) = state else { return "" }
        if filter.isEmpty { return "\(entries.count) items" }
        let filtered = applyFilter(filter, to: entries,
                                   metadata: { model.metadataStore.metadata(for: $0) },
                                   facet: { model.facets.facet(for: $0) })
        return "\(filtered.count)/\(entries.count) items"
    }

    // MARK: - Keyboard shortcuts (hidden buttons)

    @ViewBuilder
    private var keyboardShortcuts: some View {
        Group {
            Button("Select All") { model.selectAll(allFiltered) }
                .keyboardShortcut("a", modifiers: .command)
            Button("Clear Selection") { model.clearSelection() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Keyboard Shortcuts") { showKeyboardHelp = true }
                .keyboardShortcut("?", modifiers: .command)
            Button("Toggle Inspector") { inspectorShown.toggle() }
                .keyboardShortcut("\\", modifiers: .command)
            Button("Go to All") { destination = .all }
                .keyboardShortcut("1", modifiers: .command)
            Button("Go to Library") { destination = .library }
                .keyboardShortcut("2", modifiers: .command)
            Button("Go to Liked") { destination = .liked }
                .keyboardShortcut("3", modifiers: .command)
            Button("Go to Imported") { destination = .imported }
                .keyboardShortcut("4", modifiers: .command)
            if model.prefs.defaultLibraryDir != nil {
                Button("Go to Directory") { destination = .directory }
                    .keyboardShortcut("5", modifiers: .command)
            }
        }
        .hidden()
    }

    // MARK: - Inspector subject (B8)

    /// The genome the inspector shows: the first selection (deterministic by id)
    /// if any, else the last-opened genome. Never iterates a hash collection for
    /// an FP sum — `.sorted` is ordering only (rule #2 safe).
    private var inspectorSubject: LibraryEntry? {
        if let first = model.selection.sorted(by: { $0.id < $1.id }).first {
            return first
        }
        return lastOpened
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            filterButton
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
                ForEach(0..<12, id: \.self) { Text(hueBucketName($0)).tag($0) }
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
            return ChipInfo(text: hueBucketName(filter.hueBucket ?? -1), icon: "paintpalette")
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
                    lastOpened = entry                                 // remember for the inspector
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

    /// All entries currently displayed (post-filter) in the ACTIVE destination's
    /// grid — the target of Select All.
    private var allFiltered: [LibraryEntry] {
        let entries: [LibraryEntry]
        if case .ready(let e) = currentLoadState { entries = e } else { entries = [] }
        return applyFilter(filter, to: entries,
                           metadata: { model.metadataStore.metadata(for: $0) },
                           facet: { model.facets.facet(for: $0) })
    }

    private var grid: [GridItem] {
        [GridItem(.adaptive(minimum: model.prefs.density.gridMinimum), spacing: 16)]
    }

    private var thumbProgress: Double? {
        guard model.thumbTotal > 0 else { return nil }
        return Double(model.renderedThumbIDs.count) / Double(model.thumbTotal)
    }
}

// MARK: - Sidebar destination (B7)

/// Sidebar destinations. `.directory` is only surfaced when a default library
/// directory is set; the others are always present.
private enum SidebarDestination: String, Hashable, Identifiable, CaseIterable {
    case all, library, liked, imported, directory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:      return "All"
        case .library:  return "Library"
        case .liked:    return "Liked"
        case .imported: return "Imported"
        case .directory:return "Directory"
        }
    }

    var icon: String {
        switch self {
        case .all:      return "square.grid.2x2"
        case .library:  return "books.vertical"
        case .liked:    return "star"
        case .imported: return "tray.and.arrow.down"
        case .directory:return "folder"
        }
    }
}

// MARK: - Inspector pane (B8)

/// Right inspector for the selected/opened genome: a larger static poster still
/// (rendered at t=0 via `ThumbnailService`), displayName, category, a hue swatch
/// (from `GenomeFacet.hue`), rank/score, sentiment (reuses `SentimentBar`), file
/// path, health (`Flame.isRenderable`), and `importedAt` when set.
struct InspectorPane: View {
    @Environment(AppModel.self) private var model
    let subject: LibraryEntry?

    @State private var poster: NSImage?
    @State private var health: Bool?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let entry = subject {
                content(for: entry)
            } else {
                ContentUnavailableView(
                    "No genome selected",
                    systemImage: "photo",
                    description: Text("Click a flame to inspect it here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func content(for entry: LibraryEntry) -> some View {
        let facet = model.facets.facet(for: entry)
        let metadata = model.metadataStore.metadata(for: entry)
        let category = entry.rank?.category ?? facet?.category

        VStack(alignment: .leading, spacing: 14) {
            posterView

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                    .font(.headline)
                    .lineLimit(2)
                if let rank = entry.rank {
                    Text(String(format: "★ %.2f", rank.score))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            SentimentBar(entry: entry)

            VStack(alignment: .leading, spacing: 8) {
                if let category {
                    infoRow("Category") { Text(category.capitalized) }
                }
                if let facet {
                    infoRow("Palette") {
                        HStack(spacing: 6) {
                            hueSwatch(facet.hue)
                            Text(hueBucketName(facet.hueBucket))
                        }
                    }
                }
                if let health {
                    infoRow("Health") {
                        Text(health ? "Renderable" : "Degenerate")
                            .foregroundStyle(health ? Color.green : Color.red)
                    }
                }
                if let importedAt = metadata.importedAt {
                    infoRow("Imported") {
                        Text(importedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                infoRow("Path") {
                    Text(entry.fileURL.path)
                        .font(.caption.monospaced())
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
            .font(.callout)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: entry.id, priority: .utility) {
            await loadPoster(for: entry)
        }
    }

    @ViewBuilder
    private var posterView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.black)
            if let poster {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if loadFailed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Degenerate / unreadable genome")
            } else {
                ProgressView()
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Render the poster still at t=0 (the raw flame = the as-authored still)
    /// via `ThumbnailService`, at a larger display size than the grid cell.
    private func loadPoster(for entry: LibraryEntry) async {
        poster = nil
        health = nil
        loadFailed = false
        guard let flame = try? await model.libraryIndex.loadGenome(for: entry) else {
            loadFailed = true
            return
        }
        health = flame.isRenderable
        model.facets.putIfAbsent(for: entry, flame: flame)
        let outcome = await model.thumbnailService.thumbnail(
            for: entry, flame: flame,
            renderParams: model.prefs.thumbnailRenderParams(),
            displayWidth: 320, displayHeight: 180,
            backend: model.prefs.thumbnailBackend)
        switch outcome {
        case .image(let rgba):
            poster = rgba.toNSImage()
            model.facets.refine(for: entry, image: rgba)
        case .degenerate, .failed:
            loadFailed = true
        }
    }

    @ViewBuilder
    private func infoRow<C: View>(_ label: String, @ViewBuilder value: () -> C) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A small hue swatch derived from `GenomeFacet.hue` (0…1 → HSV).
    private func hueSwatch(_ hue: Double) -> some View {
        Color(hue: hue, saturation: 0.7, brightness: 0.9)
            .frame(width: 14, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            }
    }
}

// MARK: - Shared helpers (file-private)

/// 12-bucket hue names shared by the filter popover/chips and the inspector.
/// Deterministic (rule #2 — a fixed array, never a hash collection).
fileprivate func hueBucketName(_ bucket: Int) -> String {
    let names = ["Red", "Orange", "Yellow", "Lime", "Green", "Teal",
                 "Cyan", "Azure", "Blue", "Violet", "Magenta", "Rose"]
    return names.indices.contains(bucket) ? names[bucket] : "Hue \(bucket)"
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
