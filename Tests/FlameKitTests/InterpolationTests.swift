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
}
