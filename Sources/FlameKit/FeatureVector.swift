import Foundation

/// Per-sheep feature vector for similarity-based pair selection (Task 16).
///
/// # F1 DETERMINISM (load-bearing)
/// Swift `Dictionary<String,_>` / `Set<String>` hashing is **per-process
/// randomized**. Any floating-point accumulation that iterates a String-keyed
/// collection diverges across process launches. This type stores EVERY
/// floating-point component in a deterministic iteration order:
///   - the variation-set component is a lexicographically-sorted
///     `(name, weight)` array; `similarity(to:)` walks it via a sorted merge,
///     NEVER a `Dictionary`/`Set`;
///   - all other components are order-independent scalars.
/// This is what makes `similarity(a, b)` bit-identical across N separate
/// process launches (the cross-process bit-identity acceptance test).
///
/// # F9 ε-GUARDS
/// Every term has an independent ε fallback so an all-zero palette, a zero-norm
/// affine, or an empty variation set cannot NaN the score.
public struct FeatureVector: Sendable {
    /// Variation-set fingerprint: total variation weight per name, sorted by
    /// name (lexicographic). Built from `xforms` + `finalXform`. Stored as a
    /// sorted array so the cosine merge is iteration-order independent.
    public let variations: [(name: String, weight: Double)]

    /// Palette mean hue in [0,1) (HSV hue). ε-guarded to 0 for achromatic.
    public let paletteMeanHue: Double
    /// Palette mean luma in [0,1] (Rec-709). ε-guarded to 0 if non-finite.
    public let paletteMeanLuma: Double

    /// Number of (non-final) xforms.
    public let xformCount: Int
    /// Summed Frobenius norm of xform linear parts (a,b,c,d). ε-guarded to 0.
    public let summedAffineFrobenius: Double

    public init(
        variations: [(name: String, weight: Double)],
        paletteMeanHue: Double,
        paletteMeanLuma: Double,
        xformCount: Int,
        summedAffineFrobenius: Double
    ) {
        self.variations = variations
        self.paletteMeanHue = paletteMeanHue
        self.paletteMeanLuma = paletteMeanLuma
        self.xformCount = xformCount
        self.summedAffineFrobenius = summedAffineFrobenius
    }

    /// Build a feature vector from a flame genome.
    ///
    /// The variation-set aggregate is built by iterating the `xforms` ARRAY
    /// (deterministic); the `Dictionary` is only the accumulator destination.
    /// The FP sums that feed the metric iterate the sorted array in
    /// `similarity(to:)`, never the dict — this is the F1-compliant pattern.
    public init(for flame: Flame) {
        // --- variation-set: aggregate per-name weight by iterating the xform
        // array (deterministic order). Dict is accumulator only.
        var bag: [String: Double] = [:]
        for xf in flame.xforms {
            for v in xf.variations {
                bag[v.name, default: 0] += v.weight
            }
        }
        if let fx = flame.finalXform {
            for v in fx.variations {
                bag[v.name, default: 0] += v.weight
            }
        }
        // Sort by name → fixed iteration order for the cosine merge.
        let sortedVars = bag.sorted { $0.key < $1.key }
            .map { (name: $0.key, weight: $0.value) }

        // --- palette mean hue / luma (iterate the colors array — deterministic)
        var hue = 0.0, luma = 0.0
        let n = flame.palette.colors.count
        if n > 0 {
            for c in flame.palette.colors {
                hue += FeatureVector.hue(c)
                luma += 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            }
            hue /= Double(n)
            luma /= Double(n)
        }
        let meanHue = hue.truncatingRemainder(dividingBy: 1.0)
        let meanHueGuarded = meanHue.isFinite ? meanHue : 0.0
        let meanLuma = luma.isFinite ? luma : 0.0

        // --- summed affine Frobenius (iterate xforms array)
        var frob = 0.0
        for xf in flame.xforms {
            let a = xf.affine
            frob += (a.a * a.a + a.b * a.b + a.c * a.c + a.d * a.d).squareRoot()
        }
        let frobGuarded = frob.isFinite ? frob : 0.0

        self.init(
            variations: sortedVars,
            paletteMeanHue: meanHueGuarded,
            paletteMeanLuma: meanLuma,
            xformCount: flame.xforms.count,
            summedAffineFrobenius: frobGuarded
        )
    }

