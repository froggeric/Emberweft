import XCTest
@testable import FlameReference
import FlameKit

final class DensityEstimationTests: XCTestCase {
    func testPassthroughWhenDisabled() {
        var h = Histogram(gridWidth: 8, gridHeight: 8)
        for i in 0..<h.counts.count { h.counts[i] = 5; h.colors[i] = SIMD3(0.2, 0.3, 0.4) }
        let out = DensityEstimation.apply(h, radius: 0, minimum: 0, curve: 0.6)
        XCTAssertEqual(out.counts, h.counts)
    }
    func testSpreadsHotBin() {
        var h = Histogram(gridWidth: 9, gridHeight: 9)
        let c = h.binIndex(4, 4)
        h.counts[c] = 1000; h.colors[c] = SIMD3(1, 1, 1)
        let out = DensityEstimation.apply(h, radius: 3, minimum: 1, curve: 0.6)
        var sum: Float = 0
        for i in 0..<out.counts.count { sum += out.counts[i] }
        XCTAssertGreaterThan(sum, 0)
        XCTAssertTrue(out.colors.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }
}
