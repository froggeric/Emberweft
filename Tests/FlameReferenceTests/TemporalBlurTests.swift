import XCTest
@testable import FlameReference
@testable import FlameKit

/// CPU temporal motion-blur parity for `ReferenceRenderer.render(blendAt:…)`
/// (Task 2 of the motion-blur plan). Verifies the faithful flam3 port
/// (rect.c:754-905) — N chaos sub-passes across a ±width/2 window with
/// `color_scalar = weight` baked into each pass's dmap, accumulated into one
/// histogram, then DE + tone-map once with `sumfilt` threaded into `k2`.
final class TemporalBlurTests: XCTestCase {

    /// Mean of the (R+G+B)/3 channel averaged across all pixels — a scalar
    /// proxy for total light output. Used for the brightness-preservation check.
    /// Widens to Double BEFORE summing so three saturated channels (255+255+255)
    /// do not overflow `UInt8`.
    private func meanChannel(_ img: RGBA8Image) -> Double {
        var s = 0.0
        for i in stride(from: 0, to: img.pixels.count, by: 4) {
            s += Double(img.pixels[i]) + Double(img.pixels[i + 1]) + Double(img.pixels[i + 2])
        }
        return s / Double(img.pixels.count / 4) / 3.0
    }

    /// Identity: a single temporal sample with weight 1.0 must reduce EXACTLY
    /// to the existing single-pass render — byte-identical pixels. Validates
    /// that `colorScalar=1.0` default, `sumfilt=1.0`, and the per-pass seed
    /// salt do not perturb the N=1 path.
    func testSingleTemporalSampleMatchesPlainRender() throws {
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let g = try Flam3Parser.parse(Data(contentsOf: url)).first!
        let p = RenderParams(seed: 7, width: 240, height: 180, oversample: 1, samplesPerPixel: 200)

        let plain = ReferenceRenderer.render(flame: g, params: p)

        // N=1 box filter: a single sub-pass at delta=0, weight=1.0, sumfilt=1.0.
        let (temporal, sumfilt) = TemporalFilter.samples(1, type: .box, width: 1.0, exp: 0)
        let blurred = ReferenceRenderer.render(
            blendAt: { _ in g }, centerTime: 0.5,
            temporal: temporal, sumfilt: sumfilt, params: p)

        XCTAssertEqual(blurred.pixels, plain.pixels,
            "temporalSamples=1 must equal the plain single-pass render byte-for-byte")
    }

    /// Static (constant `blendAt`) box blur with N>1 must preserve total light
    /// within Monte-Carlo noise: box weights are each 1.0 and `sumfilt=1.0`,
    /// so per-pass `colorScalar=1.0` and `k2` is unchanged — the brightness
    /// math collapses to the single-pass case. The only delta is the per-pass
    /// ISAAC seed salt (decorrelating trajectories), which contributes only
    /// shot noise. 5% tolerance is generous for 8-sample variance.
    func testStaticBoxBlurPreservesTotalLight() throws {
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let g = try Flam3Parser.parse(Data(contentsOf: url)).first!
        let p = RenderParams(seed: 7, width: 200, height: 150, oversample: 1, samplesPerPixel: 300)

        let plain = ReferenceRenderer.render(flame: g, params: p)

        let (temporal, sumfilt) = TemporalFilter.samples(8, type: .box, width: 1.2, exp: 0)
        let blurred = ReferenceRenderer.render(
            blendAt: { _ in g }, centerTime: 0.3,
            temporal: temporal, sumfilt: sumfilt, params: p)

        let meanA = meanChannel(plain), meanB = meanChannel(blurred)
        XCTAssertEqual(meanB, meanA, accuracy: meanA * 0.05,
            "static box temporal blur should preserve total light (meanA=\(meanA) meanB=\(meanB))")
    }

