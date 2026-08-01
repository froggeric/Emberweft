import Foundation

/// A pure, serializable filter over `[LibraryEntry]`. Semantics documented so the
/// UI matches the tests exactly.
public struct LibraryFilter: Sendable, Hashable {

    /// Matches `LibraryEntry.displayName`, case-insensitive (substring).
    public var searchText: String = ""

    /// Restrict to a sentiment: −1 dislike / 0 neutral / +1 like. `nil` ⇒ any.
    public var sentiment: Int? = nil

    /// `CuratorRank.category` OR the heuristic `facet.category` to match exactly
    /// (`nil` ⇒ any). Every genome is categorizeable (curated via rank, others via
    /// the heuristic facet).
    public var category: String? = nil

    /// 0…11 hue bucket to match (`nil` ⇒ any). Requires a cached facet; entries
    /// without a facet are **excluded** (never force-parsed).
    public var hueBucket: Int? = nil

    public var requireFacet: Bool { hueBucket != nil }

    public init() {}

    /// True when the filter is the no-op (passes everything).
    public var isEmpty: Bool {
        searchText.isEmpty && sentiment == nil && category == nil && hueBucket == nil
    }
}

/// Pure membership test for one entry. Deterministic (rule #2 — only membership
/// checks, no float sums).
public func passes(_ f: LibraryFilter,
                   entry: LibraryEntry,
                   metadata: GenomeMetadata,
                   facet: GenomeFacet?) -> Bool {
    if !f.searchText.isEmpty,
       !entry.displayName.localizedCaseInsensitiveContains(f.searchText) {
        return false
    }
    if let s = f.sentiment, metadata.sentiment != s { return false }
    if let cat = f.category {
        let effective = entry.rank?.category ?? facet?.category
        guard effective == cat else { return false }
    }
    if let hb = f.hueBucket {
        guard let facet, facet.hueBucket == hb else { return false }   // no facet ⇒ excluded
    }
    return true
}

/// Apply `f` to `entries`, preserving source order.
public func applyFilter(_ f: LibraryFilter,
                        to entries: [LibraryEntry],
                        metadata: (LibraryEntry) -> GenomeMetadata,
                        facet: (LibraryEntry) -> GenomeFacet?) -> [LibraryEntry] {
    entries.filter { passes(f, entry: $0, metadata: metadata($0), facet: facet($0)) }
}
