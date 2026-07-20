import Foundation
import FlameKit

/// Façade tying the full CPU reference pipeline together:
/// chaos game → density estimation → tone map → `RGBA8Image`.
///
/// Deterministic: the same `(flame, params)` always yields an identical image.
public enum ReferenceRenderer {
    /// Render `flame` at `params` to an 8-bit RGBA image.
    public static func render(flame: Flame, params: RenderParams) -> RGBA8Image {
        var hist = ChaosGame.iterate(flame: flame, params: params)
        if flame.quality.estimatorRadius > 0 {
            hist = DensityEstimation.apply(hist,
                radius: flame.quality.estimatorRadius,
                minimum: flame.quality.estimatorMinimum,
                curve: flame.quality.estimatorCurveRate)
        }
        return ToneMapping.render(histogram: hist,
            width: params.width, height: params.height, oversample: params.oversample,
            gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
            vibrancy: flame.quality.vibrancy,
            brightness: flame.quality.brightness,
            sampleDensity: Double(params.samplesPerPixel),
            pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom))
    }

    /// Temporal motion-blur render: faithful port of flam3's `temporal_samples`
    /// loop (rect.c:754-905). Runs N chaos sub-passes at sub-times across a
    /// ±width/2 window, each with `samplesPerPixel/N` budget and
    /// `color_scalar = weight` baked into its dmap, then accumulates into one
    /// histogram. DE + tone-map run ONCE. Cost-neutral (rect.c:833).
    ///
    /// For a box filter every `weight` is 1.0 and `sumfilt=1.0`, so the per-pass
    /// `colorScalar` is 1.0 and `k2` is unchanged — the brightness math collapses
    /// to the single-pass case (only the per-pass ISAAC seed salt differs,
    /// contributing only Monte-Carlo shot noise). For gaussian/exp the weighted
    /// `colorScalar` is exactly canceled by `sumfilt` in `k2`, preserving total
    /// light by construction.
    ///
    /// - Parameters:
    ///   - blendAt: returns the `Flame` at a given time (time in frames; the
    ///     caller adds each sub-sample's `delta` to `centerTime`).
    ///   - centerTime: the frame's center time, passed to `blendAt`. Quality /
    ///     camera params for the center flame drive DE + tone-map.
    ///   - temporal: the `(delta, weight)` sub-samples from `TemporalFilter.samples`.
    ///   - sumfilt: the temporal filter's `Σweights/N`, threaded into `k2`
    ///     (rect.c:937). Box → 1.0; pass through unchanged.
    ///   - params: the base render params. `samplesPerPixel` is split across the
    ///     N sub-passes (rect.c:833); `sampleDensity` passed to tone-map is the
    ///     ORIGINAL value, matching flam3's `k2` formula.
    public static func render(
        blendAt: (Double) -> Flame,
        centerTime: Double,
        temporal: [(delta: Double, weight: Double)],
        sumfilt: Double,
        params: RenderParams
    ) -> RGBA8Image {
        precondition(!temporal.isEmpty,
            "ReferenceRenderer.render(blendAt:…): temporal must contain at least one sub-sample")
        let center = blendAt(centerTime)
        let N = temporal.count
        // Budget split (rect.c:833). Distribute the integer remainder across the
        // first `rem` passes so the total budget is exact when samplesPerPixel ≥ N
        // (the real-genome regime: spp≈100–1000, N≤64); passes beyond spp are
        // skipped below (flam3 truncates — per-pass budget of 0 fires no samples).
        let base = params.samplesPerPixel / N
        let rem  = params.samplesPerPixel % N
        var hist = Histogram(gridWidth: params.gridWidth, gridHeight: params.gridHeight)
        for (i, sub) in temporal.enumerated() {
            let perPass = base + (i < rem ? 1 : 0)
            guard perPass > 0 else { continue }   // samplesPerPixel < N: flam3 truncates; don't fire the iterate safety-strap
            let passParams = params.settingSamplesPerPixel(perPass)
            let g = blendAt(centerTime + sub.delta)
            // Per-pass ISAAC seed salt — only when N>1. For N=1 the path must
            // reduce EXACTLY to the single-pass `render(flame:params:)`, which
            // requires `iterate(isaacSeed: goldenIsaacSeed)`; any salt would
            // perturb the ISAAC stream and break byte-identity with the existing
            // goldens. For N>1 the salt decorrelates trajectories (the CPU
            // iterate is otherwise pinned to `goldenIsaacSeed`, so N unsalted
            // passes would draw identical streams → biased accumulator, no blur).
            let passSeed = N == 1
                ? ChaosGame.goldenIsaacSeed
                : "\(ChaosGame.goldenIsaacSeed)-tmp\(i)"
            // Per-pass `color_scalar` baked into the dmap (rect.c:757, 778-782):
            // colors AND alpha carry the weight automatically via the dmap lookup.
            // Count increments UNWEIGHTED (rect.c:501-505) — already true in
            // ChaosGame.iterate; do NOT post-scale the histogram by weight.
            let subHist = ChaosGame.iterate(
                flame: g, params: passParams,
                isaacSeed: passSeed,
                colorScalar: sub.weight)
            hist.accumulate(subHist)
        }
        let h = center.quality.estimatorRadius > 0
            ? DensityEstimation.apply(hist,
                radius: center.quality.estimatorRadius,
                minimum: center.quality.estimatorMinimum,
                curve: center.quality.estimatorCurveRate)
            : hist
        // `sampleDensity` is the ORIGINAL `params.samplesPerPixel`, NOT `perPass`:
        // this matches flam3's `k2` (rect.c:935-937), where `sample_density` is the
        // frame-level density, not the per-sub-pass count. The per-pass budget
        // only governs how many chaos samples each sub-pass fires.
        return ToneMapping.render(histogram: h,
            width: params.width, height: params.height, oversample: params.oversample,
            gamma: center.quality.gamma, gammaThreshold: center.quality.gammaThreshold,
            vibrancy: center.quality.vibrancy,
            brightness: center.quality.brightness,
            sampleDensity: Double(params.samplesPerPixel),
            pixelsPerUnit: center.camera.scale * pow(2, center.camera.zoom),
            sumfilt: sumfilt)
    }
}
