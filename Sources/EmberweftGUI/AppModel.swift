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
    var dirLoadState: LoadState = .empty
    var importedLoadState: LoadState = .empty

    /// Per-section thumbnail-render progress. Per-section so an import (which only
    /// rescans `importedLoadState`) or a directory rescan never discards the
    /// bundle/directory progress — no full-grid re-render on import.
    var bundleRendered: Set<String> = []
    var dirRendered: Set<String> = []
    var importedRendered: Set<String> = []

    /// Union of all sections' rendered ids (for the progress indicator).
    var renderedThumbIDs: Set<String> {
        bundleRendered.union(dirRendered).union(importedRendered)
    }
    var thumbTotal: Int = 0

    var importedDir: URL {
        AppPreferences.defaultDirectory.appendingPathComponent("Imported", isDirectory: true)
    }

    func markThumbResolved(for entry: LibraryEntry) {
        switch entry.source {
        case .bundle: bundleRendered.insert(entry.id)
        case .directory: dirRendered.insert(entry.id)
        case .imported: importedRendered.insert(entry.id)
        }
    }

    /// Remove a genome from its section (used to exclude degenerate genomes).
    func hideEntry(for entry: LibraryEntry) {
        switch entry.source {
        case .bundle:
            bundleLoadState = filtering(out: entry.id, in: bundleLoadState)
            bundleRendered.remove(entry.id)
        case .directory:
            dirLoadState = filtering(out: entry.id, in: dirLoadState)
            dirRendered.remove(entry.id)
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
        if case .ready(let e) = dirLoadState { n += e.count }
        if case .ready(let e) = importedLoadState { n += e.count }
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

    /// Favorite entries across all loaded sections, in source order. Reads the
    /// `@Observable` stores, so the Favorites section re-renders on toggles.
    func favoriteEntries() -> [LibraryEntry] {
        var out: [LibraryEntry] = []
        for state in [bundleLoadState, dirLoadState, importedLoadState] {
            if case .ready(let entries) = state {
                out += entries.filter { metadataStore.metadata(for: $0).favorite }
            }
        }
        return out
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

    func openDirectory(_ url: URL) async {
        prefs.defaultLibraryDir = url
        try? prefs.save()
        dirLoadState = .loading
        dirRendered.removeAll()           // fresh directory
        do {
            let entries = try await libraryIndex.scanDirectory(url)
            dirLoadState = entries.isEmpty ? .empty : .ready(entries)
        } catch {
            dirLoadState = .failed("Could not read library at \(url.path).\n\(error.localizedDescription)")
        }
        recomputeThumbTotal()
    }

    func reloadDirectoryIfSet() async {
        guard let url = prefs.defaultLibraryDir else { dirLoadState = .empty; return }
        await openDirectory(url)
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
