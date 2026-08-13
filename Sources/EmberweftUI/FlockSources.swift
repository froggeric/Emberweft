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

/// The ES `(gen,id)` parsed from an ES-archive filename
/// `electricsheep.<gen>.<id>.flam3`, or nil if this entry is NOT ES-sourced
/// (user import with an arbitrary name). Used so ES genomes keep their real
/// identity (D7) instead of being minted into flock 900000.
///
/// Strict: the full filename must be exactly 4 dot-separated parts
/// `["electricsheep", <numeric gen>, <numeric id>, "flam3"]`. A wrong prefix,
/// non-numeric gen/id, wrong extension, or extra/fewer dots ⇒ nil ⇒ mint.
/// Preserves zero-padding verbatim (e.g. id `"08200"`). Pure; rule-#2-safe
/// (the parse never touches hash order).
public func esIdentity(for entry: LibraryEntry) -> (gen: String, id: String)? {
    let parts = entry.fileURL.lastPathComponent
        .split(separator: ".").map(String.init)
    guard parts.count == 4,
          parts[0] == "electricsheep",
          parts[3] == "flam3",
          parts[1].allSatisfy(\.isNumber),
          parts[2].allSatisfy(\.isNumber)
    else { return nil }
    return (gen: parts[1], id: parts[2])
}
