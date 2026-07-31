import Foundation

/// Offline curation metadata for a genome, read from the bundled `ranking.json`
/// sidecar. Produced by the separate curation pipeline (filter → thumbnail →
/// heuristic score → vision refine); the app only consumes it.
public struct CuratorRank: Sendable, Codable, Hashable {
    /// Editorial category: "spiral" | "radial" | "filament" | "dense" | "other".
    public let category: String
    /// Heuristic pleasantness in [0, 1]; deterministic (rule #2).
    public let score: Double
    /// True if the offline vision shortlist included this genome.
    public let visionShortlist: Bool

    public init(category: String, score: Double, visionShortlist: Bool) {
        self.category = category
        self.score = score
        self.visionShortlist = visionShortlist
    }
}

/// On-disk shape of `CuratedLibrary/ranking.json`. Unknown entry keys (genomes
/// removed from the bundle) are ignored; missing keys ⇒ `rank == nil` (never an
/// error). `version` gates future migrations.
struct RankingFile: Codable, Sendable {
    let version: Int
    let entries: [String: CuratorRank]
}
