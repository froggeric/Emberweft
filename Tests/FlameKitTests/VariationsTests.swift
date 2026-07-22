import XCTest
@testable import FlameKit

final class VariationsTests: XCTestCase {
    /// Single-variation eval helper. `ef` carries the xform's affine e,f
    /// coefficients (needed by rings/fan); params holds the full XML param keys.
    private func eval(_ name: String, _ p: SIMD2<Double>, _ w: Double = 1,
                      _ params: [String:Double] = [:], _ ef: SIMD2<Double> = .zero) -> SIMD2<Double> {
        var rng = ISAAC(isaacSeed: "variations-test")
        return Variations.evaluate([Variation(name: name, weight: w, parameters: params)],
                                   at: p, ef: ef, rng: &rng)
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
    // var28_bubble (variations.c:671-678): r = weight / (0.25*sumsq + 1);
    //   (r*tx, r*ty). Paramless; 0 RNG draws.
    func testBubble() {
        // Hand-traced: sumsq = 0.6² + 0.8² = 1.0 → r = 1/(0.25+1) = 0.8 → (0.48, 0.64)
        XCTAssertEqual(eval("bubble", SIMD2(0.6, 0.8), 1.0), SIMD2<Double>(0.48, 0.64), accuracy: 1e-9)
        // Origin: sumsq=0 → r = w → output = w*p (maps origin to itself).
        XCTAssertEqual(eval("bubble", SIMD2(0, 0), 1.0), SIMD2<Double>.zero, accuracy: 1e-9)
        // Weight folds into r: 2.0 at (0.3,0.4): sumsq=0.25 → r=2/(1.0625);
        //   out = (r*0.3, r*0.4)
        let p = SIMD2<Double>(0.3, 0.4)
        let r = 2.0 / (0.25 * (p.x*p.x + p.y*p.y) + 1.0)
        XCTAssertEqual(eval("bubble", p, 2.0), SIMD2<Double>(r*p.x, r*p.y), accuracy: 1e-9)
    }
    func testJuliaUsesRngAndDeterministic() {
        var r1 = ISAAC(isaacSeed: "julia-determinism")
        var r2 = ISAAC(isaacSeed: "julia-determinism")
        let p = SIMD2<Double>(0.5, 0.5)
        let a = Variations.evaluate([Variation(name: "julia", weight: 1)], at: p, ef: .zero, rng: &r1)
        let b = Variations.evaluate([Variation(name: "julia", weight: 1)], at: p, ef: .zero, rng: &r2)
        XCTAssertEqual(a, b, accuracy: 1e-6)        // same seed => same bit => same output
    }

    // MARK: - 14 new special-sauce variations (expected values hand-traced from
    // variations.c bodies, NOT from the implementation).

    // var21_rings (variations.c:509-527): dx = e*e + EPS; r = precalc_sqrt;
    //   r = w*( fmod(r+dx, 2*dx) - dx + r*(1-dx) ); (r*cos(a), r*sin(a))
    //   where a = precalc_atan = atan2(x,y); cosa/sina via cos/sin(atan).
    func testRings() {
        let p = SIMD2<Double>(0.5, 0.0); let e = 0.7; let eps = 1e-10
        let out = eval("rings", p, 1.0, [:], SIMD2(e, 0.0))
        let dx = e*e + eps; let r = sqrt(p.x*p.x + p.y*p.y); let a = atan2(p.x, p.y)
        let rr = 1.0 * (fmod(r+dx, 2*dx) - dx + r*(1-dx))
        XCTAssertEqual(out.x, rr*cos(a), accuracy: 1e-9)
        XCTAssertEqual(out.y, rr*sin(a), accuracy: 1e-9)
    }
    // var22_fan (variations.c:529-556): dx = π*(e*e+EPS); dy = f; dx2 = dx/2;
    //   a = atan2(x,y); a += (fmod(a+dy,dx) > dx2) ? -dx2 : dx2;
    //   r = w*sqrt; (r*cos a, r*sin a).
    func testFan() {
        let p = SIMD2<Double>(0.3, 0.4); let e = 0.5; let f = 0.2
        let out = eval("fan", p, 1.0, [:], SIMD2(e, f))
        let dx = .pi*(e*e + 1e-10); let dy = f; let dx2 = 0.5*dx
        var a = atan2(p.x, p.y); let r = 1.0*sqrt(p.x*p.x+p.y*p.y)
        a += (fmod(a+dy, dx) > dx2) ? -dx2 : dx2
        XCTAssertEqual(out.x, r*cos(a), accuracy: 1e-9)
        XCTAssertEqual(out.y, r*sin(a), accuracy: 1e-9)
    }
    // var23_blob (variations.c:558-578): r = sqrt; a = atan2(x,y);
    //   r *= low + (high-low)*(0.5 + 0.5*sin(waves*a));  (w*sin(a)*r, w*cos(a)*r).
    func testBlob() {
        let p = SIMD2<Double>(0.6, 0.0)
        let out = eval("blob", p, 1.0, ["blob_low":0.3,"blob_high":1.0,"blob_waves":2.0])
        var r = sqrt(p.x*p.x+p.y*p.y); let a = atan2(p.x, p.y)
        r *= 0.3 + (1.0-0.3)*(0.5 + 0.5*sin(2.0*a))      // waves*a, NOT 2*waves*a
        XCTAssertEqual(out.x, 1.0*sin(a)*r, accuracy: 1e-9)  // sin on x, cos on y
        XCTAssertEqual(out.y, 1.0*cos(a)*r, accuracy: 1e-9)
    }
    // var25_fan2 (variations.c:599-639): dy=fan2_y; dx=π*(fan2_x²+EPS); dx2=dx/2;
    //   a=atan2(x,y); t = a+dy - dx*(int)((a+dy)/dx);
    //   if t>dx2 a-=dx2 else a+=dx2; r=w*sqrt; (r*sin a, r*cos a).  [sin on x]
    func testFan2() {
        let p = SIMD2<Double>(0.3, 0.4)
        let out = eval("fan2", p, 1.0, ["fan2_x":0.5,"fan2_y":0.2])
        let dy = 0.2; let dx = .pi*(0.5*0.5 + 1e-10); let dx2 = 0.5*dx
        var a = atan2(p.x, p.y); let r = 1.0*sqrt(p.x*p.x+p.y*p.y)
        let t = a + dy - dx*Double(Int((a+dy)/dx))
        if t > dx2 { a = a - dx2 } else { a = a + dx2 }
        XCTAssertEqual(out.x, r*sin(a), accuracy: 1e-9)   // sin on x (sa)
        XCTAssertEqual(out.y, r*cos(a), accuracy: 1e-9)
    }
    // var26_rings2 (variations.c:641-658): r=sqrt; dx=val²+EPS;
    //   r += -2*dx*(int)((r+dx)/(2*dx)) + r*(1-dx);
    //   (w*sin(a)*r, w*cos(a)*r), a=atan2(x,y). [sin on x]
    func testRings2() {
        let p = SIMD2<Double>(0.5, 0.0)
        let out = eval("rings2", p, 1.0, ["rings2_val":0.4])
        var r = sqrt(p.x*p.x+p.y*p.y); let dx = 0.4*0.4 + 1e-10
        r += -2.0*dx*Double(Int((r+dx)/(2.0*dx))) + r*(1.0-dx)
        let a = atan2(p.x, p.y)
        XCTAssertEqual(out.x, 1.0*sin(a)*r, accuracy: 1e-9)
        XCTAssertEqual(out.y, 1.0*cos(a)*r, accuracy: 1e-9)
    }
    // var30_perspective (variations.c:688-695) + perspective_precalc (L1943-1947):
    //   ang = angle*π/2; vsin=sin(ang); vfcos=dist*cos(ang);
    //   t = 1/(dist - ty*vsin); (w*dist*tx*t, w*vfcos*ty*t).
    func testPerspective() {
        let p = SIMD2<Double>(0.5, 0.3)
        let out = eval("perspective", p, 1.0, ["perspective_angle":0.5,"perspective_dist":2.0])
        let ang = 0.5 * .pi / 2.0
        let vsin = sin(ang); let vfcos = 2.0 * cos(ang)
        let t = 1.0 / (2.0 - p.y*vsin)
        XCTAssertEqual(out.x, 1.0*2.0*p.x*t, accuracy: 1e-9)
        XCTAssertEqual(out.y, 1.0*vfcos*p.y*t, accuracy: 1e-9)
    }
    // var38_ngon (variations.c:812-831): r_factor=pow(sumsq, power/2);
    //   theta=atan2(y,x); b=2π/sides; phi=theta-b*floor(theta/b); if phi>b/2 phi-=b;
    //   amp = corners*(1/(cos(phi)+EPS)-1)+circle; amp/=(r_factor+EPS);
    //   (w*tx*amp, w*ty*amp).
    func testNgon() {
        let p = SIMD2<Double>(0.5, 0.0)
        let out = eval("ngon", p, 1.0,
            ["ngon_sides":5,"ngon_power":3,"ngon_circle":1,"ngon_corners":2])
        let eps = 1e-10
        let sumsq = p.x*p.x+p.y*p.y
        let rFactor = pow(sumsq, 3.0/2.0)
        let theta = atan2(p.y, p.x); let b = 2 * Double.pi / 5
        var phi = theta - (b*floor(theta/b))
        if phi > b/2 { phi -= b }
        var amp = 2.0*(1.0/(cos(phi)+eps) - 1.0) + 1.0
        amp /= (rFactor + eps)
        XCTAssertEqual(out.x, 1.0*p.x*amp, accuracy: 1e-9)
        XCTAssertEqual(out.y, 1.0*p.y*amp, accuracy: 1e-9)
    }
    // var39_curl (variations.c:833-842): re = 1 + c1*x + c2*(x²-y²); im = c1*y + 2*c2*x*y;
    //   r = w/(re²+im²); ( (x*re + y*im)*r, (y*re - x*im)*r ).
    func testCurl() {
        let p = SIMD2<Double>(0.5, 0.2)
        let out = eval("curl", p, 1.0, ["curl_c1":0.5,"curl_c2":0.1])
        let (x,y,c1,c2) = (p.x,p.y,0.5,0.1)
        let re = 1.0 + c1*x + c2*(x*x - y*y)
        let im = c1*y + 2.0*c2*x*y
        let r = 1.0/(re*re + im*im)
        XCTAssertEqual(out.x, (x*re + y*im)*r, accuracy: 1e-9)
        XCTAssertEqual(out.y, (y*re - x*im)*r, accuracy: 1e-9)
    }
    // var40_rectangles (variations.c:844-856): if x==0: w*x  else  w*((2*floor(x/rx)+1)*rx - x).
    //   floor(x/rx), NOT floor(x/(2*rx)).
    func testRectangles() {
        let p = SIMD2<Double>(1.3, 0.7)
        let out = eval("rectangles", p, 1.0, ["rectangles_x":0.4,"rectangles_y":0.6])
        XCTAssertEqual(out.x, 1.0*((2*floor(1.3/0.4)+1)*0.4 - 1.3), accuracy: 1e-9)
        XCTAssertEqual(out.y, 1.0*((2*floor(0.7/0.6)+1)*0.6 - 0.7), accuracy: 1e-9)
    }
    // var79_wedge_sph (variations.c:1690-1709): r=1/(sqrt+EPS); a=atanyx+swirl*r;
    //   c=floor((count*a+π)*1/π*0.5); comp_fac=1-angle*count*1/π*0.5;
    //   a=a*comp_fac+c*angle; r=w*(r+hole); (r*cos a, r*sin a).
    func testWedgeSph() {
        let p = SIMD2<Double>(0.3, 0.4)
        let out = eval("wedge_sph", p, 1.0,
            ["wedge_sph_angle":0.3,"wedge_sph_count":3,"wedge_sph_hole":0.1,"wedge_sph_swirl":0.2])
        let eps = 1e-10
        let precalcSqrt = sqrt(p.x*p.x+p.y*p.y)
        var r = 1.0/(precalcSqrt+eps)
        var a = atan2(p.y, p.x) + 0.2*r
        let c = floor((3*a + .pi)*(1.0 / .pi)*0.5)
        let compFac = 1 - 0.3*3*(1.0 / .pi)*0.5
        a = a*compFac + c*0.3
        r = 1.0*(r + 0.1)
        XCTAssertEqual(out.x, r*cos(a), accuracy: 1e-9)
        XCTAssertEqual(out.y, r*sin(a), accuracy: 1e-9)
    }

    // MARK: - RNG-consuming variations: finite output + exactly 1 ISAAC word drawn.
    // Each calls Variations.evaluate directly with a SHARED rng so the draw count
    // is genuinely verified (stronger than the plan's eval-helper version).

    // var32_juliaN_generic (variations.c:711-724): one isaac01 draw.
    func testJulianDrawsOneAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "julian", weight: 1, parameters: ["julian_power":2,"julian_dist":1.0])],
            at: p, ef: .zero, rng: &rng1)
        _ = rng2.isaac01()   // julian consumed exactly one word from rng1
        XCTAssertTrue(out.x.isFinite, "julian x not finite")
        XCTAssertTrue(out.y.isFinite, "julian y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01())   // streams still aligned → 1 word
    }
    // var33_juliaScope_generic (variations.c:726-745): one isaac01 draw.
    func testJuliascopeDrawsOneAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "juliascope", weight: 1, parameters: ["juliascope_power":2,"juliascope_dist":1.0])],
            at: p, ef: .zero, rng: &rng1)
        _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite); XCTAssertTrue(out.y.isFinite)
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01())
    }
    // var50_supershape (variations.c:1093-1117): draws isaac01 UNCONDITIONALLY
    // (even when super_shape_rnd == 0, the `draw` term is evaluated).
    func testSuperShapeDrawsOneAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.4, 0.0)
        let out = Variations.evaluate(
            [Variation(name: "super_shape", weight: 1, parameters: [
                "super_shape_rnd":0,"super_shape_m":4,"super_shape_n1":2,
                "super_shape_n2":2,"super_shape_n3":2,"super_shape_holes":0])],
            at: p, ef: .zero, rng: &rng1)
        _ = rng2.isaac01()   // super_shape consumed one word (unconditional draw)
        XCTAssertTrue(out.x.isFinite, "super_shape x not finite at \(p)")
        XCTAssertTrue(out.y.isFinite, "super_shape y not finite at \(p)")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01())
    }
    // var78_wedge_julia (variations.c:1672-1688): one isaac01 draw.
    func testWedgeJuliaDrawsOneAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "wedge_julia", weight: 1, parameters: [
                "wedge_julia_angle":0.3,"wedge_julia_count":3,
                "wedge_julia_power":2,"wedge_julia_dist":1.0])],
            at: p, ef: .zero, rng: &rng1)
        _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite); XCTAssertTrue(out.y.isFinite)
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01())
    }

    // MARK: - Multi-RNG-variation word count: julia + julian on one xform.
    // Verifies that when two RNG-consuming variations are present on a single
    // xform, `evaluate` consumes exactly 2 ISAAC words total — i.e. each draws
    // exactly once even in a multi-RNG-variation context. The array order here
    // is fixed by construction, so this test does NOT pin draw ORDER.
    //
    // The draw-ORDER coincidence (parser alphabetical == flam3 numeric ==
    // canonical-slot for the {julia, julian, juliascope, super_shape,
    // wedge_julia} subset, variation indices 13/32/33/50/78) is pinned
    // separately by the Task 6 RNG-order invariant test against flam3's numeric
    // variation indices — not by this test.
    func testJuliaAndJulianTogetherDrawTwoWords() {
        var rngShared = ISAAC(isaacSeed: "align")
        let p = SIMD2<Double>(0.3, 0.2)
        let v = [Variation(name: "julia", weight: 1),
                 Variation(name: "julian", weight: 1,
                           parameters: ["julian_power":2, "julian_dist":1.0])]
        let out = Variations.evaluate(v, at: p, ef: .zero, rng: &rngShared)
        XCTAssertTrue(out.x.isFinite); XCTAssertTrue(out.y.isFinite)
        // Each variation consumed exactly 1 word → 2 words total.
        var rngRef = ISAAC(isaacSeed: "align")
        _ = rngRef.isaac01(); _ = rngRef.isaac01()
        XCTAssertEqual(rngShared.isaac01(), rngRef.isaac01())
    }

    // MARK: - finiteness & regression guards

    func testGuardsFiniteAtExtremes() {
        // flam3 accumulates ALL variation terms without a per-term finiteness guard
        // (variations.c:2129-2381) and checks `badvalue` only on the FINAL post-
        // affine result (variations.c:2392). At (0,0) every M1 variation is finite.
        // The 14 new special-sauce are checked at a non-singular point (0.3,0.4)
        // here (perspective is excluded — its default dist=0 is a genuine flam3
        // singularity, t=1/0; genomes always set a nonzero dist). Their dedicated
        // equality/RNG tests above cover them at known-good inputs.
        let origin = SIMD2<Double>.zero
        let nonSingular = SIMD2<Double>(0.3, 0.4)
        let m1Names = Set([
            "linear", "sinusoidal", "spherical", "swirl", "horseshoe", "polar",
            "handkerchief", "heart", "disc", "spiral", "hyperbolic", "diamond",
            "ex", "julia", "bent", "fisheye", "exponential", "cosine", "cylinder"
        ])
        for name in Variations.knownNames {
            // perspective's default dist=0 makes t=1/(0-ty·0)=1/0 → a genuine
            // flam3 singularity (genomes always set a nonzero dist). Its
            // dedicated testPerspective checks finiteness with a valid dist.
            if name == "perspective" { continue }
            let point = m1Names.contains(name) ? origin : nonSingular
            var rng = ISAAC(isaacSeed: "finiteness")
            let r = Variations.evaluate([Variation(name: name, weight: 1)], at: point, ef: .zero, rng: &rng)
            XCTAssertTrue(r.x.isFinite, "\(name) at \(point) x not finite")
            XCTAssertTrue(r.y.isFinite, "\(name) at \(point) y not finite")
        }
    }
    func testUnknownVariationIsZero() {
        Variations.resetWarnings()
        var rng = ISAAC(isaacSeed: "unknown-var")
        XCTAssertEqual(Variations.evaluate([Variation(name: "not_a_real_variation", weight: 5)],
                                          at: SIMD2(1, 1), ef: .zero, rng: &rng), .zero)
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
            at: SIMD2<Double>(1, 1e9), ef: .zero, rng: &rng)
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
