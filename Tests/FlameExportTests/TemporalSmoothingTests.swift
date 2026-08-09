import XCTest
@testable import FlameExport

final class TemporalSmoothingTests: XCTestCase {
    func testOffAndGenomeAreIdentity() {
        XCTAssertEqual(TemporalSmoothing.off.alpha(for: .spp(2)), 1.0)
        XCTAssertEqual(TemporalSmoothing.auto.alpha(for: .genome), 1.0)
    }
    func testAnchorsExact() {
        XCTAssertEqual(TemporalSmoothing.rampAlpha(spp: 2), 0.10, accuracy: 1e-9)
        XCTAssertEqual(TemporalSmoothing.rampAlpha(spp: 8), 0.20, accuracy: 1e-9)
        XCTAssertEqual(TemporalSmoothing.rampAlpha(spp: 30), 0.35, accuracy: 1e-9)
        XCTAssertEqual(TemporalSmoothing.rampAlpha(spp: 64), 1.0, accuracy: 1e-9)
    }
    func testClamps() {
        XCTAssertEqual(TemporalSmoothing.rampAlpha(spp: 1), 0.10, accuracy: 1e-9)
        XCTAssertEqual(TemporalSmoothing.rampAlpha(spp: 0), 0.10, accuracy: 1e-9)
        XCTAssertEqual(TemporalSmoothing.rampAlpha(spp: 10_000), 1.0, accuracy: 1e-9)
    }
    func testMonotoneNonDecreasing() {
        var prev = 0.0
        for n in [2, 3, 4, 5, 8, 12, 20, 30, 40, 50, 64] {
            let a = TemporalSmoothing.rampAlpha(spp: n)
            XCTAssertGreaterThanOrEqual(a, prev - 1e-12, "non-monotone at spp=\(n)")
            prev = a
        }
    }
}
