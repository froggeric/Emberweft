import XCTest
@testable import FlameExport
import FlameKit

final class HistogramEMATests: XCTestCase {
    private func hist(_ counts: [Double], _ rgb: [Double], _ a: [Double]) -> Histogram {
        var h = Histogram(gridWidth: counts.count, gridHeight: 1)
        h.counts = counts
        h.colors = stride(from: 0, to: rgb.count, by: 3).map { SIMD3<Double>(rgb[$0], rgb[$0+1], rgb[$0+2]) }
        h.alpha = a
        return h
    }

    func testColdStartCopiesCurrent() {
        var acc: Histogram? = nil
        let h = hist([2, 4], [10,20,30, 40,50,60], [1, 2])
        HistogramEMA.update(&acc, current: h, alpha: 0.2)
        XCTAssertEqual(acc?.counts, h.counts)
        XCTAssertEqual(acc?.alpha, h.alpha)
    }

    func testEmaIsElementwiseWeightedAverage() {
        var acc: Histogram? = hist([10, 0], [0,0,0, 0,0,0], [0, 0])
        let cur = hist([0, 10], [0,0,0, 0,0,0], [0, 0])
        HistogramEMA.update(&acc, current: cur, alpha: 0.25)   // 0.75·10 + 0.25·0 = 7.5
        XCTAssertEqual(acc!.counts[0], 7.5, accuracy: 1e-9)
        XCTAssertEqual(acc!.counts[1], 2.5, accuracy: 1e-9)
    }

    func testAlphaOneReturnsCurrentExact() {
        var acc: Histogram? = hist([9, 9], [1,1,1, 1,1,1], [9, 9])
        let cur = hist([3, 5], [2,4,6, 8,10,12], [1, 2])
        HistogramEMA.update(&acc, current: cur, alpha: 1.0)
        XCTAssertEqual(acc?.counts, cur.counts)
        XCTAssertEqual(acc?.alpha, cur.alpha)
    }

    func testAlphaZeroFreezesAccumulator() {
        var acc: Histogram? = hist([7, 3], [0,0,0, 0,0,0], [5, 5])
        let cur = hist([100, 100], [9,9,9, 9,9,9], [9, 9])
        HistogramEMA.update(&acc, current: cur, alpha: 0.0)
        XCTAssertEqual(acc?.counts, [7, 3])
    }
}
