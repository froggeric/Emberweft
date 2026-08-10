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

    // MARK: - T8′ halfWidth(forAlpha:) hardening (no trap on degenerate α)

    /// α ≥ 1.0 ⇒ OFF (halfWidth 0). Mirrors the smoothing-ON gate.
    func testHalfWidthForAlphaOff() {
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: 1.0), 0)
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: 1.5), 0)
    }

    /// α ∈ (0,1) ⇒ h = round(1/α). Anchors match the named tiers.
    func testHalfWidthForAlphaAnchors() {
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: 0.10), 10)
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: 0.20), 5)
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: 0.35), 3)
    }

    /// α ≤ 0 MUST be OFF (not a trap). Regression pin: the naive
    /// `Int((1.0/alpha).rounded())` traps on α=0 (`Int(+∞)`) and α=NaN
    /// (`Int(NaN)`); the guard returns 0 instead. α is decoded from checkpoint
    /// JSON unchecked, so a corrupt/hand-edited value must not crash the resume.
    func testHalfWidthForAlphaZeroAndNaNIsOff() {
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: 0.0), 0, "α=0 must be OFF not trap")
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: -0.5), 0, "negative α must be OFF")
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: .nan), 0, "NaN α must be OFF (0), not trap")
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: .infinity), 0)
    }
}
