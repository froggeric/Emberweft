import XCTest
@testable import FlameKit

final class GenomeTests: XCTestCase {
    func testAffineTransformFlam3Convention() {
        // flam3 parses coefs="a b c d e f" into matrix | a c e | / | b d f |
        // (parser.c:974, variations.c:2145): x' = a·x + c·y + e, y' = b·x + d·y + f.
        // Use distinct values so a regression to any other layout is caught.
        // coefs = "1 2 3 4 5 6" applied to (x=10, y=100):
        //   x' = 1·10 + 3·100 + 5 = 315
        //   y' = 2·10 + 4·100 + 6 = 426
        let t = AffineTransform(a: 1, b: 2, c: 3, d: 4, e: 5, f: 6)
        let r = t.apply(SIMD2<Double>(10, 100))
        XCTAssertEqual(r.x, 315, accuracy: 1e-6)
        XCTAssertEqual(r.y, 426, accuracy: 1e-6)
    }

    func testAffineTransformIdentity() {
        let p = SIMD2<Double>(1.234, -5.678)
        XCTAssertEqual(AffineTransform.identity.apply(p), p)
    }

    func testDefaultFlameHasDocumentedDefaults() {
        let f = Flame(name: "x", size: SIMD2<Int>(100, 100))
        XCTAssertEqual(f.camera.scale, 250)
        XCTAssertEqual(f.quality.samplesPerPixel, 100)
        XCTAssertEqual(f.quality.oversample, 1)
        XCTAssertEqual(f.quality.gamma, 2.2)
        XCTAssertEqual(f.palette.colors.count, 256)
    }

    func testVariationCarriesParameters() {
        var v = Variation(name: "curl", weight: 1)
        v.parameters = ["curl_c1": 0.5, "curl_c2": -0.2]
        XCTAssertEqual(v.parameters["curl_c1"], 0.5)
        // default-init path still works (existing call sites)
        let bare = Variation(name: "linear", weight: 1)
        XCTAssertEqual(bare.parameters, [:])
        // positional init with non-default parameters
        let v2 = Variation(name: "curl", weight: 1, parameters: ["curl_c1": 0.5, "curl_c2": -0.2])
        XCTAssertEqual(v2.parameters["curl_c1"], 0.5)
        XCTAssertEqual(v2.parameters["curl_c2"], -0.2)
    }

    func testXformAnimationFields() {
        let x = Xform()
        XCTAssertEqual(x.animate, 1.0)        // random xforms default to rotating
        XCTAssertEqual(x.padding, 0)
        XCTAssertEqual(x.wind, SIMD2<Double>.zero)
    }

    func testFlameAnimationFields() {
        let f = Flame()
        XCTAssertEqual(f.interpolation, .linear)
        XCTAssertEqual(f.interpolationType, .log)        // ES default
        XCTAssertEqual(f.paletteInterpolation, .hsvCircular)
        XCTAssertEqual(f.hueRotation, 0)
        XCTAssertEqual(f.hsvRgbPaletteBlend, 0)          // live rgb↔hsv mix fraction (default 0 = pure HSV)
        XCTAssertEqual(f.hueShift, 0)                    // retained, round-trip only (F4)
    }

    func testPaletteInterpolationWireToken() {
        XCTAssertEqual(PaletteInterpolation.hsvCircular.rawValue, "hsv_circular")
        XCTAssertEqual(PaletteInterpolation(rawValue: "hsv_circular"), .hsvCircular)
        XCTAssertEqual(PaletteInterpolation.sweep.rawValue, "sweep")
        XCTAssertEqual(PaletteInterpolation.rgb.rawValue, "rgb")
        XCTAssertEqual(PaletteInterpolation.hsv.rawValue, "hsv")
    }
}
