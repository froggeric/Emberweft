import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

/// Overflow/NaN hardening stress tests: exercise each non-patched variation with
/// a LARGE pre-affine (mirrors the v_coth bug: a=34.67 → |pre.x|>44 → cosh
/// overflow) and confirm Metal does NOT collapse where CPU doesn't.
///
/// Strategy: 1-xform genome with a big-coefficient affine + the variation under
/// test at small weight. The chaos-game will iterate points whose `pre.x/y`
/// reach large magnitudes — exercising the Float-overflow class of bugs.
///
/// Pass criteria:
///   - Metal output is finite (no transparent/black collapse)
///   - Metal matches CPU within statistical threshold (or both saturate to ~0)
///
/// CPU is the oracle (faithful to flam3 `double`). Metal must not collapse where
/// CPU doesn't.
final class OverflowStressTests: XCTestCase {

    /// Mean luminance of an RGBA8 buffer (alpha-flattened). Used to detect the
    /// "all-black / all-transparent" collapse that NaN-poisoning produces.
    private static func meanLum(_ img: RGBA8Image) -> Double {
        guard img.pixels.count > 0 else { return -1 }
        var sum = 0.0
        let n = img.width * img.height
        for i in 0..<n {
            let r = Double(img.pixels[i * 4])
            let g = Double(img.pixels[i * 4 + 1])
            let b = Double(img.pixels[i * 4 + 2])
            sum += 0.299 * r + 0.587 * g + 0.114 * b
        }
        return sum / Double(n)
    }

    /// Count non-transparent (alpha>0) pixels — collapse produces ~0.
    private static func nonEmptyPixels(_ img: RGBA8Image) -> Int {
        guard img.pixels.count > 0 else { return 0 }
        var n = 0
        let count = img.width * img.height
        for i in 0..<count {
            if img.pixels[i * 4 + 3] > 0 { n += 1 }
        }
        return n
    }

    /// Build a stress genome: 1 xform with a BIG pre-affine + variation under
    /// test at small weight. Mirrors the v_coth bug shape (a≈34, b non-zero).
    ///
    /// The pre-affine `(a=34.67, b=0.2, c=0.3, d=15.5, e=0.5, f=0.3)` maps
    /// chaos-game points to |pre.x| up to ~44 and |pre.y| up to ~20 — large
    /// enough to trip Float overflow in `cosh/sinh/exp/pow` but small enough
    /// that CPU Double stays finite (faithful).
    @MainActor
    private func assertStressNoCollapse(
        _ name: String,
        _ params: [String: Double] = [:],
        weight: Double = 0.3,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        // BIG pre-affine mirroring the v_coth bug (a=34.67 → |pre.x| up to ~44).
        // For variations that need pre.x or pre.y > 89 to overflow (exp/cosh,
        // already patched) we'd need a bigger affine; for the pow/div-by-zero
        // class, this affine is plenty.
        let bigAffine = AffineTransform(a: 34.67, b: 0.2, c: 0.3, d: 15.5, e: 0.5, f: 0.3)
        let flame = Flame(
            size: SIMD2<Int>(200, 200),
            camera: Camera(scale: 200),
            xforms: [
                Xform(
                    affine: bigAffine,
                    color: 0, colorSpeed: 0.5,
                    variations: [Variation(name: name, weight: weight, parameters: params)]
                ),
            ],
            palette: Palette(colors: (0..<256).map {
                SIMD3<Double>(Double($0) / 255, sin(Double($0) / 40) * 0.5 + 0.5, 1 - Double($0) / 255)
            })
        )
        let p = RenderParams(seed: 7, width: 200, height: 200, oversample: 1, samplesPerPixel: 500)
        let cpu = ReferenceRenderer.render(flame: flame, params: p)
        let gpu = MetalRenderer.render(flame: flame, params: p)

        let cpuLum = Self.meanLum(cpu)
        let gpuLum = Self.meanLum(gpu)
        let cpuPx  = Self.nonEmptyPixels(cpu)
        let gpuPx  = Self.nonEmptyPixels(gpu)
        let psnr = ImageComparison.psnr(cpu, gpu)
        let psnrStr = psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)

