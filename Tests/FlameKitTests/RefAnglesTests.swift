import XCTest
@testable import FlameKit

/// Tests for `RefAngles.establish` — a faithful port of flam3's
/// `establish_asymmetric_refangles` (interpolation.c:710-766).
///
/// Column→field mapping (Genome.swift): the pre-affine `c[col][row]` of flam3
/// maps to column 0 = (a,b), column 1 = (c,d), so
///   cxang[k][0] = atan2(b, a),  cxang[k][1] = atan2(d, c).
///
/// Per the C comment ("store the NON-symmetric angle", interpolation.c:750)
/// and the verified formulas, `wind[col]` receives the ANIMATING side's
/// adjusted column angle + 2π — i.e. the side where `animate != 0`.
final class RefAnglesTests: XCTestCase {

    private let twoPi = 2.0 * Double.pi

    /// Build an xform from raw coefs. (Inlining avoids naming `AffineTransform`
    /// in a function signature, which collides with Foundation's version.)
    private func xf(_ a: Double, _ b: Double, _ c: Double, _ d: Double,
                    animate: Double, padding: Int = 0) -> Xform {
        Xform(affine: AffineTransform(a: a, b: b, c: c, d: d, e: 0, f: 0),
              variations: [Variation(name: "linear", weight: 1)],
              animate: animate,
              padding: padding)
    }

    private func flame(_ x: Xform) -> Flame {
        Flame(xforms: [x])
    }

    // cp0 identity: col0 = atan2(0,1) = 0, col1 = atan2(1,0) = π/2.
    static let cp0A = 1.0, cp0B = 0.0, cp0C = 0.0, cp0D = 1.0
    // cp1: col0 = atan2(1,0) = π/2, col1 = atan2(0,1) = 0.
    static let cp1A = 0.0, cp1B = 1.0, cp1C = 1.0, cp1D = 0.0

    // MARK: - Asymmetric pairs

    /// cp0 animate=0 (sym), cp1 animate=1 (not sym) → branch `sym0 && !sym1`
    /// → cp1.wind[col] = cxang[k][col] + 2π  (cp1's OWN adjusted angle).
    func testAsymmetric_cp0Symmetric_cp1Animated_stores_cp1_angle() {
        let cp0 = flame(xf(Self.cp0A, Self.cp0B, Self.cp0C, Self.cp0D, animate: 0))
        let cp1 = flame(xf(Self.cp1A, Self.cp1B, Self.cp1C, Self.cp1D, animate: 1))
        var spun = [cp0, cp1]

        RefAngles.establish(&spun, ncp: spun.count)

        // cp1.wind = cp1's own column angle + 2π
        XCTAssertEqual(spun[1].xforms[0].wind.x, Double.pi / 2 + twoPi, accuracy: 1e-12)  // atan2(1,0)+2π
        XCTAssertEqual(spun[1].xforms[0].wind.y, 0 + twoPi, accuracy: 1e-12)              // atan2(0,1)+2π
        XCTAssertEqual(spun[0].xforms[0].wind, SIMD2<Double>.zero)
    }

    /// cp0 animate=1 (not sym), cp1 animate=0 (sym) → branch `sym1 && !sym0`
    /// → cp1.wind[col] = cxang[k-1][col] + 2π  (cp0's adjusted angle).
    func testAsymmetric_cp0Animated_cp1Symmetric_stores_cp0_angle() {
        let cp0 = flame(xf(Self.cp0A, Self.cp0B, Self.cp0C, Self.cp0D, animate: 1))
        let cp1 = flame(xf(Self.cp1A, Self.cp1B, Self.cp1C, Self.cp1D, animate: 0))
        var spun = [cp0, cp1]

        RefAngles.establish(&spun, ncp: spun.count)

        // cp1.wind = cp0's column angle + 2π
        XCTAssertEqual(spun[1].xforms[0].wind.x, 0 + twoPi, accuracy: 1e-12)              // atan2(0,1)+2π
        XCTAssertEqual(spun[1].xforms[0].wind.y, Double.pi / 2 + twoPi, accuracy: 1e-12)  // atan2(1,0)+2π
        XCTAssertEqual(spun[0].xforms[0].wind, SIMD2<Double>.zero)
    }

    // MARK: - No-op cases

    /// Both symmetric → no branch → wind stays at default.
    func testBothSymmetric_leavesWindDefault() {
        let cp0 = flame(xf(Self.cp0A, Self.cp0B, Self.cp0C, Self.cp0D, animate: 0))
        let cp1 = flame(xf(Self.cp1A, Self.cp1B, Self.cp1C, Self.cp1D, animate: 0))
        var spun = [cp0, cp1]

        RefAngles.establish(&spun, ncp: spun.count)

        XCTAssertEqual(spun[0].xforms[0].wind, SIMD2<Double>.zero)
        XCTAssertEqual(spun[1].xforms[0].wind, SIMD2<Double>.zero)
    }

    /// Both animated → no branch → wind stays at default.
    func testBothAnimated_leavesWindDefault() {
        let cp0 = flame(xf(Self.cp0A, Self.cp0B, Self.cp0C, Self.cp0D, animate: 1))
        let cp1 = flame(xf(Self.cp1A, Self.cp1B, Self.cp1C, Self.cp1D, animate: 1))
        var spun = [cp0, cp1]

        RefAngles.establish(&spun, ncp: spun.count)

        XCTAssertEqual(spun[0].xforms[0].wind, SIMD2<Double>.zero)
        XCTAssertEqual(spun[1].xforms[0].wind, SIMD2<Double>.zero)
    }

