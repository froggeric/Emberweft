import Foundation
import FlameKit

/// A cheap, deterministic palette signature for a genome, used as a filter facet.
/// `hue` is `FeatureVector.paletteMeanHue` (HSV hue ∈ [0,1), 0 for achromatic);
/// `luma` is `paletteMeanLuma` (Rec.709 ∈ [0,1]).
public struct GenomeFacet: Codable, Sendable, Hashable {
    public let hue: Double
    public let luma: Double

    public init(hue: Double, luma: Double) { self.hue = hue; self.luma = luma }

    /// 12 hue buckets (0…11), clamped defensively.
    public var hueBucket: Int {
        let b = Int((hue * 12).truncatingRemainder(dividingBy: 12))
        return min(max(b, 0), 11)
    }

    /// Compute from an already-parsed `Flame` (one `FeatureVector` pass — pure +
    /// deterministic, rule #2). Never forces a parse.
    public static func from(_ flame: Flame) -> GenomeFacet {
        let fv = FeatureVector(for: flame)
        return GenomeFacet(hue: fv.paletteMeanHue, luma: fv.paletteMeanLuma)
    }
}

/// Lazy palette-facet cache, keyed by `MetadataStore.metadataKey(for:)`. Facets
/// are computed **only when a `Flame` is already in hand** (thumbnail render, or
/// the one-shot bundle precompute) — never on demand, so a palette filter on a
/// 47k-folder never forces a mass parse.
@MainActor
@Observable
public final class FacetCache {
    public private(set) var facets: [String: GenomeFacet] = [:]

    public init() {}

    /// Compute + cache the facet IF absent (idempotent; never overwrites). The
    /// caller supplies a `Flame` it already has — this does NOT parse.
    public func putIfAbsent(for entry: LibraryEntry, flame: Flame) {
        let key = MetadataStore.metadataKey(for: entry)
        if facets[key] == nil { facets[key] = GenomeFacet.from(flame) }
    }

    public func facet(for entry: LibraryEntry) -> GenomeFacet? {
        facets[MetadataStore.metadataKey(for: entry)]
    }
}
