import XCTest
@testable import FlameKit

final class VariationsTests: XCTestCase {
    /// Single-variation eval helper. `affine` carries the xform's pre-affine
    /// 2×2 + translation as SIMD4(c, d, e, f) (needed by rings/fan/waves/popcorn);
    /// params holds the full XML param keys.
    private func eval(_ name: String, _ p: SIMD2<Double>, _ w: Double = 1,
                      _ params: [String:Double] = [:], _ affine: SIMD4<Double> = .zero) -> SIMD2<Double> {
        var rng = ISAAC(isaacSeed: "variations-test")
        return Variations.evaluate([Variation(name: name, weight: w, parameters: params)],
                                   at: p, affine: affine, rng: &rng)
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
    // var27_eyefish (variations.c:659-669): r = (weight*2)/(sqrt(sumsq) + 1);
    //   (r*tx, r*ty). Paramless; 0 RNG draws. NOT a fisheye alias — UN-swapped.
    func testEyefish() {
        // Hand-traced: sumsq = 0.6² + 0.8² = 1.0 → sqrt = 1.0 →
        //   r = (1.0*2)/(1.0+1.0) = 1.0 → (0.6, 0.8) [UN-swapped; note fisheye
        //   would give (0.8, 0.6)].
        XCTAssertEqual(eval("eyefish", SIMD2(0.6, 0.8), 1.0), SIMD2<Double>(0.6, 0.8), accuracy: 1e-9)
        // Origin: sqrt=0 → r = 2w/(0+1) = 2w → output = (2w*0, 2w*0) = (0,0).
        XCTAssertEqual(eval("eyefish", SIMD2(0, 0), 1.0), SIMD2<Double>.zero, accuracy: 1e-9)
        // Weight folds into r: at (0.3, 0.4) w=2.0: sqrt(0.25)=0.5 →
        //   r = (2.0*2.0)/(0.5+1.0) = 4/1.5; out = (r*0.3, r*0.4).
        let p = SIMD2<Double>(0.3, 0.4)
        let r = (2.0 * 2.0) / ((p.x*p.x + p.y*p.y).squareRoot() + 1.0)
        XCTAssertEqual(eval("eyefish", p, 2.0), SIMD2<Double>(r*p.x, r*p.y), accuracy: 1e-9)
    }
    /// eyefish is its own variation (var27), NOT an alias of fisheye (var16).
    /// Both share the magnitude r = 2w/(|p|+1), but fisheye SWAPS the output
    /// axes `(r*ty, r*tx)` while eyefish does NOT `(r*tx, r*ty)`. The two are
    /// equal only on the diagonals y=x and y=-x (axis-symmetric input); any
    /// other input must differ. This guards against a future "eyefish = fisheye"
    /// shortcut (which would silently corrupt every genome using eyefish).
    func testEyefishDiffersFromFisheye() {
        let p = SIMD2<Double>(0.3, 0.7)   // non-axis-symmetric (|x| ≠ |y|)
        let eye = eval("eyefish", p, 1.0, [:], .zero)
        let fish = eval("fisheye", p, 1.0, [:], .zero)
        // XCTAssertNotEqual has no accuracy overload — compare via L∞ distance.
        // For (0.3,0.7): r≈1.135 → eye≈(0.34,0.79), fish≈(0.79,0.34); the
        // |dx| ≈ 0.45 gap is far above any FP noise.
        let Linf = max(abs(eye.x - fish.x), abs(eye.y - fish.y))
        XCTAssertGreaterThan(Linf, 1e-6,
                             "eyefish must NOT equal fisheye for non-axis-symmetric input — it is un-swapped, not an alias")
        // Cross-check against the hand-traced formulae to make sure the
        // inequality is from the axis swap (not from a different magnitude).
        let r = 2.0 / ((p.x*p.x + p.y*p.y).squareRoot() + 1.0)
        XCTAssertEqual(eye,  SIMD2<Double>(r*p.x, r*p.y), accuracy: 1e-9)   // un-swapped
        XCTAssertEqual(fish, SIMD2<Double>(r*p.y, r*p.x), accuracy: 1e-9)   // swapped
    }

    // MARK: - corpus-variations paramless non-RNG set (slots 37..41).
    // Hand-traced closed forms against flam3 variations.c.

    // var15_waves (variations.c:396-413) + waves_precalc (L1969-1975).
    //   waves_dx2 = 1/(e²+EPS); waves_dy2 = 1/(f²+EPS);
    //   nx = tx + c·sin(ty·dx2); ny = ty + d·sin(tx·dy2); (w·nx, w·ny).
    //   affine SIMD4 = (c, d, e, f).
    func testWaves() {
        let p = SIMD2<Double>(0.2, 0.3)
        let (c, d, e, f) = (Double(0.3), Double(0.4), Double(0.5), Double(0.6))
        let out = eval("waves", p, 1.0, [:], SIMD4(c, d, e, f))
        let eps = 1e-10
        let dx2 = 1.0 / (e*e + eps)
        let dy2 = 1.0 / (f*f + eps)
        let nx = p.x + c * sin(p.y * dx2)
        let ny = p.y + d * sin(p.x * dy2)
        XCTAssertEqual(out, SIMD2<Double>(nx, ny), accuracy: 1e-9)
        // Weight folds into both nx and ny (weight is on the outer term).
        let out2 = eval("waves", p, 2.0, [:], SIMD4(c, d, e, f))
        XCTAssertEqual(out2, SIMD2<Double>(2.0*nx, 2.0*ny), accuracy: 1e-9)
    }
    // var17_popcorn (variations.c:433-450). affine SIMD4 = (c, d, e, f); reads e,f.
    //   dx = tan(3·ty); dy = tan(3·tx); nx = tx + e·sin(dx); ny = ty + f·sin(dy).
    func testPopcorn() {
        let p = SIMD2<Double>(0.2, 0.3)
        let (e, f) = (Double(0.5), Double(0.6))
        let out = eval("popcorn", p, 1.0, [:], SIMD4(0, 0, e, f))
        let dx = tan(3.0 * p.y); let dy = tan(3.0 * p.x)
        let nx = p.x + e * sin(dx); let ny = p.y + f * sin(dy)
        XCTAssertEqual(out, SIMD2<Double>(nx, ny), accuracy: 1e-9)
    }
    // var19_power (variations.c:472-487) — precalc sina/cosa/sqrt.
    //   sina = tx/sqrt; cosa = ty/sqrt; r = w·pow(sqrt, sina); (r·cosa, r·sina).
    func testPower() {
        // (0.6, 0.8): sqrt=1.0, sina=0.6, cosa=0.8 → pow(1.0, 0.6)=1.0 → (0.8, 0.6)
        XCTAssertEqual(eval("power", SIMD2(0.6, 0.8), 1.0),
                       SIMD2<Double>(0.8, 0.6), accuracy: 1e-9)
        // General case at (0.3, 0.4): sqrt=0.5, sina=0.6, cosa=0.8.
        let p = SIMD2<Double>(0.3, 0.4)
        let ps = (p.x*p.x + p.y*p.y).squareRoot()
        let sina = p.x / ps, cosa = p.y / ps
        let r = 1.0 * pow(ps, sina)
        XCTAssertEqual(eval("power", p, 1.0), SIMD2<Double>(r*cosa, r*sina), accuracy: 1e-9)
    }
    // var42_tangent (variations.c:885-898).
    //   p0 += w·sin(tx)/cos(ty); p1 += w·tan(ty).
    func testTangent() {
        let p = SIMD2<Double>(0.5, 0.4)
        let out = eval("tangent", p, 1.0)
        XCTAssertEqual(out.x, sin(0.5)/cos(0.4), accuracy: 1e-9)
        XCTAssertEqual(out.y, tan(0.4), accuracy: 1e-9)
    }
    // var48_cross (variations.c:1033-1052).
    //   s = tx² - ty²; r = w·sqrt(1/(s²+EPS)); (tx·r, ty·r).
    func testCross() {
        let p = SIMD2<Double>(0.6, 0.8)
        let out = eval("cross", p, 1.0)
        let eps = 1e-10
        let s = p.x*p.x - p.y*p.y
        let r = 1.0 * (1.0 / (s*s + eps)).squareRoot()
        XCTAssertEqual(out, SIMD2<Double>(p.x*r, p.y*r), accuracy: 1e-9)
    }

    // MARK: - Trig family (Z+ variations): var82_exp .. var95_coth (slots 57..70).
    // All paramless; 0 RNG draws. Formulas ported verbatim from
    // /private/tmp/flam3-build/variations.c L1747-1897.

    // var82_exp: expe = exp(tx); sincos(ty, &expsin, &expcos)
    //   (w * expe * expcos, w * expe * expsin)
    func testExp() {
        let p = SIMD2<Double>(0.5, 0.3)
        let out = eval("exp", p, 1.0)
        let expe = exp(p.x)
        let expcos = cos(p.y)
        let expsin = sin(p.y)
        XCTAssertEqual(out, SIMD2<Double>(expe * expcos, expe * expsin), accuracy: 1e-9)
    }
    // var83_log: (w * 0.5 * log(sumsq), w * atan2(y, x))
    func testLog() {
        let p = SIMD2<Double>(0.6, 0.8)
        let out = eval("log", p, 1.0)
        let sumsq = p.x*p.x + p.y*p.y
        XCTAssertEqual(out.x, 0.5 * log(sumsq), accuracy: 1e-9)
        XCTAssertEqual(out.y, atan2(p.y, p.x), accuracy: 1e-9)
    }
    // var84_sin: sincos(tx, &sinsin, &sinacos); sinhsinh = sinh(ty); sincosh = cosh(ty)
    //   (w * sinsin * sincosh, w * sinacos * sinhsinh)
    func testSin() {
        let p = SIMD2<Double>(0.5, 0.3)
        let out = eval("sin", p, 1.0)
        let sinsin = sin(p.x)
        let sinacos = cos(p.x)
        let sinhsinh = sinh(p.y)
        let sincosh = cosh(p.y)
        XCTAssertEqual(out, SIMD2<Double>(sinsin * sincosh, sinacos * sinhsinh), accuracy: 1e-9)
    }
    // var85_cos: sincos(tx, &cossin, &coscos); coshsinh = sinh(ty); coshcosh = cosh(ty)
    //   (w * coscos * coshcosh, -w * cossin * coshsinh)
    func testCos() {
        let p = SIMD2<Double>(0.5, 0.3)
        let out = eval("cos", p, 1.0)
        let cossin = sin(p.x)
        let coscos = cos(p.x)
        let coshsinh = sinh(p.y)
        let coshcosh = cosh(p.y)
        XCTAssertEqual(out, SIMD2<Double>(coscos * coshcosh, -cossin * coshsinh), accuracy: 1e-9)
    }
    // var86_tan: sincos(2*tx, &tansin, &tancos); tanhsinh = sinh(2*ty); tanhcosh = cosh(2*ty)
    //   tanden = 1/(tancos + tanhcosh); (w * tanden * tansin, w * tanden * tanhsinh)
    func testTan() {
        let p = SIMD2<Double>(0.4, 0.25)
        let out = eval("tan", p, 1.0)
        let tansin = sin(2.0 * p.x)
        let tancos = cos(2.0 * p.x)
        let tanhsinh = sinh(2.0 * p.y)
        let tanhcosh = cosh(2.0 * p.y)
        let tanden = 1.0 / (tancos + tanhcosh)
        XCTAssertEqual(out, SIMD2<Double>(tanden * tansin, tanden * tanhsinh), accuracy: 1e-9)
    }
    // var87_sec: sincos(tx, &secsin, &seccos); secsinh = sinh(ty); seccosh = cosh(ty)
    //   secden = 2/(cos(2*tx) + cosh(2*ty))
    //   (w * secden * seccos * seccosh, w * secden * secsin * secsinh)
    func testSec() {
        let p = SIMD2<Double>(0.4, 0.25)
        let out = eval("sec", p, 1.0)
        let secsin = sin(p.x)
        let seccos = cos(p.x)
        let secsinh = sinh(p.y)
        let seccosh = cosh(p.y)
        let secden = 2.0 / (cos(2.0 * p.x) + cosh(2.0 * p.y))
        XCTAssertEqual(out, SIMD2<Double>(secden * seccos * seccosh, secden * secsin * secsinh), accuracy: 1e-9)
    }
    // var88_csc: sincos(tx, &cscsin, &csccos); cscsinh = sinh(ty); csccosh = cosh(ty)
    //   cscden = 2/(cosh(2*ty) - cos(2*tx))
    //   (w * cscden * cscsin * csccosh, -w * cscden * csccos * cscsinh)
    func testCsc() {
        let p = SIMD2<Double>(0.4, 0.25)
        let out = eval("csc", p, 1.0)
        let cscsin = sin(p.x)
        let csccos = cos(p.x)
        let cscsinh = sinh(p.y)
        let csccosh = cosh(p.y)
        let cscden = 2.0 / (cosh(2.0 * p.y) - cos(2.0 * p.x))
        XCTAssertEqual(out, SIMD2<Double>(cscden * cscsin * csccosh, -cscden * csccos * cscsinh), accuracy: 1e-9)
    }
    // var89_cot: sincos(2*tx, &cotsin, &cotcos); cotsinh = sinh(2*ty); cotcosh = cosh(2*ty)
    //   cotden = 1/(cotcosh - cotcos)
    //   (w * cotden * cotsin, w * cotden * -1 * cotsinh)
    func testCot() {
        let p = SIMD2<Double>(0.4, 0.25)
        let out = eval("cot", p, 1.0)
        let cotsin = sin(2.0 * p.x)
        let cotcos = cos(2.0 * p.x)
        let cotsinh = sinh(2.0 * p.y)
        let cotcosh = cosh(2.0 * p.y)
        let cotden = 1.0 / (cotcosh - cotcos)
        XCTAssertEqual(out, SIMD2<Double>(cotden * cotsin, cotden * -1.0 * cotsinh), accuracy: 1e-9)
    }
    // var90_sinh: sincos(ty, &sinhsin, &sinhcos); sinhsinh = sinh(tx); sinhcosh = cosh(tx)
    //   (w * sinhsinh * sinhcos, w * sinhcosh * sinhsin)
    func testSinh() {
        let p = SIMD2<Double>(0.4, 0.25)
        let out = eval("sinh", p, 1.0)
        let sinhsin = sin(p.y)
        let sinhcos = cos(p.y)
        let sinhsinh = sinh(p.x)
        let sinhcosh = cosh(p.x)
        XCTAssertEqual(out, SIMD2<Double>(sinhsinh * sinhcos, sinhcosh * sinhsin), accuracy: 1e-9)
    }
    // var91_cosh: sincos(ty, &coshsin, &coshcos); coshsinh = sinh(tx); coshcosh = cosh(tx)
    //   (w * coshcosh * coshcos, w * coshsinh * coshsin)
    func testCosh() {
        let p = SIMD2<Double>(0.4, 0.25)
        let out = eval("cosh", p, 1.0)
        let coshsin = sin(p.y)
        let coshcos = cos(p.y)
        let coshsinh = sinh(p.x)
        let coshcosh = cosh(p.x)
        XCTAssertEqual(out, SIMD2<Double>(coshcosh * coshcos, coshsinh * coshsin), accuracy: 1e-9)
    }
    // var92_tanh: sincos(2*ty, &tanhsin, &tanhcos); tanhsinh = sinh(2*tx); tanhcosh = cosh(2*tx)
    //   tanhden = 1/(tanhcos + tanhcosh)
    //   (w * tanhden * tanhsinh, w * tanhden * tanhsin)
    func testTanh() {
        let p = SIMD2<Double>(0.4, 0.25)
        let out = eval("tanh", p, 1.0)
        let tanhsin = sin(2.0 * p.y)
        let tanhcos = cos(2.0 * p.y)
        let tanhsinh = sinh(2.0 * p.x)
        let tanhcosh = cosh(2.0 * p.x)
        let tanhden = 1.0 / (tanhcos + tanhcosh)
        XCTAssertEqual(out, SIMD2<Double>(tanhden * tanhsinh, tanhden * tanhsin), accuracy: 1e-9)
    }
    // var93_sech: sincos(ty, &sechsin, &sechcos); sechsinh = sinh(tx); sechcosh = cosh(tx)
    //   sechden = 2/(cos(2*ty) + cosh(2*tx))
    //   (w * sechden * sechcos * sechcosh, -w * sechden * sechsin * sechsinh)
    func testSech() {
        let p = SIMD2<Double>(0.4, 0.25)
        let out = eval("sech", p, 1.0)
        let sechsin = sin(p.y)
        let sechcos = cos(p.y)
        let sechsinh = sinh(p.x)
        let sechcosh = cosh(p.x)
        let sechden = 2.0 / (cos(2.0 * p.y) + cosh(2.0 * p.x))
        XCTAssertEqual(out, SIMD2<Double>(sechden * sechcos * sechcosh, -sechden * sechsin * sechsinh), accuracy: 1e-9)
    }
    // var94_csch: sincos(ty, &cschsin, &cschcos); cschsinh = sinh(tx); cschcosh = cosh(tx)
    //   cschden = 2/(cosh(2*tx) - cos(2*ty))
    //   (w * cschden * cschsinh * cschcos, -w * cschden * cschcosh * cschsin)
    func testCsch() {
        let p = SIMD2<Double>(0.4, 0.25)
        let out = eval("csch", p, 1.0)
        let cschsin = sin(p.y)
        let cschcos = cos(p.y)
        let cschsinh = sinh(p.x)
        let cschcosh = cosh(p.x)
        let cschden = 2.0 / (cosh(2.0 * p.x) - cos(2.0 * p.y))
        XCTAssertEqual(out, SIMD2<Double>(cschden * cschsinh * cschcos, -cschden * cschcosh * cschsin), accuracy: 1e-9)
    }
    // var95_coth: sincos(2*ty, &cothsin, &cothcos); cothsinh = sinh(2*tx); cothcosh = cosh(2*tx)
    //   cothden = 1/(cothcosh - cothcos)
    //   (w * cothden * cothsinh, w * cothden * cothsin)
    func testCoth() {
        let p = SIMD2<Double>(0.4, 0.25)
        let out = eval("coth", p, 1.0)
        let cothsin = sin(2.0 * p.y)
        let cothcos = cos(2.0 * p.y)
        let cothsinh = sinh(2.0 * p.x)
        let cothcosh = cosh(2.0 * p.x)
        let cothden = 1.0 / (cothcosh - cothcos)
        XCTAssertEqual(out, SIMD2<Double>(cothden * cothsinh, cothden * cothsin), accuracy: 1e-9)
    }

    // MARK: - corpus-variations parametric non-RNG set (slots 42..43).
    // Hand-traced closed forms against flam3 variations.c.

    // var24_pdj (variations.c:579-596). 4 params, all default 0 (flam3's
    // `clear_cp` is preceded by `memset(0)` on the genome in parser.c:229, and
    // none of pdj_a/b/c/d are explicitly initialized in clear_cp → missing XML
    // attrs parse as 0; Emberweft's descriptor default of 0 mirrors this).
    //   nx1 = cos(pdj_b * tx); nx2 = sin(pdj_c * tx);
    //   ny1 = sin(pdj_a * ty); ny2 = cos(pdj_d * ty);
    //   p0 += w*(ny1 - nx1); p1 += w*(nx2 - ny2).
    func testPdj() {
        let p = SIMD2<Double>(0.3, 0.4)
        // Real ES edge genome 244.00178's pdj params (a corpus fixture).
        let params: [String:Double] = ["pdj_a":0.2, "pdj_b":-1.18, "pdj_c":1.36, "pdj_d":-2.01]
        let out = eval("pdj", p, 1.0, params)
        let nx1 = cos(-1.18 * p.x)
        let nx2 = sin( 1.36 * p.x)
        let ny1 = sin( 0.20 * p.y)
        let ny2 = cos(-2.01 * p.y)
        XCTAssertEqual(out.x, 1.0 * (ny1 - nx1), accuracy: 1e-9)
        XCTAssertEqual(out.y, 1.0 * (nx2 - ny2), accuracy: 1e-9)
        // Weight folds into both p0 and p1 (outer factor).
        let outW = eval("pdj", p, 2.0, params)
        XCTAssertEqual(outW, SIMD2<Double>(2.0*(ny1-nx1), 2.0*(nx2-ny2)), accuracy: 1e-9)
        // Default-0 params (missing attrs → descriptor default 0):
        //   nx1=cos(0)=1, nx2=sin(0)=0, ny1=sin(0)=0, ny2=cos(0)=1
        //   → p0 += (0-1) = -1; p1 += (0-1) = -1 (constant, independent of p).
        // A genome omitting pdj_a/b/c/d therefore gets a constant (-w, -w) term.
        let outDefault = eval("pdj", p, 1.0, [:])
        XCTAssertEqual(outDefault, SIMD2<Double>(-1, -1), accuracy: 1e-9)
    }

    // var74_split (variations.c:1603-1617). 2 params, default 0.
    // NOTE: in the C source the p1 branch comes FIRST. p0/p1 accumulate
    // independently (no carry), so order is observationally equivalent — but we
    // mirror the C structure anyway. CROSS-COUPLING: tx controls p1, ty controls p0.
    //   if (cos(tx*split_xsize*π) >= 0) p1 += w*ty  else  p1 -= w*ty;
    //   if (cos(ty*split_ysize*π) >= 0) p0 += w*tx  else  p0 -= w*tx;
    func testSplit() {
        let params = ["split_xsize":0.4, "split_ysize":0.5]
        // Case 1: both branches POSITIVE (small tx, ty).
        //   cos(0.3*0.4*π)=cos(0.12π)≈0.930 ≥0 → p1 += 0.4
        //   cos(0.4*0.5*π)=cos(0.20π)≈0.809 ≥0 → p0 += 0.3
        let p1 = SIMD2<Double>(0.3, 0.4)
        let out1 = eval("split", p1, 1.0, params)
        XCTAssertEqual(out1.x,  1.0 * p1.x, accuracy: 1e-9)   // p0 += tx
        XCTAssertEqual(out1.y,  1.0 * p1.y, accuracy: 1e-9)   // p1 += ty
        // Case 2: branch 1 (p1) NEGATIVE; branch 2 (p0) still positive.
        //   cos(3.0*0.4*π)=cos(1.2π)≈-0.809 <0 → p1 -= 0.4
        //   cos(0.4*0.5*π)            ≥0      → p0 += 3.0
        let p2 = SIMD2<Double>(3.0, 0.4)
        let out2 = eval("split", p2, 1.0, params)
        XCTAssertEqual(out2.x,  1.0 * p2.x, accuracy: 1e-9)
        XCTAssertEqual(out2.y, -1.0 * p2.y, accuracy: 1e-9)
        // Case 3: branch 1 (p1) positive; branch 2 (p0) NEGATIVE.
        //   cos(0.3*0.4*π)≈0.930     ≥0      → p1 += 2.0
        //   cos(2.0*0.5*π)=cos(π)=-1 <0      → p0 -= 0.3
        let p3 = SIMD2<Double>(0.3, 2.0)
        let out3 = eval("split", p3, 1.0, params)
        XCTAssertEqual(out3.x, -1.0 * p3.x, accuracy: 1e-9)
        XCTAssertEqual(out3.y,  1.0 * p3.y, accuracy: 1e-9)
        // Case 4: BOTH branches negative.
        //   cos(3.0*0.4*π) <0 → p1 -= ty; cos(2.0*0.5*π) <0 → p0 -= tx.
        let p4 = SIMD2<Double>(3.0, 2.0)
        let out4 = eval("split", p4, 1.0, params)
        XCTAssertEqual(out4.x, -1.0 * p4.x, accuracy: 1e-9)
        XCTAssertEqual(out4.y, -1.0 * p4.y, accuracy: 1e-9)
        // Default-0 params (split_xsize=0, split_ysize=0):
        //   cos(tx*0*π)=cos(0)=1 ≥0 → p1 += ty; cos(ty*0*π)=cos(0)=1 ≥0 → p0 += tx.
        //   → (w*tx, w*ty): default-0 split acts as LINEAR. So a genome omitting
        //   split_xsize/ysize attrs gets a plain pass-through (the dispatch guard
        //   still requires weight != 0).
        let outDefault = eval("split", SIMD2(0.7, -0.3), 1.0, [:])
        XCTAssertEqual(outDefault, SIMD2<Double>(0.7, -0.3), accuracy: 1e-9)
        // Weight folds into both p0 and p1.
        let outW = eval("split", p1, 2.0, params)
        XCTAssertEqual(outW.x, 2.0 * p1.x, accuracy: 1e-9)
        XCTAssertEqual(outW.y, 2.0 * p1.y, accuracy: 1e-9)
    }

    func testJuliaUsesRngAndDeterministic() {
        var r1 = ISAAC(isaacSeed: "julia-determinism")
        var r2 = ISAAC(isaacSeed: "julia-determinism")
        let p = SIMD2<Double>(0.5, 0.5)
        let a = Variations.evaluate([Variation(name: "julia", weight: 1)], at: p, affine: .zero, rng: &r1)
        let b = Variations.evaluate([Variation(name: "julia", weight: 1)], at: p, affine: .zero, rng: &r2)
        XCTAssertEqual(a, b, accuracy: 1e-6)        // same seed => same bit => same output
    }

    // MARK: - 14 new special-sauce variations (expected values hand-traced from
    // variations.c bodies, NOT from the implementation).

    // var21_rings (variations.c:509-527): dx = e*e + EPS; r = precalc_sqrt;
    //   r = w*( fmod(r+dx, 2*dx) - dx + r*(1-dx) ); (r*cos(a), r*sin(a))
    //   where a = precalc_atan = atan2(x,y); cosa/sina via cos/sin(atan).
    //   affine SIMD4 = (c, d, e, f); rings only reads e (at .z).
    func testRings() {
        let p = SIMD2<Double>(0.5, 0.0); let e = 0.7; let eps = 1e-10
        let out = eval("rings", p, 1.0, [:], SIMD4(0, 0, e, 0))
        let dx = e*e + eps; let r = sqrt(p.x*p.x + p.y*p.y); let a = atan2(p.x, p.y)
        let rr = 1.0 * (fmod(r+dx, 2*dx) - dx + r*(1-dx))
        XCTAssertEqual(out.x, rr*cos(a), accuracy: 1e-9)
        XCTAssertEqual(out.y, rr*sin(a), accuracy: 1e-9)
    }
    // var22_fan (variations.c:529-556): dx = π*(e*e+EPS); dy = f; dx2 = dx/2;
    //   a = atan2(x,y); a += (fmod(a+dy,dx) > dx2) ? -dx2 : dx2;
    //   r = w*sqrt; (r*cos a, r*sin a).
    //   affine SIMD4 = (c, d, e, f); fan reads e (.z) and f (.w).
    func testFan() {
        let p = SIMD2<Double>(0.3, 0.4); let e = 0.5; let f = 0.2
        let out = eval("fan", p, 1.0, [:], SIMD4(0, 0, e, f))
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
            at: p, affine: .zero, rng: &rng1)
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
            at: p, affine: .zero, rng: &rng1)
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
            at: p, affine: .zero, rng: &rng1)
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
            at: p, affine: .zero, rng: &rng1)
        _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite); XCTAssertTrue(out.y.isFinite)
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01())
    }

    // var37_pie (variations.c:795-809): THREE isaac01 draws in this EXACT order:
    //   (1) slice index    sl = Int(d1 * pie_slices + 0.5)
    //   (2) angular offset inside the slice (drawn INSIDE the parens of `a`):
    //       a = pie_rotation + 2π*(Double(sl) + d2*pie_thickness) / pie_slices
    //   (3) radial          r  = weight * d3
    //   output = (r*cos(a), r*sin(a)) — INDEPENDENT of p (pie ignores its input).
    // A single reordered draw diverges the ISAAC stream and breaks vs-flam3
    // parity, so both the COUNT (3) and the ORDER (slice → angular → radial)
    // are load-bearing. Template: testJulianDrawsOneAndFinite (adapted to 3).
    func testPieDrawsThreeAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "pie", weight: 1,
                       parameters: ["pie_slices":6, "pie_rotation":0.0, "pie_thickness":0.5])],
            at: p, affine: .zero, rng: &rng1)
        // pie consumed exactly 3 words (slice, angular, radial) from rng1.
        _ = rng2.isaac01(); _ = rng2.isaac01(); _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "pie x not finite")
        XCTAssertTrue(out.y.isFinite, "pie y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(), "pie must consume exactly 3 ISAAC words")
    }

    /// Hand-traced closed form: run pie on one ISAAC, then independently draw
    /// the same 3 words from a fresh-seed twin in the SPEC order (sl → a → r)
    /// and assert the outputs agree. This pins both the draw count AND the
    /// exact draw order — any reordering makes `expected` diverge from `out`
    /// because each draw feeds a different term of the formula.
    func testPieClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "pie-closed-form")
        var rng2 = ISAAC(isaacSeed: "pie-closed-form")
        let p = SIMD2<Double>(0.3, 0.2)
        let params: [String: Double] = ["pie_slices":6, "pie_rotation":0.0, "pie_thickness":0.5]
        let out = Variations.evaluate(
            [Variation(name: "pie", weight: 1, parameters: params)],
            at: p, affine: .zero, rng: &rng1)
        // SPEC ORDER (variations.c:799-805): slice draw → angular draw (inside
        // `a`'s parens) → radial draw. Match the formula term-for-term.
        let slices = 6.0, rotation = 0.0, thickness = 0.5
        let d1 = rng2.isaac01()
        let sl = Int(d1 * slices + 0.5)
        let d2 = rng2.isaac01()
        let a = rotation + 2 * .pi * (Double(sl) + d2 * thickness) / slices
        let d3 = rng2.isaac01()
        let r = 1.0 * d3
        let expected = SIMD2<Double>(r * cos(a), r * sin(a))
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // var36_radial_blur (variations.c:775-793): FOUR isaac_01 draws summed
    // LEFT-TO-RIGHT into a pseudo-gaussian:
    //   rndG = weight * (d1 + d2 + d3 + d4 - 2.0)
    //   ra   = sqrt(tx² + ty²)
    //   spinvar = sin(radial_blur_angle * π/2)   (radial_blur_precalc L1964-1967)
    //   zoomvar = cos(radial_blur_angle * π/2)
    //   tmpa = atan2(ty, tx) + spinvar * rndG
    //   rz   = zoomvar * rndG - 1.0
    //   (ra*cos(tmpa) + rz*tx, ra*sin(tmpa) + rz*ty)
    // The `weight * (...)` outer factor means the 4 draws MUST be consumed
    // BEFORE the multiply — reordering or hoisting diverges the ISAAC stream.
    // Template: testPieDrawsThreeAndFinite (adapted to 4 draws).
    func testRadialBlurDrawsFourAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "radial_blur", weight: 1,
                       parameters: ["radial_blur_angle": 0.0])],
            at: p, affine: .zero, rng: &rng1)
        // radial_blur consumed exactly 4 words from rng1.
        _ = rng2.isaac01(); _ = rng2.isaac01(); _ = rng2.isaac01(); _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "radial_blur x not finite")
        XCTAssertTrue(out.y.isFinite, "radial_blur y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "radial_blur must consume exactly 4 ISAAC words")
    }

    /// Hand-traced closed form for radial_blur: run on one ISAAC, then
    /// independently draw the same 4 words from a fresh-seed twin in the SPEC
    /// order (d1 → d2 → d3 → d4, summed left-to-right inside `weight*(...-2)`)
    /// and assert the outputs agree. Pins both the draw count (4) AND the
    /// exact draw+sum order — any reorder makes `expected` diverge from `out`
    /// because the 4 draws feed a single summed `rndG` term.
    func testRadialBlurClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "radial-blur-closed-form")
        var rng2 = ISAAC(isaacSeed: "radial-blur-closed-form")
        let p = SIMD2<Double>(0.3, 0.2)
        let params: [String: Double] = ["radial_blur_angle": -0.583296]
        let out = Variations.evaluate(
            [Variation(name: "radial_blur", weight: 1, parameters: params)],
            at: p, affine: .zero, rng: &rng1)
        // SPEC ORDER (variations.c:775-793): four isaac_01 draws summed
        // left-to-right into rndG = weight*(d1+d2+d3+d4 - 2.0). Match term-for-term.
        let angle = -0.583296
        let spinvar = sin(angle * .pi / 2.0)
        let zoomvar = cos(angle * .pi / 2.0)
        let d1 = rng2.isaac01()
        let d2 = rng2.isaac01()
        let d3 = rng2.isaac01()
        let d4 = rng2.isaac01()
        let rndG = 1.0 * (d1 + d2 + d3 + d4 - 2.0)
        let ra   = (p.x*p.x + p.y*p.y).squareRoot()
        let tmpa = atan2(p.y, p.x) + spinvar * rndG
        let rz   = zoomvar * rndG - 1.0
        let expected = SIMD2<Double>(ra * cos(tmpa) + rz * p.x,
                                     ra * sin(tmpa) + rz * p.y)
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // MARK: - corpus-variations RNG simple set (slots 44..48).
    // Hand-traced closed forms + draw-count invariants for the 5 RNG-consuming
    // variations noise/blur/gaussian_blur/arch/square. Each pins BOTH the draw
    // COUNT and the exact draw ORDER — any reorder diverges the ISAAC stream.

    // var31_noise (variations.c:696-708): TWO isaac_01 draws in this order:
    //   (1) angle    tmpr = d1 * 2π;  sincos(tmpr, &sinr, &cosr)
    //   (2) radius   r = weight * d2
    //   output = (tx * r * cosr, ty * r * sinr)  — INPUT-SCALED (multiplies tx,ty).
    // The INPUT-SCALING is the only difference from `blur` (var34), whose output
    // is (r*cosr, r*sinr) — NOT input-scaled. The two are easy to confuse.
    func testNoiseDrawsTwoAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "noise", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        // noise consumed exactly 2 words (angle, radius) from rng1.
        _ = rng2.isaac01(); _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "noise x not finite")
        XCTAssertTrue(out.y.isFinite, "noise y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "noise must consume exactly 2 ISAAC words")
    }
    /// Closed form for noise (INPUT-SCALED): run on one ISAAC, then independently
    /// draw the same 2 words from a fresh-seed twin in the SPEC order (angle →
    /// radius) and assert outputs agree. Pins both count (2) AND order.
    func testNoiseClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "noise-closed-form")
        var rng2 = ISAAC(isaacSeed: "noise-closed-form")
        let p = SIMD2<Double>(0.3, 0.4)
        let out = Variations.evaluate(
            [Variation(name: "noise", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        let d1 = rng2.isaac01()                                  // draw #1 (angle)
        let tmpr = d1 * 2 * .pi
        let cosr = cos(tmpr), sinr = sin(tmpr)
        let d2 = rng2.isaac01()                                  // draw #2 (radius)
        let r = 1.0 * d2
        let expected = SIMD2<Double>(p.x * r * cosr, p.y * r * sinr)
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // var34_blur (variations.c:746-758): TWO isaac_01 draws in this order:
    //   (1) angle    tmpr = d1 * 2π;  sincos(tmpr, &sinr, &cosr)
    //   (2) radius   r = weight * d2
    //   output = (r * cosr, r * sinr)  — NOT INPUT-SCALED (no tx, ty multiply).
    // Identical draw structure to noise; differs ONLY in the input-scaling.
    func testBlurDrawsTwoAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "blur", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        _ = rng2.isaac01(); _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "blur x not finite")
        XCTAssertTrue(out.y.isFinite, "blur y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "blur must consume exactly 2 ISAAC words")
    }
    /// Closed form for blur (NOT input-scaled): same 2-draw structure as noise
    /// but without the tx,ty factor. Pins count (2) AND order.
    func testBlurClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "blur-closed-form")
        var rng2 = ISAAC(isaacSeed: "blur-closed-form")
        let p = SIMD2<Double>(0.3, 0.4)
        let out = Variations.evaluate(
            [Variation(name: "blur", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        let d1 = rng2.isaac01()                                  // draw #1 (angle)
        let tmpr = d1 * 2 * .pi
        let cosr = cos(tmpr), sinr = sin(tmpr)
        let d2 = rng2.isaac01()                                  // draw #2 (radius)
        let r = 1.0 * d2
        let expected = SIMD2<Double>(r * cosr, r * sinr)
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    /// noise vs blur distinction: the two differ ONLY in input-scaling (noise
    /// multiplies tx,ty; blur does not). For the SAME non-unit input p, the two
    /// must produce different outputs — guards against an accidental copy/paste
    /// port that blurs the input-scaling distinction.
    func testNoiseDiffersFromBlurDueToInputScaling() {
        var rngN1 = ISAAC(isaacSeed: "noise-vs-blur")
        var rngN2 = ISAAC(isaacSeed: "noise-vs-blur")
        // p with |x| and |y| ≠ 1 so input-scaling is observable.
        let p = SIMD2<Double>(0.3, 0.7)
        let n = Variations.evaluate([Variation(name: "noise", weight: 1)],
                                    at: p, affine: .zero, rng: &rngN1)
        let b = Variations.evaluate([Variation(name: "blur",  weight: 1)],
                                    at: p, affine: .zero, rng: &rngN2)
        let Linf = max(abs(n.x - b.x), abs(n.y - b.y))
        XCTAssertGreaterThan(Linf, 1e-6,
                             "noise (input-scaled) must differ from blur (not) for non-unit |x|,|y|")
        // Cross-check against hand-traced formulae: the magnitude (r·cosr, r·sinr)
        // is shared; noise additionally multiplies by (tx, ty).
        var rngRef = ISAAC(isaacSeed: "noise-vs-blur")
        let d1 = rngRef.isaac01(), d2 = rngRef.isaac01()
        let tmpr = d1 * 2 * .pi
        let cosr = cos(tmpr), sinr = sin(tmpr)
        let r = d2
        XCTAssertEqual(n, SIMD2<Double>(p.x * r * cosr, p.y * r * sinr), accuracy: 1e-12)
        XCTAssertEqual(b, SIMD2<Double>(r * cosr, r * sinr), accuracy: 1e-12)
    }

    // var35_gaussian_blur (variations.c:760-773): FIVE isaac_01 draws in order:
    //   (1) angle    ang = d1 * 2π;  sincos(ang, &sina, &cosa)
    //   (2..5) sum   r = weight * (d2 + d3 + d4 + d5 - 2.0)
    //   output = (r * cosa, r * sina)  — NOT input-scaled.
    // 5 draws, NOT 4 (the angle draw is separate from the 4-sum).
    func testGaussianBlurDrawsFiveAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "gaussian_blur", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        // gaussian_blur consumed exactly 5 words (1 angle + 4-sum) from rng1.
        _ = rng2.isaac01(); _ = rng2.isaac01(); _ = rng2.isaac01()
        _ = rng2.isaac01(); _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "gaussian_blur x not finite")
        XCTAssertTrue(out.y.isFinite, "gaussian_blur y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "gaussian_blur must consume exactly 5 ISAAC words")
    }
    /// Closed form for gaussian_blur: angle draw then 4-sum draws, in SPEC order.
    /// Pins count (5) AND order — any reorder diverges the expected output.
    func testGaussianBlurClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "gaussian-closed-form")
        var rng2 = ISAAC(isaacSeed: "gaussian-closed-form")
        let p = SIMD2<Double>(0.3, 0.4)
        let out = Variations.evaluate(
            [Variation(name: "gaussian_blur", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        let d1 = rng2.isaac01()                                  // draw #1 (angle)
        let ang = d1 * 2 * .pi
        let sina = sin(ang), cosa = cos(ang)
        let d2 = rng2.isaac01()                                  // draws #2..5 summed
        let d3 = rng2.isaac01()
        let d4 = rng2.isaac01()
        let d5 = rng2.isaac01()
        let r = 1.0 * (d2 + d3 + d4 + d5 - 2.0)
        let expected = SIMD2<Double>(r * cosa, r * sina)
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // var41_arch (variations.c:857-883): ONE isaac_01 draw, UN-GUARDED sinr²/cosr:
    //   ang = d1 * weight * π;  sincos(ang, &sinr, &cosr)
    //   p0 += weight * sinr;   p1 += weight * (sinr*sinr)/cosr;
    // No `if cosr==0` guard — match flam3 (the chaos game's post-affine badvalue
    // check handles Inf downstream). At the draw-weight=1 default this can be
    // Inf/NaN for rare angles near ±π/2 where cosr≈0; the finiteness test below
    // seeds a fixed "t" ISAAC and asserts finite at that seed (if it goes Inf on
    // some other seed, that's the un-guarded flam3 behavior, not a bug).
    func testArchDrawsOneAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "arch", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        // arch consumed exactly 1 word (angle, with weight*π scale).
        _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "arch x not finite")
        XCTAssertTrue(out.y.isFinite, "arch y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "arch must consume exactly 1 ISAAC word")
    }
    /// Closed form for arch (un-guarded sinr²/cosr): run on one ISAAC, draw 1
    /// word from a fresh-seed twin, compute the formula and assert agreement.
    /// Pins count (1) AND the un-guarded formula structure (no per-term guard).
    func testArchClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "arch-closed-form")
        var rng2 = ISAAC(isaacSeed: "arch-closed-form")
        let p = SIMD2<Double>(0.3, 0.4)
        let weight = 1.0
        let out = Variations.evaluate(
            [Variation(name: "arch", weight: weight, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        let d1 = rng2.isaac01()                                  // draw #1 (angle)
        let ang = d1 * weight * .pi
        let sinr = sin(ang), cosr = cos(ang)
        let expected = SIMD2<Double>(weight * sinr,
                                     weight * (sinr * sinr) / cosr)   // UN-GUARDED
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // var43_square (variations.c:900-913): TWO isaac_01 draws (NOT paramless
    // despite the name — the "square" shape comes from the RNG distribution):
    //   p0 += weight * (d1 - 0.5);   p1 += weight * (d2 - 0.5);
    // Output is bounded in [-w/2, w/2]² (independent of input p).
    func testSquareDrawsTwoAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "square", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        _ = rng2.isaac01(); _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "square x not finite")
        XCTAssertTrue(out.y.isFinite, "square y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "square must consume exactly 2 ISAAC words")
    }
    /// Closed form for square (2 independent draws, no shared terms):
    ///   p0 += w*(d1-0.5); p1 += w*(d2-0.5).
    func testSquareClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "square-closed-form")
        var rng2 = ISAAC(isaacSeed: "square-closed-form")
        let p = SIMD2<Double>(0.3, 0.4)
        let out = Variations.evaluate(
            [Variation(name: "square", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        let d1 = rng2.isaac01()                                  // draw #1 → p0
        let d2 = rng2.isaac01()                                  // draw #2 → p1
        let expected = SIMD2<Double>(1.0 * (d1 - 0.5),
                                     1.0 * (d2 - 0.5))
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // MARK: - corpus-variations RNG + Inf/badvalue care set (slots 49..51).
    // Hand-traced closed forms + draw-count invariants for the 3 RNG-consuming
    // variations rays/blade/twintrian. Each pins BOTH the draw COUNT (exactly 1)
    // AND the exact draw ORDER — any reorder diverges the ISAAC stream. Plus a
    // dedicated test proving the twintrian badvalue→-30.0 replacement fires.

    // var44_rays (variations.c:915-944): ONE isaac_01 draw, UN-GUARDED tan(ang):
    //   ang  = weight * d1 * π                            // draw #1 (angle)
    //   r    = weight / (sumsq + EPS)                     // sumsq = tx²+ty²; EPS guard
    //   tanr = weight * tan(ang) * r                      // UN-GUARDED (ang=π/2+kπ → Inf)
    //   p0 += tanr * cos(tx);  p1 += tanr * sin(ty)
    // Note the surprising cos(tx)/sin(ty) (NOT cos(ang)/sin(ang)) — the angle draw
    // only enters via tan(ang); the input point enters via cos/sin. NO per-term
    // guard on tanr — match flam3 (the chaos game's post-affine badvalue check
    // handles Inf downstream, redrawing).
    func testRaysDrawsOneAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "rays", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        // rays consumed exactly 1 word (angle) from rng1.
        _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "rays x not finite")
        XCTAssertTrue(out.y.isFinite, "rays y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "rays must consume exactly 1 ISAAC word")
    }
    /// Closed form for rays: 1 draw (angle), then r=w/(sumsq+EPS), tanr=w*tan(ang)*r,
    /// output = (tanr*cos(tx), tanr*sin(ty)). Pins count (1), order (angle is the
    /// only draw), and the un-guarded tan structure.
    func testRaysClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "rays-closed-form")
        var rng2 = ISAAC(isaacSeed: "rays-closed-form")
        let p = SIMD2<Double>(0.3, 0.4)
        let weight = 1.0
        let out = Variations.evaluate(
            [Variation(name: "rays", weight: weight, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        let d1 = rng2.isaac01()                                      // draw #1 (angle)
        let ang = weight * d1 * .pi
        let sumsq = p.x*p.x + p.y*p.y
        let r = weight / (sumsq + 1e-10)                             // EPS = 1e-10
        let tanr = weight * tan(ang) * r                             // UN-GUARDED
        let expected = SIMD2<Double>(tanr * cos(p.x),
                                     tanr * sin(p.y))
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // var45_blade (variations.c:946-974): ONE isaac_01 draw:
    //   r = d1 * weight * precalc_sqrt;  sincos(r, &sinr, &cosr)   // draw #1
    //   p0 += weight * tx * (cosr + sinr)
    //   p1 += weight * tx * (cosr - sinr)
    // NOTE: both p0 AND p1 use `tx` (NOT ty for p1). Easy to typo as ty.
    func testBladeDrawsOneAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "blade", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "blade x not finite")
        XCTAssertTrue(out.y.isFinite, "blade y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "blade must consume exactly 1 ISAAC word")
    }
    /// Closed form for blade: 1 draw (r = d1*w*sqrt), then (w*tx*(cosr+sinr),
    /// w*tx*(cosr-sinr)). Note BOTH terms use tx. Pins count (1), order, formula.
    func testBladeClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "blade-closed-form")
        var rng2 = ISAAC(isaacSeed: "blade-closed-form")
        let p = SIMD2<Double>(0.3, 0.4)
        let weight = 1.0
        let out = Variations.evaluate(
            [Variation(name: "blade", weight: weight, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        let d1 = rng2.isaac01()                                      // draw #1
        let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
        let r = d1 * weight * precalcSqrt
        let sinr = sin(r), cosr = cos(r)
        let expected = SIMD2<Double>(weight * p.x * (cosr + sinr),
                                     weight * p.x * (cosr - sinr))   // BOTH use tx
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // var47_twintrian (variations.c:998-1031): ONE isaac_01 draw, BADVALUE-GUARDED:
    //   r = d1 * weight * precalc_sqrt;  sincos(r, &sinr, &cosr)   // draw #1
    //   diff = log10(sinr*sinr) + cosr                              // log10(sinr²)→-Inf at sinr≈0
    //   if (badvalue(diff)) diff = -30.0                            // CRITICAL — see test below
    //   p0 += weight * tx * diff
    //   p1 += weight * tx * (diff - sinr * π)
    // The badvalue→-30.0 replacement is the load-bearing care item: both CPU AND
    // Metal must replicate it EXACTLY (or the orbit diverges). Pinned by
    // `testTwintrianBadvalueReplacementFires` below.
    func testTwintrianDrawsOneAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "twintrian", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "twintrian x not finite")
        XCTAssertTrue(out.y.isFinite, "twintrian y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "twintrian must consume exactly 1 ISAAC word")
    }
    /// Closed form for twintrian: 1 draw, then badvalue-guarded diff computation.
    /// Pins count (1), order, the log10(sinr²)+cosr formula, the badvalue→-30.0
    /// replacement (mirrored verbatim from flam3 variations.c:1024-1026), AND the
    /// surprising `tx` in BOTH p0 and p1.
    func testTwintrianClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "twintrian-closed-form")
        var rng2 = ISAAC(isaacSeed: "twintrian-closed-form")
        let p = SIMD2<Double>(0.3, 0.4)
        let weight = 1.0
        let out = Variations.evaluate(
            [Variation(name: "twintrian", weight: weight, parameters: [:])],
            at: p, affine: .zero, rng: &rng1)
        let d1 = rng2.isaac01()                                      // draw #1
        let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
        let r = d1 * weight * precalcSqrt
        let sinr = sin(r), cosr = cos(r)
        var diff = log10(sinr * sinr) + cosr
        // flam3's badvalue(x) = (x != x) || (x > 1e10) || (x < -1e10) — covers NaN,
        // +Inf, -Inf, and any |x| > 1e10. Mirrored verbatim (variations.c:22 + 1025).
        if diff != diff || diff > 1e10 || diff < -1e10 { diff = -30.0 }
        let expected = SIMD2<Double>(weight * p.x * diff,
                                     weight * p.x * (diff - sinr * .pi))
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    /// PROOF that the twintrian badvalue→-30.0 replacement fires (the load-bearing
    /// care item). Constructs an input where `sinr` is small enough that
    /// `sinr*sinr` UNDERFLOWS to +0 (sub-eps: |p.x| = 1e-200 → precalc_sqrt = 1e-200
    /// → r ≈ d1*1e-200 ≈ 1e-200 → sinr ≈ 1e-200 → sinr² underflows to +0 →
    /// log10(+0) = -Inf → diff = -Inf → badvalue fires → diff = -30.0).
    ///
    /// Without the guard: output would be (1e-200 * -Inf, ...) = (-Inf, -Inf).
    /// With the guard: output is (1e-200 * -30, ...) ≈ (-3e-199, -3e-199) — FINITE.
    /// So asserting finiteness + exact-equality-with-the-guarded-form proves the
    /// replacement fired in BOTH form and value.
    ///
    /// Asserts the SAME replacement semantics as flam3's `badvalue(diff)` macro
    /// (NaN/Inf/|x|>1e10 → -30.0); the Metal `badvalue_ms` mirror uses the same
    /// threshold (BAD_MS = 1e10), so a Metal-only OR CPU-only guard would fail
    /// this test (or its Metal↔CPU parity test in SpecialSauceParityTests).
    func testTwintrianBadvalueReplacementFires() {
        var rng = ISAAC(isaacSeed: "twintrian-badvalue")
        // |p.x| = 1e-200 → precalc_sqrt = 1e-200 → sinr² underflows → log10(0) = -Inf.
        let p = SIMD2<Double>(1e-200, 0)
        let out = Variations.evaluate(
            [Variation(name: "twintrian", weight: 1, parameters: [:])],
            at: p, affine: .zero, rng: &rng)
        // Verify the un-guarded precondition: diff would be -Inf/NaN.
        var rngRef = ISAAC(isaacSeed: "twintrian-badvalue")
        let d1 = rngRef.isaac01()
        let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()      // = 1e-200
        let r = d1 * 1.0 * precalcSqrt
        let sinr = sin(r)                                       // ≈ 1e-200 (small-angle)
        let cosr = cos(r)                                       // ≈ 1
        let diffUnguarded = log10(sinr * sinr) + cosr           // log10(0) = -Inf
        XCTAssertTrue(diffUnguarded.isInfinite || diffUnguarded.isNaN,
                      "precondition: un-guarded diff must be -Inf/NaN here; got \(diffUnguarded)")
        // The replacement makes the output FINITE — proves the guard fired.
        XCTAssertTrue(out.x.isFinite,
                      "twintrian x must be finite (badvalue→-30.0 replacement); got \(out.x)")
        XCTAssertTrue(out.y.isFinite,
                      "twintrian y must be finite (badvalue→-30.0 replacement); got \(out.y)")
        // And specifically: the output EQUALS the guarded formula with diff = -30.0
        // (not just any finite value) — pins the exact replacement constant.
        let diffGuarded = -30.0
        let expected = SIMD2<Double>(1.0 * p.x * diffGuarded,
                                     1.0 * p.x * (diffGuarded - sinr * .pi))
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // MARK: - corpus-variations parametric + RNG hybrid set (slots 52..54).
    // Hand-traced closed forms + draw-count invariants for the 3 parametric
    // RNG-consuming variations flower/conic/parabola. Each pins BOTH the draw
    // COUNT and the exact draw ORDER — any reorder diverges the ISAAC stream.
    // All params default 0 (flam3 clear_cp does NOT initialize them; memset(0)
    // in parser.c:229 wins, so missing XML attrs parse as 0).

    // var51_flower (variations.c:1118-1131): ONE isaac_01 draw, params
    // flower_holes + flower_petals (both default 0). Divide by precalc_sqrt
    // with NO +EPS — match flam3 (origin → 0/0 = NaN; the chaos game's
    // post-affine badvalue check handles Inf/NaN downstream, redrawing).
    //   theta = precalc_atanyx = atan2(ty, tx)
    //   r = weight * (d1 - flower_holes) * cos(flower_petals*theta) / precalc_sqrt
    //   p0 += r * tx;   p1 += r * ty
    // Note the param is `flower_petals`, NOT `flower_freq` (flam3 has no
    // flower_freq — parser.c:1090, flam3.h:302).
    func testFlowerDrawsOneAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "flower", weight: 1,
                       parameters: ["flower_holes": 0.1, "flower_petals": 2.0])],
            at: p, affine: .zero, rng: &rng1)
        _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "flower x not finite")
        XCTAssertTrue(out.y.isFinite, "flower y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "flower must consume exactly 1 ISAAC word")
    }
    /// Closed form for flower: 1 draw, then r = w*(d1-holes)*cos(petals*theta)/sqrt
    /// with NO +EPS. Pins count (1), order (draw is the inner-most random factor),
    /// the /sqrt-no-EPS structure, and the (tx, ty) propagation.
    func testFlowerClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "flower-closed-form")
        var rng2 = ISAAC(isaacSeed: "flower-closed-form")
        let p = SIMD2<Double>(0.3, 0.4)
        let weight = 1.0
        let holes = 0.1, petals = 2.0
        let out = Variations.evaluate(
            [Variation(name: "flower", weight: weight,
                       parameters: ["flower_holes": holes, "flower_petals": petals])],
            at: p, affine: .zero, rng: &rng1)
        let d1 = rng2.isaac01()                                      // draw #1
        let theta = atan2(p.y, p.x)                                  // precalc_atanyx
        let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
        let r = weight * (d1 - holes) * cos(petals * theta) / precalcSqrt   // NO EPS
        let expected = SIMD2<Double>(r * p.x, r * p.y)
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // var52_conic (variations.c:1133-1146): ONE isaac_01 draw, params
    // conic_eccentricity + conic_holes (both default 0). Divide by precalc_sqrt
    // with NO +EPS — match flam3 (origin → 0/0 = NaN; badvalue handles it
    // downstream). NOTE: with eccentricity=0 (the parse default), r = 0 for all
    // inputs → conic outputs (0,0) regardless of input. Real genomes always set
    // a nonzero eccentricity; the closed-form test uses ecc=0.5 to exercise the
    // actual formula.
    //   ct = tx / precalc_sqrt (NO EPS)
    //   r = weight * (d1 - conic_holes) * conic_eccentricity
    //       / (1 + conic_eccentricity*ct) / precalc_sqrt (NO EPS)
    //   p0 += r * tx;   p1 += r * ty
    func testConicDrawsOneAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "conic", weight: 1,
                       parameters: ["conic_eccentricity": 0.5, "conic_holes": 0.1])],
            at: p, affine: .zero, rng: &rng1)
        _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "conic x not finite")
        XCTAssertTrue(out.y.isFinite, "conic y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "conic must consume exactly 1 ISAAC word")
    }
    /// Closed form for conic: 1 draw, then ct = tx/sqrt, r = w*(d1-holes)*ecc
    /// / (1+ecc*ct) / sqrt — all with NO +EPS. Pins count (1), order, formula.
    func testConicClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "conic-closed-form")
        var rng2 = ISAAC(isaacSeed: "conic-closed-form")
        let p = SIMD2<Double>(0.3, 0.4)
        let weight = 1.0
        let ecc = 0.5, holes = 0.1
        let out = Variations.evaluate(
            [Variation(name: "conic", weight: weight,
                       parameters: ["conic_eccentricity": ecc, "conic_holes": holes])],
            at: p, affine: .zero, rng: &rng1)
        let d1 = rng2.isaac01()                                      // draw #1
        let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
        let ct = p.x / precalcSqrt                                   // NO EPS
        let r = weight * (d1 - holes) * ecc
                / (1 + ecc * ct) / precalcSqrt                       // NO EPS
        let expected = SIMD2<Double>(r * p.x, r * p.y)
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // var53_parabola (variations.c:1148-1162): TWO per-axis isaac_01 draws
    // (draw #1 → p0, draw #2 → p1). Params parabola_height + parabola_width
    // (both default 0).
    //   r = precalc_sqrt;  sincos(r, &sr, &cr)
    //   p0 += parabola_height * weight * sr*sr * isaac01()   // draw #1
    //   p1 += parabola_width  * weight * cr    * isaac01()   // draw #2
    // The draw order is load-bearing: each isaac01() is a SEPARATE statement
    // (MSL/C++ arg-eval order is unspecified — see chaosGame in Kernels.metal).
    func testParabolaDrawsTwoAndFinite() {
        var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
        let p = SIMD2<Double>(0.3, 0.2)
        let out = Variations.evaluate(
            [Variation(name: "parabola", weight: 1,
                       parameters: ["parabola_height": 0.5, "parabola_width": 0.4])],
            at: p, affine: .zero, rng: &rng1)
        _ = rng2.isaac01(); _ = rng2.isaac01()
        XCTAssertTrue(out.x.isFinite, "parabola x not finite")
        XCTAssertTrue(out.y.isFinite, "parabola y not finite")
        XCTAssertEqual(rng1.isaac01(), rng2.isaac01(),
                      "parabola must consume exactly 2 ISAAC words")
    }
    /// Closed form for parabola: 2 draws (p0 first, then p1). Pins count (2),
    /// order (draw #1 → p0 via height*sin²*r; draw #2 → p1 via width*cos*r),
    /// and the per-axis separation (no shared draw).
    func testParabolaClosedFormOrderedStream() {
        var rng1 = ISAAC(isaacSeed: "parabola-closed-form")
        var rng2 = ISAAC(isaacSeed: "parabola-closed-form")
        let p = SIMD2<Double>(0.3, 0.4)
        let weight = 1.0
        let height = 0.5, width = 0.4
        let out = Variations.evaluate(
            [Variation(name: "parabola", weight: weight,
                       parameters: ["parabola_height": height, "parabola_width": width])],
            at: p, affine: .zero, rng: &rng1)
        let r = (p.x*p.x + p.y*p.y).squareRoot()                    // precalc_sqrt
        let sr = sin(r), cr = cos(r)
        let d1 = rng2.isaac01()                                      // draw #1 → p0
        let d2 = rng2.isaac01()                                      // draw #2 → p1
        let expected = SIMD2<Double>(height * weight * sr * sr * d1,
                                     width  * weight * cr      * d2)
        XCTAssertEqual(out, expected, accuracy: 1e-12)
    }

    // MARK: - corpus-variations final pair: secant2 + disc2 (CV7).
    // Hand-traced closed forms against flam3 variations.c. These complete
    // 100% corpus-used variation coverage (57/99 of all flam3 variations).

    // var46_secant2 (variations.c:920-944). Paramless; 0 RNG draws.
    // Intended as a 'fixed' version of secant. UN-GUARDED 1/cos (cr=0 → Inf;
    // match flam3 — NO per-term guard; the chaos game's post-affine badvalue
    // check handles Inf downstream, redrawing).
    //   r   = w * precalc_sqrt (= w*sqrt(tx²+ty²)); cr = cos(r); icr = 1/cr;
    //   p0 += w * tx;
    //   if (cr < 0) p1 += w * (icr + 1);   // positive branch offset
    //   else        p1 += w * (icr - 1);   // negative branch offset
    func testSecant2() {
        // Case 1: cr ≥ 0 (else branch). (0.3, 0.4): sqrt=0.5, r=0.5, cr=cos(0.5)≈0.8776.
        //   icr = 1/cos(0.5); p1 = (icr - 1).
        let p1 = SIMD2<Double>(0.3, 0.4)
        let r1 = (p1.x*p1.x + p1.y*p1.y).squareRoot()                  // 0.5
        let cr1 = cos(r1)
        let icr1 = 1.0 / cr1
        let out1 = eval("secant2", p1, 1.0)
        XCTAssertEqual(out1.x, 1.0 * p1.x, accuracy: 1e-9)
        XCTAssertEqual(out1.y, 1.0 * (icr1 - 1.0), accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(cr1, 0, "case 1 must hit the else (cr≥0) branch")

        // Case 2: cr < 0 (if branch). (2, 0): sqrt=2, r=2, cr=cos(2)≈-0.4161.
        //   icr = 1/cos(2); p1 = (icr + 1).
        let p2 = SIMD2<Double>(2.0, 0.0)
        let r2 = (p2.x*p2.x + p2.y*p2.y).squareRoot()                  // 2.0
        let cr2 = cos(r2)
        let icr2 = 1.0 / cr2
        let out2 = eval("secant2", p2, 1.0)
        XCTAssertEqual(out2.x, 1.0 * p2.x, accuracy: 1e-9)
        XCTAssertEqual(out2.y, 1.0 * (icr2 + 1.0), accuracy: 1e-9)
        XCTAssertLessThan(cr2, 0, "case 2 must hit the if (cr<0) branch")

        // Case 3: another cr<0 point with non-zero ty, to pin that ty does NOT
        // feed p1 (only tx does). (1.2, 1.6): sqrt=2.0, same r/cr/icr as case 2,
        // so p1 is identical to case 2; only p0 differs (uses tx=1.2 not 2.0).
        let p3 = SIMD2<Double>(1.2, 1.6)
        let out3 = eval("secant2", p3, 1.0)
        XCTAssertEqual(out3.x, 1.0 * p3.x, accuracy: 1e-9)
        XCTAssertEqual(out3.y, 1.0 * (icr2 + 1.0), accuracy: 1e-9)
            // same p1 as p2: confirms ty is unused by the p1 term

        // Weight folds into BOTH r (r = w*sqrt(...)) AND the outer p0/p1 factor.
        // At w=2.0: r = 2.0*0.5 = 1.0 (NOT 0.5) → cr = cos(1.0); icr = 1/cos(1.0).
        // So p0 = 2.0*0.3 = 0.6; p1 = 2.0*(icr - 1) [cos(1.0)>0 → else branch].
        // This is NOT a simple "w*(icr1±1)" fold — weight lives inside r too.
        let outW = eval("secant2", p1, 2.0)
        let rW = 2.0 * (p1.x*p1.x + p1.y*p1.y).squareRoot()        // 2.0 * 0.5 = 1.0
        let crW = cos(rW)
        let icrW = 1.0 / crW
        XCTAssertEqual(outW.x, 2.0 * p1.x, accuracy: 1e-9)
        XCTAssertEqual(outW.y, 2.0 * (icrW - 1.0), accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(crW, 0, "weight case must hit the else (cr≥0) branch")

        // Origin: sqrt=0 → r=0 → cr=cos(0)=1 > 0 → else → p1 = w*(1-1) = 0.
        // p0 = w*0 = 0. No pole at the origin.
        XCTAssertEqual(eval("secant2", .zero, 1.0), SIMD2<Double>.zero, accuracy: 1e-9)
    }

    // var49_disc2 (variations.c:1019-1052) + disc2_precalc (variations.c:1977-1997).
    // Parametric (`disc2_rot`, `disc2_twist`, both default 0); 0 RNG draws.
    // PRECALC (inlined into the closure, mirroring radial_blur's spinvar/zoomvar):
    //   timespi = rot * π
    //   add     = twist
    //   sincos(add, &sinadd, &cosadd);  cosadd -= 1
    //   if (add >  2π)  k = 1 + add - 2π;  cosadd *= k; sinadd *= k
    //   if (add < -2π)  k = 1 + add + 2π;  cosadd *= k; sinadd *= k
    // BODY:
    //   t   = timespi * (tx + ty);  sincos(t, &sinr, &cosr)
    //   r   = w * precalc_atan / π    (precalc_atan = atan2(tx, ty) — flam3 order)
    //   p0 += (sinr + cosadd) * r
    //   p1 += (cosr + sinadd) * r
    func testDisc2() {
        let p = SIMD2<Double>(0.3, 0.4)
        // |twist| < 2π → no scaling branch.
        let params: [String:Double] = ["disc2_rot": 0.5, "disc2_twist": 0.3]
        // Hand-traced precalc: timespi = 0.5π; sinadd = sin(0.3); cosadd = cos(0.3) - 1.
        let timespi = 0.5 * .pi
        let sinadd = sin(0.3)
        let cosadd = cos(0.3) - 1.0
        let t = timespi * (p.x + p.y)
        let sinr = sin(t), cosr = cos(t)
        let r = 1.0 * atan2(p.x, p.y) / .pi                       // atan2(tx,ty) flam3 order
        let out = eval("disc2", p, 1.0, params)
        XCTAssertEqual(out.x, (sinr + cosadd) * r, accuracy: 1e-9)
        XCTAssertEqual(out.y, (cosr + sinadd) * r, accuracy: 1e-9)

        // Weight folds into the outer r term (both p0 and p1 scale with w).
        let outW = eval("disc2", p, 2.0, params)
        XCTAssertEqual(outW.x, 2.0 * (sinr + cosadd) * r, accuracy: 1e-9)
        XCTAssertEqual(outW.y, 2.0 * (cosr + sinadd) * r, accuracy: 1e-9)

        // twist > 2π scaling branch: k = 1 + twist - 2π multiplies BOTH cosadd and sinadd.
        let paramsBig: [String:Double] = ["disc2_rot": 0.5, "disc2_twist": 7.0]
        let addBig = 7.0
        let kBig = 1.0 + addBig - 2.0 * .pi
        let sinaddBig = sin(addBig) * kBig
        let cosaddBig = (cos(addBig) - 1.0) * kBig
        let outBig = eval("disc2", p, 1.0, paramsBig)
        // timespi unchanged (rot same) → t, sinr, cosr, r all identical to above.
        XCTAssertEqual(outBig.x, (sinr + cosaddBig) * r, accuracy: 1e-9)
        XCTAssertEqual(outBig.y, (cosr + sinaddBig) * r, accuracy: 1e-9)

        // twist < -2π scaling branch: k = 1 + twist + 2π.
        let paramsNeg: [String:Double] = ["disc2_rot": 0.5, "disc2_twist": -7.0]
        let addNeg = -7.0
        let kNeg = 1.0 + addNeg + 2.0 * .pi
        let sinaddNeg = sin(addNeg) * kNeg
        let cosaddNeg = (cos(addNeg) - 1.0) * kNeg
        let outNeg = eval("disc2", p, 1.0, paramsNeg)
        XCTAssertEqual(outNeg.x, (sinr + cosaddNeg) * r, accuracy: 1e-9)
        XCTAssertEqual(outNeg.y, (cosr + sinaddNeg) * r, accuracy: 1e-9)

        // Default-0 params (rot=0, twist=0): timespi=0, sinadd=0, cosadd=cos(0)-1=0.
        //   t=0 → sinr=0, cosr=1; r = w*atan2(x,y)/π.
        //   p0 = (0 + 0)*r = 0;  p1 = (1 + 0)*r = r.
        // So a genome omitting disc2_rot/twist gets a pure angular disc (p0=0,
        // p1 = w*atan2(tx,ty)/π), independent of magnitude.
        let outDefault = eval("disc2", p, 1.0, [:])
        let rDef = 1.0 * atan2(p.x, p.y) / .pi
        XCTAssertEqual(outDefault.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(outDefault.y, rDef, accuracy: 1e-9)
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
        let out = Variations.evaluate(v, at: p, affine: .zero, rng: &rngShared)
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
            let r = Variations.evaluate([Variation(name: name, weight: 1)], at: point, affine: .zero, rng: &rng)
            XCTAssertTrue(r.x.isFinite, "\(name) at \(point) x not finite")
            XCTAssertTrue(r.y.isFinite, "\(name) at \(point) y not finite")
        }
    }
    func testUnknownVariationIsZero() {
        Variations.resetWarnings()
        var rng = ISAAC(isaacSeed: "unknown-var")
        XCTAssertEqual(Variations.evaluate([Variation(name: "not_a_real_variation", weight: 5)],
                                          at: SIMD2(1, 1), affine: .zero, rng: &rng), .zero)
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
            at: SIMD2<Double>(1, 1e9), affine: .zero, rng: &rng)
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