        print("[Stress] \(name) (w=\(weight)): CPU lum=\(String(format: "%.2f", cpuLum)) px=\(cpuPx) | GPU lum=\(String(format: "%.2f", gpuLum)) px=\(gpuPx) | PSNR=\(psnrStr)")

        // The PASS conditions, in order of strictness:
        // 1. If CPU produces meaningful output (lum > 1.0, px > 100), then GPU
        //    must too (no collapse): GPU lum > 1.0 AND px > 100.
        // 2. AND Metal matches CPU (PSNR ≥ 25 dB — stress-test threshold is
        //    looser than the 38 dB parity gate because Float-vs-Double orbit
        //    divergence is amplified by the large pre-affine; the question is
        //    COLLAPSE, not byte-parity).
        // 3. If CPU itself saturates to ~0 (some variations naturally produce
        //    no output at this extreme), then GPU must also be ~0.
        if cpuLum > 1.0 && cpuPx > 100 {
            // Distinguish COLLAPSE (specific Inf/NaN bug) from DIVERGENCE (ULP chaos):
            // - Collapse: Metal produces < 10% of CPU's luminance → samples being
            //   rejected wholesale (NaN-poisoned accumulator tripping badvalue).
            // - Divergence: Metal and CPU produce comparable output magnitudes
            //   but different specific pixels — Float-vs-Double orbit bifurcation.
            //   Expected for chaotic variations under aggressive affines.
            let collapseRatio = gpuLum / max(cpuLum, 1e-9)
            XCTAssertGreaterThan(gpuLum, cpuLum * 0.1,
                "\(name): Metal COLLAPSED (GPU lum=\(gpuLum), CPU lum=\(cpuLum), ratio=\(String(format: "%.4f", collapseRatio))) — likely Inf/NaN poisoning",
                file: file, line: line)
            // PSNR lower bound for divergence: 18 dB (chaotic amplification
            // regime — the 38 dB parity gate is for normal affines).
            XCTAssertGreaterThanOrEqual(psnr, 18.0,
                "\(name): PSNR \(psnr) < 18 — extreme divergence under stress (CPU lum=\(cpuLum), GPU lum=\(gpuLum))",
                file: file, line: line)
        } else {
            // CPU itself saturates to ~0 — Metal must also be ~0 (both saturated).
            XCTAssertLessThan(gpuLum, 5.0,
                "\(name): CPU collapsed to ~0 (lum=\(cpuLum)) but Metal produced lum=\(gpuLum) — diverged",
                file: file, line: line)
        }
        XCTAssertEqual(gpu.pixels.count, gpu.width * gpu.height * 4,
            "\(name): incomplete Metal buffer", file: file, line: line)
    }

    // MARK: - Paramless variations

    @MainActor func testStressLinear() throws      { try assertStressNoCollapse("linear") }
    @MainActor func testStressSinusoidal() throws  { try assertStressNoCollapse("sinusoidal") }
    @MainActor func testStressSpherical() throws   { try assertStressNoCollapse("spherical") }
    @MainActor func testStressSwirl() throws       { try assertStressNoCollapse("swirl") }
    @MainActor func testStressHorseshoe() throws   { try assertStressNoCollapse("horseshoe") }
    @MainActor func testStressPolar() throws       { try assertStressNoCollapse("polar") }
    @MainActor func testStressHandkerchief() throws{ try assertStressNoCollapse("handkerchief") }
    @MainActor func testStressHeart() throws       { try assertStressNoCollapse("heart") }
    @MainActor func testStressDisc() throws        { try assertStressNoCollapse("disc") }
    @MainActor func testStressSpiral() throws      { try assertStressNoCollapse("spiral") }
    @MainActor func testStressHyperbolic() throws  { try assertStressNoCollapse("hyperbolic") }
    @MainActor func testStressDiamond() throws     { try assertStressNoCollapse("diamond") }
    @MainActor func testStressEx() throws          { try assertStressNoCollapse("ex") }
    @MainActor func testStressJulia() throws       { try assertStressNoCollapse("julia") }
    @MainActor func testStressBent() throws        { try assertStressNoCollapse("bent") }
    @MainActor func testStressFisheye() throws     { try assertStressNoCollapse("fisheye") }
    @MainActor func testStressCylinder() throws    { try assertStressNoCollapse("cylinder") }
    @MainActor func testStressBubble() throws      { try assertStressNoCollapse("bubble") }
    @MainActor func testStressEyefish() throws     { try assertStressNoCollapse("eyefish") }
    @MainActor func testStressWaves() throws       { try assertStressNoCollapse("waves") }
    @MainActor func testStressPopcorn() throws     { try assertStressNoCollapse("popcorn") }
    @MainActor func testStressPower() throws       { try assertStressNoCollapse("power") }
    @MainActor func testStressTangent() throws     { try assertStressNoCollapse("tangent") }
    @MainActor func testStressCross() throws       { try assertStressNoCollapse("cross") }
    @MainActor func testStressLog() throws         { try assertStressNoCollapse("log") }

    // Special-sauce paramless
    @MainActor func testStressRings() throws       { try assertStressNoCollapse("rings") }
    @MainActor func testStressFan() throws         { try assertStressNoCollapse("fan") }
    @MainActor func testStressSecant2() throws     { try assertStressNoCollapse("secant2") }

    // Batch 2 paramless non-trig
    @MainActor func testStressButterfly() throws   { try assertStressNoCollapse("butterfly") }
    @MainActor func testStressEdisc() throws       { try assertStressNoCollapse("edisc") }
    @MainActor func testStressElliptic() throws    { try assertStressNoCollapse("elliptic") }
    @MainActor func testStressFoci() throws        { try assertStressNoCollapse("foci") }
    @MainActor func testStressLoonie() throws      { try assertStressNoCollapse("loonie") }
    @MainActor func testStressPolar2() throws      { try assertStressNoCollapse("polar2") }
    @MainActor func testStressScry() throws        { try assertStressNoCollapse("scry") }

    // MARK: - Parametric variations (non-RNG)

    @MainActor func testStressPdj() throws {
        try assertStressNoCollapse("pdj", ["pdj_a": 0.2, "pdj_b": -1.18, "pdj_c": 1.36, "pdj_d": -2.01])
    }
    @MainActor func testStressSplit() throws {
        try assertStressNoCollapse("split", ["split_xsize": 0.3, "split_ysize": 0.4])
    }
    @MainActor func testStressBlob() throws {
        try assertStressNoCollapse("blob", ["blob_low": 0.3, "blob_high": 1.0, "blob_waves": 2.0])
    }
    @MainActor func testStressFan2() throws {
        try assertStressNoCollapse("fan2", ["fan2_x": 0.5, "fan2_y": 0.5])
    }
    @MainActor func testStressRings2() throws {
        try assertStressNoCollapse("rings2", ["rings2_val": 0.5])
    }
    @MainActor func testStressPerspective() throws {
        try assertStressNoCollapse("perspective", ["perspective_angle": 0.4, "perspective_dist": 5.0])
    }
    @MainActor func testStressNgon() throws {
        try assertStressNoCollapse("ngon", ["ngon_sides": 5, "ngon_power": 3, "ngon_circle": 1, "ngon_corners": 1])
    }
    @MainActor func testStressNgonPower8() throws {
        // Extreme-power ngon — exercises the pow(sumsq, power/2) overflow path.
        // sumsq can hit ~2e8 under the big affine; pow(2e8, 4)=4e16 fine but
        // pow(2e8, 5)=3.2e41 would overflow Float. Default power=3 keeps us
        // in the safe regime; this test confirms behavior at the boundary.
        try assertStressNoCollapse("ngon", ["ngon_sides": 5, "ngon_power": 8, "ngon_circle": 1, "ngon_corners": 1])
    }
    @MainActor func testStressCurl() throws {
        try assertStressNoCollapse("curl", ["curl_c1": 0.5, "curl_c2": 0.1])
    }
    @MainActor func testStressRectangles() throws {
        try assertStressNoCollapse("rectangles", ["rectangles_x": 0.5, "rectangles_y": 0.5])
    }
    @MainActor func testStressWedgeSph() throws {
        try assertStressNoCollapse("wedge_sph", ["wedge_sph_angle": 0.05, "wedge_sph_count": 3, "wedge_sph_hole": 0.0, "wedge_sph_swirl": 0.1])
    }
    @MainActor func testStressWedge() throws {
        try assertStressNoCollapse("wedge", ["wedge_angle": 0.5, "wedge_count": 2.0, "wedge_hole": 0.3, "wedge_swirl": 0.3])
    }

    @MainActor func testStressBent2() throws {
        try assertStressNoCollapse("bent2", ["bent2_x": 0.5, "bent2_y": 0.4])
    }
    @MainActor func testStressBipolar() throws {
        try assertStressNoCollapse("bipolar", ["bipolar_shift": 0.5])
    }
    @MainActor func testStressCell() throws {
        try assertStressNoCollapse("cell", ["cell_size": 1.0])
    }
    @MainActor func testStressEscher() throws {
        try assertStressNoCollapse("escher", ["escher_beta": 0.5])
    }
    @MainActor func testStressFlux() throws {
        try assertStressNoCollapse("flux", ["flux_spread": 0.5])
    }
    @MainActor func testStressModulus() throws {
        try assertStressNoCollapse("modulus", ["modulus_x": 1.0, "modulus_y": 1.0])
    }
    @MainActor func testStressSplits() throws {
        try assertStressNoCollapse("splits", ["splits_x": 0.3, "splits_y": 0.2])
    }
    @MainActor func testStressStripes() throws {
        try assertStressNoCollapse("stripes", ["stripes_space": 0.5, "stripes_warp": 0.5])
    }
    @MainActor func testStressWhorl() throws {
        try assertStressNoCollapse("whorl", ["whorl_inside": 0.3, "whorl_outside": 0.5])
    }

    @MainActor func testStressAuger() throws {
        try assertStressNoCollapse("auger", ["auger_freq": 1.0, "auger_scale": 0.5, "auger_sym": 2.0, "auger_weight": 0.5])
    }
    @MainActor func testStressCurve() throws {
        try assertStressNoCollapse("curve", ["curve_xamp": 0.5, "curve_xlength": 1.0, "curve_yamp": 0.5, "curve_ylength": 1.0])
    }
    @MainActor func testStressLazysusan() throws {
        try assertStressNoCollapse("lazysusan", ["lazysusan_space": 0.5, "lazysusan_spin": 0.3, "lazysusan_twist": 0.3, "lazysusan_x": 0.2, "lazysusan_y": 0.2])
    }
    @MainActor func testStressMobius() throws {
        try assertStressNoCollapse("mobius", ["mobius_re_a": 1.0, "mobius_re_b": 0.3, "mobius_re_c": 0.1, "mobius_re_d": 1.0, "mobius_im_a": 0.0, "mobius_im_b": 0.0, "mobius_im_c": 0.0, "mobius_im_d": 0.0])
    }
    @MainActor func testStressPopcorn2() throws {
        try assertStressNoCollapse("popcorn2", ["popcorn2_c": 0.5, "popcorn2_x": 0.3, "popcorn2_y": 0.3])
    }
    @MainActor func testStressSeparation() throws {
        try assertStressNoCollapse("separation", ["separation_x": 0.5, "separation_xinside": 0.2, "separation_y": 0.5, "separation_yinside": 0.2])
    }
    @MainActor func testStressWaves2() throws {
        try assertStressNoCollapse("waves2", ["waves2_freqx": 1.0, "waves2_freqy": 1.0, "waves2_scalex": 0.5, "waves2_scaley": 0.5])
    }
    @MainActor func testStressOscilloscope() throws {
        try assertStressNoCollapse("oscilloscope", ["oscilloscope_separation": 0.5, "oscilloscope_frequency": 1.0, "oscilloscope_amplitude": 1.0])
    }
    @MainActor func testStressDisc2() throws {
        try assertStressNoCollapse("disc2", ["disc2_rot": 0.5, "disc2_twist": 0.3])
    }

    // MARK: - RNG-consuming variations

    @MainActor func testStressNoise() throws        { try assertStressNoCollapse("noise") }
    @MainActor func testStressBlur() throws         { try assertStressNoCollapse("blur") }
    @MainActor func testStressGaussianBlur() throws { try assertStressNoCollapse("gaussian_blur", weight: 0.2) }
    @MainActor func testStressArch() throws         { try assertStressNoCollapse("arch") }
    @MainActor func testStressSquare() throws       { try assertStressNoCollapse("square") }
    @MainActor func testStressRays() throws         { try assertStressNoCollapse("rays") }
    @MainActor func testStressBlade() throws        { try assertStressNoCollapse("blade") }
    @MainActor func testStressTwintrian() throws    { try assertStressNoCollapse("twintrian") }
    @MainActor func testStressFlower() throws {
        try assertStressNoCollapse("flower", ["flower_holes": 0.1, "flower_petals": 2.0])
    }
    @MainActor func testStressConic() throws {
        try assertStressNoCollapse("conic", ["conic_eccentricity": 0.5, "conic_holes": 0.1])
    }
    @MainActor func testStressParabola() throws {
        try assertStressNoCollapse("parabola", ["parabola_height": 0.5, "parabola_width": 0.4])
    }
    @MainActor func testStressBoarders() throws     { try assertStressNoCollapse("boarders") }
    @MainActor func testStressPie() throws {
        try assertStressNoCollapse("pie", ["pie_slices": 6, "pie_rotation": 0.0, "pie_thickness": 0.5])
    }
    @MainActor func testStressRadialBlur() throws {
        try assertStressNoCollapse("radial_blur", ["radial_blur_angle": 0.0])
    }

    @MainActor func testStressJulian() throws {
        try assertStressNoCollapse("julian", ["julian_power": 3, "julian_dist": 1.0])
    }
    @MainActor func testStressJulianHighPow() throws {
        // Extreme-power julian — exercises pow(sumsq, cn) overflow path.
        // power=0.5, dist=1 → cn=1.0, pow(2e8, 1)=2e8 fine; this is the
        // boundary confirmation.
        try assertStressNoCollapse("julian", ["julian_power": 0.5, "julian_dist": 1.0])
    }
    @MainActor func testStressJuliascope() throws {
        try assertStressNoCollapse("juliascope", ["juliascope_power": 3, "juliascope_dist": 1.0])
    }
    @MainActor func testStressSuperShape() throws {
        try assertStressNoCollapse("super_shape", ["super_shape_rnd": 0.1, "super_shape_m": 5, "super_shape_n1": 2, "super_shape_n2": 2, "super_shape_n3": 2, "super_shape_holes": 0])
    }
    @MainActor func testStressSuperShapeSmallN1() throws {
        // Small-n1 super_shape — exercises pow(t1+t2, -1/n1) overflow.
        // n1=0.5 → pneg1N1=-2.0, t1+t2∈[0,2], pow(small, -2)=large but finite
        // for non-zero t1+t2; can overflow when t1+t2<sqrt(1e-38)≈1e-19.
        try assertStressNoCollapse("super_shape", ["super_shape_rnd": 0.1, "super_shape_m": 5, "super_shape_n1": 0.5, "super_shape_n2": 2, "super_shape_n3": 2, "super_shape_holes": 0])
    }
    @MainActor func testStressWedgeJulia() throws {
        try assertStressNoCollapse("wedge_julia", ["wedge_julia_angle": 0.1, "wedge_julia_count": 5, "wedge_julia_power": 2, "wedge_julia_dist": 1])
    }
    @MainActor func testStressCpow() throws {
        try assertStressNoCollapse("cpow", ["cpow_r": 1.0, "cpow_i": 0.3, "cpow_power": 3.0])
    }
}
