import XCTest
@testable import FlameKit

/// Pinned behavior for the small Histogram/RenderParams helpers added alongside
/// the temporal-filter port (Task 1). Pure value-type methods with no renderer
/// coupling, so they live here next to the other model-level tests.
final class HistogramHelpersTests: XCTestCase {

    // MARK: - Histogram.accumulate

    func testAccumulateSumsColorsAlphaCountsElementwise() {
        // 1×2 grid (2 cells) with distinct values per channel/cell so any
        // mis-dispatch (wrong array, wrong offset, wrong field) is caught.
        var a = Histogram(gridWidth: 1, gridHeight: 2)
        a.colors[0] = SIMD3<Double>(1, 2, 3)
        a.colors[1] = SIMD3<Double>(4, 5, 6)
        a.alpha[0]  = 0.10; a.alpha[1]  = 0.20
        a.counts[0] = 7;    a.counts[1] = 8

        var b = Histogram(gridWidth: 1, gridHeight: 2)
        b.colors[0] = SIMD3<Double>(10, 20, 30)
        b.colors[1] = SIMD3<Double>(40, 50, 60)
        b.alpha[0]  = 1.00; b.alpha[1]  = 2.00
        b.counts[0] = 70;   b.counts[1] = 80

        a.accumulate(b)

        XCTAssertEqual(a.colors[0], SIMD3<Double>(11, 22, 33))
        XCTAssertEqual(a.colors[1], SIMD3<Double>(44, 55, 66))
        XCTAssertEqual(a.alpha[0], 1.10, accuracy: 1e-12)
        XCTAssertEqual(a.alpha[1], 2.20, accuracy: 1e-12)
        XCTAssertEqual(a.counts[0], 77, accuracy: 1e-12)
        XCTAssertEqual(a.counts[1], 88, accuracy: 1e-12)
    }

    func testAccumulateIsIdempotentOnEmptyRHSAndPreservesDims() {
        // Accumulating a zero-initialized histogram is a no-op for values and
        // must NOT touch gridWidth/gridHeight (they're `let`).
        var a = Histogram(gridWidth: 3, gridHeight: 4)
        a.colors[5] = SIMD3<Double>(1, 1, 1)
        a.alpha[5]  = 2
        a.counts[5] = 3
        let snapshot = a
        a.accumulate(Histogram(gridWidth: 3, gridHeight: 4))
        XCTAssertEqual(a, snapshot)
        XCTAssertEqual(a.gridWidth, 3)
        XCTAssertEqual(a.gridHeight, 4)
    }

    // The precondition (gridWidth/gridHeight match) cannot be trap-tested
    // in-process — a `precondition` failure aborts the test runner, not just
    // the calling thread. This matches the rest of the codebase (14+ other
    // `precondition` guards in FlameKit/FlameReference are likewise not
    // trap-tested). The happy-path tests above pin the post-condition that the
    // guard protects (no corruption on valid input); the guard itself is
    // visually verified at RenderTypes.swift:81.

    // MARK: - Histogram.scale

    func testScaleMultipliesColorsAlphaCountsElementwise() {
        var h = Histogram(gridWidth: 1, gridHeight: 2)
        h.colors[0] = SIMD3<Double>(1, 2, 3)
        h.colors[1] = SIMD3<Double>(4, 5, 6)
        h.alpha[0]  = 0.5; h.alpha[1]  = 2.0
        h.counts[0] = 10;  h.counts[1] = 20

        h.scale(by: 3.0)

        XCTAssertEqual(h.colors[0], SIMD3<Double>(3, 6, 9))
        XCTAssertEqual(h.colors[1], SIMD3<Double>(12, 15, 18))
        XCTAssertEqual(h.alpha[0], 1.5, accuracy: 1e-12)
        XCTAssertEqual(h.alpha[1], 6.0, accuracy: 1e-12)
        XCTAssertEqual(h.counts[0], 30, accuracy: 1e-12)
        XCTAssertEqual(h.counts[1], 60, accuracy: 1e-12)
    }

    func testScaleByOneIsIdentity() {
        var h = Histogram(gridWidth: 2, gridHeight: 2)
        h.colors[0] = SIMD3<Double>(0.25, 0.5, 0.75)
        h.alpha[0]  = 0.125
        h.counts[0] = 42
        let snapshot = h
        h.scale(by: 1.0)
        XCTAssertEqual(h, snapshot)
    }

    // MARK: - RenderParams.settingSamplesPerPixel

    func testSettingSamplesPerPixelReturnsCopyWithOnlySamplesPerPixelChanged() {
        let p = RenderParams(seed: 42, width: 320, height: 240, oversample: 2, samplesPerPixel: 100)
        let q = p.settingSamplesPerPixel(50)

        // Only samplesPerPixel moves; everything else is identity.
        XCTAssertEqual(q.samplesPerPixel, 50)
        XCTAssertEqual(q.seed, p.seed)
        XCTAssertEqual(q.width, p.width)
        XCTAssertEqual(q.height, p.height)
        XCTAssertEqual(q.oversample, p.oversample)
    }

    func testSettingSamplesPerPixelEqualitySemantics() {
        let p = RenderParams(seed: 1, width: 10, height: 10, oversample: 1, samplesPerPixel: 100)

        // Equal samplesPerPixel → Equal value (the helper must NOT touch any
        // other field; otherwise this would diverge).
        XCTAssertEqual(p.settingSamplesPerPixel(100), p)

        // Different samplesPerPixel → Unequal value.
        XCTAssertNotEqual(p.settingSamplesPerPixel(50), p)
    }
}
