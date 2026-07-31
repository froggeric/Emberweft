import XCTest
@testable import EmberweftUI
import FlameKit

final class GenomeHealthTests: XCTestCase {

    private func flame(center: SIMD2<Double> = .zero,
                       scale: Double = 250,
                       xformWeight: Double = 1.0) -> Flame {
        Flame(
            camera: Camera(center: center, scale: scale),
            xforms: [Xform(weight: xformWeight, variations: [Variation(name: "linear", weight: 1.0)])]
        )
    }

    func testWellFormedGenomeIsRenderable() {
        XCTAssertTrue(flame().isRenderable)
    }

    func testNaNCenterRejected() {
        let nan = Double.nan
        XCTAssertFalse(flame(center: SIMD2<Double>(nan, 0)).isRenderable)
        XCTAssertFalse(flame(center: SIMD2<Double>(0, nan)).isRenderable)
    }

    func testNaNScaleRejected() {
        XCTAssertFalse(flame(scale: .nan).isRenderable)
    }

    func testDegenerateScaleRejected() {
        XCTAssertFalse(flame(scale: -259).isRenderable)   // negative (real gen-248 example)
        XCTAssertFalse(flame(scale: 0).isRenderable)      // zero
        XCTAssertFalse(flame(scale: 6e-05).isRenderable)  // tiny (real gen-248 example)
        XCTAssertFalse(flame(scale: 5760).isRenderable)   // huge (out of band)
    }

    func testInBandScaleExtremesAccepted() {
        XCTAssertTrue(flame(scale: 1e-3).isRenderable)    // lower bound inclusive
        XCTAssertTrue(flame(scale: 4000).isRenderable)    // upper bound inclusive
        XCTAssertTrue(flame(scale: 3092).isRenderable)    // real gen-248 p999
    }

    func testZeroTotalXformWeightRejected() {
        XCTAssertFalse(flame(xformWeight: 0).isRenderable)
    }
}
