import Foundation
import SwiftUI
import EmberweftUI
import FlameKit

/// App-wide, MainActor-owned state: preferences, the shared library index +
/// thumbnail service, metadata store, palette facets, and the per-section grid
/// load states. Owned by `EmberweftApp`.
@MainActor
@Observable
final class AppModel {

    /// Persisted user settings.
    var prefs: AppPreferences

    let libraryIndex = LibraryIndex()
    let thumbnailService: ThumbnailService
    let metadataStore: MetadataStore
    let facets = FacetCache()

    /// The bundled curated library resource root (`CuratedLibrary/`).
    private let bundleRoot: URL?

    var bundleLoadState: LoadState = .loading
    var importedLoadState: LoadState = .empty

    /// Per-opened-folder load state, keyed by the exact `URL` stored in
    /// `prefs.directorySources` (the scan root). A Dictionary is fine here: it is
    /// used for keyed LOOKUP only — every list built for display iterates
    /// `prefs.directorySources` (an array) sorted by path (rule #2).
    var directoryLoadStates: [URL: LoadState] = [:]

    /// Per-section thumbnail-render progress. Per-section so an import (which only
    /// rescans `importedLoadState`) or a per-folder rescan never discards the
    /// bundle/other-folder progress — no full-grid re-render on import.
    var bundleRendered: Set<String> = []
    var directoryRendered: [URL: Set<String>] = [:]
    var importedRendered: Set<String> = []

    /// Multi-selection of genomes (for bulk actions / future collections).
    var selection: Set<LibraryEntry> = []
    private(set) var selectionAnchor: LibraryEntry?

    /// Union of all sections' rendered ids (for the progress indicator). Iterates
    /// the `directorySources` array (not the Dictionary) — rule #2; the union is
    /// order-independent anyway.
    var renderedThumbIDs: Set<String> {
        var out = bundleRendered.union(importedRendered)
        for url in prefs.directorySources {
            out.formUnion(directoryRendered[url] ?? [])
        }
        return out
    }
    var thumbTotal: Int = 0

    var importedDir: URL {
        AppPreferences.defaultDirectory.appendingPathComponent("Imported", isDirectory: true)
    }

    func markThumbResolved(for entry: LibraryEntry) {
        switch entry.source {
        case .bundle: bundleRendered.insert(entry.id)
        case .directory(let url): directoryRendered[url, default: []].insert(entry.id)
        case .imported: importedRendered.insert(entry.id)
        }
    }

    /// Remove a genome from its section (used to exclude degenerate genomes).
    func hideEntry(for entry: LibraryEntry) {
        switch entry.source {
        case .bundle:
            bundleLoadState = filtering(out: entry.id, in: bundleLoadState)
            bundleRendered.remove(entry.id)
        case .directory(let url):
            directoryLoadStates[url] = filtering(out: entry.id, in: directoryLoadStates[url] ?? .empty)
            directoryRendered[url]?.remove(entry.id)
        case .imported:
            importedLoadState = filtering(out: entry.id, in: importedLoadState)
            importedRendered.remove(entry.id)
        }
        recomputeThumbTotal()
    }

    private func filtering(out id: String, in state: LoadState) -> LoadState {
        guard case .ready(let entries) = state else { return state }
        let filtered = entries.filter { $0.id != id }
        return filtered.isEmpty ? .empty : .ready(filtered)
    }

    func recomputeThumbTotal() {
        var n = 0
        if case .ready(let e) = bundleLoadState { n += e.count }
        if case .ready(let e) = importedLoadState { n += e.count }
        for url in prefs.directorySources {
            if case .ready(let e) = directoryLoadStates[url] ?? .empty { n += e.count }
        }
        thumbTotal = n
    }

    init() {
        let (loaded, _) = AppPreferences.loadResilient()
        self.prefs = loaded
        self.bundleRoot = Bundle.module.url(forResource: "CuratedLibrary", withExtension: nil)
        let thumbs = AppPreferences.defaultDirectory.appendingPathComponent("thumbs", isDirectory: true)
        self.thumbnailService = ThumbnailService(cacheDirectory: thumbs)
        let (mdStore, _) = MetadataStore.loadResilient()
        self.metadataStore = mdStore
    }

    /// Liked genomes (sentiment == +1) across all loaded sections. Folder order
    /// is deterministic (sorted by path — rule #2). Reads the `@Observable`
    /// stores, so the Liked section re-renders on changes.
    func likedEntries() -> [LibraryEntry] {
        var out: [LibraryEntry] = []
        if case .ready(let entries) = bundleLoadState {
            out += entries.filter { metadataStore.metadata(for: $0).sentiment == 1 }
        }
        for url in prefs.directorySources.sorted(by: { $0.path < $1.path }) {
            if case .ready(let entries) = directoryLoadStates[url] ?? .empty {
                out += entries.filter { metadataStore.metadata(for: $0).sentiment == 1 }
            }
        }
        if case .ready(let entries) = importedLoadState {
            out += entries.filter { metadataStore.metadata(for: $0).sentiment == 1 }
        }
        return out
    }

