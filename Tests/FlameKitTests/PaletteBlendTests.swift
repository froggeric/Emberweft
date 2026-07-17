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
