import Foundation
import SwiftUI
import EmberweftUI
import FlameKit

/// App-wide, MainActor-owned state: preferences, the shared library index +
/// thumbnail service, and the grid load states. Owned by `EmberweftApp`.
@MainActor
@Observable
final class AppModel {

    /// Persisted user settings.
    var prefs: AppPreferences

    let libraryIndex = LibraryIndex()
    let thumbnailService: ThumbnailService
    let metadataStore: MetadataStore

    /// The bundled curated library resource root (`CuratedLibrary/`).
    private let bundleRoot: URL?

    var bundleLoadState: LoadState = .loading
    var dirLoadState: LoadState = .empty

    /// Thumbnail-render progress: ids whose thumbnail has resolved this session,
    /// and the total count of currently-listed entries. Approximate (scroll
    /// remounts cells, but cache hits are still counted as resolved). Drives the
    /// grid's progress indicator.
    var renderedThumbIDs: Set<String> = []
    var thumbTotal: Int = 0

    func markThumbResolved(_ id: String) {
        renderedThumbIDs.insert(id)
    }

    /// Remove a genome from the grid (both sections). Used to exclude degenerate
    /// (all-black / NaN-camera) genomes so they don't appear at all — per the
    /// data-integrity class documented in CLAUDE.md, they're not real candidates.
    func hideEntry(_ id: String) {
        bundleLoadState = filtering(out: id, in: bundleLoadState)
        dirLoadState = filtering(out: id, in: dirLoadState)
        renderedThumbIDs.remove(id)
        recomputeThumbTotal()
    }

    private func filtering(out id: String, in state: LoadState) -> LoadState {
        guard case .ready(let entries) = state else { return state }
        let filtered = entries.filter { $0.id != id }
        return filtered.isEmpty ? .empty : .ready(filtered)
    }

    /// Number of entries shown across the loaded sections.
    func recomputeThumbTotal() {
        var n = 0
        if case .ready(let e) = bundleLoadState { n += e.count }
        if case .ready(let e) = dirLoadState { n += e.count }
        thumbTotal = n
    }

    init() {
        let (loaded, _) = AppPreferences.loadResilient()
        self.prefs = loaded
        self.bundleRoot = Bundle.module.url(forResource: "CuratedLibrary", withExtension: nil)
        let thumbs = AppPreferences.defaultDirectory.appendingPathComponent("thumbs", isDirectory: true)
        // ThumbnailService is an actor; its init creates the dir.
        self.thumbnailService = ThumbnailService(cacheDirectory: thumbs)
        let (mdStore, _) = MetadataStore.loadResilient()
        self.metadataStore = mdStore
    }

    /// Favorite entries across all loaded sections (bundle + directory), in source
    /// order. @Observable-tracked (reads `metadataStore.entries` + the load states)
    /// so the Favorites section re-renders when a favorite is toggled.
    func favoriteEntries() -> [LibraryEntry] {
        var out: [LibraryEntry] = []
        for state in [bundleLoadState, dirLoadState] {
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
        recomputeThumbTotal()
    }

    func openDirectory(_ url: URL) async {
        prefs.defaultLibraryDir = url
        try? prefs.save()
        dirLoadState = .loading
        renderedThumbIDs.removeAll()
        do {
            let entries = try await libraryIndex.scanDirectory(url)
            dirLoadState = entries.isEmpty ? .empty : .ready(entries)
        } catch {
            dirLoadState = .failed("Could not read library at \(url.path).\n\(error.localizedDescription)")
        }
        recomputeThumbTotal()
    }

    func reloadDirectoryIfSet() async {
        guard let url = prefs.defaultLibraryDir else {
            dirLoadState = .empty
            return
        }
        await openDirectory(url)
    }
}