    /// Unified entries across every loaded source for the sidebar **All** grid
    /// (B7). Deduped by `(sourceRank, sourcePath, id)` (folders carry their root
    /// path in the key, so two folders never collide), then sorted
    /// deterministically by that key — rule #2: the `Set` is used only for
    /// membership checks; folder iteration is over a path-sorted array. Stable
    /// across launches and machines.
    func unifiedEntries() -> [LibraryEntry] {
        var seen = Set<String>()
        var out: [LibraryEntry] = []
        func absorb(_ state: LoadState) {
            guard case .ready(let entries) = state else { return }
            for e in entries {
                let key = "\(Self.sourceRank(e.source))|\(Self.sourcePath(e.source))|\(e.id)"
                if seen.insert(key).inserted { out.append(e) }
            }
        }
        absorb(bundleLoadState)
        for url in prefs.directorySources.sorted(by: { $0.path < $1.path }) {
            absorb(directoryLoadStates[url] ?? .empty)
        }
        absorb(importedLoadState)
        return out.sorted {
            let a = (Self.sourceRank($0.source), Self.sourcePath($0.source), $0.id)
            let b = (Self.sourceRank($1.source), Self.sourcePath($1.source), $1.id)
            return a < b
        }
    }

    /// Lookup the load state for an opened folder by its root path. Used by
    /// `PlaybackRoute.resolve` to resolve a route against the folder it came from
    /// (multi-folder: the route's `rootPath` may be ANY opened folder, not just a
    /// single primary one). Returns `nil` when no opened folder matches.
    func directoryLoadState(forRootPath path: String) -> LoadState? {
        for url in prefs.directorySources.sorted(by: { $0.path < $1.path }) {
            if url.path == path { return directoryLoadStates[url] ?? .empty }
        }
        return nil
    }

    /// Sum of `.ready` entry counts across all opened folders (integer count —
    /// rule #2 safe; iterates the `directorySources` array, not the Dict). Used
    /// by the sidebar's All-destination badge.
    func folderSourcesReadyCount() -> Int {
        var n = 0
        for url in prefs.directorySources {
            if case .ready(let e) = directoryLoadStates[url] ?? .empty { n += e.count }
        }
        return n
    }

    /// Deterministic ordering rank for a source (bundle < directory < imported).
    /// Pure; never reads hash order (rule #2).
    private static func sourceRank(_ s: LibrarySource) -> Int {
        switch s {
        case .bundle: return 0
        case .directory: return 1
        case .imported: return 2
        }
    }

    /// Stable disambiguator string for a source (the directory's path, or "" for
    /// single-namespace sources). Pure.
    private static func sourcePath(_ s: LibrarySource) -> String {
        switch s {
        case .bundle: return ""
        case .directory(let url): return url.path
        case .imported: return ""
        }
    }

    // MARK: - Selection (multi-select)

    func selectOnly(_ entry: LibraryEntry) {
        selection = [entry]; selectionAnchor = entry
    }
    func toggleInSelection(_ entry: LibraryEntry) {
        if selection.contains(entry) { selection.remove(entry) } else { selection.insert(entry) }
        selectionAnchor = entry
    }
    /// Range-select within an ordered (filtered) list, from the anchor to `entry`.
    func selectRange(_ entry: LibraryEntry, in ordered: [LibraryEntry]) {
        guard let anchor = selectionAnchor,
              let a = ordered.firstIndex(of: anchor),
              let b = ordered.firstIndex(of: entry) else {
            selectOnly(entry); return
        }
        let lo = min(a, b), hi = max(a, b)
        for e in ordered[lo...hi] { selection.insert(e) }
        selectionAnchor = entry
    }
    func selectAll(_ entries: [LibraryEntry]) {
        selection = Set(entries); selectionAnchor = entries.first
    }
    func clearSelection() { selection.removeAll(); selectionAnchor = nil }
    func isSelected(_ entry: LibraryEntry) -> Bool { selection.contains(entry) }

    /// Bulk-set sentiment over a selection (iterate a SORTED sequence — rule #2:
    /// never accumulate over the hashed `Set`). `scheduleSave` coalesces the writes.
    func applySentiment(_ value: Int, to entries: Set<LibraryEntry>) {
        for e in entries.sorted(by: { $0.id < $1.id }) {
            metadataStore.setSentiment(value, for: e)
        }
    }

    // MARK: - Scan

