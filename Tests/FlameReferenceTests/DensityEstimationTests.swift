import XCTest
@testable import FlameReference
import FlameKit

final class DensityEstimationTests: XCTestCase {
    func testPassthroughWhenDisabled() {
        var h = Histogram(gridWidth: 8, gridHeight: 8)
        for i in 0..<h.counts.count { h.counts[i] = 5; h.colors[i] = SIMD3<Float>(0.2, 0.3, 0.4) }
        let out = DensityEstimation.apply(h, radius: 0, minimum: 0, curve: 0.6)
        XCTAssertEqual(out.counts, h.counts)
        XCTAssertEqual(out.colors, h.colors)            // exact passthrough
    }

    func testCountsPreservedExactly() {
        // Count mass is an exact invariant of this approximation.
        var h = Histogram(gridWidth: 9, gridHeight: 9)
        let c = h.binIndex(4, 4)
        h.counts[c] = 1000; h.colors[c] = SIMD3<Float>(1, 1, 1)
        h.counts[h.binIndex(3, 4)] = 2; h.colors[h.binIndex(3, 4)] = SIMD3<Float>(0.1, 0.2, 0.3)
        let out = DensityEstimation.apply(h, radius: 3, minimum: 1, curve: 0.6)
        XCTAssertEqual(out.counts, h.counts)
    }

    func testIsolatedBinIsApproximatelyIdentity() {
        // An isolated non-zero bin does NOT spread: its output color stays ~equal
        // to its input average color. (Documents the M1 approximation honestly.)
        // Measured drift on this implementation is exactly 0: empty neighbors fall
        // back to the center's `colorAvg`, and the conical kernel weights them by
        // `1 - dist/max(r,1)`. For a dense center the adaptive radius collapses
        // below 1 so only the center cell (dist=0, w=1) contributes, yielding
        // out == in exactly. Even for sparser bins the fallback keeps the weighted
        // average equal to colorAvg, so identity holds regardless of radius.
        var h = Histogram(gridWidth: 9, gridHeight: 9)
        let c = h.binIndex(4, 4)
        h.counts[c] = 1000; h.colors[c] = SIMD3<Float>(1, 1, 1)
        let out = DensityEstimation.apply(h, radius: 3, minimum: 1, curve: 0.6)
        let avgIn = h.colors[c] / h.counts[c]
        let avgOut = out.colors[c] / out.counts[c]
        XCTAssertEqual(avgOut.x, avgIn.x, accuracy: 1e-4)
        XCTAssertEqual(avgOut.y, avgIn.y, accuracy: 1e-4)
        XCTAssertEqual(avgOut.z, avgIn.z, accuracy: 1e-4)
    }

    func testOutputFiniteEverywhere() {
        var h = Histogram(gridWidth: 9, gridHeight: 9)
        let c = h.binIndex(4, 4)
        h.counts[c] = 1000; h.colors[c] = SIMD3<Float>(1, 1, 1)
        let out = DensityEstimation.apply(h, radius: 3, minimum: 1, curve: 0.6)
        XCTAssertTrue(out.colors.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        XCTAssertTrue(out.counts.allSatisfy { $0.isFinite })
    }
}
