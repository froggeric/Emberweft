import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

/// Readback-fidelity pins for the fused chaos histogram variants (T6).
///
/// `renderFusedCoreToHistogram` / `renderTemporalFusedCoreToHistogram` encode the
/// chaos stage ONLY, commit, read `atomicBuf` back to the CPU, and decode it via
/// `MetalHistogramDecode.decode` (T4) — returning the pre-DE Double `Histogram`
/// that T8 EMAs before calling T5's `applyCore`+`renderCore`. The readback path
/// round-trips the histogram through Doubles (uint32 → Double → Float repack in
/// applyCore/renderCore) whereas the inline fused path keeps it GPU-resident in
/// Float throughout (uint32 → Float via the `atomicBinToFloatBin` decode kernel).
/// The two should agree to within a very tight band — the only difference is the
/// Float-vs-Double division by `colorScale` in the decode step.
///
/// These tests pin that invariant: at α=1.0 (no EMA — the histogram feeds DE+
/// display directly), the readback → applyCore → renderCore output must match the
/// inline fused render within the `FusedUnfusedParityTests` parity band (≥ 50 dB
/// PSNR; the round-trip is high-PSNR, not byte-exact, because of the Double
/// division). The single-flame and temporal (motion-blur) variants are both pinned.
@MainActor
final class MetalReadbackHistogramTests: XCTestCase {

