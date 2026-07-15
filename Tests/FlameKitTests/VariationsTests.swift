import XCTest
@testable import FlameKit

final class VariationsTests: XCTestCase {
    private func eval(_ name: String, _ p: SIMD2<Float>, weight: Float = 1) -> SIMD2<Float> {
        var rng = PCG32(seed: 1, stream: 1)
        return Variations.evaluate([Variation(name: name, weight: weight)], at: p, rng: &rng)
    }
    func testLinearIsIdentity() {
        let p = SIMD2<Float>(0.3, -0.7)
        XCTAssertEqual(eval("linear", p), p, accuracy: 1e-6)
    }
    func testSinusoidal() {
        let p = SIMD2<Float>(0.5, -0.25)
        XCTAssertEqual(eval("sinusoidal", p), SIMD2<Float>(sin(0.5), sin(-0.25)), accuracy: 1e-6)
    }
    func testSpherical() {
        XCTAssertEqual(eval("spherical", SIMD2(2, 0)), SIMD2<Float>(0.5, 0), accuracy: 1e-6)
    }
    // Closed-form spot checks against flam3 variations.c (not the doc summary).
    func testSwirlMatchesFlam3() {
        let p = SIMD2<Float>(0.3, 0.4)              // r² = 0.25
        let s = Float(sin(0.25)), c = Float(cos(0.25))
        XCTAssertEqual(eval("swirl", p), SIMD2<Float>(s*0.3 - c*0.4, c*0.3 + s*0.4), accuracy: 1e-6)
    }
    func testDiscMatchesFlam3() {
        let p = SIMD2<Float>(0.3, 0.4)
        let r = (p.x*p.x + p.y*p.y).squareRoot()
        let a = atan2(p.y, p.x) / .pi
        XCTAssertEqual(eval("disc", p), SIMD2<Float>(a*sin(.pi*r), a*cos(.pi*r)), accuracy: 1e-6)
    }
    func testBentMatchesFlam3() {
        XCTAssertEqual(eval("bent", SIMD2(-1, -4)), SIMD2<Float>(-2, -2), accuracy: 1e-6)
    }
    func testJuliaUsesRngAndDeterministic() {
        var r1 = PCG32(seed: 7, stream: 1)
        var r2 = PCG32(seed: 7, stream: 1)
        let p = SIMD2<Float>(0.5, 0.5)
        let a = Variations.evaluate([Variation(name: "julia", weight: 1)], at: p, rng: &r1)
        let b = Variations.evaluate([Variation(name: "julia", weight: 1)], at: p, rng: &r2)
        XCTAssertEqual(a, b, accuracy: 1e-6)        // same seed => same bit => same output
    }
    func testGuardsFiniteAtExtremes() {
        // AC: every known variation returns finite output at (0,0) AND (1e9,1e9).
        // cosine/exponential overflow at 1e9 (cosh(1e9)=inf, exp(1e9)=inf); the
        // final evaluate() guard must clamp those to zero. Negative coords exercise
        // bent/horseshoe branches.
        let points: [SIMD2<Float>] = [.zero, SIMD2(1e9, 1e9), SIMD2(-1e9, 1e9)]
        for name in Variations.knownNames {
            for p in points {
                var rng = PCG32(seed: 0, stream: 0)
                let r = Variations.evaluate([Variation(name: name, weight: 1)], at: p, rng: &rng)
                XCTAssertTrue(r.x.isFinite, "\(name) at \(p) x not finite")
                XCTAssertTrue(r.y.isFinite, "\(name) at \(p) y not finite")
            }
        }
    }
    func testUnknownVariationIsZero() {
        Variations.resetWarnings()
        var rng = PCG32(seed: 1, stream: 1)
        XCTAssertEqual(Variations.evaluate([Variation(name: "not_a_real_variation", weight: 5)], at: SIMD2(1, 1), rng: &rng), .zero)
        XCTAssertTrue(Variations.warnings.contains("not_a_real_variation"))
    }
    func testOverflowingVariationDoesNotZeroSiblings() {
        // cosine overflows at large y (cosh(1e9)=inf); linear must survive.
        // At (1, 1e9): linear term = 0.5*(1, 1e9) = (0.5, 5e8); cosine term = inf → dropped.
        var rng = PCG32(seed: 1, stream: 1)
        let r = Variations.evaluate(
            [Variation(name: "linear", weight: 0.5),
             Variation(name: "cosine", weight: 0.5)],
            at: SIMD2<Float>(1, 1e9), rng: &rng)
        XCTAssertEqual(r.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(r.y, 5e8, accuracy: 1.0)
    }
}

// SIMD2<Float> accuracy helper for the tests above. Defined as a free function
// (not an XCTest instance method) so it overloads — rather than shadows — the
// global `XCTAssertEqual` functions used elsewhere in the test suite.
func XCTAssertEqual(_ a: SIMD2<Float>, _ b: SIMD2<Float>, accuracy: Float, file: StaticString = #file, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: (file), line: line)
    XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: (file), line: line)
}
