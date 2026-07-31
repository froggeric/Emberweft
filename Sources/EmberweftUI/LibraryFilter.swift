import Foundation

/// A pure, serializable filter over `[LibraryEntry]`. All semantics are
/// documented so the UI matches the tests exactly.
public struct LibraryFilter: Sendable, Hashable {

    /// Matches `LibraryEntry.displayName`, case-insensitive (substring).
    public var searchText: String = ""

    /// **AND** semantics: an entry's tags must include *all* selected tags
    /// (case-insensitive). Empty set ⇒ passes all.
    public var selectedTags: Set<String> = []

    /// Entry's `rating` must be ≥ this. 0 ⇒ no constraint.
    public var minRating: Int = 0

    /// If true, only favorites.
    public var favoritesOnly: Bool = false

    /// `CuratorRank.category` to match exactly (bundle-only; `nil` ⇒ any). A
    /// directory entry has `rank == nil` and is excluded by a non-nil category.
    public var category: String? = nil

    /// 0…11 hue bucket to match (`nil` ⇒ any). Requires a cached facet; entries
    /// without a facet are **excluded** (never force-parsed).
    public var hueBucket: Int? = nil

    public var requireFacet: Bool { hueBucket != nil }

    public init() {}

    /// True when the filter is the no-op (passes everything).
    public var isEmpty: Bool {
        searchText.isEmpty && selectedTags.isEmpty && minRating == 0
            && !favoritesOnly && category == nil && hueBucket == nil
    }
}

/// Pure membership test for one entry. Deterministic (rule #2 — only membership
/// checks over `Set<String>`, no float sums).
public func passes(_ f: LibraryFilter,
                   entry: LibraryEntry,
                   metadata: GenomeMetadata,
                   facet: GenomeFacet?) -> Bool {
    if !f.searchText.isEmpty,
       !entry.displayName.localizedCaseInsensitiveContains(f.searchText) {
        return false
    }
    if !f.selectedTags.isEmpty {
        let entryTags = Set(metadata.tags.map { $0.lowercased() })
        for t in f.selectedTags where !entryTags.contains(t.lowercased()) { return false }
    }
    if metadata.rating < f.minRating { return false }
    if f.favoritesOnly && !metadata.favorite { return false }
    if let cat = f.category {
        // Curated genomes carry an accurate vision `rank.category`; others fall
        // back to the heuristic `facet.category`. Every genome is categorizeable.
        let effective = entry.rank?.category ?? facet?.category
        guard effective == cat else { return false }
    }
    if let hb = f.hueBucket {
        // No cached facet ⇒ excluded (never force a parse).
        guard let facet, facet.hueBucket == hb else { return false }
    }
    return true
}

/// Apply `f` to `entries`, preserving source order. The `metadata` / `facet`
/// lookups are injected so the predicate stays pure and testable without the
/// `@MainActor` stores.
public func applyFilter(_ f: LibraryFilter,
                        to entries: [LibraryEntry],
                        metadata: (LibraryEntry) -> GenomeMetadata,
                        facet: (LibraryEntry) -> GenomeFacet?) -> [LibraryEntry] {
    entries.filter { passes(f, entry: $0, metadata: metadata($0), facet: facet($0)) }
}
