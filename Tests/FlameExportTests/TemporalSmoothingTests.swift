import XCTest
@testable import FlameExport

final class TemporalSmoothingTests: XCTestCase {
    func testOffAndGenomeAreIdentity() {
        XCTAssertEqual(TemporalSmoothing.off.alpha(for: .spp(2)), 1.0)
        XCTAssertEqual(TemporalSmoothing.auto.alpha(for: .genome), 1.0)
    }

    // MARK: - flat α (RETUNED 2026-08-11: was the continuous `rampAlpha(spp:)` ramp)

    /// `.auto` + `.spp` ⇒ flat α = 0.2 for ANY spp (was a continuous ramp through
    /// anchors (2,0.10)/(8,0.20)/(30,0.35)/(64,1.0)). α is now vestigial — the
    /// centered window uses `halfWidth(for:)` (= `centeredHalfWidth`), not α —
    /// but is kept so `ExportSettings.smoothingAlpha` stays consistent (`< 1.0`
    /// = ON) for the resume-warmup notice check.
    func testAutoSppIsFlatAlpha() {
        for n in [1, 2, 8, 30, 64, 100, 128, 200, 10_000] {
            XCTAssertEqual(TemporalSmoothing.auto.alpha(for: .spp(n)), 0.2, accuracy: 1e-9,
                           "flat α=0.2 for spp=\(n)")
        }
    }

    // MARK: - halfWidth(for:) uniform (RETUNED 2026-08-11)

    /// `.auto` + `.spp` ⇒ uniform `centeredHalfWidth` (5) for ANY spp; `.off`
    /// and `.genome` ⇒ 0 (OFF). Decoupled from α (was `round(1/α)`, which clamped
    /// to 0 at spp ≥ 64).
    func testHalfWidthForIsUniformForSpp() {
        XCTAssertEqual(TemporalSmoothing.centeredHalfWidth, 5)
        XCTAssertEqual(TemporalSmoothing.off.halfWidth(for: .spp(8)), 0)
        XCTAssertEqual(TemporalSmoothing.auto.halfWidth(for: .genome), 0)
        for n in [1, 2, 8, 30, 64, 100, 128, 200, 10_000] {
            XCTAssertEqual(TemporalSmoothing.auto.halfWidth(for: .spp(n)), 5,
                           "uniform h=5 for spp=\(n)")
        }
    }

    // MARK: - halfWidth(forAlpha:) hardening (no trap on degenerate α)
    // halfWidth(forAlpha:) is KEPT: ExportCoordinator calls it directly to gate
    // on the checkpoint-decoded `smoothingAlpha` (defensive against corrupt /
    // hand-edited values). Under the flat α=0.2 it yields h=5 (== centeredHalfWidth),
    // so both `halfWidth(for:)` paths agree.

    /// α ≥ 1.0 ⇒ OFF (halfWidth 0). Mirrors the smoothing-ON gate.
    func testHalfWidthForAlphaOff() {
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: 1.0), 0)
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: 1.5), 0)
    }

    /// α ∈ (0,1) ⇒ h = round(1/α). The flat α=0.2 production value ⇒ h=5.
    func testHalfWidthForAlphaAnchors() {
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: 0.20), 5)
        // Pure round(1/α) math pins (no longer ramp "anchors", just function math).
        XCTAssertEqual(TemporalSmoothing.halfWidth(forAlpha: 0.10), 10)
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
