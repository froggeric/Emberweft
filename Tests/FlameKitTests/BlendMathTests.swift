import XCTest
@testable import FlameKit

/// Tests for the flam3 `interpolation.c` math ports (`smoother`, `get_stagger_coef`).
///
/// These pin (a) the smoothstep endpoints/monotonicity and (b) a hand-computed
/// staggered case derived directly from the C body of `get_stagger_coef`
/// (interpolation.c:343-367), including the C evaluation order for the
/// multiply-before-divide `st` term.
final class BlendMathTests: XCTestCase {

    // MARK: - smoother

    func testSmootherEndpoints() {
        // smoother(0) = 0, smoother(1) = 1 (also the blend identity).
        XCTAssertEqual(BlendMath.smoother(0), 0, accuracy: 0)
        XCTAssertEqual(BlendMath.smoother(1), 1, accuracy: 1e-15)
    }

    func testSmootherMidpoint() {
        // smoother(0.5) = 3·0.25 − 2·0.125 = 0.75 − 0.25 = 0.5 (fixed point).
        XCTAssertEqual(BlendMath.smoother(0.5), 0.5, accuracy: 1e-15)
    }

    func testSmootherMonotoneOnUnitInterval() {
        // smoother is monotone non-decreasing on [0,1]; sample finely.
        var prev = -Double.infinity
        for step in 0...100 {
            let t = Double(step) / 100.0
            let v = BlendMath.smoother(t)
            XCTAssertGreaterThanOrEqual(v, prev, "non-monotone at t=\(t)")
            prev = v
        }
        // Range stays within [0,1] across the unit interval.
        XCTAssertGreaterThanOrEqual(BlendMath.smoother(0), 0)
        XCTAssertLessThanOrEqual(BlendMath.smoother(1), 1)
    }

    // MARK: - staggerCoef gates (return smoother(t) unchanged)

    func testStaggerCoefStaggerZeroOrNegativeReturnsSmoother() {
        let t = 0.37
        // stagger == 0
        XCTAssertEqual(
            BlendMath.staggerCoef(t: t, stagger: 0,
                                  numXforms: 3, xformIndex: 0, isFinal: false),
            BlendMath.smoother(t), accuracy: 1e-15)
        // stagger < 0
        XCTAssertEqual(
            BlendMath.staggerCoef(t: t, stagger: -0.5,
                                  numXforms: 3, xformIndex: 0, isFinal: false),
            BlendMath.smoother(t), accuracy: 1e-15)
    }

    func testStaggerCoefFinalXformReturnsSmoother() {
        // The genome's final/post xform is never staggered.
        let t = 0.37
        XCTAssertEqual(
            BlendMath.staggerCoef(t: t, stagger: 0.5,
                                  numXforms: 3, xformIndex: 0, isFinal: true),
            BlendMath.smoother(t), accuracy: 1e-15)
    }

    // MARK: - staggerCoef staggered values (port of get_stagger_coef)