    /// `#filePath`-relative loader for frozen goldens in `Tests/Goldens/genomes/`.
    private func loadFrozen(_ name: String) throws -> Flame {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name).flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture missing: \(url.path)")
        }
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }

    /// PSNR over two RGBA8 pixel arrays (MAX = 255). Returns +∞ when identical.
    private func psnr(_ a: RGBA8Image, _ b: RGBA8Image) -> Double {
        precondition(a.pixels.count == b.pixels.count, "dimension mismatch")
        var mse: Double = 0
        for i in a.pixels.indices {
            let d = Double(a.pixels[i]) - Double(b.pixels[i])
            mse += d * d
        }
        mse /= Double(a.pixels.count)
        if mse == 0 { return .infinity }
        return 10 * log10((255.0 * 255.0) / mse)
    }

    // MARK: - Temporal (motion-blur) readback fidelity (§9.3)

    /// Temporal readback fidelity: at α=1.0,
    /// `renderTemporalHistogramOffMain → applyCore → renderCore` ≈ inline
    /// `MetalRenderer.render(blendAt:…)` within the parity band (≥ 50 dB). Uses a
    /// synthetic box temporal of 4 sub-samples (weight 1.0) on `sierpinski`, which
    /// exercises the per-pass loop (dmap rebuild, seed salt, budget split) that T6
    /// must replicate byte-identically from `renderTemporalFusedCore`.
    func testTemporalReadbackMatchesInlineFused() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try loadFrozen("sierpinski")
        let (temporal, sumfilt) = TemporalFilter.samples(4, type: .box, width: 1.0, exp: 0)
        let params = RenderParams(seed: 1, width: 160, height: 100,
                                  oversample: 1, samplesPerPixel: 200)

        // (a) Inline fused temporal render (the production path).
        let inline = MetalRenderer.render(
            blendAt: { _ in flame }, centerTime: 0.5, temporal: temporal,
            sumfilt: sumfilt, params: params)

        // (b) Readback path: chaos → readback → decode (T6) → DE (T5) → display (T5).
        // `blendAt` is `{ _ in flame }` so the center flame == flame; the display
        // params must match what `renderTemporalFusedCore` derives from the center
        // flame (gamma/brightness/etc. are frame-level). `p` mirrors the internal
        // `params.settingSpatialFilterRadius(center.quality.filterRadius)`.
        let p = params.settingSpatialFilterRadius(flame.quality.filterRadius)
        let hist = try XCTUnwrap(
            MetalRenderer.renderTemporalHistogramOffMain(
                blendAt: { _ in flame }, centerTime: 0.5, temporal: temporal,
                sumfilt: sumfilt, params: params),
            "off-main temporal readback must succeed (Metal available, box temporal)")
        let deRadius = flame.quality.estimatorRadius
        let deHist = deRadius > 0
            ? try DensityEstimationMetal.apply(
                hist, radius: deRadius,
                minimum: flame.quality.estimatorMinimum,
                curve: flame.quality.estimatorCurveRate)
            : hist
        let readback = try DisplayPipelineMetal.render(
            histogram: deHist, width: p.width, height: p.height, oversample: p.oversample,
            gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
            vibrancy: flame.quality.vibrancy, brightness: flame.quality.brightness,
            sampleDensity: Double(p.samplesPerPixel),
            pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom),
            highlightPower: flame.quality.highlightPower,
            spatialFilterRadius: p.spatialFilterRadius)

        let score = psnr(inline, readback)
        XCTAssertGreaterThanOrEqual(score, 50.0,
            "temporal readback → DE → display must match inline fused within ≥ 50 dB (got \(score) dB)")
    }

    // MARK: - Single-flame readback fidelity

    /// Single-flame readback fidelity: `renderHistogramOffMain → applyCore →
    /// renderCore` ≈ inline `MetalRenderer.render(flame:params:)` within the parity
    /// band. The single-pass variant is the degenerate temporal case (N=1).
    func testSingleFlameReadbackMatchesInlineFused() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try loadFrozen("sierpinski")
        let params = RenderParams(seed: 1, width: 160, height: 100,
                                  oversample: 1, samplesPerPixel: 200)

        let inline = MetalRenderer.render(flame: flame, params: params)

        let p = params.settingSpatialFilterRadius(flame.quality.filterRadius)
        let hist = try XCTUnwrap(
            MetalRenderer.renderHistogramOffMain(flame: flame, params: params),
            "off-main readback must succeed (Metal available)")
        let deRadius = flame.quality.estimatorRadius
        let deHist = deRadius > 0
            ? try DensityEstimationMetal.apply(
                hist, radius: deRadius,
                minimum: flame.quality.estimatorMinimum,
                curve: flame.quality.estimatorCurveRate)
            : hist
        let readback = try DisplayPipelineMetal.render(
            histogram: deHist, width: p.width, height: p.height, oversample: p.oversample,
            gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
            vibrancy: flame.quality.vibrancy, brightness: flame.quality.brightness,
            sampleDensity: Double(p.samplesPerPixel),
            pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom),
            highlightPower: flame.quality.highlightPower,
            spatialFilterRadius: p.spatialFilterRadius)

        let score = psnr(inline, readback)
        XCTAssertGreaterThanOrEqual(score, 50.0,
            "single-flame readback → DE → display must match inline fused within ≥ 50 dB (got \(score) dB)")
    }

    // MARK: - Zero-weight guard (no trap)

    /// A zero-weight flame must yield an empty `Histogram` (all-zero counts), not
    /// trap — mirroring `ChaosGameMetal.iterate`'s guard. The temporal variant is
    /// guarded identically (its per-pass guard `continue`s on degenerate passes;
    /// an all-zero-weight flame produces all-degenerate passes → empty histogram).
    func testZeroWeightFlameReturnsEmptyHistogram() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        var flame = try loadFrozen("sierpinski")
        flame.xforms = flame.xforms.map { var x = $0; x.weight = 0; return x }
        let params = RenderParams(seed: 1, width: 64, height: 64,
                                  oversample: 1, samplesPerPixel: 8)

        // Single-flame.
        let singleHist = try XCTUnwrap(
            MetalRenderer.renderHistogramOffMain(flame: flame, params: params),
            "zero-weight single-flame readback must return an empty histogram, not nil/trap")
        XCTAssertEqual(singleHist.counts.max(), 0,
            "zero-weight flame must produce an empty (all-zero) histogram")

        // Temporal (box, weight 1.0 — the per-pass flame is zero-weight).
        let (temporal, sumfilt) = TemporalFilter.samples(2, type: .box, width: 1.0, exp: 0)
        let tempHist = try XCTUnwrap(
            MetalRenderer.renderTemporalHistogramOffMain(
                blendAt: { _ in flame }, centerTime: 0, temporal: temporal,
                sumfilt: sumfilt, params: params),
            "zero-weight temporal readback must return an empty histogram, not nil/trap")
        XCTAssertEqual(tempHist.counts.max(), 0,
            "zero-weight temporal flame must produce an empty (all-zero) histogram")
    }

    // MARK: - Non-box guard

    /// The temporal off-main readback must return nil (not trap) on non-box
    /// temporal — the same defensive boundary as `renderTemporalOffMain`.
    func testTemporalReadbackReturnsNilOnNonBox() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try loadFrozen("sierpinski")
        let nonBox = TemporalFilter.samples(4, type: .gaussian, width: 1.0, exp: 0)
        let params = RenderParams(seed: 1, width: 32, height: 32,
                                  oversample: 1, samplesPerPixel: 8)
        let res = MetalRenderer.renderTemporalHistogramOffMain(
            blendAt: { _ in flame }, centerTime: 0, temporal: nonBox.0,
            sumfilt: nonBox.1, params: params)
        XCTAssertNil(res, "non-box temporal readback must return nil off-main, not trap")
    }
}
