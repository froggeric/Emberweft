import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EmberweftUI

/// Two-column studio shell (B7): a `NavigationSplitView` sidebar of destinations
/// (All / Library / Liked / Imported, plus one row per opened folder) drives a
/// single detail grid (one section at a time — calmer than stacked sections).
///
/// Reuses unchanged: the filter popover + active-filter chips + `.searchable`
/// (A3), `ContentUnavailableView`/skeleton states (A4), `SelectionBar` +
/// selection model, the drop handler, and the `?`/`⌘?` keyboard help.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var openImporter = false
    @State private var filter = LibraryFilter()
    @State private var importToast: String?
    @State private var showFilterPopover = false
    @State private var showKeyboardHelp = false

    /// Sidebar destination (B7). `List(selection:)` drives which entries the
    /// detail grid shows. Defaults to `.all` (the unified grid landing).
    @State private var destination: SidebarDestination = .all
    /// Pending folder for the remove-from-library confirmation dialog.
    /// `nil` ⇒ dialog hidden. Set by a folder row's remove control.
    @State private var pendingRemoval: URL?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailGrid
        }
        // Persist prefs (density, opened folders, etc.) on any change — spec §5.7
        // ("no extra plumbing": the onChange save is the persistence hook).
        .onChange(of: model.prefs) { _, _ in
            try? model.prefs.save()
        }
        .confirmationDialog(
            Text("Remove “\(pendingRemoval?.lastPathComponent ?? "folder")” from your library?"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { url in
            Button("Remove from Library", role: .destructive) {
                confirmRemoveDirectory(url)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Files stay on disk. Only the library reference is removed.")
        }
    }

    // MARK: - Sidebar (B7)

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $destination) {
            Section("Library") {
                ForEach(SidebarDestination.builtIn) { d in
                    Label {
                        Text(d.title)
                    } icon: {
                        Image(systemName: d.icon)
                    }
                    .badge(badgeCount(for: d))
                    .tag(d)
                    .accessibilityLabel("\(d.title) genomes")
                }
            }
            Section("Folders") {
                if folderSources.isEmpty {
                    Text("No folders added")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(folderSources, id: \.self) { url in
                        folderRow(url)
                    }
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

    /// Opened folders, sorted by path for deterministic display (rule #2).
    private var folderSources: [URL] {
        model.prefs.directorySources.sorted(by: { $0.path < $1.path })
    }

    /// One row per opened folder: a folder label and a trailing remove control.
    /// Selecting the row shows that folder's grid; the minus button and the
    /// context-menu item both trigger the remove-from-library confirmation
    /// (files stay on disk — see the confirmation dialog in `body`).
    @ViewBuilder
    private func folderRow(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Label {
                Text(url.lastPathComponent).lineLimit(1)
            } icon: {
                Image(systemName: "folder")
            }
            Spacer(minLength: 0)
            Button {
                pendingRemoval = url
            } label: {
                Image(systemName: "minus.circle")
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
            }
            // `.borderless` is the macOS List-row button style: it activates on
            // click without being swallowed by the row's selection gesture.
            .buttonStyle(.borderless)
            .help("Remove from library (files stay on disk)")
        }
        .contentShape(Rectangle())
        .tag(SidebarDestination.folder(url))
        .contextMenu {
            Button("Remove from Library", role: .destructive) {
                pendingRemoval = url
            }
        }
        .accessibilityLabel("Folder \(url.lastPathComponent)")
    }

    /// Confirm removal of a folder: drop it from the library (no disk changes),
    /// and if it was selected, fall back to the All grid.
    private func confirmRemoveDirectory(_ url: URL) {
        model.removeDirectory(url)
        if case .folder(let current) = destination, current == url {
            destination = .all
        }
        pendingRemoval = nil
    }

    /// Live count badge per destination (P6 — visible payoff of sentiment etc.).
    /// Integer counts only (rule #2 safe). Folders carry no badge (their count
    /// shows in the detail title bar when selected) to keep the minus control
    /// uncluttered.
    private func badgeCount(for d: SidebarDestination) -> Int {
        switch d {
        case .all:
            return readyCount(model.bundleLoadState)
                + model.folderSourcesReadyCount()
                + readyCount(model.importedLoadState)
        case .library:   return readyCount(model.bundleLoadState)
        case .liked:     return model.likedEntries().count
        case .imported:  return readyCount(model.importedLoadState)
        case .folder(let url): return readyCount(model.directoryLoadStates[url] ?? .empty)
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
        // ⌘? opens the keyboard cheat-sheet; ⌘1…⌘4 jump to sidebar destinations.
        .background { keyboardShortcuts }
        .fileImporter(isPresented: $openImporter, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await model.openDirectory(url) }
            case .failure: break
            }
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
        case .folder(let url):
            return model.directoryLoadStates[url] ?? .empty
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

    /// Empty state is destination-aware (Liked teaches sentiment; All offers the
    /// open-directory CTA; a folder shows a folder-scoped empty message).
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
        case .folder(let url):
            ContentUnavailableView(
                "No genomes in \(url.lastPathComponent)",
                systemImage: "folder",
                description: Text("This folder has no readable .flam3 files.")
            )
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
            Button("Go to All") { destination = .all }
                .keyboardShortcut("1", modifiers: .command)
            Button("Go to Library") { destination = .library }
                .keyboardShortcut("2", modifiers: .command)
            Button("Go to Liked") { destination = .liked }
                .keyboardShortcut("3", modifiers: .command)
            Button("Go to Imported") { destination = .imported }
                .keyboardShortcut("4", modifiers: .command)
        }
        .hidden()
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
        let dirStates = model.prefs.directorySources
            .sorted(by: { $0.path < $1.path })
            .map { model.directoryLoadStates[$0] ?? .empty }
        for state in [model.bundleLoadState] + dirStates + [model.importedLoadState] {
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
                    openWindow(value: PlaybackRoute(entry))            // plain → open playback window
                }
            }
            .contextMenu {
                Button("Play") { openWindow(value: PlaybackRoute(entry)) }
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

/// Sidebar destinations. The built-in destinations are always present; each
/// opened library folder is its own `.folder(URL)` destination (multi-folder).
/// Not `CaseIterable` — the `.folder` case carries an associated URL — so
/// `builtIn` lists the always-present static destinations (keyboard ⌘1…⌘4 and
/// the sidebar "Library" section iterate that stable array). Structured so a
/// future Collections group can add a `.collection(...)` case the same way.
private enum SidebarDestination: Hashable, Identifiable {
    case all, library, liked, imported
    case folder(URL)

    /// Always-present destinations (the sidebar "Library" section + ⌘1…⌘4).
    static let builtIn: [SidebarDestination] = [.all, .library, .liked, .imported]

    var id: String {
        switch self {
        case .all:      return "all"
        case .library:  return "library"
        case .liked:    return "liked"
        case .imported: return "imported"
        case .folder(let url): return "folder:\(url.path)"
        }
    }

    var title: String {
        switch self {
        case .all:      return "All"
        case .library:  return "Library"
        case .liked:    return "Liked"
        case .imported: return "Imported"
        case .folder(let url): return url.lastPathComponent
        }
    }

    var icon: String {
        switch self {
        case .all:      return "square.grid.2x2"
        case .library:  return "books.vertical"
        case .liked:    return "star"
        case .imported: return "tray.and.arrow.down"
        case .folder:   return "folder"
        }
    }
}

// MARK: - Shared helpers (file-private)

/// 12-bucket hue names shared by the filter popover and chips.
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
