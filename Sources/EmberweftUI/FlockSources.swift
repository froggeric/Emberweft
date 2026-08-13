import Foundation

// Flock source resolution helpers (M6.5). The Flock builders (Generate source /
// Stitch sequence) source their genomes from the in-app library — Favorites
// (Liked), collections (playlists), or the active multi-selection — instead of
// an `NSOpenPanel` file pick. This file holds the pure, rule-#2-critical piece:
// the DETERMINISTIC ORDERING of an unordered entry set into the stable sequence
// the Flock coordinators consume.

/// Canonical ordering helpers for `LibrarySource`. The `(rank, path)` sort key
/// is the single source of truth used by BOTH `AppModel.unifiedEntries` (the
/// sidebar "All" grid) AND `flockSortedSources` (the Flock source list), so the
/// sidebar and the Flock picker always agree on entry order. Pure; never reads
/// hash order (rule #2).
public enum LibrarySourceOrder {
    /// bundle < directory < imported (stable across launches/machines).
    public static func rank(_ s: LibrarySource) -> Int {
        switch s {
        case .bundle: return 0
        case .directory: return 1
        case .imported: return 2
        }
    }
    /// The directory's root path (disambiguator between opened folders), or ""
    /// for the single-namespace sources (bundle/imported).
    public static func path(_ s: LibrarySource) -> String {
        switch s {
        case .bundle: return ""
        case .directory(let url): return url.path
        case .imported: return ""
        }
    }
}

/// Deterministic ordering for an unordered set of library entries destined for a
/// Flock source list (Favorites / the multi-selection). Sort key
/// `(sourceRank, sourcePath, id)` — bundle < directory < imported, then the
/// directory root path, then the entry id. Pure and rule-#2-safe: the same input
/// always yields the same output regardless of how the entries were gathered
/// (Favorites come from a cross-section scan; the selection is a `Set` — both
/// would be hash-ordered without this).
///
/// Collections are NOT routed through this: their stored `entries` array IS the
/// sequence (its order is user-meaningful), so the caller resolves them via
/// `AppModel.resolvedPairs(for:)` and preserves that order verbatim.
public func flockSortedSources(_ entries: [LibraryEntry]) -> [LibraryEntry] {
    entries.sorted {
        let a = (LibrarySourceOrder.rank($0.source), LibrarySourceOrder.path($0.source), $0.id)
        let b = (LibrarySourceOrder.rank($1.source), LibrarySourceOrder.path($1.source), $1.id)
        return a < b
    }
}
