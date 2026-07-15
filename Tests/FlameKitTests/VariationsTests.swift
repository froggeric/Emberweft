import XCTest
@testable import FlameKit

final class VariationsTests: XCTestCase {
    private func eval(_ name: String, _ p: SIMD2<Double>, weight: Double = 1) -> SIMD2<Double> {
        var rng = ISAAC(isaacSeed: "variations-test")
        return Variations.evaluate([Variation(name: name, weight: weight)], at: p, rng: &rng)
    }
    func testLinearIsIdentity() {
        let p = SIMD2<Double>(0.3, -0.7)
        XCTAssertEqual(eval("linear", p), p, accuracy: 1e-6)
    }
    func testSinusoidal() {
        let p = SIMD2<Double>(0.5, -0.25)
        XCTAssertEqual(eval("sinusoidal", p), SIMD2<Double>(sin(0.5), sin(-0.25)), accuracy: 1e-6)
    }
    func testSpherical() {
        XCTAssertEqual(eval("spherical", SIMD2(2, 0)), SIMD2<Double>(0.5, 0), accuracy: 1e-6)
    }
    // Closed-form spot checks against flam3 variations.c (not the doc summary).
    func testSwirlMatchesFlam3() {
        let p = SIMD2<Double>(0.3, 0.4)              // r² = 0.25
        let s = Double(sin(0.25)), c = Double(cos(0.25))
        XCTAssertEqual(eval("swirl", p), SIMD2<Double>(s*0.3 - c*0.4, c*0.3 + s*0.4), accuracy: 1e-6)
    }
    func testDiscMatchesFlam3() {
        let p = SIMD2<Double>(0.3, 0.4)
        let r = (p.x*p.x + p.y*p.y).squareRoot()
        // flam3 precalc_atan = atan2(tx, ty) = atan2(x, y) (variations.c:2159)
        let a = atan2(p.x, p.y) / .pi
        XCTAssertEqual(eval("disc", p), SIMD2<Double>(a*sin(.pi*r), a*cos(.pi*r)), accuracy: 1e-6)
    }
    func testBentMatchesFlam3() {
        XCTAssertEqual(eval("bent", SIMD2(-1, -4)), SIMD2<Double>(-2, -2), accuracy: 1e-6)
    }
    func testJuliaUsesRngAndDeterministic() {
        var r1 = ISAAC(isaacSeed: "julia-determinism")
        var r2 = ISAAC(isaacSeed: "julia-determinism")
        let p = SIMD2<Double>(0.5, 0.5)
        let a = Variations.evaluate([Variation(name: "julia", weight: 1)], at: p, rng: &r1)
        let b = Variations.evaluate([Variation(name: "julia", weight: 1)], at: p, rng: &r2)
        XCTAssertEqual(a, b, accuracy: 1e-6)        // same seed => same bit => same output
    }
    func testGuardsFiniteAtExtremes() {
        // flam3 accumulates ALL variation terms without a per-term finiteness guard
        // (variations.c:2129-2381) and checks `badvalue` only on the FINAL post-
        // affine result (variations.c:2392). So variations that overflow at extreme
        // inputs (cosine/exponential: cosh(1e9)=inf, exp(1e9)=inf) legitimately
        // produce Inf — the chaos game's badvalue path handles it. At (0,0) every
        // variation must be finite (no singularity hit for the implemented set).
        let p = SIMD2<Double>.zero
        for name in Variations.knownNames {
            var rng = ISAAC(isaacSeed: "finiteness")
            let r = Variations.evaluate([Variation(name: name, weight: 1)], at: p, rng: &rng)
            XCTAssertTrue(r.x.isFinite, "\(name) at \(p) x not finite")
            XCTAssertTrue(r.y.isFinite, "\(name) at \(p) y not finite")
        }
    }
    func testUnknownVariationIsZero() {
        Variations.resetWarnings()
        var rng = ISAAC(isaacSeed: "unknown-var")
        XCTAssertEqual(Variations.evaluate([Variation(name: "not_a_real_variation", weight: 5)], at: SIMD2(1, 1), rng: &rng), .zero)
        XCTAssertTrue(Variations.warnings.contains("not_a_real_variation"))
    }
    func testOverflowingVariationPropagatesToBadvalue() {
        // flam3 does NOT per-term-guard: cosine overflows at large y (cosh(1e9)=inf),
        // and the Inf propagates into the sum (linear + inf = inf). The chaos game's
        // `badvalue` check on the final result then redraws — matching flam3's
        // `apply_xform` return-1 path (variations.c:2392-2395).
        var rng = ISAAC(isaacSeed: "overflow")
        let r = Variations.evaluate(
            [Variation(name: "linear", weight: 0.5),
             Variation(name: "cosine", weight: 0.5)],
            at: SIMD2<Double>(1, 1e9), rng: &rng)
        XCTAssertFalse(r.y.isFinite, "Inf from cosine must propagate, not be dropped")
    }
}

// SIMD2<Double> accuracy helper for the tests above. Defined as a free function
// (not an XCTest instance method) so it overloads — rather than shadows — the
// global `XCTAssertEqual` functions used elsewhere in the test suite.
func XCTAssertEqual(_ a: SIMD2<Double>, _ b: SIMD2<Double>, accuracy: Double, file: StaticString = #file, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: (file), line: line)
    XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: (file), line: line)
}
