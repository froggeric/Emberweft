import XCTest
import Foundation
@testable import FlamePlayer

// Tests for Task 21: AdaptiveQualityController (M3 deterministic-quality gate).
//
// The controller is a PURE value type: `(measuredFps, thermalState,
// currentBudget) -> newBudget` with hysteretic feedback. Fed SIMULATED fps /
// thermal signals, it is fully deterministic — this is the M3 gate; real
// thermal-throttle behavior is verified manually and deferred to M4.
//
// Defaults under test (Config.default):
//   targetFps                       = 30
//   deadbandFps                     = 3      → step DOWN below 27, UP above 33
//   downFactor                      = 0.5    (halve)
//   upFactor                        = 2.0    (double)
//   minSamplesPerPixel              = 2
//   maxSamplesPerPixel              = 512
//   criticalFloorSamplesPerPixel    = 4      (.critical thermal → floor)
final class AdaptiveQualityControllerTests: XCTestCase {

    private let ctrl = AdaptiveQualityController()

    // MARK: - AC: pure + deterministic mapping table (hand-computed)

    // Each row: (fps, thermal, currentBudget) → expected newBudget, recomputed
    // by hand from the documented thresholds. The same inputs MUST always yield
    // the same output — no Date(), no RNG, no global state.
    func testDeterministicMappingTable() {
        // (fps, thermal, current, expected)
        let cases: [(Double, ProcessInfo.ThermalState, Int, Int)] = [
            // Deadband [27, 33] inclusive → unchanged (clamped to range).
            (30.0, .nominal, 100, 100),   // center of deadband
            (29.0, .nominal,  64,  64),   // inside deadband
            (27.0, .nominal,  64,  64),   // lower boundary inclusive
            (33.0, .nominal,  64,  64),   // upper boundary inclusive
            // Below 27 → step DOWN (× 0.5).
            (26.9, .nominal,  64,  32),   // just below lower boundary
            (25.0, .nominal, 100,  50),
            (20.0, .nominal, 200, 100),
            // Above 33 → step UP (× 2.0).
            (33.1, .nominal,  64, 128),   // just above upper boundary
            (40.0, .nominal, 100, 200),
            (45.0, .nominal,  50, 100),
            // .fair / .serious behave like .nominal (only .critical forces floor).
            (25.0, .fair,    100,  50),
            (40.0, .fair,    100, 200),
            (25.0, .serious, 100,  50),
            (40.0, .serious, 100, 200),
            // .critical → floor (4) regardless of fps.
            (15.0, .critical, 100,   4),  // low fps + critical → floor
            (60.0, .critical, 100,   4),  // high fps + critical → STILL floor
            (30.0, .critical, 512,   4),  // deadband fps, but critical → floor
            // Clamping to [min=2, max=512].
            (20.0, .nominal,   2,   2),   // down from min clamps to min
            (20.0, .nominal,   3,   2),   // 3×0.5=1.5 → 2 (round + clamp)
            (40.0, .nominal, 512, 512),   // up from max clamps to max
            (40.0, .nominal, 300, 512),   // 300×2=600 → clamp to 512
            // Out-of-range input budget is normalized into range even in deadband.
            (30.0, .nominal,   1,   2),   // below min → clamp up to min
            (30.0, .nominal, 999, 512),   // above max → clamp down to max
        ]

        for (i, c) in cases.enumerated() {
            let (fps, thermal, current, expected) = c
            let got = ctrl.step(measuredFps: fps, thermalState: thermal, currentBudget: current)
            XCTAssertEqual(got, expected,
                           "case \(i): fps=\(fps) thermal=\(thermal) current=\(current) → expected \(expected), got \(got)")
        }
    }

    // MARK: - AC: determinism — repeated calls with identical inputs are identical

    func testDeterminismRepeatedCalls() {
        for _ in 0..<50 {
            let a = ctrl.step(measuredFps: 22.0, thermalState: .nominal, currentBudget: 96)
            let b = ctrl.step(measuredFps: 22.0, thermalState: .nominal, currentBudget: 96)
            XCTAssertEqual(a, b, "identical inputs must yield identical output (every call)")
        }
    }

    // MARK: - AC: deadband stability — fps jitter inside the deadband never moves the budget

    // A realistic jitter sequence (29.5, 28.1, 31.4, 27.6, 30.9, 32.2, 28.8) all
    // inside [27, 33]. Starting at budget 100, the budget must stay 100 across
    // every step — the deadband is the anti-oscillation guarantee.
    func testDeadbandStabilityUnderJitter() {
        let jitter: [Double] = [29.5, 28.1, 31.4, 27.6, 30.9, 32.2, 28.8,
                                30.0, 27.0, 33.0, 31.0, 29.0]
        var budget = 100
        for fps in jitter {
            budget = ctrl.step(measuredFps: fps, thermalState: .nominal, currentBudget: budget)
            XCTAssertEqual(budget, 100, "fps=\(fps) is inside the deadband; budget must not move")
        }
    }