    /// RGB in [0,1] → HSV hue in [0,1). ε-guarded for achromatic pixels.
    static func hue(_ rgb: SIMD3<Double>) -> Double {
        let (r, g, b) = (rgb.x, rgb.y, rgb.z)
        let mx = max(r, max(g, b))
        let mn = min(r, min(g, b))
        let d = mx - mn
        if d < 1e-12 { return 0.0 }       // achromatic — ε fallback (F9)
        var h: Double
        if mx == r {
            h = (g - b) / d
            if g < b { h += 6.0 }
        } else if mx == g {
            h = (b - r) / d + 2.0
        } else {
            h = (r - g) / d + 4.0
        }
        h /= 6.0
        return h.isFinite ? h : 0.0
    }

    /// Similarity score in [0,1] (higher = more similar). Combines four
    /// ε-guarded terms: variation-set cosine, palette hue/luma, xform-count,
    /// summed affine Frobenius.
    ///
    /// F1: the variation-set cosine walks `variations` (sorted arrays) via a
    /// two-pointer merge — no String-keyed Dict/Set in the accumulation path.
    /// Deterministic across process launches.
    public func similarity(to other: FeatureVector) -> Double {
        let eps = 1e-12

        // --- variation-set cosine via sorted-array merge (F1-critical path)
        var dot = 0.0, na = 0.0, nb = 0.0
        var i = 0, j = 0
        let A = self.variations, B = other.variations
        while i < A.count && j < B.count {
            if A[i].name == B[j].name {
                dot += A[i].weight * B[j].weight
                na += A[i].weight * A[i].weight
                nb += B[j].weight * B[j].weight
                i += 1; j += 1
            } else if A[i].name < B[j].name {
                na += A[i].weight * A[i].weight
                i += 1
            } else {
                nb += B[j].weight * B[j].weight
                j += 1
            }
        }
        while i < A.count { na += A[i].weight * A[i].weight; i += 1 }
        while j < B.count { nb += B[j].weight * B[j].weight; j += 1 }
        // ε-guarded denom: zero-norm vectors → varCos = 0 (neutral), never NaN.
        let denom = (na.squareRoot() + eps) * (nb.squareRoot() + eps)
        let varCos = dot / denom                  // weights ≥ 0 → [0,1]
        let varSim = 0.5 + 0.5 * varCos           // [0,1]

        // --- palette hue (circular distance) + luma
        let rawHue = abs(self.paletteMeanHue - other.paletteMeanHue)
        let hueDiff = min(rawHue, 1.0 - rawHue)
        let lumaDiff = abs(self.paletteMeanLuma - other.paletteMeanLuma)
        let palSim = 1.0 / (1.0 + hueDiff + lumaDiff)   // (0,1]

        // --- xform count
        let countDiff = Double(abs(self.xformCount - other.xformCount))
        let countSim = 1.0 / (1.0 + countDiff)          // (0,1]

        // --- summed affine Frobenius (scale-normalized)
        let scale = 1.0 + self.summedAffineFrobenius
                    + other.summedAffineFrobenius + eps
        let affDiff = abs(self.summedAffineFrobenius - other.summedAffineFrobenius)
        let affSim = 1.0 / (1.0 + affDiff / scale)      // (0,1]

        let score = 0.5 * varSim + 0.2 * palSim
                  + 0.15 * countSim + 0.15 * affSim
        return score.isFinite ? score : 0.0
    }
}