    /// Hand-computed reference for nx=3, i=0, stagger=0.5.
    ///
    /// ```
    /// max_stag    = (double)(3-1)/3        = 2/3
    /// stag_scaled = 0.5 * 2/3              = 1/3
    /// st          = (1/3 * (3-1-0)) / (3-1) = (1/3 * 2)/2 = 1/3   (multiply before divide)
    /// et          = 1/3 + (1 - 1/3)        = 1.0
    /// ```
    /// So the active window is [1/3, 1.0]; t ≤ 1/3 → 0, t ≥ 1 → 1.
    func testStaggerCoefKnownValuesNx3I0Stag0_5() {
        let nx = 3, i = 0, s = 0.5

        // t below the window → 0
        XCTAssertEqual(
            BlendMath.staggerCoef(t: 0.0, stagger: s, numXforms: nx, xformIndex: i, isFinal: false),
            0, accuracy: 1e-12)
        XCTAssertEqual(
            BlendMath.staggerCoef(t: 0.3, stagger: s, numXforms: nx, xformIndex: i, isFinal: false),
            0, accuracy: 1e-12)
        // t at the st boundary (t <= st) → 0
        XCTAssertEqual(
            BlendMath.staggerCoef(t: 1.0 / 3.0, stagger: s, numXforms: nx, xformIndex: i, isFinal: false),
            0, accuracy: 1e-12)
        // t at/above et (== 1.0) → 1
        XCTAssertEqual(
            BlendMath.staggerCoef(t: 1.0, stagger: s, numXforms: nx, xformIndex: i, isFinal: false),
            1, accuracy: 1e-12)

        // t = 0.5: (0.5 − 1/3)/(1 − 1/3) = (1/6)/(2/3) = 0.25
        //   smoother(0.25) = 3·0.0625 − 2·0.015625 = 0.1875 − 0.03125 = 0.15625
        XCTAssertEqual(
            BlendMath.staggerCoef(t: 0.5, stagger: s, numXforms: nx, xformIndex: i, isFinal: false),
            0.15625, accuracy: 1e-12)

        // t = 2/3: (2/3 − 1/3)/(2/3) = 0.5 → smoother(0.5) = 0.5
        XCTAssertEqual(
            BlendMath.staggerCoef(t: 2.0 / 3.0, stagger: s, numXforms: nx, xformIndex: i, isFinal: false),
            0.5, accuracy: 1e-12)
    }

    /// Pin the C evaluation order for the `st` term:
    /// `stag_scaled * (num_xforms-1-this_xform) / (num_xforms-1)` is computed
    /// multiply-before-divide in C (left-associative `*` and `/`). With nx=7,
    /// i=2 the divisor (nx-1)=6 is non-power-of-two, so the order can affect
    /// rounding. We recompute using the documented Swift port and confirm the
    /// boundary + interior value match.
    func testStaggerCoefMultiplyBeforeDivideOrderNx7I2() {
        let nx = 7, i = 2, s = 0.5

        // Recompute st/et exactly as the Swift port does (mirrors C order).
        let maxStag = Double(nx - 1) / Double(nx)
        let stagScaled = s * maxStag
        let st = (stagScaled * Double(nx - 1 - i)) / Double(nx - 1)
        let et = st + (1 - stagScaled)

        // t just below st → 0; t at et → 1; t in-window → smoother((t-st)/(1-stag_scaled)).
        let tIn = (st + et) / 2
        let expectedIn = BlendMath.smoother((tIn - st) / (1 - stagScaled))

        XCTAssertEqual(
            BlendMath.staggerCoef(t: st - 1e-9, stagger: s, numXforms: nx, xformIndex: i, isFinal: false),
            0, accuracy: 1e-12)
        XCTAssertEqual(
            BlendMath.staggerCoef(t: et, stagger: s, numXforms: nx, xformIndex: i, isFinal: false),
            1, accuracy: 1e-12)
        XCTAssertEqual(
            BlendMath.staggerCoef(t: tIn, stagger: s, numXforms: nx, xformIndex: i, isFinal: false),
            expectedIn, accuracy: 1e-12)
    }

    /// The ACTIVE `st` line makes the LAST xform interpolate first: higher
    /// xformIndex → smaller st → nonzero contribution at earlier t.
    func testStaggerCoefLastXformInterpolatesFirst() {
        let nx = 3, s = 0.5
        // At t = 0.2:
        //   i=2: st = (1/3 * (3-1-2)) / (3-1) = (1/3 * 0)/2 = 0 → in-window (et=2/3)
        //   i=0: st = 1/3 ≈ 0.333 → t < st → 0
        let firstXformCoef = BlendMath.staggerCoef(
            t: 0.2, stagger: s, numXforms: nx, xformIndex: 0, isFinal: false)
        let lastXformCoef = BlendMath.staggerCoef(
            t: 0.2, stagger: s, numXforms: nx, xformIndex: 2, isFinal: false)
        XCTAssertEqual(firstXformCoef, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(lastXformCoef, 0)
    }
}
