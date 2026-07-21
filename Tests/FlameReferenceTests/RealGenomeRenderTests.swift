import XCTest
@testable import FlameReference
@testable import FlameKit

/// End-to-end regression guard for real Electric Sheep genomes. Real genomes
/// (decimal `<color rgb>` palettes, DE on, non-default camera/brightness) differ
/// from the synthetic goldens (palette-less, default camera) in ways that have
/// historically hidden bugs:
///   - `testRealGenomeRendersNonBlack`: the all-black render regression
///     (decimal-`<color>` parse + brightness).
///   - `testTransitionToLoopSeamlessness`: the transition→loop seam from
///     weight-1 padding xforms (05739=16 xforms → 31943=7 ⇒ 9 padding xforms).
///     The synthetic goldens share xform counts so padding never triggered.
final class RealGenomeRenderTests: XCTestCase {

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    private func genomesRealDir() -> URL {
        repoRoot().appendingPathComponent("Tests/Goldens/genomes_real")
    }

    private func loadReal(_ name: String) throws -> Flame {
        let url = genomesRealDir().appendingPathComponent("\(name).flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("real-genome fixture missing: \(url.path)")
        }
        return try XCTUnwrap(Flam3Parser.parse(Data(contentsOf: url)).first, "parse failed for \(name)")
    }

    func testRealGenomeRendersNonBlack() throws {
        let url = repoRoot().appendingPathComponent("Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("real-genome fixture missing: \(url.path)")
        }
        let flame = try XCTUnwrap(Flam3Parser.parse(Data(contentsOf: url)).first, "parse failed")
        // 00256 has 12 xforms + finalxform + DE; render on CPU (available everywhere).
        let img = ReferenceRenderer.render(
            flame: flame,
            params: RenderParams(seed: 0, width: 320, height: 240, oversample: 1, samplesPerPixel: 200)
        )
        var maxChannel: UInt8 = 0
        var nonBlack = 0
        let px = img.pixels
        var i = 0
        while i + 3 < px.count {
            let m = max(px[i], px[i + 1], px[i + 2])
            if m > maxChannel { maxChannel = m }
            if m > 4 { nonBlack += 1 }
            i += 4
        }
        let pixels = px.count / 4
        XCTAssertGreaterThan(maxChannel, 0, "real genome rendered ALL-black (palette-parse regression)")
        XCTAssertGreaterThan(Double(nonBlack) / Double(pixels), 0.10,
                             "real genome rendered mostly black (\(nonBlack)/\(pixels) non-zero)")
    }

    // MARK: - transition→loop seamlessness (Task-4 motion-blur user gate)

    /// AC: at the transition→loop boundary, the last transition frame (t=1,
    /// `Transition.blend(A, B, 1.0)` = align(B)) must render ≈ identically to the
    /// first loop frame (t=0, `Loop.blend(B, 0)` = raw B). Real genomes 05739 (16
    /// xforms) → 31943 (7 xforms) ⇒ 9 padding xforms; those MUST be invisible in
    /// the chaos game (weight 0, matching flam3's `initialize_xforms` which sets
    /// `density = 0.0`). If they carry the default weight 1.0, align(B) renders
    /// 9 extra xforms that raw B doesn't ⇒ a visible structural/color seam.
    ///
    /// flam3 cross-check: `initialize_xforms` (variations.c:2406) sets padding
    /// `density = 0.0`; `flam3_create_chaos_distrib` (flam3.c:179) uses `density`
    /// directly so weight-0 xforms are never selected; `INTERP(xform[i].density)`
    /// (interpolation.c:530) interpolates it, so the real xform's weight fades
    /// out across the blend and reaches 0 at t=1 — seamless.
    ///
    /// Threshold: ≥ 35 dB. The residual at t=1 is the same R(2π) FP-trig residual
    /// (~1e-16) that bounds `testLoopSeamlessnessGenomeSpaceAndRendered` to ≥38 dB;
    /// 35 dB leaves margin for statistical sampling noise at 1000 spp.
    func testTransitionToLoopSeamlessness() throws {
        // 05739 (16 regular xforms) → 31943 (7 regular xforms) ⇒ 9 padding xforms.
        let a = try loadReal("electricsheep.248.05739")
        let b = try loadReal("electricsheep.248.31943")
        XCTAssertEqual(a.xforms.count, 16, "05739 fixture xform count drifted (padding test assumes 16)")
        XCTAssertEqual(b.xforms.count, 7, "31943 fixture xform count drifted (padding test assumes 7)")

        // Last transition frame (t=1) vs first loop frame (t=0). Both should
        // render B's 7 real xforms identically; the 9 padding xforms in the
        // aligned genome must be invisible (weight 0).
        let endOfTransition = Transition.blend(a, b, t: 1.0, stagger: 0)
        let startOfLoop = Loop.blend(b, t: 0.0)

        // High spp so statistical sampling noise clears the 35 dB gate (same
        // operating point as testLoopSeamlessnessGenomeSpaceAndRendered).
        let p = RenderParams(seed: 0, width: 320, height: 200, oversample: 1, samplesPerPixel: 1000)
        let imgEnd = ReferenceRenderer.render(flame: endOfTransition, params: p)
        let imgStart = ReferenceRenderer.render(flame: startOfLoop, params: p)

        let psnr = ImageComparison.psnr(imgEnd, imgStart)
        print("[TransitionSeam] 05739→31943 boundary PSNR(t=1 vs loop t=0) = "
              + "\(psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)) dB")
        XCTAssertGreaterThanOrEqual(psnr, 35.0,
            "transition→loop seam: PSNR \(psnr) < 35 dB — padding xforms are visible at t=1 "
            + "(expected weight 0 / invisible, like flam3 initialize_xforms density=0)")
    }
}
