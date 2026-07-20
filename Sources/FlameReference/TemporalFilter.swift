import Foundation
import FlameKit

/// Faithful port of flam3's `flam3_create_temporal_filter`
/// (`/tmp/flam3/filters.c:409-489`). Produces N (delta, weight) sub-samples
/// across a ±width/2 frame window + the `sumfilt` scalar (Σweights/N) that the
/// caller threads into ToneMapping's k2.
///
/// `delta` is in frames (added to the frame's center time); `weight` scales the
/// sub-pass's dmap via `color_scalar` (rect.c:757, 778-782). Weights are
/// UN-NORMALIZED — box weights are each literally 1.0 (so a box sub-pass is
/// byte-identical to the existing single-pass iterate); gaussian and exp
/// weights are max-normalized to 1.0. The caller MUST NOT re-normalize.
public enum TemporalFilter {
    public static func samples(
        _ n: Int, type: FilterShape, width: Double, exp temporalExp: Double
    ) -> (samples: [(delta: Double, weight: Double)], sumfilt: Double) {
        let n = max(1, n)
        // flam3 uses `filter_width` directly (filters.c:434). Width 0 collapses
        // all sub-passes to the frame center (all-zero deltas); faithful, harmless.
        let w = width
        if n == 1 {
            // `flam3_create_temporal_filter` single-step identity (filters.c:423-430).
            return ([(delta: 0.0, weight: 1.0)], 1.0)
        }
        var deltas = [Double](repeating: 0, count: n)
        var filter = [Double](repeating: 0, count: n)
        // `deltas[i] = ((i/(n-1)) - 0.5) * filter_width` (filters.c:432-434).
        for i in 0..<n {
            deltas[i] = ((Double(i) / Double(n - 1)) - 0.5) * w
        }
        // Branch on `filter_type` (filters.c:436-474).
        switch type {
        case .exp:
            // filters.c:437-452. slpx direction depends on the sign of
            // `filter_exp`; `filter[i] = pow(slpx, |filter_exp|)`. maxfilt is
            // tracked in the original C loop but we use `filter.max()` below —
            // mathematically identical.
            for i in 0..<n {
                let slpx = temporalExp >= 0
                    ? (Double(i) + 1.0) / Double(n)
                    : Double(n - i) / Double(n)
                filter[i] = pow(slpx, abs(temporalExp))
            }
        case .gaussian:
            // filters.c:454-465: `filter[i] = flam3_spatial_filter(gaussian_kernel,
            //   flam3_spatial_support[gaussian_kernel] * |i - halfsteps| / halfsteps)`
            // — it REUSES the SPATIAL gaussian filter function (not a fresh exp).
            // halfsteps = n/2.0; support = 1.5 (`flam3_spatial_support[gaussian]`,
            // filters.c:31).
            let halfsteps = Double(n) / 2.0
            let support = 1.5
            for i in 0..<n {
                let arg = support * abs(Double(i) - halfsteps) / halfsteps
                // `flam3_gaussian_filter` (filters.c:156-158): exp(-2x²) · sqrt(2/π).
                filter[i] = exp(-2.0 * arg * arg) * (2.0 / Double.pi).squareRoot()
            }
        case .box:
            // filters.c:467-473 — every weight is literally 1.0 (NOT 1/N);
            // `maxfilt = 1.0` is set explicitly in flam3 but is also just `filter.max()`.
            for i in 0..<n { filter[i] = 1.0 }
        }
        // filters.c:476-483 — divide every weight by `maxfilt` (so max → 1.0),
        // then `sumfilt = Σ adjusted weights / numsteps`.
        let maxfilt = filter.max() ?? 1.0
        var sumfilt = 0.0
        for i in 0..<n {
            filter[i] /= maxfilt
            sumfilt += filter[i]
        }
        sumfilt /= Double(n)
        let out = (0..<n).map { i in (delta: deltas[i], weight: filter[i]) }
        return (out, sumfilt)
    }
}
