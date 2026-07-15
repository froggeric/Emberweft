import XCTest
@testable import FlameKit

final class InterpolationTests: XCTestCase {
    private func flame(_ c: Float, _ scale: Float, xformCount: Int = 1) -> Flame {
        Flame(camera: Camera(scale: scale),
              xforms: (0..<xformCount).map { _ in
                  Xform(affine: AffineTransform(a: c, b: 0, c: 0, d: 0, e: c, f: 0),
                        variations: [Variation(name: "linear", weight: 1)]) })
    }
    func testEndpoints() {
        let a = flame(1, 200), b = flame(2, 400)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 0), a)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 1), b)
    }
    func testMidpointCoeffs() {
        let a = flame(0, 200), b = flame(10, 200)
        let m = Interpolation.interpolate(a, b, at: 0.5)
        XCTAssertEqual(m.xforms[0].affine.a, 5, accuracy: 1e-6)
    }
    func testScaleLogSpace() {
        let a = flame(0, 100), b = flame(0, 400)
        let m = Interpolation.interpolate(a, b, at: 0.5)
        XCTAssertEqual(m.camera.scale, 200, accuracy: 1e-3)   // geometric mean
    }
    func testUnequalXformCounts() {
        let a = flame(1, 200, xformCount: 1), b = flame(2, 200, xformCount: 2)
        let m = Interpolation.interpolate(a, b, at: 0.5)
        XCTAssertEqual(m.xforms.count, 2)
    }
    func testExtraXformTakenUnchanged() {
        // Unequal counts: the extra xform must come through UNCHANGED from the longer side.
        let extra = Xform(affine: AffineTransform(a: 9, b: 0, c: 0, d: 0, e: 9, f: 0),
                          variations: [Variation(name: "spherical", weight: 2)])
        let a = flame(1, 200, xformCount: 1)
        var b = flame(2, 200, xformCount: 2)
        b.xforms[1] = extra
        let m = Interpolation.interpolate(a, b, at: 0.5)
        XCTAssertEqual(m.xforms.count, 2)
        XCTAssertEqual(m.xforms[1], extra)              // unchanged
    }
    func testEndpointsDifferInSizeAndQuality() {
        // Proves the Important fix: at t=1, size & quality come from b, not a.
        var a = flame(1, 200)
        var b = flame(2, 400)
        a.size = SIMD2<Int>(640, 480)
        b.size = SIMD2<Int>(320, 240)
        a.quality.samplesPerPixel = 10
        b.quality.samplesPerPixel = 90
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 0).size, a.size)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 0).quality, a.quality)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 1).size, b.size)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 1).quality, b.quality)
    }
    func testFinalXformAsymmetric() {
        var a = flame(1, 200)
        a.finalXform = Xform(variations: [Variation(name: "linear", weight: 1)])
        let b = flame(2, 400)
        // a has finalXform, b does not -> carried through (a.finalXform ?? b.finalXform).
        XCTAssertNotNil(Interpolation.interpolate(a, b, at: 0.5).finalXform)
        // b has none, a has one -> still carried through (b.finalXform ?? a.finalXform).
        XCTAssertNotNil(Interpolation.interpolate(b, a, at: 0.5).finalXform)
        // neither has one -> nil
        XCTAssertNil(Interpolation.interpolate(flame(1, 200), flame(2, 400), at: 0.5).finalXform)
    }
}
