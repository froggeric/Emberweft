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
    /// Pending collection for the rename sheet. `nil` ⇒ sheet hidden.
    @State private var renamingCollection: GenomeCollection?
    @State private var renameText: String = ""

    /// Collection drag-reorder state. A custom in-app `DragGesture` (NOT system
    /// pasteboard DnD) — `.draggable`/`.dropDestination` never fired the drop and
    /// `List.onMove` replaced the grid with a list, so the grid uses its own
    /// `DragGesture` instead. `draggingStoredIndex` is the STORED `entries` index
    /// of the lifted cell; `collectionCellFrames` maps STORED index → cell frame
    /// (in the collection-grid coordinate space) collected from cell
    /// preferences for deterministic hit-testing (rule #2: a sorted/by-key map
    /// read, never a float sum over a hash collection).
    @State private var draggingStoredIndex: Int?
    @State private var dragTranslation: CGSize = .zero
    @State private var dropTargetStoredIndex: Int?
    @State private var collectionCellFrames: [Int: CGRect] = [:]

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
        .sheet(isPresented: Binding(
            get: { renamingCollection != nil },
            set: { if !$0 { renamingCollection = nil; renameText = "" } }
        )) {
            // Small rename sheet (a `.sheet` with a TextField is reliable on
            // macOS; `.alert`+TextField is less consistent across versions).
            NameCollectionSheet(title: "Rename Collection",
                                 confirmLabel: "Rename",
                                 name: $renameText) {
                commitRename()
            } onCancel: {
                renamingCollection = nil; renameText = ""
            }
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
            Section("Collections") {
                if model.collectionsStore.collections.isEmpty {
                    Text("No collections")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(model.collectionsStore.collections) { c in
                        collectionRow(c)
                    }
                }
            }
            // The dedicated Flock archive area (M6.5 / D9, §13). Routes to
            // `FlockView`, which owns its own chrome (it is NOT a library grid).
            // `flockModel` is AppModel-owned, so dismissing the area mid-generate
            // cannot orphan the coordinator actors (M4 §13.2).
            //
            // v0.5.9: while ANY flock operation runs (generate or stitch), the
            // row carries a live activity indicator (spinner or determinate bar +
            // a compact "~12:36" / "3/12" token) — GLOBAL presence, so a long
            // render is visible from every pane (the owner's explicit ask). Read
            // from `model.flockModel.flockActivity` (the model, never local
            // `@State`) so it stays live; nothing renders when idle (no animation
            // at rest).
            Section("Archive") {
                flockSidebarRow
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

    /// One row per collection: a playlist icon + its (resolved) genome count,
    /// selectable to show its grid, with a context menu for manage / play.
    /// `model.collectionsStore.collections` is `@Observable` so the badge count
    /// and the row list refresh when entries are added/removed/reordered.
    @ViewBuilder
    private func collectionRow(_ c: GenomeCollection) -> some View {
        Label {
            Text(c.name).lineLimit(1)
        } icon: {
            Image(systemName: "list.bullet.rectangle")
        }
        .badge(resolvedCount(of: c))
        .tag(SidebarDestination.collection(c.id))
        .contextMenu {
            Button("Play as Sequence") { openWindow(value: CollectionPlaybackRoute(id: c.id)) }
            Divider()
            Button("Rename…") { renamingCollection = c; renameText = c.name }
            Button("Delete", role: .destructive) { deleteCollection(c.id) }
        }
        .accessibilityLabel("Collection \(c.name), \(resolvedCount(of: c)) genomes")
    }

    /// Number of a collection's entries that currently resolve to a live genome
    /// (entries whose folder was removed / file gone are skipped). Integer count
    /// only — rule #2 safe.
    private func resolvedCount(of c: GenomeCollection) -> Int {
        model.resolvedPairs(for: c).count
    }

    /// Delete a collection; if it was selected, fall back to the All grid.
    private func deleteCollection(_ id: UUID) {
        model.collectionsStore.delete(id)
        if case .collection(let current) = destination, current == id {
            destination = .all
        }
    }

    /// Commit a pending rename (sheet "Done"/Enter). Trims; empty ⇒ "Untitled".
    private func commitRename() {
        guard let c = renamingCollection else { return }
        model.collectionsStore.rename(c.id, to: renameText)
        renamingCollection = nil
        renameText = ""
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
        case .flock:     return 0
        case .folder(let url): return readyCount(model.directoryLoadStates[url] ?? .empty)
        case .collection(let id): return model.collectionsStore.collection(id: id).map { resolvedCount(of: $0) } ?? 0
        }
    }

    private func readyCount(_ s: LoadState) -> Int {
        if case .ready(let entries) = s { return entries.count }
        return 0
    }

    // MARK: - Flock sidebar row + global activity indicator (v0.5.9)

    /// The Archive-section row. `HStack(Label, Spacer, indicator?)` so the whole
    /// row keeps its List-selection tag while the trailing slot shows live flock
    /// activity (nil ⇒ nothing — the row is identical to before at rest).
    @ViewBuilder
    private var flockSidebarRow: some View {
        HStack(spacing: 6) {
            Label {
                Text("Flock")
            } icon: {
                Image(systemName: "bird.fill")
            }
            Spacer(minLength: 0)
            if let activity = model.flockModel.flockActivity {
                flockActivityIndicator(activity)
            }
        }
        .contentShape(Rectangle())
        .tag(SidebarDestination.flock)
        .accessibilityLabel(flockAccessibilityLabel)
    }

    /// Compact running indicator for the Flock sidebar row: a determinate mini
    /// bar when the overall fraction is known, else a spinner; plus the summary's
    /// compact token ("~12:36" remaining or "3/12"). Subtle by design — macOS
    /// sidebar idiom, `.mini` controls + caption2 secondary text.
    @ViewBuilder
    private func flockActivityIndicator(_ a: FlockActivitySummary) -> some View {
        HStack(spacing: 4) {
            if let fraction = a.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .frame(width: 32)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            let token = a.compactStatus
            if !token.isEmpty {
                Text(token)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .help("Flock: \(a.kindLabel) — open Flock for details and cancel.")
    }

    private var flockAccessibilityLabel: String {
        if let a = model.flockModel.flockActivity {
            return "Flock archive, \(a.kindLabel)"
        }
        return "Flock archive"
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
        // The Flock archive area (M6.5 / D9) gets its OWN chrome — it is a
        // Generate/Stitch/Browse surface over `FlockModel`, not a library grid,
        // so it bypasses `detailChrome` (search / drop / selection bar / title).
        // `flockModel` is AppModel-owned, so dismissing the area mid-run cannot
        // orphan the coordinator actors (M4 §13.2 — the strong-self cancel path
        // in `FlockModel.cancelGenerate`/`cancelStitch` keeps them alive until
        // they acknowledge stop).
        if case .flock = destination {
            FlockView()
                .environment(model.flockModel)
        } else {
            detailChrome {
                // Collections render in the SAME `LazyVGrid` of `ThumbnailCell` as
                // every other destination, with a custom in-app `DragGesture` for
                // reorder (no system pasteboard DnD, no `List`). The prior two
                // attempts both failed: `.draggable`+`.dropDestination` (Transferable)
                // never fired the drop action on this bundle-less app, and
                // `List`+`.onMove` replaced the grid with a list (regression).
                if case .collection(let id) = destination,
                   let c = model.collectionsStore.collection(id: id) {
                    collectionGridBody(c)
                } else {
                    gridScrollBody(for: state)
                }
            }
        }
    }

    /// Shared detail chrome (search, file-URL import drop, selection bar / toast,
    /// animations, title/subtitle, toolbar, keyboard shortcuts, importer) applied
    /// to BOTH the collection grid and the browsing `ScrollView` so the
    /// destination swap only changes the inner content.
    @ViewBuilder
    private func detailChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let state = currentLoadState
        content()
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
            .overlay(alignment: .top) {
                // Non-blocking export-progress banner (spec §4.7 / G8). Mounted in
                // all three window types — the main window is NOT always open, and
                // an export is most often started from a playback window. Top
                // alignment so it never collides with the bottom SelectionBar.
                // Self-hides (returns EmptyView) when `exportManager.state == .idle`.
                ExportProgressSurface()
                    .padding(.top, 10)
            }
            .animation(.snappy, value: model.selection.isEmpty)
            .animation(.snappy, value: filter)
            .animation(.snappy, value: destination)
            .navigationTitle(destinationTitle)
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

    /// The non-collection browsing surface: a `ScrollView` of filter chips + the
    /// destination grid body. (Collections use `collectionGridBody` instead.)
    @ViewBuilder
    private func gridScrollBody(for state: LoadState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                activeFilterChips
                gridBody(for: state)
            }
            .padding(20)
        }
    }

    /// Title-bar title for the active destination. Collections use their name
    /// (not the generic "Collection" label).
    private var destinationTitle: String {
        if case .collection(let id) = destination,
           let c = model.collectionsStore.collection(id: id) {
            return c.name
        }
        return destination.title
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
        case .flock:
            // The Flock area renders `FlockView` (its own chrome, not a library
            // grid); it never consults `currentLoadState`. `.empty` is the inert
            // fallback so any incidental read is safe.
            return .empty
        case .folder(let url):
            return model.directoryLoadStates[url] ?? .empty
        // Collections are not backed by a `LoadState`; the resolved entries are
        // wrapped in `.ready` so count/search/filter read naturally. The detail
        // body routes collections through the stored-index-aware reorder list
        // (`collectionDetailBody`) — remove/reorder need the stored `entries`
        // index, recovered via the identity→stored map.
        case .collection(let id):
            guard let c = model.collectionsStore.collection(id: id) else { return .empty }
            let resolved = model.resolvedPairs(for: c).map(\.entry)
            return resolved.isEmpty ? .empty : .ready(resolved)
        }
    }

    @ViewBuilder
    private func gridBody(for state: LoadState) -> some View {
        // Collections are routed to `collectionGridBody` (the same `LazyVGrid` of
        // `ThumbnailCell`, plus a custom drag-reorder `DragGesture`) before this
        // point; this grid body serves the non-collection browsing destinations
        // (All / Library / Liked / Imported / Folders).
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

    /// A collection's detail surface: the SAME `LazyVGrid` of `ThumbnailCell`
    /// used by every other destination (identical card, hover sentiment bar,
    /// tick, category pill, density), PLUS a custom in-app `DragGesture` for
    /// reorder. This is the proven pattern after two failed attempts:
    /// `.draggable`+`.dropDestination` (Transferable) never fired the drop action
    /// on this bundle-less SwiftPM executable, and `List`+`.onMove` replaced the
    /// grid with a list (rejected as a regression). No pasteboard, no UTType, no
    /// `List` — just a `DragGesture` that lifts, hit-tests, and calls
    /// `CollectionsStore.moveEntries(in:from:to:)`.
    ///
    /// **Stored vs resolved indices:** a collection can have unresolvable or
    /// filtered-out entries (gaps). `moveEntries` operates on STORED `entries`
    /// indices, but the grid shows the RESOLVED+FILTERED view. Each cell
    /// publishes its STORED index + frame via `CollectionCellFramePreference`;
    /// the drag hit-test resolves pointer position → STORED target index, and
    /// the move calls `moveEntries` with STORED indices for BOTH source and
    /// target (translated through the same identity→stored map the resolved view
    /// is built from). Gaps therefore stay put relative to their stored
    /// neighbors — no desync (rule #2).
    @ViewBuilder
    private func collectionGridBody(_ c: GenomeCollection) -> some View {
        let pairs = model.resolvedPairs(for: c)
        let resolved = pairs.map(\.entry)
        let filtered = applyFilter(filter, to: resolved,
                                   metadata: { model.metadataStore.metadata(for: $0) },
                                   facet: { model.facets.facet(for: $0) })
        // Identity → stored index, and stored index → entry (LOOKUP only; the
        // display order still comes from the filtered array — rule #2). The
        // stored→entry map backs the lifted-copy overlay.
        let storedOf: [String: Int] = Dictionary(
            pairs.map { (CollectionEntry($0.entry).identity, $0.storedIndex) },
            uniquingKeysWith: { a, _ in a })
        let entryByStored: [Int: LibraryEntry] = Dictionary(
            pairs.map { ($0.storedIndex, $0.entry) },
            uniquingKeysWith: { a, _ in a })
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                activeFilterChips
                if filtered.isEmpty {
                    // Mirror the grid's empty-state messaging: "collection empty"
                    // vs "no resolvable" (resolved empty) vs "no matches" (filter).
                    if resolved.isEmpty {
                        emptyStateView
                    } else {
                        filteredEmptyState(hadEntries: true)
                    }
                } else {
                    LazyVGrid(columns: grid, spacing: 16) {
                        ForEach(filtered) { entry in
                            collectionCell(entry,
                                           storedIndex: storedOf[CollectionEntry(entry).identity] ?? 0,
                                           collection: c,
                                           in: filtered)
                        }
                    }
                    .coordinateSpace(name: CollectionGridSpace.name)
                    .onPreferenceChange(CollectionCellFramePreference.self) {
                        collectionCellFrames = $0
                    }
                    // The lifted copy: a translucent `ThumbnailCell` that follows
                    // the pointer while a drag is in progress. Rendered as a grid
                    // overlay (above all cells), positioned at the SOURCE cell's
                    // center + the drag translation. Source cells themselves never
                    // move, so their published frames stay stable and hit-testing
                    // is exact. `allowsHitTesting(false)` so the copy can't
                    // intercept the drag or taps. (The thumbnail loads from the
                    // warm ThumbnailService cache — keyed by entry.id — so it
                    // resolves in ~one frame.)
                    .overlay {
                        if let source = draggingStoredIndex,
                           let frame = collectionCellFrames[source],
                           let sourceEntry = entryByStored[source] {
                            ThumbnailCell(entry: sourceEntry, selected: false)
                                .opacity(0.92)
                                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                                .position(x: frame.midX + dragTranslation.width,
                                          y: frame.midY + dragTranslation.height)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .padding(20)
            .animation(.snappy(duration: 0.15), value: dropTargetStoredIndex)
        }
    }

    /// One cell of the collection grid: the shared `ThumbnailCell` (identical
    /// look to every other destination) + a per-cell `DragGesture(minimumDistance:
    /// 10)` for reorder. The drag only recognizes after 10pt of movement, so a
    /// quick tap still opens the preview (`.onTapGesture`) and the in-cell
    /// Buttons (tick, sentiment) still receive their clicks. `.highPriorityGesture`
    /// lets the drag claim the gesture once it recognizes (after 10pt), so a drag
    /// does NOT also fire the tap (which would open the preview), and a click does
    /// NOT start a drag. While dragging, the source cell is dimmed in place and a
    /// lifted copy follows the pointer (see `collectionGridBody`'s overlay); the
    /// `dropTargetStoredIndex` cell gets an accent border.
    ///
    /// Each cell publishes its frame + STORED index via a preference so the
    /// grid-level drag state can hit-test pointer position → stored target. The
    /// frame is read from `.background` on the unmoved cell, so it is the stable
    /// laid-out frame (the lift is a separate overlay, not an offset on this cell).
    @ViewBuilder
    private func collectionCell(_ entry: LibraryEntry,
                                storedIndex: Int,
                                collection c: GenomeCollection,
                                in filtered: [LibraryEntry]) -> some View {
        let isSource = draggingStoredIndex == storedIndex
        let isTarget = dropTargetStoredIndex == storedIndex
        ThumbnailCell(entry: entry, selected: model.isSelected(entry))
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CollectionCellFramePreference.self,
                        value: [storedIndex: proxy.frame(in: .named(CollectionGridSpace.name))])
                }
            )
            .overlay {
                if isTarget {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            // Dim the source cell in place while its lifted copy follows the
            // pointer (the copy is rendered by the grid overlay).
            .opacity(isSource ? 0.35 : 1.0)
            .contentShape(Rectangle())
            .onTapGesture { handleCellTap(entry, in: filtered) }
            .highPriorityGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        if draggingStoredIndex == nil {
                            draggingStoredIndex = storedIndex
                        }
                        dragTranslation = value.translation
                        dropTargetStoredIndex = collectionDragTarget(
                            sourceStored: storedIndex, translation: value.translation)
                    }
                    .onEnded { value in
                        let target = collectionDragTarget(
                            sourceStored: storedIndex, translation: value.translation)
                        if let target = target, target != storedIndex {
                            // "Drop on target → take target's stored slot." For a
                            // DOWNWARD move (source < target) the source lands at
                            // the target's original stored index via toOffset =
                            // target+1 (Array.move's original-indexing "insert
                            // after"); an UPWARD move uses toOffset = target
                            // ("insert before"). Both proven against the store
                            // tests (moveEntries delegates to Array.move).
                            let toOffset = storedIndex < target ? target + 1 : target
                            model.collectionsStore.moveEntries(
                                in: c.id, from: IndexSet([storedIndex]), to: toOffset)
                        }
                        draggingStoredIndex = nil
                        dropTargetStoredIndex = nil
                        dragTranslation = .zero
                    }
            )
            .contextMenu {
                Button("Play") { openWindow(value: PlaybackRoute(entry)) }
                Divider()
                Button("👍 Like") { model.metadataStore.setSentiment(1, for: entry) }
                Button("● Neutral") { model.metadataStore.setSentiment(0, for: entry) }
                Button("👎 Dislike") { model.metadataStore.setSentiment(-1, for: entry) }
                Divider()
                Button("Move Up") {
                    model.collectionsStore.moveEntry(in: c.id, from: storedIndex, to: storedIndex - 1)
                }.disabled(storedIndex == 0)
                Button("Move Down") {
                    model.collectionsStore.moveEntry(in: c.id, from: storedIndex, to: storedIndex + 1)
                }.disabled(storedIndex >= c.entries.count - 1)
                Divider()
                Button("Remove from Collection", role: .destructive) {
                    model.collectionsStore.removeEntry(at: storedIndex, from: c.id)
                }
                Divider()
                addToCollectionMenu(for: [CollectionEntry(entry)])
            }
            .accessibilityLabel(cellAccessibilityLabel(entry))
    }

    /// Hit-test the in-progress drag: returns the STORED index of the cell under
    /// the pointer (pointer = the SOURCE cell's center + the drag translation),
    /// or nil if none. Iterates the collected cell frames in STORED-INDEX order
    /// (deterministic — rule #2): prefers a frame that CONTAINS the pointer, else
    /// the nearest cell by squared-center-distance (comparison, not a float sum,
    /// so iteration order can't affect the result). The source cell itself is
    /// excluded (dropping on self is a no-op). Only VISIBLE cells publish frames
    /// (LazyVGrid), which is all the user can drag over.
    private func collectionDragTarget(sourceStored: Int, translation: CGSize) -> Int? {
        guard let source = collectionCellFrames[sourceStored] else { return nil }
        let pointer = CGPoint(x: source.midX + translation.width,
                              y: source.midY + translation.height)
        // Sorted by stored index for deterministic iteration (rule #2).
        let orderedFrames = collectionCellFrames.sorted { $0.key < $1.key }
        var contained: Int?
        var nearest: (stored: Int, dist: CGFloat)?
        for (stored, frame) in orderedFrames where stored != sourceStored {
            if frame.contains(pointer) {
                contained = stored
                break
            }
            let dx = frame.midX - pointer.x
            let dy = frame.midY - pointer.y
            let dist = dx * dx + dy * dy
            if nearest == nil || dist < nearest!.dist {
                nearest = (stored, dist)
            }
        }
        return contained ?? nearest?.stored
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
        case .collection(let id):
            // Distinguish "collection is empty" from "all its genomes became
            // unresolvable" (folder removed / rescanned away) for a useful message.
            let stored = model.collectionsStore.collection(id: id)?.entries.count ?? 0
            ContentUnavailableView(
                stored > 0 ? "No resolvable genomes" : "Empty collection",
                systemImage: "list.bullet.rectangle",
                description: Text(stored > 0
                    ? "The genomes in this collection's folder(s) are no longer available. Re-open the folder to bring them back."
                    : "Add genomes with the selection bar's “Save as Collection…” or “Add to ▾”, or drag them from another collection.")
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

    // MARK: - Cell (display + selection interaction)

    /// Shared cell body (thumbnail + tap interaction). Plain click opens the
    /// single-genome playback window; ⌘/ctrl toggles selection; shift range-
    /// selects. Context menus are added by the callers (`cell` / `collectionCell`).
    @ViewBuilder
    private func cellCore(_ entry: LibraryEntry, in filtered: [LibraryEntry]) -> some View {
        ThumbnailCell(entry: entry, selected: model.isSelected(entry))
            .contentShape(Rectangle())
            .onTapGesture { handleCellTap(entry, in: filtered) }
    }

    /// Shared tap behavior: plain click → open the single-genome playback window;
    /// ⌘/ctrl → toggle selection; shift → range-select. Used by both the grid
    /// cell and the collection reorder-list row so the interaction stays uniform.
    private func handleCellTap(_ entry: LibraryEntry, in filtered: [LibraryEntry]) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) || mods.contains(.control) {
            model.toggleInSelection(entry)
        } else if mods.contains(.shift) {
            model.selectRange(entry, in: filtered)
        } else {
            openWindow(value: PlaybackRoute(entry))
        }
    }

    @ViewBuilder
    private func cell(_ entry: LibraryEntry, in filtered: [LibraryEntry]) -> some View {
        cellCore(entry, in: filtered)
            .contextMenu {
                Button("Play") { openWindow(value: PlaybackRoute(entry)) }
                Divider()
                Button("👍 Like") { model.metadataStore.setSentiment(1, for: entry) }
                Button("● Neutral") { model.metadataStore.setSentiment(0, for: entry) }
                Button("👎 Dislike") { model.metadataStore.setSentiment(-1, for: entry) }
                Divider()
                addToCollectionMenu(for: [CollectionEntry(entry)])
            }
            .accessibilityLabel(cellAccessibilityLabel(entry))
    }

    /// "Add to Collection ▾" submenu — adds the given entries (deduped by
    /// identity) to whichever collection the user picks. Shared by the per-cell
    /// context menu (one entry) and the selection bar (the whole selection).
    /// Reads `model.collectionsStore.collections` (`@Observable`) so the menu
    /// refreshes as collections are created/deleted.
    @ViewBuilder
    private func addToCollectionMenu(for entries: [CollectionEntry]) -> some View {
        Menu("Add to Collection") {
            if model.collectionsStore.collections.isEmpty {
                Button("No collections yet") {}.disabled(true)
            } else {
                ForEach(model.collectionsStore.collections) { c in
                    Button(c.name) {
                        let added = model.collectionsStore.addEntries(entries, to: c.id)
                        importToast = added == 0 ? "Already in \(c.name)" : "Added \(added) to \(c.name)"
                    }
                }
            }
        }
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
    case flock
    case folder(URL)
    case collection(UUID)

    /// Always-present destinations (the sidebar "Library" section + ⌘1…⌘4).
    static let builtIn: [SidebarDestination] = [.all, .library, .liked, .imported]

    var id: String {
        switch self {
        case .all:      return "all"
        case .library:  return "library"
        case .liked:    return "liked"
        case .imported: return "imported"
        case .flock:    return "flock"
        case .folder(let url): return "folder:\(url.path)"
        case .collection(let id): return "collection:\(id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .all:      return "All"
        case .library:  return "Library"
        case .liked:    return "Liked"
        case .imported: return "Imported"
        case .flock:    return "Flock"
        case .folder(let url): return url.lastPathComponent
        case .collection: return "Collection"
        }
    }

    var icon: String {
        switch self {
        case .all:      return "square.grid.2x2"
        case .library:  return "books.vertical"
        case .liked:    return "star"
        case .imported: return "tray.and.arrow.down"
        case .flock:    return "bird.fill"
        case .folder:   return "folder"
        case .collection: return "list.bullet.rectangle"
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

// MARK: - Collection grid drag-reorder support (private to file)

/// Coordinate-space name for the collection grid. Each collection cell publishes
/// its frame in this space, and the drag hit-test resolves the pointer position
/// in it. A small enum (not a bare `String`) keeps the call sites self-documenting
/// and typo-proof.
private enum CollectionGridSpace {
    static let name = "CollectionGrid"
}

/// Per-cell frame preference for the collection grid's drag-reorder hit-test.
/// Each collection cell publishes `[storedIndex: frame(in: .named("CollectionGrid"))]`;
/// the grid reduces all cells' values into one `[Int: CGRect]` map. STORED
/// indices (not grid-row indices) travel with each frame so the drag →
/// `moveEntries` call stays in STORED space — gaps from unresolvable/filtered
/// entries never desync (rule #2).
private struct CollectionCellFramePreference: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        // Later values win per stored index (the live frame supersedes stale).
        value.merge(nextValue()) { _, new in new }
    }
}
