import Foundation

/// One browsable genome in the library grid.
///
/// `id` is **deterministic per source**: for `.bundle`, the genome filename stem;
/// for `.directory`, the source path relative to the scanned root with `.flam3`
/// stripped and path separators collapsed to `__` (mirrors `FeatureCache.sheepID`
/// so bundle and user-library ids never collide). The grid sections cells by
/// `source`, so two sources never share an id namespace in the UI.
public struct LibraryEntry: Sendable, Identifiable, Hashable {
    public let id: String
    public let source: LibrarySource
    /// Absolute URL of the `.flam3` file (for parse-on-click).
    public let fileURL: URL
    /// File stem — the only display label available without parsing (`Flame` has
    /// no UI metadata today, only a render-relevant `name`).
    public let displayName: String
    /// Offline curation rank, or `nil` when no sidecar data exists (user dir, or
    /// an unranked bundled genome).
    public let rank: CuratorRank?
    /// `nil` until the genome is first parsed; thereafter the `isRenderable` result.
    public var healthKnownRenderable: Bool?

    public init(id: String,
                source: LibrarySource,
                fileURL: URL,
                displayName: String,
                rank: CuratorRank?,
                healthKnownRenderable: Bool? = nil) {
        self.id = id
        self.source = source
        self.fileURL = fileURL
        self.displayName = displayName
        self.rank = rank
        self.healthKnownRenderable = healthKnownRenderable
    }
}