    /// Static (constant `blendAt`) GAUSSIAN blur must also preserve total light.
    /// Unlike the box test, gaussian weights are <1 and `sumfilt < 1`, so this
    /// is the test that actually exercises the `sumfilt`-in-`k2` cancellation
    /// (the hardest correctness property of the plan: the weighted `colorScalar`
    /// in the dmap must be exactly canceled by `sumfilt` in `k2`). Box has
    /// `sumfilt=1.0` and cannot detect a missing or wrong `sumfilt`.
    func testStaticGaussianBlurPreservesTotalLight() throws {
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let g = try Flam3Parser.parse(Data(contentsOf: url)).first!
        let p = RenderParams(seed: 7, width: 200, height: 150, oversample: 1, samplesPerPixel: 300)

        let plain = ReferenceRenderer.render(flame: g, params: p)

        let (temporal, sumfilt) = TemporalFilter.samples(8, type: .gaussian, width: 1.2, exp: 0)
        // Sanity: gaussian must actually have non-unit weights + sumfilt<1,
        // otherwise this test degenerates into the box case and tests nothing.
        XCTAssertLessThan(sumfilt, 1.0, "gaussian sumfilt must be < 1")
        let nonUnitWeight = temporal.contains { $0.weight < 1.0 }
        XCTAssertTrue(nonUnitWeight, "gaussian must produce at least one weight < 1.0")

        let blurred = ReferenceRenderer.render(
            blendAt: { _ in g }, centerTime: 0.3,
            temporal: temporal, sumfilt: sumfilt, params: p)

        let meanA = meanChannel(plain), meanB = meanChannel(blurred)
        XCTAssertEqual(meanB, meanA, accuracy: meanA * 0.05,
            "gaussian temporal blur must preserve total light (sumfilt cancels the weighted colorScalar; meanA=\(meanA) meanB=\(meanB))")
    }

    /// Negative test: the per-pass ISAAC seed salt is the ONLY thing preventing
    /// N>1 box passes from drawing identical ISAAC streams (the CPU iterate is
    /// otherwise pinned to `goldenIsaacSeed`; `params.seed` is not on the CPU
    /// path). Driving `iterate` N times with the SAME seed must yield a
    /// DIFFERENT image than the salted temporal path — otherwise a future
    /// refactor dropping the salt would go undetected (the result would be a
    /// biased accumulator with no real blur, but the box brightness-preservation
    /// test would still pass because the brightness math is unchanged).
    func testUnsaltedPassesProduceDifferentImageThanSalted() throws {
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let g = try Flam3Parser.parse(Data(contentsOf: url)).first!
        let p = RenderParams(seed: 7, width: 200, height: 150, oversample: 1, samplesPerPixel: 300)
        let (temporal, sumfilt) = TemporalFilter.samples(8, type: .box, width: 1.2, exp: 0)

        // Salted (the real path).
        let salted = ReferenceRenderer.render(
            blendAt: { _ in g }, centerTime: 0.3,
            temporal: temporal, sumfilt: sumfilt, params: p)

        // Unsalted: N passes, SAME `goldenIsaacSeed`, per-pass budget, accumulate, tone-map once.
        let N = temporal.count
        let base = p.samplesPerPixel / N, rem = p.samplesPerPixel % N
        var unsaltedHist = Histogram(gridWidth: p.gridWidth, gridHeight: p.gridHeight)
        for (i, sub) in temporal.enumerated() {
            let perPass = base + (i < rem ? 1 : 0)
            guard perPass > 0 else { continue }
            let subHist = ChaosGame.iterate(
                flame: g, params: p.settingSamplesPerPixel(perPass),
                isaacSeed: ChaosGame.goldenIsaacSeed,   // SAME seed every pass — correlated
                colorScalar: sub.weight)
            unsaltedHist.accumulate(subHist)
        }
        let unsalted = ToneMapping.render(histogram: unsaltedHist,
            width: p.width, height: p.height, oversample: p.oversample,
            gamma: g.quality.gamma, gammaThreshold: g.quality.gammaThreshold,
            vibrancy: g.quality.vibrancy, brightness: g.quality.brightness,
            sampleDensity: Double(p.samplesPerPixel),
            pixelsPerUnit: g.camera.scale * pow(2, g.camera.zoom), sumfilt: sumfilt)

        XCTAssertNotEqual(unsalted.pixels, salted.pixels,
            "unsalted (correlated) passes must differ from the salted temporal render — else the seed-salt is dead code")
    }
}
