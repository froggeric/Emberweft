import Foundation
import FlameKit

/// A cheap, deterministic per-genome signature used as filter facets:
/// - `hue`: the dominant HSV hue. Initially from the palette (instant); refined
///   from the **rendered thumbnail** pixels when available (matches what the user
///   sees — the palette mean is only a proxy, since the chaos game may hit only a
///   slice of the palette).
/// - `luma`: mean Rec.709 luma of the palette.
/// - `category`: a heuristic structural category (spiral/radial/filament/dense/
///   other) from the genome's variation set, so EVERY genome is categorizeable —
///   not just the curated bundle (which carries an accurate, vision-assigned
///   `CuratorRank.category` used first by the filter).
public struct GenomeFacet: Codable, Sendable, Hashable {
    public var hue: Double
    public var luma: Double
    public var category: String

    public init(hue: Double, luma: Double, category: String) {
        self.hue = hue; self.luma = luma; self.category = category
    }

    /// 12 hue buckets (0…11), clamped defensively.
    public var hueBucket: Int {
        let b = Int((hue * 12).truncatingRemainder(dividingBy: 12))
        return min(max(b, 0), 11)
    }

    /// Compute from an already-parsed `Flame`: hue/luma from the palette (instant,
    /// approximate) + the heuristic category. Pure + deterministic (rule #2).
    public static func from(_ flame: Flame) -> GenomeFacet {
        let fv = FeatureVector(for: flame)
        return GenomeFacet(hue: fv.paletteMeanHue, luma: fv.paletteMeanLuma,
                           category: category(for: flame))
    }

    /// A heuristic structural category from the genome's weighted variation set.
    /// Crude (a true category needs vision), but gives every genome a bucket so the
    /// category filter works on arbitrary folders, not just the curated bundle.
    public static func category(for flame: Flame) -> String {
        var w: [String: Double] = [:]
        var all = flame.xforms
        if let fx = flame.finalXform { all.append(fx) }
        for xf in all {
            for v in xf.variations where v.weight > 0 { w[v.name, default: 0] += v.weight }
        }
        func sum(_ names: Set<String>) -> Double {
            w.reduce(0) { $0 + (names.contains($1.key) ? $1.value : 0) }
        }
        let spiral    = sum(["spiral", "swirl", "horseshoe", "hypertile", "hyperbolic",
                             "curve", "bent2", "sech"])
        let radial    = sum(["radial_blur", "pie", "wedge", "flower", "disc", "rings2",
                             "rings", "butterfly", "clover", "popcorn", "popcorn2", " julia"])
        let filament  = sum(["fisheye", "eyefish", "spherical", "curl", "curl3d", "noise",
                             "linear3d", "bipolar", "tan", "sinusoidal", "lazysusan"])
        let dense     = sum(["blur", "gaussian_blur", "circleblur", "pre_blur", "exp",
                             "exponential", "cosine", "square", "bubble"])
        let best = max(spiral, radial, filament, dense)
        guard best > 0 else { return "other" }
        if spiral >= radial && spiral >= filament && spiral >= dense { return "spiral" }
        if radial >= filament && radial >= dense { return "radial" }
        if filament >= dense { return "filament" }
        return "dense"
    }

    /// Mean HSV hue of a rendered thumbnail's non-background pixels (matches the
    /// perceived dominant color better than the palette mean). Pure.
    public static func hue(from image: RGBA8Image) -> Double {
        let p = image.pixels
        var hueSum = 0.0
        var count = 0
        var i = 0
        while i + 3 < p.count {
            let r = Double(p[i]) / 255.0, g = Double(p[i + 1]) / 255.0, b = Double(p[i + 2]) / 255.0
            i += 4
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            let d = mx - mn
            // Skip near-achromatic and near-black (background) pixels.
            guard d >= 0.12, mx >= 0.05 else { continue }
            var h: Double
            if mx == r {
                h = (g - b) / d
                if g < b { h += 6.0 }
            } else if mx == g {
                h = (b - r) / d + 2.0
            } else {
                h = (r - g) / d + 4.0
            }
            hueSum += h / 6.0
            count += 1
        }
        guard count > 0 else { return 0 }
        return hueSum / Double(count)
    }
}

/// Lazy facet cache, keyed by `MetadataStore.metadataKey(for:)`. Facets are
/// computed **only when a Flame or rendered thumbnail is already in hand** — never
/// on demand, so a palette/category filter on a 47k-folder never forces a mass
/// parse or mass render.
@MainActor
@Observable
public final class FacetCache {
    public private(set) var facets: [String: GenomeFacet] = [:]

    public init() {}

    /// Compute + cache the facet IF absent (idempotent; never overwrites). Supplies
    /// palette hue + heuristic category before any render. Caller supplies a `Flame`
    /// it already has — this does NOT parse.
    public func putIfAbsent(for entry: LibraryEntry, flame: Flame) {
        let key = MetadataStore.metadataKey(for: entry)
        if facets[key] == nil { facets[key] = GenomeFacet.from(flame) }
    }

    /// Refine the hue from a rendered thumbnail (more accurate than the palette
    /// mean). Keeps the heuristic category. Called after a thumbnail renders.
    public func refine(for entry: LibraryEntry, image: RGBA8Image) {
        let key = MetadataStore.metadataKey(for: entry)
        var f = facets[key] ?? GenomeFacet(hue: 0, luma: 0, category: "other")
        f.hue = GenomeFacet.hue(from: image)
        facets[key] = f
    }

    public func facet(for entry: LibraryEntry) -> GenomeFacet? {
        facets[MetadataStore.metadataKey(for: entry)]
    }
}