    // MARK: - Coefs untouched

    /// establish must write ONLY wind; affine coefficients unchanged.
    func testCoefsUntouched() {
        let cp0 = flame(xf(Self.cp0A, Self.cp0B, Self.cp0C, Self.cp0D, animate: 0))
        let cp1 = flame(xf(Self.cp1A, Self.cp1B, Self.cp1C, Self.cp1D, animate: 1))
        var spun = [cp0, cp1]
        let a0 = spun[0].xforms[0].affine
        let a1 = spun[1].xforms[0].affine

        RefAngles.establish(&spun, ncp: spun.count)

        XCTAssertEqual(spun[0].xforms[0].affine, a0)
        XCTAssertEqual(spun[1].xforms[0].affine, a1)
    }

    // MARK: - Final xform skipped

    /// Final xforms live in `Flame.finalXform` (separate from `xforms`), so they
    /// are never visited. Their wind stays at default regardless of animate.
    func testFinalXformSkipped() {
        var cp0 = flame(xf(Self.cp0A, Self.cp0B, Self.cp0C, Self.cp0D, animate: 0))
        cp0.finalXform = xf(Self.cp0A, Self.cp0B, Self.cp0C, Self.cp0D, animate: 0)
        var cp1 = flame(xf(Self.cp1A, Self.cp1B, Self.cp1C, Self.cp1D, animate: 1))
        cp1.finalXform = xf(Self.cp1A, Self.cp1B, Self.cp1C, Self.cp1D, animate: 1)
        var spun = [cp0, cp1]

        RefAngles.establish(&spun, ncp: spun.count)

        XCTAssertEqual(spun[0].finalXform?.wind, SIMD2<Double>.zero)
        XCTAssertEqual(spun[1].finalXform?.wind, SIMD2<Double>.zero)
    }

    // MARK: - Padding is NOT symmetry

    /// padsymflag is hardcoded 0 (interpolation.c:753), so `padding==1` does NOT
    /// make an xform symmetric. A padded cp1 with animate!=0 next to a symmetric
    /// cp0 must still take the case-A branch and have wind written.
    func testPaddingDoesNotCountAsSymmetry() {
        let cp0 = flame(xf(Self.cp0A, Self.cp0B, Self.cp0C, Self.cp0D, animate: 0))               // sym
        let cp1 = flame(xf(Self.cp1A, Self.cp1B, Self.cp1C, Self.cp1D, animate: 1, padding: 1))   // padding, NOT sym
        var spun = [cp0, cp1]

        RefAngles.establish(&spun, ncp: spun.count)

        // If padding had counted as symmetry, both sym → no write → wind == .zero.
        XCTAssertNotEqual(spun[1].xforms[0].wind, SIMD2<Double>.zero)
        XCTAssertEqual(spun[1].xforms[0].wind.x, Double.pi / 2 + twoPi, accuracy: 1e-12)
        XCTAssertEqual(spun[1].xforms[0].wind.y, 0 + twoPi, accuracy: 1e-12)
    }

    // MARK: - ±π discontinuity adjust

    /// Exercises `d > π+EPS` (interpolation.c:745-746).
    /// cp0 col0 = atan2(-1,-1) = -3π/4 ; cp1 col0 = atan2(1,-1) = 3π/4.
    /// d = 3π/2 > π+EPS → cxang[1][0] -= 2π → -5π/4.
    /// Case A (cp0 sym, cp1 not) → wind[0] = -5π/4 + 2π = 3π/4.
    /// A buggy port skipping the adjust would yield 3π/4 + 2π = 11π/4.
    func testPiDiscontinuityAdjust_highBranch() {
        let cp0 = flame(xf(-1, -1, 0, 1, animate: 0))  // col0=-3π/4, col1=π/2
        let cp1 = flame(xf(-1,  1, 0, 1, animate: 1))  // col0= 3π/4, col1=π/2
        var spun = [cp0, cp1]

        RefAngles.establish(&spun, ncp: spun.count)

        XCTAssertEqual(spun[1].xforms[0].wind.x, 3.0 * Double.pi / 4, accuracy: 1e-12)
        // col1: both π/2, d=0, no adjust → π/2 + 2π.
        XCTAssertEqual(spun[1].xforms[0].wind.y, Double.pi / 2 + twoPi, accuracy: 1e-12)
    }

    /// Exercises `d < -(π-EPS)` (interpolation.c:747-748).
    /// cp0 col0 = 3π/4 ; cp1 col0 = -3π/4. d = -3π/2 < -(π-EPS)
    /// → cxang[1][0] += 2π → 5π/4. Case A → wind[0] = 5π/4 + 2π = 13π/4.
    func testPiDiscontinuityAdjust_lowBranch() {
        let cp0 = flame(xf(-1,  1, 0, 1, animate: 0))  // col0= 3π/4
        let cp1 = flame(xf(-1, -1, 0, 1, animate: 1))  // col0=-3π/4
        var spun = [cp0, cp1]

        RefAngles.establish(&spun, ncp: spun.count)

        XCTAssertEqual(spun[1].xforms[0].wind.x, 13.0 * Double.pi / 4, accuracy: 1e-12)
    }
}
