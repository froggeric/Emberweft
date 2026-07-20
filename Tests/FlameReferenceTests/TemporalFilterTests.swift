import XCTest
@testable import FlameReference
@testable import FlameKit

final class TemporalFilterTests: XCTestCase {
    func testBoxFilterUnitWeightsEvenDeltasSpanWidth() {
        let (f, sumfilt) = TemporalFilter.samples(4, type: .box, width: 1.2, exp: 0)
        XCTAssertEqual(f.count, 4)
        // Box: every weight is LITERALLY 1.0 (filters.c:469-472, max=1, /1).
        for s in f { XCTAssertEqual(s.weight, 1.0, accuracy: 1e-12) }
        XCTAssertEqual(sumfilt, 1.0, accuracy: 1e-12)            // (4·1)/4 == 1
        // deltas: ((i/(n-1)) - 0.5) * width, i.e. {-0.6, -0.2, +0.2, +0.6}
        let mean = f.map(\.delta).reduce(0, +) / Double(f.count)
        XCTAssertEqual(mean, 0.0, accuracy: 1e-12)
        XCTAssertEqual(f.last!.delta - f.first!.delta, 1.2, accuracy: 1e-12)   // span == width
    }

    func testSingleSampleIsNoBlur() {
        let (f, sumfilt) = TemporalFilter.samples(1, type: .box, width: 1.0, exp: 0)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].weight, 1.0)
        XCTAssertEqual(f[0].delta, 0.0, accuracy: 1e-12)
        XCTAssertEqual(sumfilt, 1.0, accuracy: 1e-12)
    }

    func testGaussianMaxNormalizedToUnit() {
        let (f, sumfilt) = TemporalFilter.samples(8, type: .gaussian, width: 1.2, exp: 0)
        XCTAssertEqual(f.count, 8)
        // Max-normalized to 1.0 (filters.c:476-483 — divide-by-max step).
        let mx = f.map(\.weight).max()!
        XCTAssertEqual(mx, 1.0, accuracy: 1e-12)
        // flam3 centers the gaussian at `halfsteps = numsteps/2.0` (filters.c:456,
        // `fabs(i - halfsteps)`), NOT at the array midpoint. For n=8 that puts
        // the peak at index 4 (an integer), so the symmetric pairs are
        // (1,7), (2,6), (3,5); f[0] has no counterpart (its mirror would be
        // f[8], which is out of bounds) and is the smallest weight (most
        // distant from the peak). The provided spec's `f[0]==f[7]` assertion
        // would only hold for a midpoint-centered gaussian, which flam3 is not.
        let peak = f[4].weight
        XCTAssertEqual(peak, mx, accuracy: 1e-12, "peak must sit at index halfsteps = n/2 = 4")
        XCTAssertEqual(f[1].weight, f[7].weight, accuracy: 1e-12)
        XCTAssertEqual(f[2].weight, f[6].weight, accuracy: 1e-12)
        XCTAssertEqual(f[3].weight, f[5].weight, accuracy: 1e-12)
        // Monotone increasing from each edge toward the peak.
        XCTAssertLessThan(f[0].weight, f[1].weight)
        XCTAssertLessThan(f[1].weight, f[2].weight)
        XCTAssertLessThan(f[2].weight, f[3].weight)
        XCTAssertLessThan(f[3].weight, f[4].weight)
        XCTAssertLessThan(sumfilt, 1.0)                         // (Σw)/8 < 1
    }

    func testExpBranchPositiveExpMonotoneIncreasingMaxNormalized() {
        // filters.c:437-452 — for filter_exp > 0, slpx = (i+1)/n (rising),
        // filter[i] = pow(slpx, |filter_exp|). After max-norm, last weight is 1.0.
        let (f, sumfilt) = TemporalFilter.samples(8, type: .exp, width: 1.2, exp: 2.0)
        XCTAssertEqual(f.count, 8)
        // f[7] uses slpx = 8/8 = 1.0 → 1.0² = 1.0 (the max), unchanged by /maxfilt.
        XCTAssertEqual(f[7].weight, 1.0, accuracy: 1e-12)
        // Spot-check f[0]: slpx = 1/8, weight = (1/8)² = 0.015625.
        XCTAssertEqual(f[0].weight, 0.015625, accuracy: 1e-12)
        // Strictly monotone increasing for positive exp.
        for i in 0..<7 {
            XCTAssertLessThan(f[i].weight, f[i + 1].weight, "exp(+) must be monotone increasing")
        }
        XCTAssertLessThan(sumfilt, 1.0)
    }

    func testExpBranchNegativeExpMonotoneDecreasing() {
        // filters.c:444 — for filter_exp < 0, slpx = (n-i)/n (falling), so the
        // peak flips to index 0 and the curve is monotone DECREASING.
        let (f, _) = TemporalFilter.samples(8, type: .exp, width: 1.2, exp: -2.0)
        XCTAssertEqual(f.count, 8)
        XCTAssertEqual(f[0].weight, 1.0, accuracy: 1e-12)   // slpx = 8/8 → 1.0²
        XCTAssertEqual(f[7].weight, 0.015625, accuracy: 1e-12)  // slpx = 1/8 → (1/8)²
        for i in 0..<7 {
            XCTAssertGreaterThan(f[i].weight, f[i + 1].weight, "exp(-) must be monotone decreasing")
        }
    }
}