    func loadBundle() async {
        guard let root = bundleRoot else {
            bundleLoadState = .failed("Curated library not found in the app bundle.")
            return
        }
        let entries = await libraryIndex.scanBundle(rootURL: root)
        bundleLoadState = entries.isEmpty ? .empty : .ready(entries)
        // Precompute palette facets for the curated bundle (24 genomes, all cached)
        // so palette filtering works immediately. Directory/imported entries get
        // facets lazily as their thumbnails render (no mass parse).
        for e in entries {
            if let flame = try? await libraryIndex.loadGenome(for: e) {
                facets.putIfAbsent(for: e, flame: flame)
            }
        }
        recomputeThumbTotal()
    }

    /// Open (and scan) a library folder. ADDS it to `prefs.directorySources`
    /// (deduped by standardized path) rather than replacing, and stores its
    /// `LoadState` under the folder's canonical URL. Re-opening an already-opened
    /// folder just rescans it in place (state stays keyed under one URL even if
    /// the incoming URL has a different representation, e.g. a trailing slash).
    /// Persisted via `prefs.save()`.
    func openDirectory(_ url: URL) async {
        prefs.addDirectorySource(url)
        let key = canonicalDirectoryURL(url)
        try? prefs.save()
        directoryLoadStates[key] = .loading
        directoryRendered[key] = []           // fresh scan of this folder
        do {
            let entries = try await libraryIndex.scanDirectory(key)
            directoryLoadStates[key] = entries.isEmpty ? .empty : .ready(entries)
        } catch {
            directoryLoadStates[key] = .failed("Could not read library at \(key.path).\n\(error.localizedDescription)")
        }
        recomputeThumbTotal()
    }

    /// Remove a folder from the library: drops it from `prefs.directorySources`
    /// and clears its load state + thumbnail progress. **Does NOT touch any file
    /// on disk** — only the in-app library reference is removed. The canonical
    /// key is captured before mutating `prefs` (it reads `directorySources`).
    func removeDirectory(_ url: URL) {
        let key = canonicalDirectoryURL(url)
        prefs.removeDirectorySource(url)
        try? prefs.save()
        directoryLoadStates[key] = nil
        directoryRendered[key] = nil
        recomputeThumbTotal()
    }

    /// The URL stored in `directorySources` that is equivalent to `url` (by
    /// standardized path), or `url` itself when none. Always key per-folder state
    /// by this canonical value so re-opening / removing a folder is stable
    /// regardless of URL representation (trailing slash, `..`, etc.).
    private func canonicalDirectoryURL(_ url: URL) -> URL {
        let key = url.standardizedFileURL.path
        return prefs.directorySources.first { $0.standardizedFileURL.path == key } ?? url
    }

    /// Re-scan every opened folder (called at launch to pick up on-disk changes).
    func reloadDirectorySources() async {
        for url in prefs.directorySources.sorted(by: { $0.path < $1.path }) {
            await openDirectory(url)
        }
    }

    // MARK: - Import (drag-and-drop)

    /// Re-scan the Imported folder only. Does NOT touch bundle/directory state or
    /// their rendered-id progress (incremental — the scalability fix).
    func rescanImported() async {
        let entries = await libraryIndex.scanImported(rootURL: importedDir)
        importedLoadState = entries.isEmpty ? .empty : .ready(entries)
        importedRendered = []
        recomputeThumbTotal()
    }

    /// Import a batch of dropped file URLs into the Imported folder. Parse-before-
    /// copy (reject junk); dedup filenames; stamp `importedAt`. Returns counts.
    func importFiles(_ urls: [URL]) async -> (imported: Int, skipped: Int) {
        do { try FileManager.default.createDirectory(at: importedDir, withIntermediateDirectories: true) }
        catch { return (0, urls.count) }

        let plan = planImports(urls: urls, existingStems: importedStems())
        var imported = 0
        var skipped = urls.count - plan.count          // non-.flam3 / unsanitary
        for item in plan {
            // Parse before copy — never copy an unparseable file into Imported.
            guard let data = try? Data(contentsOf: item.source),
                  (try? Flam3Parser.parse(data).first) != nil else {
                skipped += 1
                continue
            }
            let dest = importedDir.appendingPathComponent("\(item.destStem).flam3")
            do {
                try FileManager.default.copyItem(at: item.source, to: dest)
            } catch {
                skipped += 1
                continue
            }
            let e = LibraryEntry(id: item.destStem, source: .imported,
                                 fileURL: dest, displayName: item.destStem, rank: nil)
            metadataStore.update(for: e) { $0.importedAt = Date() }
            imported += 1
        }
        await rescanImported()
        return (imported, skipped)
    }

    /// Existing .flam3 stems in the Imported folder (read from disk so dedup is
    /// robust against stale in-memory state).
    private func importedStems() -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: importedDir.path) else {
            return []
        }
        return Set(names
            .filter { ($0 as NSString).pathExtension == "flam3" }
            .map { ($0 as NSString).deletingPathExtension })
    }
}