    // MARK: - AC: sustained below-threshold fps steps the budget DOWN each step

    // 20 fps (< 27) sustained: starting at 200, the budget halves each step:
    // 200 → 100 → 50 → 25. Each call sees the previous output as currentBudget.
    func testSustainedBelowStepsDown() {
        var budget = 200
        let expected = [100, 50, 25]
        for (i, want) in expected.enumerated() {
            budget = ctrl.step(measuredFps: 20.0, thermalState: .nominal, currentBudget: budget)
            XCTAssertEqual(budget, want, "step \(i) of sustained-below: expected \(want), got \(budget)")
        }
    }

    // MARK: - AC: sustained above-threshold fps steps the budget UP each step

    // 40 fps (> 33) sustained: starting at 25, the budget doubles each step:
    // 25 → 50 → 100 → 200.
    func testSustainedAboveStepsUp() {
        var budget = 25
        let expected = [50, 100, 200]
        for (i, want) in expected.enumerated() {
            budget = ctrl.step(measuredFps: 40.0, thermalState: .nominal, currentBudget: budget)
            XCTAssertEqual(budget, want, "step \(i) of sustained-above: expected \(want), got \(budget)")
        }
    }

    // MARK: - AC: .critical thermal forces the floor regardless of fps

    // No matter the budget or fps, .critical → 4 (the configured floor).
    func testCriticalThermalForcesFloor() {
        let budgets = [2, 8, 64, 256, 512]
        let fpss: [Double] = [10, 20, 30, 45, 120]
        for budget in budgets {
            for fps in fpss {
                let got = ctrl.step(measuredFps: fps, thermalState: .critical, currentBudget: budget)
                XCTAssertEqual(got, 4,
                               "critical thermal: fps=\(fps) budget=\(budget) → expected floor 4, got \(got)")
            }
        }
    }

    // MARK: - AC: budget always stays within [minSamplesPerPixel, maxSamplesPerPixel]

    // Fuzz-ish: drive many step sequences and assert the result is in range.
    func testBudgetStaysWithinBounds() {
        let min = AdaptiveQualityController.Config.default.minSamplesPerPixel
        let max = AdaptiveQualityController.Config.default.maxSamplesPerPixel
        var budget = 100
        let fpss: [Double] = [1, 10, 20, 26, 27, 30, 33, 34, 60, 200]
        let thermals: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        for fps in fpss {
            for thermal in thermals {
                budget = ctrl.step(measuredFps: fps, thermalState: thermal, currentBudget: budget)
                XCTAssertGreaterThanOrEqual(budget, min, "fps=\(fps) thermal=\(thermal): below min")
                XCTAssertLessThanOrEqual(budget, max, "fps=\(fps) thermal=\(thermal): above max")
            }
        }
    }

    // MARK: - AC: hysteresis — a single below/above excursion then return to
    // deadband does NOT auto-revert; recovery requires sustained above-threshold.

    // Drop below (20 fps) once: 100 → 50. Return to deadband (30 fps): stays 50
    // (no free recovery). Only sustained above-threshold lifts it back up.
    func testHysteresisNoFreeRevert() {
        var budget = 100
        budget = ctrl.step(measuredFps: 20.0, thermalState: .nominal, currentBudget: budget)
        XCTAssertEqual(budget, 50, "below-threshold step down")
        // Deadband does NOT restore the budget.
        budget = ctrl.step(measuredFps: 30.0, thermalState: .nominal, currentBudget: budget)
        XCTAssertEqual(budget, 50, "deadband must not auto-revert the earlier step-down")
        budget = ctrl.step(measuredFps: 31.0, thermalState: .nominal, currentBudget: budget)
        XCTAssertEqual(budget, 50, "still inside deadband — unchanged")
        // Above threshold recovers.
        budget = ctrl.step(measuredFps: 40.0, thermalState: .nominal, currentBudget: budget)
        XCTAssertEqual(budget, 100, "above-threshold step up")
    }

    // MARK: - AC: pure value type — equality + Sendable compile-time contract

    func testControllerIsPureValueType() {
        // Equal configs → equal controllers (value semantics).
        let a = AdaptiveQualityController()
        let b = AdaptiveQualityController()
        XCTAssertEqual(a, b, "default-constructed controllers are equal (value type)")
        // Different config → not equal.
        let custom = AdaptiveQualityController(config: .init(targetFps: 60))
        XCTAssertNotEqual(a, custom, "different config → different controller")
    }
}
