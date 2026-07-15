import XCTest
@testable import FlameKit

final class GenomeTests: XCTestCase {
    func testAffineTransformFlam3Convention() {
        // coefs a b c d e f = 1 0 5  0 1 7  -> x'=x+5, y'=y+7
        let t = AffineTransform(a: 1, b: 0, c: 5, d: 0, e: 1, f: 7)
        let r = t.apply(SIMD2<Float>(2, -3))
        XCTAssertEqual(r.x, 7, accuracy: 1e-6)
        XCTAssertEqual(r.y, 4, accuracy: 1e-6)
    }

    func testAffineTransformIdentity() {
        let p = SIMD2<Float>(1.234, -5.678)
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
}
