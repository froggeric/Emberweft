import XCTest
@testable import FlameKit

final class PaletteBlendTests: XCTestCase {

    // 256-entry palette filled with a single color.
    private func palette(_ c: SIMD3<Double>) -> Palette {
        Palette(colors: Array(repeating: c, count: 256))
    }

    // 256-entry palette with a gradient from c0 (index 0) to c1 (index 255).
    private func gradient(_ c0: SIMD3<Double>, _ c1: SIMD3<Double>) -> Palette {
        let colors = (0..<256).map { i -> SIMD3<Double> in
            let f = Double(i) / 255.0
            return c0 * (1 - f) + c1 * f
        }
        return Palette(colors: colors)
    }

    private func assertFinite(_ p: Palette, _ msg: String = "") {
        for c in p.colors {
            XCTAssertTrue(c.x.isFinite, msg)
            XCTAssertTrue(c.y.isFinite, msg)
            XCTAssertTrue(c.z.isFinite, msg)
        }
    }

    /// Element-wise equality (XCTest has no scalar-accuracy overload for SIMD3).
    private func assertEq(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ accuracy: Double,
                          _ message: String = "",
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - Endpoints

    func testEndpointsHSVcircular() {
        let a = gradient(SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        let b = gradient(SIMD3(0, 0, 1), SIMD3(0, 1, 1))
        assertPaletteEqual(PaletteBlend.blend(a, b, at: 0, mode: .hsvCircular, hsvMix: 0), a, 1e-9)
        assertPaletteEqual(PaletteBlend.blend(a, b, at: 1, mode: .hsvCircular, hsvMix: 0), b, 1e-9)
    }

    func testEndpointsRGB() {
        let a = gradient(SIMD3(0.2, 0.9, 0.4), SIMD3(0.7, 0.1, 0.5))
        let b = gradient(SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        // rgb mode: rgb_fraction=1, so endpoints are the raw palettes (no hsv round-trip).
        assertPaletteEqual(PaletteBlend.blend(a, b, at: 0, mode: .rgb, hsvMix: 0), a, 1e-12)
        assertPaletteEqual(PaletteBlend.blend(a, b, at: 1, mode: .rgb, hsvMix: 0), b, 1e-12)
    }

    func testEndpointsHSV() {
        let a = gradient(SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        let b = gradient(SIMD3(0, 0, 1), SIMD3(1, 1, 0))
        // hsv mode: rgb_fraction=0; endpoints round-trip through rgb2hsv/hsv2rgb.
        assertPaletteEqual(PaletteBlend.blend(a, b, at: 0, mode: .hsv, hsvMix: 0), a, 1e-9)
        assertPaletteEqual(PaletteBlend.blend(a, b, at: 1, mode: .hsv, hsvMix: 0), b, 1e-9)
    }

    func testEndpointsSweep() {
        let a = palette(SIMD3(0.1, 0.2, 0.3))
        let b = palette(SIMD3(0.8, 0.9, 1.0))
        // sweep: at t=0 c[0]=1 -> i<256 always -> all from a; at t=1 c[0]=0 -> all from b.
        assertPaletteEqual(PaletteBlend.blend(a, b, at: 0, mode: .sweep, hsvMix: 0), a, 0)
        assertPaletteEqual(PaletteBlend.blend(a, b, at: 1, mode: .sweep, hsvMix: 0), b, 0)
    }

    // MARK: - hsv_circular midpoint (hand-traced against interpolation.c)

    func testHSVcircularMidpointRedToGreen() {
        // red->green at t=0.5, hsvMix=0:
        //  red hsv=(0,1,1), green hsv=(2,1,1); delta=2 (no +/-6 adjust)
        //  new_hsv = (1,1,1) -> hsv2rgb = (1,1,0) yellow
        let a = palette(SIMD3(1, 0, 0))
        let b = palette(SIMD3(0, 1, 0))
        let r = PaletteBlend.blend(a, b, at: 0.5, mode: .hsvCircular, hsvMix: 0)
        assertEq(r.colors[128], SIMD3<Double>(1, 1, 0), 1e-12)
    }

    func testHSVcircularShorterArcRedToBlue() {
        // red->blue at t=0.5, hsvMix=0:
        //  red hsv=(0,1,1), blue hsv=(4,1,1); delta=4>3 -> cp0 hue += 6 -> 6
        //  new_hsv[0] = 0.5*6 + 0.5*4 = 5; new_hsv=(5,1,1)
        //  hsv2rgb(5,1,1): j=5 -> (v,p,q)=(1,0,1) magenta
        let a = palette(SIMD3(1, 0, 0))
        let b = palette(SIMD3(0, 0, 1))
        let r = PaletteBlend.blend(a, b, at: 0.5, mode: .hsvCircular, hsvMix: 0)
        assertEq(r.colors[128], SIMD3<Double>(1, 0, 1), 1e-12)
    }

    // MARK: - hsvMix / rgb_fraction mixing

    func testHSVMixZeroVsOneDiffer() {
        let a = palette(SIMD3(1, 0, 0))
        let b = palette(SIMD3(0, 1, 0))
        let pureHSV = PaletteBlend.blend(a, b, at: 0.5, mode: .hsvCircular, hsvMix: 0)
        let pureRGB = PaletteBlend.blend(a, b, at: 0.5, mode: .hsvCircular, hsvMix: 1)
        // pureHSV midpoint = (1,1,0); pureRGB midpoint = (0.5,0.5,0)
        let delta = pureHSV.colors[128] - pureRGB.colors[128]
        XCTAssertGreaterThan(abs(delta.x), 1e-6)
        assertEq(pureHSV.colors[128], SIMD3<Double>(1, 1, 0), 1e-12)
        assertEq(pureRGB.colors[128], SIMD3<Double>(0.5, 0.5, 0), 1e-12)
    }

    func testHSVMixOneEqualsRGBMode() {
        // hsv_circular with hsvMix=1 must equal rgb mode (rgb_fraction=1 in both).
        let a = palette(SIMD3(1, 0, 0))
        let b = palette(SIMD3(0, 1, 0))
        let viaMix = PaletteBlend.blend(a, b, at: 0.5, mode: .hsvCircular, hsvMix: 1)
        let viaRGB = PaletteBlend.blend(a, b, at: 0.5, mode: .rgb, hsvMix: 1)
        assertPaletteEqual(viaMix, viaRGB, 1e-12)
    }

    func testHSVModeDoesNotApplyShorterArcAdjust() {
        // The shorter-arc hue adjust is gated on mode == hsv_circular
        // (interpolation.c:403), NOT on rgb_fraction. Plain .hsv blends hue
        // linearly the long way around; .hsvCircular takes the short arc.
        //
        // red(0) -> blue(4) at t=0.5:
        //  .hsv         : no adjust; new_h = 0.5*0 + 0.5*4 = 2 -> hsv2rgb(2,1,1) = (0,1,0) green
        //  .hsvCircular : cp0 hue += 6 -> 6; new_h = 0.5*6 + 0.5*4 = 5 -> hsv2rgb(5,1,1) = (1,0,1) magenta
        let a = palette(SIMD3(1, 0, 0))
        let b = palette(SIMD3(0, 0, 1))
        let viaHSV = PaletteBlend.blend(a, b, at: 0.5, mode: .hsv, hsvMix: 0)
        let viaCirc = PaletteBlend.blend(a, b, at: 0.5, mode: .hsvCircular, hsvMix: 0)
        assertEq(viaHSV.colors[128], SIMD3<Double>(0, 1, 0), 1e-12)
        assertEq(viaCirc.colors[128], SIMD3<Double>(1, 0, 1), 1e-12)
        // And the two modes must differ.
        let delta = viaHSV.colors[128] - viaCirc.colors[128]
        XCTAssertGreaterThan(abs(delta.x), 0.5)
    }

    func testHSVModeRgbFractionIsZero() {
        // .hsv mode => rgb_fraction=0: even with hsvMix=1 (ignored), the rgb
        // triple contributes nothing. For a pair whose hue delta is < 3 (no
        // shorter-arc adjust either way), .hsv and .hsvCircular(hsvMix=0)
        // coincide. red->green: delta hue = 2 (< 3), so no adjust in either mode.
        let a = palette(SIMD3(1, 0, 0))
        let b = palette(SIMD3(0, 1, 0))
        let viaHSV = PaletteBlend.blend(a, b, at: 0.5, mode: .hsv, hsvMix: 1 /* ignored */)
        let viaCirc = PaletteBlend.blend(a, b, at: 0.5, mode: .hsvCircular, hsvMix: 0)
        assertPaletteEqual(viaHSV, viaCirc, 1e-12)
    }

    // MARK: - Sweep hard-cut (interpolation.c:458-461)

    func testSweepHardCut() {
        // c[0]=1-t=0.5 -> threshold = 256*0.5 = 128.
        // entries i<128 -> from a; i>=128 -> from b.
        let a = palette(SIMD3(0.1, 0.2, 0.3))
        let b = palette(SIMD3(0.8, 0.9, 1.0))
        let r = PaletteBlend.blend(a, b, at: 0.5, mode: .sweep, hsvMix: 0)
        XCTAssertEqual(r.colors[0], a.colors[0])
        XCTAssertEqual(r.colors[127], a.colors[127])
        XCTAssertEqual(r.colors[128], b.colors[128])
        XCTAssertEqual(r.colors[255], b.colors[255])
    }

    // MARK: - Finiteness

    func testFinitenessBlackPalette() {
        let a = Palette.black
        let b = Palette.black
        let r = PaletteBlend.blend(a, b, at: 0.5, mode: .hsvCircular, hsvMix: 0.5)
        assertFinite(r, "black palette blend not finite")
    }

    func testFinitenessSaturatedPalette() {
        let a = palette(SIMD3(1, 0, 0))
        let b = palette(SIMD3(0, 1, 0))
        let r = PaletteBlend.blend(a, b, at: 0.3, mode: .hsvCircular, hsvMix: 0.5)
        assertFinite(r, "saturated palette blend not finite")
    }

    // MARK: - Opaque-palette equivalence to flam3's 4-channel+index blend

    /// Pins the documented equivalence in `PaletteBlend.blend` between Emberweft's
    /// 3-channel RGB blend+clip and flam3's 4-channel (RGB+color[3]) + index
    /// blend+clip (interpolation.c:416-454).
    ///
    /// Emberweft `Palette` is opaque RGB only (alpha = 1.0 everywhere; no
    /// per-entry index). For such inputs flam3's extra accumulators evaluate
    /// trivially:
    ///   • `new_count` (interpolation.c:422): every `color[3] == 1.0`, so the
    ///     `alpha1` rule fires (interpolation.c:423-424, 429-430) and
    ///     `result.color[3] = 1.0`. Its 4th-channel clip (interpolation.c:444-449)
    ///     is a no-op on 1.0.
    ///   • `new_index` (interpolation.c:425): `palette[i].index == i` (the slot)
    ///     and `sum(c[k]) == 1`, so `new_index == i` — the array position
    ///     Emberweft uses implicitly.
    ///
    /// So for opaque palettes, flam3's RGB output equals Emberweft's RGB output
    /// channel-for-channel, and its `color[3]` / `index` are constants (1.0 /
    /// slot) with no effect on the RGB result. This test builds two opaque RGB
    /// palettes, blends them, and asserts the RGB output matches the value
    /// computed by the 3-channel blend — which, per the proof above, is exactly
    /// what flam3's 4-channel+index math produces for these inputs. If `Palette`
    /// is ever widened to RGBA+index, or a regression introduces non-opaque
    /// handling, this test's premise (and the documented equivalence) must be
    /// revisited.
    func testOpaquePaletteBlendMatchesFlam3FourChannelEquivalence() {
        // Two distinct opaque palettes.
        let a = gradient(SIMD3(0.9, 0.1, 0.2), SIMD3(0.3, 0.8, 0.5))
        let b = gradient(SIMD3(0.05, 0.6, 0.95), SIMD3(0.7, 0.25, 0.4))
        let t = 0.37
        let hsvMix = 0.6

        for mode: PaletteInterpolation in [.hsvCircular, .rgb, .hsv] {
            let result = PaletteBlend.blend(a, b, at: t, mode: mode, hsvMix: hsvMix)

            // flam3's color[3] for opaque palettes is always 1.0 (alpha1 rule);
            // its index is always the slot i. Neither influences the RGB output,
            // so Emberweft's 3-channel result IS flam3's RGB result here.
            //
            // Re-derive the expected RGB directly from the 3-channel math to
            // guard against any drift in the blend itself; the equivalence point
            // is that no 4th channel / index term is needed.
            let c0 = 1.0 - t
            let c1 = t
            var rgbFraction: Double = 0.0
            switch mode {
            case .rgb:         rgbFraction = 1.0
            case .hsvCircular: rgbFraction = hsvMix
            case .hsv, .sweep: rgbFraction = 0.0
            }
            @Sendable func rgb2hsvLocal(_ rgb: SIMD3<Double>) -> (h: Double, s: Double, v: Double) {
                // Independent reference rgb2hsv (hue on flam3's 0-6 scale) to
                // avoid coupling the test to the internal implementation.
                let mx = max(rgb.x, max(rgb.y, rgb.z))
                let mn = min(rgb.x, min(rgb.y, rgb.z))
                let del = mx - mn
                let v = mx
                let s = mx != 0 ? del / mx : 0
                var h = 0.0
                if s != 0 {
                    let rc = (mx - rgb.x) / del
                    let gc = (mx - rgb.y) / del
                    let bc = (mx - rgb.z) / del
                    if      rgb.x == mx { h = bc - gc }
                    else if rgb.y == mx { h = 2 + rc - bc }
                    else if rgb.z == mx { h = 4 + gc - rc }
                    if h < 0 { h += 6 }
                }
                return (h, s, v)
            }
            for i in 0..<256 {
                let rgbA = a.colors[i]
                let rgbB = b.colors[i]
                var hsvA = rgb2hsvLocal(rgbA)
                let hsvB = rgb2hsvLocal(rgbB)
                if mode == .hsvCircular {
                    let d = hsvB.h - hsvA.h
                    if d > 3 { hsvA.h += 6 } else if d < -3 { hsvA.h -= 6 }
                }
                let newRGB = c0 * rgbA + c1 * rgbB
                let newH = c0 * hsvA.h + c1 * hsvB.h
                let newS = c0 * hsvA.s + c1 * hsvB.s
                let newV = c0 * hsvA.v + c1 * hsvB.v
                // hsv2rgb
                var hh = newH
                while hh >= 6 { hh -= 6 }; while hh < 0 { hh += 6 }
                let j = Int(floor(hh)); let f = hh - Double(j)
                let p = newV * (1 - newS)
                let q = newV * (1 - newS * f)
                let tt = newV * (1 - newS * (1 - f))
                let hsvRGB: SIMD3<Double>
                switch j {
                case 0: hsvRGB = SIMD3(newV, tt, p)
                case 1: hsvRGB = SIMD3(q, newV, p)
                case 2: hsvRGB = SIMD3(p, newV, tt)
                case 3: hsvRGB = SIMD3(p, q, newV)
                case 4: hsvRGB = SIMD3(tt, p, newV)
                default: hsvRGB = SIMD3(newV, p, q)
                }
                let expected = SIMD3<Double>(
                    min(max(rgbFraction * newRGB.x + (1 - rgbFraction) * hsvRGB.x, 0), 1),
                    min(max(rgbFraction * newRGB.y + (1 - rgbFraction) * hsvRGB.y, 0), 1),
                    min(max(rgbFraction * newRGB.z + (1 - rgbFraction) * hsvRGB.z, 0), 1)
                )
                assertEq(result.colors[i], expected, 1e-12,
                         "mode \(mode) slot \(i) not equivalent to 3-channel flam3 math")
                // Document the flam3-derived constants for opaque input (asserted
                // implicitly by Emberweft's Palette shape; stated here to pin
                // the proof): color[3] would be 1.0, index would be i. These
                // are not stored on Palette — that's the whole point of the
                // equivalence — so there is nothing to assert numerically; the
                // slot-aligned RGB match above is the load-bearing check.
            }
        }
    }

    // MARK: - hueRotation (interpolation.c:478 INTERP(hue_rotation))

    func testHueRotationLinear() {
        XCTAssertEqual(PaletteBlend.interpolateHueRotation(0.0, 1.0, at: 0.0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(PaletteBlend.interpolateHueRotation(0.0, 1.0, at: 1.0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(PaletteBlend.interpolateHueRotation(0.0, 1.0, at: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(PaletteBlend.interpolateHueRotation(-0.25, 0.75, at: 0.5), 0.25, accuracy: 1e-12)
    }
}

private func assertPaletteEqual(_ a: Palette, _ b: Palette, _ accuracy: Double,
                                _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.colors.count, 256, message, file: file, line: line)
    XCTAssertEqual(b.colors.count, 256, message, file: file, line: line)
    for i in 0..<256 {
        XCTAssertEqual(a.colors[i].x, b.colors[i].x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.colors[i].y, b.colors[i].y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.colors[i].z, b.colors[i].z, accuracy: accuracy, message, file: file, line: line)
    }
}
