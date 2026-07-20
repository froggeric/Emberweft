import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

/// Metal temporal motion-blur parity for `MetalRenderer.render(blendAt:…)`
/// (Task 3 of the motion-blur plan). The Metal twin of the CPU
/// `ReferenceRenderer.render(blendAt:…)` — N chaos sub-passes encoded into ONE
/// `atomicBuf` (cleared once, accumulated across passes), then a single
/// decode → (optional) DE → log → display. Per pass: rebuild the dmap with
/// `colorScalar = sub.weight` baked in, regenerate `threadSeeds` with a distinct
/// salt (`params.seed &+ UInt64(i)`), dispatch `≈threadCount/N` threads. Box
/// (the only type real ES genomes use) → `colorScalar=1.0` per pass → dmap
/// byte-identical to single-pass; cost-neutral (rect.c:833).
@MainActor
final class TemporalBlurMetalTests: XCTestCase {

    /// Load a real-genome fixture from `Tests/Goldens/genomes_real/`. Throws
    /// `XCTSkip` (NOT fail) when missing — same convention as the CPU temporal
    /// tests (`TemporalBlurTests.swift`) and the real-genome suite.
    private func loadReal(_ name: String) throws -> Flame {
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/\(name).flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture missing: \(url.path)")
        }
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }

    /// Load a frozen genome from `Tests/Goldens/genomes/` (the same suite the
    /// existing `EndToEndParityTests` uses for its 38 dB / 0.95 SSIM gate).
    /// These genomes are well-conditioned (low chaos) — the Monte Carlo noise
    /// floor at 1000 spp is ≥ 38 dB, against which a statistical-parity gate
    /// is meaningful. Real ES genomes (chaotic) need 10k+ spp for the same
    /// noise floor and are exercised by the smoke tests below.
    private func loadFrozen(_ name: String) throws -> Flame {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name).flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture missing: \(url.path)")
        }
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }

    /// Identity: a single temporal sample (N=1, weight=1.0, sumfilt=1.0) must
    /// reduce EXACTLY to the existing single-pass Metal render — byte-identical
    /// pixels. Validates that `perPassThreads == tc_full`, the per-pass seed salt
    /// is `params.seed &+ UInt64(0) == params.seed`, the box `colorScalar=1.0`
    /// leaves the dmap unchanged, and `sumfilt=1.0` leaves the inline Metal `k2`
    /// unchanged. This is the load-bearing N=1 contract.
    func testMetalTemporalSingleSampleMatchesPlain() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let g = try loadReal("electricsheep.248.00256")
        let p = RenderParams(seed: 7, width: 240, height: 180,
                             oversample: 1, samplesPerPixel: 200)

        let plain = MetalRenderer.render(flame: g, params: p)

        let (temporal, sumfilt) = TemporalFilter.samples(1, type: .box, width: 1.0, exp: 0)
        let blurred = MetalRenderer.render(
            blendAt: { _ in g }, centerTime: 0.5,
            temporal: temporal, sumfilt: sumfilt, params: p)

        XCTAssertEqual(blurred.pixels, plain.pixels,
            "N=1 temporal must equal the plain single-pass Metal render byte-for-byte")
    }

    /// A 2-sheep Metal render (blendAt switches between two real genomes) with
    /// `temporalSamples=8` (box) must complete and produce a non-black image.
    /// Smoke check that the N>1 path dispatches, accumulates across passes, and
    /// decodes/displays without producing garbage. The Metal↔CPU parity test
    /// below is the stronger correctness check.
    func testMetalTemporalBoxSamplesNonBlack() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let g0 = try loadReal("electricsheep.248.00256")
        let g1 = try loadReal("electricsheep.248.00000")
        let p = RenderParams(seed: 7, width: 200, height: 150,
                             oversample: 1, samplesPerPixel: 300)

        let (temporal, sumfilt) = TemporalFilter.samples(8, type: .box, width: 1.2, exp: 0)
        // 2-sheep blendAt: the 8 sub-passes sample both genomes across the
        // ±width/2 window. The two genomes have different palettes + xforms, so
        // a non-black result means all 8 encoders ran and accumulated correctly.
        let img = MetalRenderer.render(
            blendAt: { t in t < 0.5 ? g0 : g1 },
            centerTime: 0.5,
            temporal: temporal, sumfilt: sumfilt, params: p)

        let nonBlack = img.pixels.contains { $0 > 0 }
        XCTAssertTrue(nonBlack,
            "N=8 box temporal render must be non-black (some pixel R/G/B > 0)")
    }

    /// Gaussian/exp guard: the spec mandates `fatalError` at the function top
    /// if any `temporal.weight != 1.0`. A `fatalError` aborts the process, so it
    /// CANNOT be trap-tested in-process (same constraint as Task 1's
    /// precondition, and the 14+ `precondition` guards elsewhere in
    /// FlameKit/FlameReference — see `HistogramHelpersTests.swift:50-56`). The
    /// project convention is to document the guard and pin the happy-path
    /// post-condition; spawning a subprocess is explicitly advised against in
    /// the spec.
    ///
    /// What this test DOES verify: a single-sample gaussian (N=1, weight=1.0 —
    /// the max-normalized peak) passes the guard and produces a valid image.
    /// This is the closest in-process probe of the guard's predicate without
    /// crossing the abort boundary.
    func testMetalTemporalGaussianGuardAllowedAtUnitWeight() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let g = try loadReal("electricsheep.248.00256")
        let p = RenderParams(seed: 7, width: 160, height: 120,
                             oversample: 1, samplesPerPixel: 100)
        // N=1 gaussian: filter is `[(0.0, 1.0)]` (max-normalized → 1.0). The
        // `weight != 1.0` guard passes; the render must complete normally and
        // be byte-identical to the plain single-pass path (gaussian N=1 is
        // algebraically identical to box N=1).
        let (temporal, sumfilt) = TemporalFilter.samples(1, type: .gaussian, width: 1.0, exp: 0)
        XCTAssertEqual(temporal.count, 1)
        XCTAssertEqual(temporal[0].weight, 1.0, accuracy: 1e-12,
            "N=1 gaussian must max-normalize to weight=1.0 (guard predicate)")
        XCTAssertEqual(sumfilt, 1.0, accuracy: 1e-12)

        let plain = MetalRenderer.render(flame: g, params: p)
        let blurred = MetalRenderer.render(
            blendAt: { _ in g }, centerTime: 0.5,
            temporal: temporal, sumfilt: sumfilt, params: p)
        XCTAssertEqual(blurred.pixels, plain.pixels,
            "N=1 gaussian (weight=1.0) must equal the plain single-pass render")
        // NOTE: The N>1 gaussian/exp `fatalError` branch is visually verified at
        // the top of `MetalRenderer.render(blendAt:…)`. It is the project's
        // documented convention not to trap-test `fatalError` in-process.
    }

    /// The strengthened Metal↔CPU temporal statistical-parity gate. For a box
    /// temporal blur (N=8), `MetalRenderer.render(blendAt:…)` and
    /// `ReferenceRenderer.render(blendAt:…)` on the same genome+params must
    /// agree at PSNR ≥ 30 dB. They are statistical twins (like the existing
    /// single-frame CPU↔Metal gate), NOT byte-identical — the per-pass thread
    /// geometry and ISAAC layering differ between CPU (single-threaded) and
    /// Metal (multi-threaded). This catches drift in the per-pass budget, seed
    /// salt, atomic accumulation, and `colorScale`-from-full-budget math.
    ///
    /// Fixture choice: a FROZEN genome (`sierpinski`) at 1000 spp, matching the
    /// existing `EndToEndParityTests` operating point where the single-frame
    /// Metal↔CPU gate holds at 38 dB / 0.95 SSIM. The per-pass budget at N=8 is
    /// 125 spp; the accumulated histogram has the same total budget as a 1000
    /// spp single-frame render, so the same noise floor applies. Chaotic real
    /// ES genomes (e.g. `electricsheep.248.00256`) need 10k+ spp for the noise
    /// floor to rise above 30 dB and are exercised by the smoke test above.
    func testMetalTemporalBoxMatchesCpuWithinParity() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let g = try loadFrozen("sierpinski")
        let p = RenderParams(seed: 0, width: 320, height: 200,
                             oversample: 1, samplesPerPixel: 1000)

        let (temporal, sumfilt) = TemporalFilter.samples(8, type: .box, width: 1.2, exp: 0)
        let cpu = ReferenceRenderer.render(
            blendAt: { _ in g }, centerTime: 0.3,
            temporal: temporal, sumfilt: sumfilt, params: p)
        let gpu = MetalRenderer.render(
            blendAt: { _ in g }, centerTime: 0.3,
            temporal: temporal, sumfilt: sumfilt, params: p)

        let psnr = ImageComparison.psnr(cpu, gpu)
        let ssim = ImageComparison.ssim(cpu, gpu)
        print("[TemporalMetalParity] N=8 box sierpinski @\(p.samplesPerPixel)spp "
              + "(\(p.width)×\(p.height)): PSNR="
              + "\(psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)) dB, "
              + "SSIM=\(String(format: "%.4f", ssim))")
        XCTAssertGreaterThanOrEqual(psnr, 30.0,
            "Metal↔CPU temporal parity: \(psnr) dB < 30 dB — per-pass budget, "
            + "seed salt, atomic accumulation, or colorScale math has drifted")
    }
}
