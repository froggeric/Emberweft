import Foundation

public enum Variations {
    // Swift 6 strict concurrency: mutable static state must be annotated. The
    // CPU reference is single-threaded by design (constraint #2), and access is
    // additionally guarded by `lock`, so `nonisolated(unsafe)` is sound here.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _warnings = Set<String>()

    /// Names whose formulas are ported into the CPU `evaluate` table (M1's 19
    /// parameterless variations + the 14 special-sauce ported in M3). Each
    /// formula was verified term-by-term against flam3 `variations.c`
    /// (scottdraves/flam3@master, v2.5.1), so the CPU reference matches the
    /// oracle. `julia` plus `julian`/`juliascope`/`super_shape`/`wedge_julia`
    /// are handled in `evaluate` directly because each consumes one ISAAC word
    /// from the RNG stream (see flam3 `var13_julia`/`var32_*`/`var50_*`/`var78_*`).
    public static let knownNames: Set<String> = [
        // M1's 19
        "linear", "sinusoidal", "spherical", "swirl", "horseshoe", "polar",
        "handkerchief", "heart", "disc", "spiral", "hyperbolic", "diamond",
        "ex", "julia", "bent", "fisheye", "exponential", "cosine", "cylinder",
        // 14 special-sauce (M3): faithful ports of variations.c var21..var79
        "rings", "fan", "blob", "fan2", "rings2", "perspective", "julian",
        "juliascope", "ngon", "curl", "rectangles", "super_shape",
        "wedge_julia", "wedge_sph",
        // var28_bubble: paramless, RNG-free
        "bubble",
        // var27_eyefish: paramless, RNG-free (NOT a fisheye alias — un-swapped)
        "eyefish",
        // var37_pie: 3 ordered isaac_01 draws (slice, angular, radial).
        // RNG-consuming → lives in `evaluate`'s switch.
        "pie",
        // var36_radial_blur: 4 isaac_01 draws summed left-to-right
        // (weight*(d1+d2+d3+d4-2)). RNG-consuming → lives in `evaluate`'s switch.
        "radial_blur",
        // var15_waves: paramless, RNG-free; needs affine c,d,e,f
        // (waves_dx2=1/(e²+EPS), waves_dy2=1/(f²+EPS)).
        "waves",
        // var17_popcorn: paramless, RNG-free; needs affine e,f.
        "popcorn",
        // var19_power: paramless, RNG-free; precalc sina/cosa/sqrt.
        "power",
        // var42_tangent: paramless, RNG-free.
        "tangent",
        // var48_cross: paramless, RNG-free.
        "cross",
        // var24_pdj: parametric (4 params, all default 0), RNG-free.
        "pdj",
        // var74_split: parametric (2 params, default 0), RNG-free.
        "split",
        // var31_noise: 2 isaac_01 draws (angle, radius); INPUT-SCALED (tx, ty).
        // RNG-consuming → lives in `evaluate`'s switch.
        "noise",
        // var34_blur: 2 isaac_01 draws; NOT input-scaled.
        // RNG-consuming → lives in `evaluate`'s switch.
        "blur",
        // var35_gaussian_blur: 5 isaac_01 draws (1 angle + 4-sum).
        // RNG-consuming → lives in `evaluate`'s switch.
        "gaussian_blur",
        // var41_arch: 1 isaac_01 draw; un-guarded sinr²/cosr.
        // RNG-consuming → lives in `evaluate`'s switch.
        "arch",
        // var43_square: 2 isaac_01 draws; output bounded in [-w/2, w/2]².
        // RNG-consuming → lives in `evaluate`'s switch.
        "square",
        // var44_rays: 1 isaac_01 draw; UN-GUARDED tan(ang) (ang=w*d1*π).
        // RNG-consuming → lives in `evaluate`'s switch.
        "rays",
        // var45_blade: 1 isaac_01 draw; p0=w*tx*(cosr+sinr), p1=w*tx*(cosr-sinr).
        // RNG-consuming → lives in `evaluate`'s switch.
        "blade",
        // var47_twintrian: 1 isaac_01 draw; BADVALUE-GUARDED log10(sinr²)+cosr
        // (→ -30.0 when NaN/Inf/|x|>1e10). RNG-consuming → lives in `evaluate`'s
        // switch.
        "twintrian",
        // var51_flower: 1 isaac_01 draw; params flower_holes + flower_petals
        // (NOT flower_freq). r = w*(d1-holes)*cos(petals*atanyx)/sqrt — /sqrt
        // NO EPS (origin → NaN; badvalue handles downstream). RNG-consuming →
        // lives in `evaluate`'s switch.
        "flower",
        // var52_conic: 1 isaac_01 draw; params conic_eccentricity + conic_holes.
        // TWO /sqrt NO EPS (ct = tx/sqrt; r = .../sqrt). RNG-consuming.
        "conic",
        // var53_parabola: TWO per-axis isaac_01 draws (draw #1 → p0 via
        // height*sin²*r; draw #2 → p1 via width*cos*r); params
        // parabola_height + parabola_width. RNG-consuming.
        "parabola",
        // var46_secant2: paramless; 0 RNG draws. UN-GUARDED 1/cos (cr=0 → Inf;
        // match flam3). Intended as a 'fixed' version of secant.
        "secant2",
        // var49_disc2: parametric (disc2_rot, disc2_twist, default 0); 0 RNG
        // draws. disc2_precalc (timespi/sinadd/cosadd) inlined into the closure.
        "disc2",
        // ---- Trig family (Z+ variations): var82_exp .. var95_coth ----
        // All paramless; 0 RNG draws. Formulas ported verbatim from
        // /private/tmp/flam3-build/variations.c L1747-1897.
        // var82_exp: expe = exp(tx); sincos(ty, &expsin, &expcos)
        "exp",
        // var83_log: (w * 0.5 * log(sumsq), w * atan2(y, x))
        "log",
        // var84_sin: sincos(tx, &sinsin, &sinacos); sinhsinh = sinh(ty); sincosh = cosh(ty)
        "sin",
        // var85_cos: sincos(tx, &cossin, &coscos); coshsinh = sinh(ty); coshcosh = cosh(ty)
        "cos",
        // var86_tan: sincos(2*tx, &tansin, &tancos); tanhsinh = sinh(2*ty); tanhcosh = cosh(2*ty)
        "tan",
        // var87_sec: secden = 2/(cos(2*tx) + cosh(2*ty))
        "sec",
        // var88_csc: cscden = 2/(cosh(2*ty) - cos(2*tx))
        "csc",
        // var89_cot: cotden = 1/(cotcosh - cotcos)
        "cot",
        // var90_sinh: sincos(ty, &sinhsin, &sinhcos); sinhsinh = sinh(tx); sinhcosh = cosh(tx)
        "sinh",
        // var91_cosh: sincos(ty, &coshsin, &coshcos); coshsinh = sinh(tx); coshcosh = cosh(tx)
        "cosh",
        // var92_tanh: tanhden = 1/(tanhcos + tanhcosh)
        "tanh",
        // var93_sech: sechden = 2/(cos(2*ty) + cosh(2*tx))
        "sech",
        // var94_csch: cschden = 2/(cosh(2*tx) - cos(2*ty))
        "csch",
        // var95_coth: cothden = 1/(cothcosh - cothcos)
        "coth",
        // ---- Batch 2: paramless non-trig (var57/61/62/64/66/70/72) ----
        // All paramless; 0 RNG draws. Formulas ported verbatim from
        // /Users/frederic/flam3-oracle-src/flam3/variations.c L1238-1590.
        // var57_butterfly: r=wx*sqrt(|ty*tx|/(EPS+tx²+(2ty)²)); wx=w*1.30294...
        "butterfly",
        // var61_edisc: r1/r2 from sumsq±2tx; a1=log(...); a2=-acos(tx/xmax);
        //   if ty>0 snv=-snv; w=w/11.57034632
        "edisc",
        // var62_elliptic: xmax=0.5*(sqrt(tmp+x2)+sqrt(tmp-x2)); w=w/M_PI_2;
        //   b=max(0,1-a²); ssx=max(0,xmax-1)
        "elliptic",
        // var64_foci: expx=exp(tx)*0.5; expnx=0.25/expx; tmp=w/(expx+expnx-cn)
        "foci",
        // var66_loonie: r2=sumsq; w2=w²; if r2<w2 r=w*sqrt(w2/r2-1) else r=w.
        //   NO EPS.
        "loonie",
        // var70_polar2: p2v=w/M_PI; (p2v*atan2(tx,ty), p2v/2*log(sumsq))
        //   uses precalc_atan = atan2(tx,ty) (SWAPPED).
        "polar2",
        // var72_scry: t=sumsq; r=1/(sqrt*(t+1/(w+EPS))); (tx*r, ty*r)
        "scry",
    ]

    public static var warnings: Set<String> { lock.withLock { _warnings } }
    public static func resetWarnings() { lock.withLock { _warnings.removeAll() } }
    static func warnUnknown(_ name: String) { _ = lock.withLock { _warnings.insert(name) } }

    /// Sum of variations over the given list, matching flam3 `apply_xform`
    /// (variations.c:2129-2381). Each variation applies its `weight` internally
    /// in flam3's EXACT arithmetic order (e.g. spherical computes
    /// `r2 = weight/(sumsq+EPS)` then `p0 += r2*tx`) — the weight does NOT
    /// wrap the whole term. This ULP order is load-bearing for chaotic maps
    /// (julia) where 1-ULP differences compound exponentially.
    ///
    /// No per-term finiteness guard: flam3 accumulates every term into `f.p0/p1`
    /// and only checks `badvalue` on the final post-affine result (variations.c:2392).
    /// The chaos game performs that check + 2-word redraw (ChaosGame badvalue path).
    ///
    /// `affine` carries the xform's pre-affine 2×2 + translation as a SIMD4 of
    /// `(c, d, e, f)` (flam3 `c[1][0], c[1][1], c[2][0], c[2][1]`), needed by the
    /// coefficient-dependent variations: `rings`/`fan` (use e,f;
    /// variations.c:521,543), `waves` (uses c,d,e,f; variations.c:405-409),
    /// `popcorn` (uses e,f; variations.c:442-446). `rng` is threaded for the
    /// eighteen RNG-consuming variations (julia/julian/juliascope/super_shape/
    /// wedge_julia/pie/radial_blur/noise/blur/gaussian_blur/arch/square/
    /// rays/blade/twintrian/flower/conic/parabola):
    /// julia/julian/juliascope/super_shape/wedge_julia each draw one
    /// `flam3_random_isaac_01`/`_bit` word when reached; `pie` draws three
    /// `isaac_01` words in flam3's exact order (slice → angular → radial);
    /// `radial_blur` draws four `isaac_01` words summed left-to-right into
    /// `weight*(d1+d2+d3+d4-2.0)`; `noise` draws two (angle, radius) and
    /// multiplies the result by tx,ty (INPUT-SCALED — the only difference from
    /// `blur`, which is NOT input-scaled); `blur` draws two (angle, radius);
    /// `gaussian_blur` draws five (1 angle + 4-sum into `weight*(Σ-2)`);
    /// `arch` draws one (angle, scaled by `weight*π`); `square` draws two
    /// (independent for p0 and p1); `rays` draws one (angle, un-guarded tan);
    /// `blade` draws one (r = d1*w*sqrt; both p0,p1 use tx); `twintrian` draws
    /// one (r = d1*w*sqrt; badvalue-guarded log10(sinr²)+cosr → -30.0);
    /// `flower` draws one (r = w*(d1-holes)*cos(petals*θ)/sqrt, NO EPS);
    /// `conic` draws one (ct = tx/sqrt, r = w*(d1-holes)*ecc/(1+ecc*ct)/sqrt,
    /// NO EPS); `parabola` draws TWO per-axis (draw #1 → p0 via height*sin²*r,
    /// draw #2 → p1 via width*cos*r).
    ///
    /// `variations` is walked in ARRAY order — the parser already sorts an xform's
    /// variations alphabetically, so for [julia, julian] julia draws before julian.
    public static func evaluate(_ variations: [Variation], at p: SIMD2<Double>,
                                affine: SIMD4<Double>, rng: inout ISAAC) -> SIMD2<Double> {
        var acc = SIMD2<Double>.zero
        for v in variations {
            guard v.weight != 0 else { continue }
            let term: SIMD2<Double>
            switch v.name {
            case "julia":
                term = julia(p, weight: v.weight, rng: &rng)
            case "julian":
                term = julian(p, weight: v.weight, params: v.parameters, rng: &rng)
            case "juliascope":
                term = juliascope(p, weight: v.weight, params: v.parameters, rng: &rng)
            case "pie":
                term = pie(p, weight: v.weight, params: v.parameters, rng: &rng)
            case "radial_blur":
                term = radialBlur(p, weight: v.weight, params: v.parameters, rng: &rng)
            case "noise":
                term = noise(p, weight: v.weight, rng: &rng)
            case "blur":
                term = blur(p, weight: v.weight, rng: &rng)
            case "gaussian_blur":
                term = gaussianBlur(p, weight: v.weight, rng: &rng)
            case "arch":
                term = arch(p, weight: v.weight, rng: &rng)
            case "square":
                term = square(p, weight: v.weight, rng: &rng)
            case "rays":
                term = rays(p, weight: v.weight, rng: &rng)
            case "blade":
                term = blade(p, weight: v.weight, rng: &rng)
            case "twintrian":
                term = twintrian(p, weight: v.weight, rng: &rng)
            case "flower":
                term = flower(p, weight: v.weight, params: v.parameters, rng: &rng)
            case "conic":
                term = conic(p, weight: v.weight, params: v.parameters, rng: &rng)
            case "parabola":
                term = parabola(p, weight: v.weight, params: v.parameters, rng: &rng)
            case "super_shape":
                term = superShape(p, weight: v.weight, params: v.parameters, rng: &rng)
            case "wedge_julia":
                term = wedgeJulia(p, weight: v.weight, params: v.parameters, rng: &rng)
            default:
                if let fn = table[v.name] {
                    term = fn(p, v.weight, v.parameters, affine)
                } else {
                    warnUnknown(v.name)
                    continue
                }
            }
            acc += term
        }
        return acc
    }

    // MARK: - RNG-consuming variations (special-cased in evaluate)

    /// flam3 `var13_julia` (variations.c:350-374). Operation order matches the C
    /// source line-for-line so the chaotic julia map reproduces the oracle's
    /// trajectory bit-for-bit:
    ///   a   = 0.5 * precalc_atan            (precalc_atan = atan2(tx,ty) = atan2(x,y))
    ///   if (isaac_bit) a += M_PI
    ///   r   = weight * sqrt(precalc_sqrt)   (precalc_sqrt = sqrt(x²+y²); weight HERE)
    ///   sincos(a, &sa, &ca)
    ///   p0 += r * ca                        (NOT weight * (r4 * ca))
    ///   p1 += r * sa
    private static func julia(_ p: SIMD2<Double>, weight: Double, rng: inout ISAAC) -> SIMD2<Double> {
        let sumsq = p.x*p.x + p.y*p.y
        let precalcSqrt = sumsq.squareRoot()        // sqrt(x²+y²) — flam3 precalc
        let a = 0.5 * atan2(p.x, p.y)               // 0.5 * precalc_atan
        let r = weight * precalcSqrt.squareRoot()   // weight * sqrt(precalc_sqrt)
        var aa = a
        if rng.bit() { aa += .pi }                   // flam3_random_isaac_bit (1 word)
        return SIMD2(r * cos(aa), r * sin(aa))      // r * ca , r * sa
    }

    /// flam3 `var32_juliaN_generic` (variations.c:711-724) + `juliaN_precalc`
    /// (variations.c:1949-1952). Consumes ONE `flam3_random_isaac_01` word.
    ///   rN = fabs(power); cn = dist / power / 2.0
    ///   t_rnd = trunc(rN * isaac01())
    ///   tmpr = (precalc_atanyx + 2π·t_rnd) / power
    ///   r = weight * pow(sumsq, cn); (r·cos(tmpr), r·sin(tmpr))
    private static func julian(_ p: SIMD2<Double>, weight: Double,
                               params: [String: Double], rng: inout ISAAC) -> SIMD2<Double> {
        let power = resolve("julian", "julian_power", params)
        let dist  = resolve("julian", "julian_dist", params)
        let rN = abs(power)                              // julian_rN
        let cn = dist / power / 2.0                      // julian_cn
        let sumsq = p.x*p.x + p.y*p.y
        let atanyx = atan2(p.y, p.x)                     // precalc_atanyx (standard order)
        let tRnd = Int(rN * rng.isaac01())               // trunc(rN * isaac01); rN≥0 → Int==trunc
        let tmpr = (atanyx + 2 * .pi * Double(tRnd)) / power
        let r = weight * pow(sumsq, cn)
        return SIMD2(r * cos(tmpr), r * sin(tmpr))
    }

    /// flam3 `var33_juliaScope_generic` (variations.c:726-745) + `juliaScope_precalc`
    /// (variations.c:1960-1963). Consumes ONE `flam3_random_isaac_01` word.
    ///   rN = fabs(power); cn = dist / power / 2.0
    ///   t_rnd = trunc(rN * isaac01())
    ///   tmpr = (t_rnd&1)==0 ? (2π·t_rnd + atanyx)/power : (2π·t_rnd - atanyx)/power
    ///   r = weight * pow(sumsq, cn); (r·cos(tmpr), r·sin(tmpr))
    private static func juliascope(_ p: SIMD2<Double>, weight: Double,
                                   params: [String: Double], rng: inout ISAAC) -> SIMD2<Double> {
        let power = resolve("juliascope", "juliascope_power", params)
        let dist  = resolve("juliascope", "juliascope_dist", params)
        let rN = abs(power)
        let cn = dist / power / 2.0
        let sumsq = p.x*p.x + p.y*p.y
        let atanyx = atan2(p.y, p.x)
        let tRnd = Int(rN * rng.isaac01())
        let tmpr: Double
        if (tRnd & 1) == 0 {
            tmpr = (2 * .pi * Double(tRnd) + atanyx) / power
        } else {
            tmpr = (2 * .pi * Double(tRnd) - atanyx) / power
        }
        let r = weight * pow(sumsq, cn)
        return SIMD2(r * cos(tmpr), r * sin(tmpr))
    }

    /// flam3 `var37_pie` (variations.c:795-809). Consumes THREE
    /// `flam3_random_isaac_01` words in this EXACT order:
    ///   sl = (int)(isaac01 * pie_slices + 0.5)                 // draw #1 (slice index)
    ///   a  = pie_rotation + 2π*(Double(sl) + isaac01*pie_thickness) / pie_slices
    ///                                                            // draw #2 (angular offset, inside parens)
    ///   r  = weight * isaac01                                  // draw #3 (radial)
    ///   (r*cos(a), r*sin(a))
    /// A single reordered draw diverges the ISAAC stream and breaks vs-flam3
    /// parity — keep the calls in this order. `p` is UNUSED (pie's output is
    /// independent of its input, like flam3); kept in the signature for
    /// dispatch-shape parity with the other RNG-consuming variations.
    private static func pie(_ p: SIMD2<Double>, weight: Double,
                            params: [String: Double], rng: inout ISAAC) -> SIMD2<Double> {
        _ = p   // pie ignores its input (matches flam3 var37_pie)
        let slices   = resolve("pie", "pie_slices", params)
        let rotation = resolve("pie", "pie_rotation", params)
        let thickness = resolve("pie", "pie_thickness", params)
        let d1 = rng.isaac01()
        let sl = Int(d1 * slices + 0.5)                                          // draw #1
        let d2 = rng.isaac01()
        let a  = rotation + 2 * .pi * (Double(sl) + d2 * thickness) / slices     // draw #2
        let d3 = rng.isaac01()                                                   // draw #3
        let r  = weight * d3
        return SIMD2(r * cos(a), r * sin(a))
    }

    /// flam3 `var36_radial_blur` (variations.c:775-793) + `radial_blur_precalc`
    /// (variations.c:1964-1967). Consumes FOUR `flam3_random_isaac_01` words,
    /// summed LEFT-TO-RIGHT into a pseudo-gaussian:
    ///   rndG = weight * (d1 + d2 + d3 + d4 - 2.0)
    /// The `weight * (...)` outer factor means the 4 draws MUST be consumed
    /// before the multiply — reordering or hoisting any draw diverges the ISAAC
    /// stream and breaks vs-flam3 parity. spinvar/zoomvar are the precalc
    /// sincos of `radial_blur_angle * π/2` (inlined here, no precalc struct).
    ///   ra   = precalc_sqrt = sqrt(tx² + ty²)
    ///   tmpa = precalc_atanyx + spinvar * rndG   (atanyx = atan2(ty,tx))
    ///   rz   = zoomvar * rndG - 1.0
    ///   (ra*cos(tmpa) + rz*tx, ra*sin(tmpa) + rz*ty)
    private static func radialBlur(_ p: SIMD2<Double>, weight: Double,
                                   params: [String: Double], rng: inout ISAAC) -> SIMD2<Double> {
        let angle   = resolve("radial_blur", "radial_blur_angle", params)
        let spinvar = sin(angle * .pi / 2.0)
        let zoomvar = cos(angle * .pi / 2.0)
        let d1 = rng.isaac01(), d2 = rng.isaac01(), d3 = rng.isaac01(), d4 = rng.isaac01()
        let rndG = weight * (d1 + d2 + d3 + d4 - 2.0)
        let ra   = (p.x*p.x + p.y*p.y).squareRoot()
        let tmpa = atan2(p.y, p.x) + spinvar * rndG
        let rz   = zoomvar * rndG - 1.0
        return SIMD2(ra * cos(tmpa) + rz * p.x, ra * sin(tmpa) + rz * p.y)
    }

    /// flam3 `var31_noise` (variations.c:696-708). Consumes TWO
    /// `flam3_random_isaac_01` words in this EXACT order:
    ///   tmpr = d1 * 2π;  sincos(tmpr, &sinr, &cosr)         // draw #1 (angle)
    ///   r    = weight * d2                                   // draw #2 (radius)
    ///   p0 += tx * r * cosr;  p1 += ty * r * sinr           // INPUT-SCALED (tx, ty)
    /// The INPUT-SCALING is the ONLY difference from `blur` (var34), whose
    /// output is `(r*cosr, r*sinr)` — NOT input-scaled. Easy to mix up;
    /// `testNoiseDiffersFromBlurDueToInputScaling` pins the distinction.
    private static func noise(_ p: SIMD2<Double>, weight: Double,
                              rng: inout ISAAC) -> SIMD2<Double> {
        let d1 = rng.isaac01()                                     // draw #1 (angle)
        let tmpr = d1 * 2 * .pi
        let cosr = cos(tmpr)
        let sinr = sin(tmpr)
        let d2 = rng.isaac01()                                     // draw #2 (radius)
        let r = weight * d2
        return SIMD2(p.x * r * cosr, p.y * r * sinr)
    }

    /// flam3 `var34_blur` (variations.c:746-758). Consumes TWO
    /// `flam3_random_isaac_01` words — IDENTICAL draw structure to `noise`:
    ///   tmpr = d1 * 2π;  sincos(tmpr, &sinr, &cosr)         // draw #1 (angle)
    ///   r    = weight * d2                                   // draw #2 (radius)
    ///   p0 += r * cosr;  p1 += r * sinr                     // NOT INPUT-SCALED
    /// Differs from `noise` ONLY in the absence of the tx,ty factor.
    private static func blur(_ p: SIMD2<Double>, weight: Double,
                             rng: inout ISAAC) -> SIMD2<Double> {
        _ = p   // blur ignores its input (matches flam3 var34_blur)
        let d1 = rng.isaac01()                                     // draw #1 (angle)
        let tmpr = d1 * 2 * .pi
        let cosr = cos(tmpr)
        let sinr = sin(tmpr)
        let d2 = rng.isaac01()                                     // draw #2 (radius)
        let r = weight * d2
        return SIMD2(r * cosr, r * sinr)
    }

    /// flam3 `var35_gaussian` (variations.c:760-773). Consumes FIVE
    /// `flam3_random_isaac_01` words — 1 angle draw, THEN 4 summed draws:
    ///   ang  = d1 * 2π;  sincos(ang, &sina, &cosa)          // draw #1 (angle)
    ///   r    = weight * (d2 + d3 + d4 + d5 - 2.0)            // draws #2..5 (4-sum)
    ///   p0 += r * cosa;  p1 += r * sina                     // NOT INPUT-SCALED
    /// 5 draws, NOT 4 (the angle draw is separate from the 4-sum). The XML name
    /// is `gaussian_blur`; the C function is `var35_gaussian` (the README/column
    /// list uses `gaussian_blur`).
    private static func gaussianBlur(_ p: SIMD2<Double>, weight: Double,
                                     rng: inout ISAAC) -> SIMD2<Double> {
        _ = p   // gaussian_blur ignores its input (matches flam3 var35_gaussian)
        let d1 = rng.isaac01()                                     // draw #1 (angle)
        let ang = d1 * 2 * .pi
        let sina = sin(ang)
        let cosa = cos(ang)
        let d2 = rng.isaac01()                                     // draws #2..5 (4-sum)
        let d3 = rng.isaac01()
        let d4 = rng.isaac01()
        let d5 = rng.isaac01()
        let r = weight * (d2 + d3 + d4 + d5 - 2.0)
        return SIMD2(r * cosa, r * sina)
    }

    /// flam3 `var41_arch` (variations.c:857-883). Consumes ONE
    /// `flam3_random_isaac_01` word, with UN-GUARDED `sinr²/cosr`:
    ///   ang  = d1 * weight * π;  sincos(ang, &sinr, &cosr)   // draw #1 (angle)
    ///   p0 += weight * sinr
    ///   p1 += weight * (sinr * sinr) / cosr                  // UN-GUARDED
    /// NO per-term `if cosr==0` guard — match flam3 (cosr=0 → Inf; the chaos
    /// game's post-affine badvalue check handles Inf downstream, redrawing).
    /// `p` is UNUSED (arch's output is RNG-driven only, like flam3).
    private static func arch(_ p: SIMD2<Double>, weight: Double,
                             rng: inout ISAAC) -> SIMD2<Double> {
        _ = p   // arch ignores its input (matches flam3 var41_arch)
        let d1 = rng.isaac01()                                     // draw #1 (angle)
        let ang = d1 * weight * .pi
        let sinr = sin(ang)
        let cosr = cos(ang)
        return SIMD2(weight * sinr,
                     weight * (sinr * sinr) / cosr)               // UN-GUARDED
    }

    /// flam3 `var43_square` (variations.c:900-913). Consumes TWO
    /// `flam3_random_isaac_01` words — INDEPENDENT for p0 and p1:
    ///   p0 += weight * (d1 - 0.5)                            // draw #1
    ///   p1 += weight * (d2 - 0.5)                            // draw #2
    /// Output is bounded in [-weight/2, weight/2]² (independent of input p).
    /// Despite the name, this is an RNG-consuming variation (the "square" shape
    /// comes from the uniform RNG distribution), NOT paramless.
    private static func square(_ p: SIMD2<Double>, weight: Double,
                               rng: inout ISAAC) -> SIMD2<Double> {
        _ = p   // square ignores its input (matches flam3 var43_square)
        let d1 = rng.isaac01()                                     // draw #1 (p0)
        let d2 = rng.isaac01()                                     // draw #2 (p1)
        return SIMD2(weight * (d1 - 0.5), weight * (d2 - 0.5))
    }

    /// flam3 `var44_rays` (variations.c:915-944). Consumes ONE
    /// `flam3_random_isaac_01` word, with UN-GUARDED `tan(ang)`:
    ///   ang  = weight * d1 * π                                  // draw #1 (angle)
    ///   r    = weight / (precalc_sumsq + EPS)                  // sumsq = tx²+ty²; EPS guard
    ///   tanr = weight * tan(ang) * r                            // UN-GUARDED (ang=π/2+kπ → Inf)
    ///   p0 += tanr * cos(tx);   p1 += tanr * sin(ty)
    /// The `cos(tx)`/`sin(ty)` are over the INPUT POINT, not the drawn angle —
    /// the only role of the drawn `ang` is to feed `tan`. NO per-term finiteness
    /// guard on `tanr` — match flam3 (the chaos game's post-affine badvalue
    /// check handles Inf downstream, redrawing). `p` is UNUSED for output
    /// scaling beyond the cos/sin factors (rays's output IS input-dependent,
    /// unlike arch/blur/square — it uses p.x in cos, p.y in sin, and p in sumsq).
    private static func rays(_ p: SIMD2<Double>, weight: Double,
                             rng: inout ISAAC) -> SIMD2<Double> {
        let d1 = rng.isaac01()                                     // draw #1 (angle)
        let ang = weight * d1 * .pi
        let sumsq = p.x*p.x + p.y*p.y                              // precalc_sumsq
        let r = weight / (sumsq + 1e-10)                           // EPS guard
        let tanr = weight * tan(ang) * r                           // UN-GUARDED
        return SIMD2(tanr * cos(p.x),
                     tanr * sin(p.y))
    }

    /// flam3 `var45_blade` (variations.c:946-974). Consumes ONE
    /// `flam3_random_isaac_01` word:
    ///   r = d1 * weight * precalc_sqrt;  sincos(r, &sinr, &cosr)   // draw #1
    ///   p0 += weight * tx * (cosr + sinr)
    ///   p1 += weight * tx * (cosr - sinr)
    /// NOTE: both p0 AND p1 use `tx` (NOT ty for p1) — surprising but verbatim
    /// from flam3. Bounded output (no poles) → the orbit is well-behaved at
    /// any weight.
    private static func blade(_ p: SIMD2<Double>, weight: Double,
                              rng: inout ISAAC) -> SIMD2<Double> {
        let d1 = rng.isaac01()                                     // draw #1
        let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
        let r = d1 * weight * precalcSqrt
        let sinr = sin(r)
        let cosr = cos(r)
        return SIMD2(weight * p.x * (cosr + sinr),
                     weight * p.x * (cosr - sinr))                // BOTH use tx
    }

    /// flam3 `var47_twintrian` (variations.c:998-1031). Consumes ONE
    /// `flam3_random_isaac_01` word, with a BADVALUE GUARD on `log10(sinr²)`:
    ///   r = d1 * weight * precalc_sqrt;  sincos(r, &sinr, &cosr)   // draw #1
    ///   diff = log10(sinr * sinr) + cosr                          // → -Inf when sinr≈0
    ///   if (badvalue(diff)) diff = -30.0                          // CRITICAL — both CPU+Metal
    ///   p0 += weight * tx * diff
    ///   p1 += weight * tx * (diff - sinr * π)
    /// `badvalue(x)` is flam3's macro: `(x != x) || (x > 1e10) || (x < -1e10)`
    /// (variations.c:22) — covers NaN, ±Inf, and any |x| > 1e10. The Metal
    /// `badvalue_ms` mirror uses the same BAD_MS=1e10 threshold (Kernels.metal).
    /// The replacement is load-bearing: without it, `log10(0)` returns -Inf
    /// whenever `sinr*sinr` underflows (sub-|p.x| ≈ 1e-162 → sinr² ≈ 0), and the
    /// orbit diverges. NOTE: both p0 AND p1 use `tx` (NOT ty for p1).
    private static func twintrian(_ p: SIMD2<Double>, weight: Double,
                                  rng: inout ISAAC) -> SIMD2<Double> {
        let d1 = rng.isaac01()                                     // draw #1
        let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
        let r = d1 * weight * precalcSqrt
        let sinr = sin(r)
        let cosr = cos(r)
        var diff = log10(sinr * sinr) + cosr
        // flam3's badvalue(x) = (x != x) || (x > 1e10) || (x < -1e10) — covers NaN,
        // +Inf, -Inf, and any |x| > 1e10. Mirrored verbatim
        // (variations.c:22 + 1024-1026). The Metal `badvalue_ms` mirror uses
        // the same BAD_MS=1e10 threshold.
        if diff != diff || diff > 1e10 || diff < -1e10 { diff = -30.0 }
        return SIMD2(weight * p.x * diff,
                     weight * p.x * (diff - sinr * .pi))           // BOTH use tx
    }

    /// flam3 `var51_flower` (variations.c:1118-1131). Parametric + RNG: 2 params
    /// (`flower_holes`, `flower_petals` [NOT `flower_freq` — flam3 has no
    /// flower_freq; parser.c:1090, flam3.h:302], both default 0). Consumes ONE
    /// `flam3_random_isaac_01` word:
    ///   theta = precalc_atanyx = atan2(ty, tx)
    ///   r = weight * (isaac01 - flower_holes) * cos(flower_petals * theta)
    ///       / precalc_sqrt                                       // draw #1; /sqrt NO EPS
    ///   p0 += r * tx;   p1 += r * ty
    /// The /precalc_sqrt has NO +EPS (unlike spherical/rays which use sumsq+EPS).
    /// At the origin → 0/0 → NaN; match flam3 (do NOT add EPS — the chaos game's
    /// post-affine badvalue check handles NaN downstream, redrawing).
    private static func flower(_ p: SIMD2<Double>, weight: Double,
                               params: [String: Double], rng: inout ISAAC) -> SIMD2<Double> {
        let holes  = resolve("flower", "flower_holes", params)
        let petals = resolve("flower", "flower_petals", params)
        let theta = atan2(p.y, p.x)                                 // precalc_atanyx
        let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
        let d1 = rng.isaac01()                                      // draw #1
        let r = weight * (d1 - holes) * cos(petals * theta) / precalcSqrt   // NO EPS
        return SIMD2(r * p.x, r * p.y)
    }

    /// flam3 `var52_conic` (variations.c:1133-1146). Parametric + RNG: 2 params
    /// (`conic_eccentricity`, `conic_holes`, both default 0). Consumes ONE
    /// `flam3_random_isaac_01` word. TWO divisions by `precalc_sqrt` with NO +EPS:
    ///   ct = tx / precalc_sqrt                                    // NO EPS
    ///   r = weight * (isaac01 - conic_holes) * conic_eccentricity
    ///       / (1 + conic_eccentricity * ct) / precalc_sqrt        // draw #1; /sqrt NO EPS
    ///   p0 += r * tx;   p1 += r * ty
    /// At the origin → 0/0 → NaN; match flam3 (no EPS). NOTE: when eccentricity=0
    /// (the parse default), r = 0 for all inputs → conic outputs (0, 0) regardless
    /// of input. The `ecc=1.0` default in flam3's `initialize_xforms` applies only
    /// to NEWLY-ADDED xforms (interpolation padding), NOT to parsed genomes.
    private static func conic(_ p: SIMD2<Double>, weight: Double,
                              params: [String: Double], rng: inout ISAAC) -> SIMD2<Double> {
        let ecc   = resolve("conic", "conic_eccentricity", params)
        let holes = resolve("conic", "conic_holes", params)
        let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
        let ct = p.x / precalcSqrt                                  // NO EPS
        let d1 = rng.isaac01()                                      // draw #1
        let r = weight * (d1 - holes) * ecc
                / (1 + ecc * ct) / precalcSqrt                      // NO EPS
        return SIMD2(r * p.x, r * p.y)
    }

    /// flam3 `var53_parabola` (variations.c:1148-1162). Parametric + RNG: 2 params
    /// (`parabola_height`, `parabola_width`, both default 0). Consumes TWO
    /// `flam3_random_isaac_01` words — ONE PER AXIS (draw #1 → p0, draw #2 → p1):
    ///   r = precalc_sqrt;  sincos(r, &sr, &cr)
    ///   p0 += parabola_height * weight * sr * sr * isaac01()      // draw #1 → p0
    ///   p1 += parabola_width  * weight * cr       * isaac01()     // draw #2 → p1
    /// The per-axis draw order is load-bearing: each `isaac01()` MUST be its own
    /// statement in this order (p0 first, p1 second). Reordering or hoisting
    /// diverges the ISAAC stream from flam3.
    private static func parabola(_ p: SIMD2<Double>, weight: Double,
                                 params: [String: Double], rng: inout ISAAC) -> SIMD2<Double> {
        let height = resolve("parabola", "parabola_height", params)
        let width  = resolve("parabola", "parabola_width", params)
        let r = (p.x*p.x + p.y*p.y).squareRoot()                   // precalc_sqrt
        let sr = sin(r), cr = cos(r)
        let d1 = rng.isaac01()                                      // draw #1 → p0
        let p0 = height * weight * sr * sr * d1
        let d2 = rng.isaac01()                                      // draw #2 → p1
        let p1 = width  * weight * cr       * d2
        return SIMD2(p0, p1)
    }

    /// flam3 `var50_supershape` (variations.c:1093-1117) + `supershape_precalc`
    /// (variations.c:2000-2003). Draws ONE `flam3_random_isaac_01` word
    /// UNCONDITIONALLY — the `draw` term is always evaluated even when
    /// `super_shape_rnd == 0` (the `myrnd*draw` product is 0 but the side-effect
    /// of consuming the RNG word still happens).
    ///   pm_4 = m/4; pneg1_n1 = -1/n1
    ///   theta = pm_4·atanyx + π/4
    ///   t1 = pow(|cos(theta)|, n2); t2 = pow(|sin(theta)|, n3)
    ///   r = w·((rnd·draw + (1-rnd)·sqrt) - holes)·pow(t1+t2, pneg1_n1)/sqrt
    ///   (r·tx, r·ty)
    private static func superShape(_ p: SIMD2<Double>, weight: Double,
                                   params: [String: Double], rng: inout ISAAC) -> SIMD2<Double> {
        let m   = resolve("super_shape", "super_shape_m", params)
        let n1  = resolve("super_shape", "super_shape_n1", params)
        let n2  = resolve("super_shape", "super_shape_n2", params)
        let n3  = resolve("super_shape", "super_shape_n3", params)
        let holes = resolve("super_shape", "super_shape_holes", params)
        let rndParam = resolve("super_shape", "super_shape_rnd", params)
        let pm4 = m / 4.0                                // super_shape_pm_4
        let pneg1N1 = -1.0 / n1                          // super_shape_pneg1_n1
        let sumsq = p.x*p.x + p.y*p.y
        let precalcSqrt = sumsq.squareRoot()
        let atanyx = atan2(p.y, p.x)
        let theta = pm4 * atanyx + .pi / 4
        let t1 = pow(abs(cos(theta)), n2)
        let t2 = pow(abs(sin(theta)), n3)
        let draw = rng.isaac01()                         // UNCONDITIONAL (variations.c:1112)
        let r = weight * ((rndParam * draw + (1.0 - rndParam) * precalcSqrt) - holes)
                * pow(t1 + t2, pneg1N1) / precalcSqrt
        return SIMD2(r * p.x, r * p.y)
    }

    /// flam3 `var78_wedge_julia` (variations.c:1672-1688) + `wedgeJulia_precalc`
    /// (variations.c:1954-1958). Consumes ONE `flam3_random_isaac_01` word.
    ///   cf = 1 - angle·count·(1/π)·0.5; rN = fabs(power); cn = dist/power/2
    ///   r = weight·pow(sumsq, cn)
    ///   t_rnd = (int)(rN·isaac01())
    ///   a = (atanyx + 2π·t_rnd)/power; c = floor((count·a + π)·(1/π)·0.5)
    ///   a = a·cf + c·angle; (r·cos a, r·sin a)
    private static func wedgeJulia(_ p: SIMD2<Double>, weight: Double,
                                   params: [String: Double], rng: inout ISAAC) -> SIMD2<Double> {
        let angle = resolve("wedge_julia", "wedge_julia_angle", params)
        let count = resolve("wedge_julia", "wedge_julia_count", params)
        let power = resolve("wedge_julia", "wedge_julia_power", params)
        let dist  = resolve("wedge_julia", "wedge_julia_dist", params)
        let cf = 1.0 - angle * count * (1.0 / .pi) * 0.5   // wedgeJulia_cf
        let rN = abs(power)                                // wedgeJulia_rN
        let cn = dist / power / 2.0                        // wedgeJulia_cn
        let sumsq = p.x*p.x + p.y*p.y
        let atanyx = atan2(p.y, p.x)
        let r = weight * pow(sumsq, cn)
        let tRnd = Int(rN * rng.isaac01())
        var a = (atanyx + 2 * .pi * Double(tRnd)) / power
        let c = floor((count * a + .pi) * (1.0 / .pi) * 0.5)
        a = a * cf + c * angle
        return SIMD2(r * cos(a), r * sin(a))
    }

    /// Resolve a variation parameter: the genome value if present, else the
    /// descriptor default (the SINGLE source of truth in `VariationDescriptor`),
    /// else 0. The parser only fills `parameters` with attrs present in the XML,
    /// so absent keys fall through to the documented flam3 default.
    private static func resolve(_ name: String, _ key: String,
                                _ par: [String: Double]) -> Double {
        par[key] ?? VariationDescriptor.descriptor(for: name)?.defaults[key] ?? 0
    }

    // `nonisolated(unsafe)` is sound: `table` is a `let` initialized once at
    // first access and never mutated; the closures it holds are pure (no shared
    // mutable state). The CPU reference path is single-threaded by design.
    //
    // Each closure takes `(p, weight, params, affine)` and returns the term that
    // flam3 would add to `f.p0`/`f.p1`, with weight folded in at flam3's exact
    // position. Formulas are line-for-line ports of flam3 variations.c (varN_*),
    // using flam3's `precalc_atan = atan2(tx, ty)` = atan2(x, y),
    // `precalc_atanyx = atan2(ty, tx)` = atan2(y, x), and `EPS = 1e-10`
    // (private.h:47). C source lines cited per closure.
    //
    // `affine` is SIMD4(c, d, e, f) = flam3 c[1][0], c[1][1], c[2][0], c[2][1]:
    // the xform's pre-affine 2×2 second row + translation. Used by the four
    // coefficient-dependent variations: `rings` (e), `fan` (e,f), `waves`
    // (c,d,e,f), `popcorn` (e,f). All other closures ignore it (`_`).
    //
    // NOTE on sina/cosa: flam3 computes `precalc_sina = tx/sqrt`,
    // `precalc_cosa = ty/sqrt` (variations.c:2164-2165). These equal
    // `sin(atan2(x,y))` and `cos(atan2(x,y))` respectively; the existing M1 table
    // (spiral/hyperbolic/diamond/…) uses the `cos(a)`/`sin(a)` form, so the new
    // ports follow that same convention for table-wide consistency. The ULP-level
    // difference is inside the M1 statistical-parity envelope.
    private nonisolated(unsafe) static let table: [String: (SIMD2<Double>, Double, [String: Double], SIMD4<Double>) -> SIMD2<Double>] = {
        var t: [String: (SIMD2<Double>, Double, [String: Double], SIMD4<Double>) -> SIMD2<Double>] = [:]
        let eps = 1e-10
        // var0_linear (variations.c:143-152): p0 += weight*tx
        t["linear"]      = { p, w, _, _ in SIMD2(w * p.x, w * p.y) }
        // var1_sinusoidal: p0 += weight*sin(tx)
        t["sinusoidal"]  = { p, w, _, _ in SIMD2(w * sin(p.x), w * sin(p.y)) }
        // var2_spherical: r2 = weight/(sumsq+EPS); p0 += r2*tx
        t["spherical"]   = { p, w, _, _ in
            let sumsq = p.x*p.x + p.y*p.y
            let r2 = w / (sumsq + eps)
            return SIMD2(r2 * p.x, r2 * p.y)
        }
        // var3_swirl: sincos(r2,&c1,&c2); nx=c1*tx-c2*ty; p0+=weight*nx
        t["swirl"]       = { p, w, _, _ in
            let r2 = p.x*p.x + p.y*p.y
            let c1 = sin(r2), c2 = cos(r2)
            return SIMD2(w * (c1*p.x - c2*p.y), w * (c2*p.x + c1*p.y))
        }
        // var4_horseshoe: r = weight/(sqrt+EPS); p0 += (tx-ty)*(tx+ty)*r
        t["horseshoe"]   = { p, w, _, _ in
            let r = w / ((p.x*p.x + p.y*p.y).squareRoot() + eps)
            return SIMD2((p.x - p.y) * (p.x + p.y) * r, 2.0 * p.x * p.y * r)
        }
        // var5_polar: nx=atan/pi; ny=sqrt-1; p0+=weight*nx
        t["polar"]       = { p, w, _, _ in
            let nx = atan2(p.x, p.y) / .pi
            let ny = (p.x*p.x + p.y*p.y).squareRoot() - 1.0
            return SIMD2(w * nx, w * ny)
        }
        // var6_handkerchief: a=atan; r=sqrt; p0+=weight*r*sin(a+r)
        t["handkerchief"] = { p, w, _, _ in
            let a = atan2(p.x, p.y)
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            return SIMD2(w * r * sin(a + r), w * r * cos(a - r))
        }
        // var7_heart: a=sqrt*atan; r=weight*sqrt; p0+=r*sa; p1+=(-r)*ca
        t["heart"]       = { p, w, _, _ in
            let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
            let a = precalcSqrt * atan2(p.x, p.y)
            let r = w * precalcSqrt
            return SIMD2(r * sin(a), (-r) * cos(a))
        }
        // var8_disc: a=atan/pi; r=pi*sqrt; p0+=weight*sin(r)*a
        t["disc"]        = { p, w, _, _ in
            let a = atan2(p.x, p.y) / .pi
            let r = .pi * (p.x*p.x + p.y*p.y).squareRoot()
            return SIMD2(w * sin(r) * a, w * cos(r) * a)
        }
        // var9_spiral: r=sqrt+EPS; r1=weight/r; p0+=r1*(cosa+sin(r))
        t["spiral"]      = { p, w, _, _ in
            let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
            let r = precalcSqrt + eps
            let r1 = w / r
            let a = atan2(p.x, p.y)
            return SIMD2(r1 * (cos(a) + sin(r)), r1 * (sin(a) - cos(r)))
        }
        // var10_hyperbolic: r=sqrt+EPS; p0+=weight*sin(a)/r; p1+=weight*cos(a)*r
        t["hyperbolic"]  = { p, w, _, _ in
            let r = (p.x*p.x + p.y*p.y).squareRoot() + eps
            let a = atan2(p.x, p.y)
            return SIMD2(w * sin(a) / r, w * cos(a) * r)
        }
        // var11_diamond: p0+=weight*sina*cos(r); p1+=weight*cosa*sin(r)
        t["diamond"]     = { p, w, _, _ in
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            let a = atan2(p.x, p.y)
            return SIMD2(w * sin(a) * cos(r), w * cos(a) * sin(r))
        }
        // var12_ex: m0=sin(a+r)³*r; p0+=weight*(m0+m1)
        t["ex"]          = { p, w, _, _ in
            let a = atan2(p.x, p.y)
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            let n0 = sin(a + r)
            let n1 = cos(a - r)
            let m0 = n0*n0*n0 * r
            let m1 = n1*n1*n1 * r
            return SIMD2(w * (m0 + m1), w * (m0 - m1))
        }
        // julia (var13) is implemented in `julia(_:weight:rng:)` — consumes the RNG.
        // var14_bent: nx=tx(×2 if<0); ny=ty(/2 if<0); p0+=weight*nx
        t["bent"]        = { p, w, _, _ in
            let nx = p.x < 0 ? p.x * 2 : p.x
            let ny = p.y < 0 ? p.y / 2 : p.y
            return SIMD2(w * nx, w * ny)
        }
        // var16_fisheye: r=2/(sqrt+1); (r*ty, r*tx)  [axis swap per flam3]
        t["fisheye"]     = { p, w, _, _ in
            let r = 2.0 / ((p.x*p.x + p.y*p.y).squareRoot() + 1.0)
            return SIMD2(w * r * p.y, w * r * p.x)
        }
        // var18_exponential: e=exp(tx-1); (e*cos(pi*ty), e*sin(pi*ty))
        t["exponential"] = { p, w, _, _ in
            let e = exp(p.x - 1)
            return SIMD2(w * e * cos(.pi * p.y), w * e * sin(.pi * p.y))
        }
        // var20_cosine: (cos(pi*tx)*cosh(ty), -sin(pi*tx)*sinh(ty))
        t["cosine"]      = { p, w, _, _ in
            SIMD2(w * cos(p.x * .pi) * cosh(p.y),
                  w * (-sin(p.x * .pi)) * sinh(p.y))
        }
        // var29_cylinder: (sin(tx), ty)
        t["cylinder"]    = { p, w, _, _ in SIMD2(w * sin(p.x), w * p.y) }
        // var28_bubble (variations.c:671-678): r = weight / (0.25*sumsq + 1);
        //   (r*tx, r*ty). Paramless; 0 RNG draws.
        t["bubble"]      = { p, w, _, _ in
            let r = w / (0.25 * (p.x*p.x + p.y*p.y) + 1)
            return SIMD2(r * p.x, r * p.y)
        }
        // var27_eyefish (variations.c:659-669): r = (weight*2)/(precalc_sqrt + 1);
        //   (r*tx, r*ty). Paramless; 0 RNG draws. NOT an alias of fisheye
        //   (var16) — output is UN-swapped, vs fisheye's (r*ty, r*tx). Both
        //   share the magnitude r = 2w/(|p|+1); only the axis assignment differs.
        t["eyefish"]     = { p, w, _, _ in
            let r = (w * 2.0) / ((p.x*p.x + p.y*p.y).squareRoot() + 1.0)
            return SIMD2(r * p.x, r * p.y)
        }
        // var15_waves (variations.c:396-413) + waves_precalc (L1969-1975).
        //   waves_dx2 = 1/(e²+EPS); waves_dy2 = 1/(f²+EPS); (e=c[2][0], f=c[2][1])
        //   nx = tx + c * sin(ty * waves_dx2);                (c = c[1][0])
        //   ny = ty + d * sin(tx * waves_dy2);                (d = c[1][1])
        //   (w*nx, w*ny). Paramless; 0 RNG draws. Needs affine c,d,e,f.
        t["waves"]       = { p, w, _, affine in
            let c = affine.x, d = affine.y, e = affine.z, f = affine.w
            let wavesDx2 = 1.0 / (e*e + eps)                 // 1/(e²+EPS)
            let wavesDy2 = 1.0 / (f*f + eps)                 // 1/(f²+EPS)
            let nx = p.x + c * sin(p.y * wavesDx2)
            let ny = p.y + d * sin(p.x * wavesDy2)
            return SIMD2(w * nx, w * ny)
        }
        // var17_popcorn (variations.c:433-450) — affine e,f (c[2][0], c[2][1]).
        //   dx = tan(3*ty); dy = tan(3*tx);
        //   nx = tx + e * sin(dx); ny = ty + f * sin(dy);
        //   (w*nx, w*ny). Paramless; 0 RNG draws.
        t["popcorn"]     = { p, w, _, affine in
            let e = affine.z, f = affine.w
            let dx = tan(3.0 * p.y)
            let dy = tan(3.0 * p.x)
            let nx = p.x + e * sin(dx)
            let ny = p.y + f * sin(dy)
            return SIMD2(w * nx, w * ny)
        }
        // var19_power (variations.c:472-487) — precalc sina/cosa/sqrt.
        //   sina = tx/sqrt; cosa = ty/sqrt; sqrt = sqrt(tx²+ty²)
        //   r = w * pow(sqrt, sina); (r*cosa, r*sina).
        //   Paramless; 0 RNG draws.
        t["power"]       = { p, w, _, _ in
            let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
            let sina = p.x / precalcSqrt                     // precalc_sina = tx/sqrt
            let cosa = p.y / precalcSqrt                     // precalc_cosa = ty/sqrt
            let r = w * pow(precalcSqrt, sina)
            return SIMD2(r * cosa, r * sina)
        }
        // var42_tangent (variations.c:885-898).
        //   p0 += w * sin(tx)/cos(ty); p1 += w * tan(ty).
        //   Paramless; 0 RNG draws.
        t["tangent"]     = { p, w, _, _ in
            SIMD2(w * sin(p.x) / cos(p.y), w * tan(p.y))
        }
        // var48_cross (variations.c:1033-1052).
        //   s = tx² - ty²; r = w * sqrt(1/(s²+EPS));
        //   (tx*r, ty*r). Paramless; 0 RNG draws.
        t["cross"]       = { p, w, _, _ in
            let s = p.x*p.x - p.y*p.y
            let r = w * (1.0 / (s*s + eps)).squareRoot()
            return SIMD2(p.x * r, p.y * r)
        }
        // ---- Trig family (Z+ variations): var82_exp .. var95_coth ----
        // All paramless; 0 RNG draws. Formulas ported verbatim from
        // /private/tmp/flam3-build/variations.c L1747-1897.
        // var82_exp: expe = exp(tx); sincos(ty, &expsin, &expcos)
        //   (w * expe * expcos, w * expe * expsin)
        t["exp"]         = { p, w, _, _ in
            let expe = exp(p.x)
            let (expsin, expcos) = (sin(p.y), cos(p.y))
            return SIMD2(w * expe * expcos, w * expe * expsin)
        }
        // var83_log: (w * 0.5 * log(sumsq), w * atan2(y, x))
        //   uses precalc_atanyx = atan2(ty, tx) = atan2(y, x)
        t["log"]         = { p, w, _, _ in
            let sumsq = p.x*p.x + p.y*p.y
            return SIMD2(w * 0.5 * log(sumsq), w * atan2(p.y, p.x))
        }
        // var84_sin: sincos(tx, &sinsin, &sinacos); sinhsinh = sinh(ty); sincosh = cosh(ty)
        //   (w * sinsin * sincosh, w * sinacos * sinsinh)
        t["sin"]         = { p, w, _, _ in
            let sinsin = sin(p.x)
            let sinacos = cos(p.x)
            let sinsinh = sinh(p.y)
            let sincosh = cosh(p.y)
            return SIMD2(w * sinsin * sincosh, w * sinacos * sinsinh)
        }
        // var85_cos: sincos(tx, &cossin, &coscos); cossinh = sinh(ty); coscosh = cosh(ty)
        //   (w * coscos * coscosh, -w * cossin * cossinh)
        t["cos"]         = { p, w, _, _ in
            let cossin = sin(p.x)
            let coscos = cos(p.x)
            let cossinh = sinh(p.y)
            let coscosh = cosh(p.y)
            return SIMD2(w * coscos * coscosh, -w * cossin * cossinh)
        }
        // var86_tan: sincos(2*tx, &tansin, &tancos); tansinh = sinh(2*ty); tancosh = cosh(2*ty)
        //   tanden = 1/(tancos + tancosh); (w * tanden * tansin, w * tanden * tansinh)
        t["tan"]         = { p, w, _, _ in
            let tansin = sin(2.0 * p.x)
            let tancos = cos(2.0 * p.x)
            let tansinh = sinh(2.0 * p.y)
            let tancosh = cosh(2.0 * p.y)
            let tanden = 1.0 / (tancos + tancosh)
            return SIMD2(w * tanden * tansin, w * tanden * tansinh)
        }
        // var87_sec: sincos(tx, &secsin, &seccos); secsinh = sinh(ty); seccosh = cosh(ty)
        //   secden = 2/(cos(2*tx) + cosh(2*ty))
        //   (w * secden * seccos * seccosh, w * secden * secsin * secsinh)
        t["sec"]         = { p, w, _, _ in
            let secsin = sin(p.x)
            let seccos = cos(p.x)
            let secsinh = sinh(p.y)
            let seccosh = cosh(p.y)
            let secden = 2.0 / (cos(2.0 * p.x) + cosh(2.0 * p.y))
            return SIMD2(w * secden * seccos * seccosh, w * secden * secsin * secsinh)
        }
        // var88_csc: sincos(tx, &cscsin, &csccos); cscsinh = sinh(ty); csccosh = cosh(ty)
        //   cscden = 2/(cosh(2*ty) - cos(2*tx))
        //   (w * cscden * cscsin * csccosh, -w * cscden * csccos * cscsinh)
        t["csc"]         = { p, w, _, _ in
            let cscsin = sin(p.x)
            let csccos = cos(p.x)
            let cscsinh = sinh(p.y)
            let csccosh = cosh(p.y)
            let cscden = 2.0 / (cosh(2.0 * p.y) - cos(2.0 * p.x))
            return SIMD2(w * cscden * cscsin * csccosh, -w * cscden * csccos * cscsinh)
        }
        // var89_cot: sincos(2*tx, &cotsin, &cotcos); cotsinh = sinh(2*ty); cotcosh = cosh(2*ty)
        //   cotden = 1/(cotcosh - cotcos)
        //   (w * cotden * cotsin, w * cotden * -1 * cotsinh)
        t["cot"]         = { p, w, _, _ in
            let cotsin = sin(2.0 * p.x)
            let cotcos = cos(2.0 * p.x)
            let cotsinh = sinh(2.0 * p.y)
            let cotcosh = cosh(2.0 * p.y)
            let cotden = 1.0 / (cotcosh - cotcos)
            return SIMD2(w * cotden * cotsin, w * cotden * -1.0 * cotsinh)
        }
        // var90_sinh: sincos(ty, &sinhsin, &sinhcos); sinhsinh = sinh(tx); sinhcosh = cosh(tx)
        //   (w * sinhsinh * sinhcos, w * sinhcosh * sinhsin)
        t["sinh"]        = { p, w, _, _ in
            let sinhsin = sin(p.y)
            let sinhcos = cos(p.y)
            let sinhsinh = sinh(p.x)
            let sinhcosh = cosh(p.x)
            return SIMD2(w * sinhsinh * sinhcos, w * sinhcosh * sinhsin)
        }
        // var91_cosh: sincos(ty, &coshsin, &coshcos); coshsinh = sinh(tx); coshcosh = cosh(tx)
        //   (w * coshcosh * coshcos, w * coshsinh * coshsin)
        t["cosh"]        = { p, w, _, _ in
            let coshsin = sin(p.y)
            let coshcos = cos(p.y)
            let coshsinh = sinh(p.x)
            let coshcosh = cosh(p.x)
            return SIMD2(w * coshcosh * coshcos, w * coshsinh * coshsin)
        }
        // var92_tanh: sincos(2*ty, &tanhsin, &tanhcos); tanhsinh = sinh(2*tx); tanhcosh = cosh(2*tx)
        //   tanhden = 1/(tanhcos + tanhcosh)
        //   (w * tanhden * tanhsinh, w * tanhden * tanhsin)
        t["tanh"]        = { p, w, _, _ in
            let tanhsin = sin(2.0 * p.y)
            let tanhcos = cos(2.0 * p.y)
            let tanhsinh = sinh(2.0 * p.x)
            let tanhcosh = cosh(2.0 * p.x)
            let tanhden = 1.0 / (tanhcos + tanhcosh)
            return SIMD2(w * tanhden * tanhsinh, w * tanhden * tanhsin)
        }
        // var93_sech: sincos(ty, &sechsin, &sechcos); sechsinh = sinh(tx); sechcosh = cosh(tx)
        //   sechden = 2/(cos(2*ty) + cosh(2*tx))
        //   (w * sechden * sechcos * sechcosh, -w * sechden * sechsin * sechsinh)
        t["sech"]        = { p, w, _, _ in
            let sechsin = sin(p.y)
            let sechcos = cos(p.y)
            let sechsinh = sinh(p.x)
            let sechcosh = cosh(p.x)
            let sechden = 2.0 / (cos(2.0 * p.y) + cosh(2.0 * p.x))
            return SIMD2(w * sechden * sechcos * sechcosh, -w * sechden * sechsin * sechsinh)
        }
        // var94_csch: sincos(ty, &cschsin, &cschcos); cschsinh = sinh(tx); cschcosh = cosh(tx)
        //   cschden = 2/(cosh(2*tx) - cos(2*ty))
        //   (w * cschden * cschsinh * cschcos, -w * cschden * cschcosh * cschsin)
        t["csch"]        = { p, w, _, _ in
            let cschsin = sin(p.y)
            let cschcos = cos(p.y)
            let cschsinh = sinh(p.x)
            let cschcosh = cosh(p.x)
            let cschden = 2.0 / (cosh(2.0 * p.x) - cos(2.0 * p.y))
            return SIMD2(w * cschden * cschsinh * cschcos, -w * cschden * cschcosh * cschsin)
        }
        // var95_coth: sincos(2*ty, &cothsin, &cothcos); cothsinh = sinh(2*tx); cothcosh = cosh(2*tx)
        //   cothden = 1/(cothcosh - cothcos)
        //   (w * cothden * cothsinh, w * cothden * cothsin)
        t["coth"]        = { p, w, _, _ in
            let cothsin = sin(2.0 * p.y)
            let cothcos = cos(2.0 * p.y)
            let cothsinh = sinh(2.0 * p.x)
            let cothcosh = cosh(2.0 * p.x)
            let cothden = 1.0 / (cothcosh - cothcos)
            return SIMD2(w * cothden * cothsinh, w * cothden * cothsin)
        }
        // ---- End trig family (14 variations, slots 57..70) ----
        // ---- Batch 2: paramless non-trig (var57/61/62/64/66/70/72; slots 71..77) ----
        // All paramless; 0 RNG draws. Formulas ported verbatim from
        // /Users/frederic/flam3-oracle-src/flam3/variations.c L1238-1590.
        // EPS = 1e-10 (private.h:47). precalc_sumsq = tx²+ty²;
        // precalc_sqrt = sqrt(sumsq); precalc_atan = atan2(tx,ty) (SWAPPED).
        // var57_butterfly: wx=w*1.3029400317411197908970256609023; y2=ty*2;
        //   r=wx*sqrt(|ty*tx|/(EPS+tx²+y2²)); (r*tx, r*y2)
        t["butterfly"]    = { p, w, _, _ in
            let wx = w * 1.3029400317411197908970256609023
            let y2 = p.y * 2.0
            let r = wx * (abs(p.y * p.x) / (1e-10 + p.x*p.x + y2*y2)).squareRoot()
            return SIMD2(r * p.x, r * y2)
        }
        // var61_edisc: tmp=sumsq+1; tmp2=2tx; r1=sqrt(tmp+tmp2); r2=sqrt(tmp-tmp2);
        //   xmax=(r1+r2)/2; a1=log(xmax+sqrt(xmax-1)); a2=-acos(tx/xmax);
        //   w=w/11.57034632; sincos(a1,&snv,&csv); snhu=sinh(a2); cshu=cosh(a2);
        //   if ty>0 snv=-snv; (w*cshu*csv, w*snhu*snv)
        t["edisc"]        = { p, w, _, _ in
            let sumsq = p.x*p.x + p.y*p.y
            let tmp = sumsq + 1.0
            let tmp2 = 2.0 * p.x
            let r1 = (tmp + tmp2).squareRoot()
            let r2 = (tmp - tmp2).squareRoot()
            let xmax = (r1 + r2) * 0.5
            let a1 = log(xmax + (xmax - 1.0).squareRoot())
            let a2 = -acos(p.x / xmax)
            let ww = w / 11.57034632
            var snv = sin(a1)
            let csv = cos(a1)
            let snhu = sinh(a2)
            let cshu = cosh(a2)
            if p.y > 0.0 { snv = -snv }
            return SIMD2(ww * cshu * csv, ww * snhu * snv)
        }
        // var62_elliptic: tmp=sumsq+1; x2=2tx; xmax=0.5*(sqrt(tmp+x2)+sqrt(tmp-x2));
        //   a=tx/xmax; b=1-a²; ssx=xmax-1; w=w/M_PI_2;
        //   if b<0 b=0 else b=sqrt(b); if ssx<0 ssx=0 else ssx=sqrt(ssx);
        //   (w*atan2(a,b), ±w*log(xmax+ssx))  [sign from ty]
        t["elliptic"]     = { p, w, _, _ in
            let sumsq = p.x*p.x + p.y*p.y
            let tmp = sumsq + 1.0
            let x2 = 2.0 * p.x
            let xmax = 0.5 * ((tmp + x2).squareRoot() + (tmp - x2).squareRoot())
            let a = p.x / xmax
            var b = 1.0 - a*a
            var ssx = xmax - 1.0
            let ww = w / (Double.pi / 2.0)
            if b < 0 { b = 0 } else { b = b.squareRoot() }
            if ssx < 0 { ssx = 0 } else { ssx = ssx.squareRoot() }
            let p1mag = ww * log(xmax + ssx)
            let p1 = p.y > 0 ? p1mag : -p1mag
            return SIMD2(ww * atan2(a, b), p1)
        }
        // var64_foci: expx=exp(tx)*0.5; expnx=0.25/expx; sincos(ty,&sn,&cn);
        //   tmp=w/(expx+expnx-cn); (tmp*(expx-expnx), tmp*sn)
        t["foci"]         = { p, w, _, _ in
            let expx = exp(p.x) * 0.5
            let expnx = 0.25 / expx
            let sn = sin(p.y)
            let cn = cos(p.y)
            let tmp = w / (expx + expnx - cn)
            return SIMD2(tmp * (expx - expnx), tmp * sn)
        }
        // var66_loonie: r2=sumsq; w2=w²; if r2<w2: r=w*sqrt(w2/r2-1) else r=w.
        //   (r*tx, r*ty). NO EPS (origin → div-by-zero → badvalue downstream).
        t["loonie"]       = { p, w, _, _ in
            let r2 = p.x*p.x + p.y*p.y
            let w2 = w * w
            if r2 < w2 {
                let r = w * (w2 / r2 - 1.0).squareRoot()
                return SIMD2(r * p.x, r * p.y)
            } else {
                return SIMD2(w * p.x, w * p.y)
            }
        }
        // var70_polar2: p2v=w/M_PI; (p2v*precalc_atan, p2v/2*log(sumsq)).
        //   precalc_atan = atan2(tx,ty) = atan2(p.x,p.y) (SWAPPED — see var5_polar).
        t["polar2"]       = { p, w, _, _ in
            let p2v = w / Double.pi
            let sumsq = p.x*p.x + p.y*p.y
            return SIMD2(p2v * atan2(p.x, p.y), p2v / 2.0 * log(sumsq))
        }
        // var72_scry: t=sumsq; r=1/(precalc_sqrt*(t+1/(w+EPS))); (tx*r, ty*r).
        //   NOTE: weight folded ONLY inside 1/(w+EPS) — the (tx*r,ty*r) outer
        //   multiply has NO explicit weight (flam3 comment confirms intentional).
        t["scry"]         = { p, w, _, _ in
            let sumsq = p.x*p.x + p.y*p.y
            let precalcSqrt = sumsq.squareRoot()
            let r = 1.0 / (precalcSqrt * (sumsq + 1.0 / (w + 1e-10)))
            return SIMD2(p.x * r, p.y * r)
        }
        // ---- End batch 2 (7 variations, slots 71..77) ----
        // var24_pdj (variations.c:579-596). 4 params, all default 0. Parametric;
        // 0 RNG draws. Bounded trig of params·tx/ty (no poles).
        //   nx1 = cos(pdj_b * tx); nx2 = sin(pdj_c * tx);
        //   ny1 = sin(pdj_a * ty); ny2 = cos(pdj_d * ty);
        //   p0 += w*(ny1 - nx1); p1 += w*(nx2 - ny2).
        t["pdj"]         = { p, w, par, _ in
            let a = resolve("pdj", "pdj_a", par)
            let b = resolve("pdj", "pdj_b", par)
            let c = resolve("pdj", "pdj_c", par)
            let d = resolve("pdj", "pdj_d", par)
            let nx1 = cos(b * p.x)
            let nx2 = sin(c * p.x)
            let ny1 = sin(a * p.y)
            let ny2 = cos(d * p.y)
            return SIMD2(w * (ny1 - nx1), w * (nx2 - ny2))
        }
        // var74_split (variations.c:1603-1617). 2 params, default 0. Parametric;
        // 0 RNG draws. NOTE: the p1 branch comes FIRST in the C source (mirror
        // the structure). CROSS-COUPLING: tx controls p1, ty controls p0.
        //   if (cos(tx*split_xsize*π) >= 0) p1 += w*ty  else  p1 -= w*ty;
        //   if (cos(ty*split_ysize*π) >= 0) p0 += w*tx  else  p0 -= w*tx;
        // p0/p1 accumulate independently so order is observationally equivalent.
        t["split"]       = { p, w, par, _ in
            let xsize = resolve("split", "split_xsize", par)
            let ysize = resolve("split", "split_ysize", par)
            var p0 = 0.0, p1 = 0.0
            if cos(p.x * xsize * .pi) >= 0 { p1 += w * p.y }
            else                           { p1 -= w * p.y }
            if cos(p.y * ysize * .pi) >= 0 { p0 += w * p.x }
            else                           { p0 -= w * p.x }
            return SIMD2(p0, p1)
        }
        // var46_secant2 (variations.c:920-944). Paramless; 0 RNG draws.
        // Intended as a 'fixed' version of secant. UN-GUARDED 1/cos (cr=0 → Inf;
        // match flam3 — NO per-term guard; the chaos game's post-affine badvalue
        // check handles Inf downstream, redrawing).
        //   r   = w * precalc_sqrt (= w*sqrt(tx²+ty²)); cr = cos(r); icr = 1/cr;
        //   p0 += w * tx;
        //   if (cr < 0) p1 += w * (icr + 1);   // positive branch offset
        //   else        p1 += w * (icr - 1);   // negative branch offset
        t["secant2"]     = { p, w, _, _ in
            let r = w * (p.x*p.x + p.y*p.y).squareRoot()       // w * precalc_sqrt
            let cr = cos(r)
            let icr = 1.0 / cr                                 // UN-GUARDED (cr=0 → Inf)
            let p1 = cr < 0 ? w * (icr + 1.0) : w * (icr - 1.0)
            return SIMD2(w * p.x, p1)
        }
        // var49_disc2 (variations.c:1019-1052) + disc2_precalc (variations.c:1977-1997).
        // Parametric (`disc2_rot`, `disc2_twist`, both default 0); 0 RNG draws.
        // disc2_precalc is inlined here (like radial_blur's spinvar/zoomvar) —
        // `disc2_timespi`/`disc2_sinadd`/`disc2_cosadd` are derived, NOT XML params.
        // PRECALC:
        //   timespi = rot * π
        //   add     = twist
        //   sincos(add, &sinadd, &cosadd);  cosadd -= 1
        //   if (add >  2π)  k = 1 + add - 2π;  cosadd *= k; sinadd *= k
        //   if (add < -2π)  k = 1 + add + 2π;  cosadd *= k; sinadd *= k
        // BODY:
        //   t   = timespi * (tx + ty);  sincos(t, &sinr, &cosr)
        //   r   = w * precalc_atan / π     (precalc_atan = atan2(tx, ty) — flam3 order)
        //   p0 += (sinr + cosadd) * r
        //   p1 += (cosr + sinadd) * r
        t["disc2"]       = { p, w, par, _ in
            let rot   = resolve("disc2", "disc2_rot", par)
            let twist = resolve("disc2", "disc2_twist", par)
            let timespi = rot * .pi
            let add = twist
            var sinadd = sin(add)
            var cosadd = cos(add) - 1.0
            if add >  2 * .pi { let k = 1 + add - 2 * .pi; cosadd *= k; sinadd *= k }
            if add < -2 * .pi { let k = 1 + add + 2 * .pi; cosadd *= k; sinadd *= k }
            let t = timespi * (p.x + p.y)
            let sinr = sin(t), cosr = cos(t)
            let r = w * atan2(p.x, p.y) / .pi                // atan2(tx,ty) — flam3 order
            return SIMD2((sinr + cosadd) * r, (cosr + sinadd) * r)
        }

        // ---- 14 special-sauce (M3): line-for-line ports of variations.c ----

        // var21_rings (variations.c:509-527) — affine.z = c[2][0] = e.
        //   dx = e*e + EPS; r = precalc_sqrt;
        //   r = w*(fmod(r+dx,2*dx) - dx + r*(1-dx));
        //   (r*cosa, r*sina) where cosa=cos(atan2(x,y)), sina=sin(atan2(x,y)).
        t["rings"] = { p, w, _, affine in
            let e = affine.z
            let dx = e*e + eps
            var r = (p.x*p.x + p.y*p.y).squareRoot()          // precalc_sqrt
            let a = atan2(p.x, p.y)                            // precalc_atan = atan2(x,y)
            r = w * (fmod(r + dx, 2*dx) - dx + r * (1 - dx))
            return SIMD2(r * cos(a), r * sin(a))               // r*cosa, r*sina
        }
        // var22_fan (variations.c:529-556) — affine.z=e=c[2][0], affine.w=f=c[2][1].
        //   dx = π*(e*e+EPS); dy = f; dx2 = dx/2; a = precalc_atan;
        //   a += (fmod(a+dy,dx) > dx2) ? -dx2 : dx2;
        //   r = w*precalc_sqrt; (r*cos a, r*sin a).
        t["fan"] = { p, w, _, affine in
            let e = affine.z, f = affine.w
            let dx = .pi * (e*e + eps)
            let dy = f
            let dx2 = 0.5 * dx
            var a = atan2(p.x, p.y)                            // precalc_atan
            let r = w * (p.x*p.x + p.y*p.y).squareRoot()
            a += (fmod(a + dy, dx) > dx2) ? -dx2 : dx2
            return SIMD2(r * cos(a), r * sin(a))
        }
        // var23_blob (variations.c:558-578).
        //   r = precalc_sqrt; a = precalc_atan;
        //   r *= low + (high-low)*(0.5 + 0.5*sin(waves*a));
        //   p0 += w*sina*r; p1 += w*cosa*r   (sin on x, cos on y).
        t["blob"] = { p, w, par, _ in
            let low   = resolve("blob", "blob_low", par)
            let high  = resolve("blob", "blob_high", par)
            let waves = resolve("blob", "blob_waves", par)
            var r = (p.x*p.x + p.y*p.y).squareRoot()
            let a = atan2(p.x, p.y)
            r *= low + (high - low) * (0.5 + 0.5 * sin(waves * a))
            return SIMD2(w * sin(a) * r, w * cos(a) * r)      // sina on p0, cosa on p1
        }
        // var25_fan2 (variations.c:599-639).
        //   dy = fan2_y; dx = π*(fan2_x²+EPS); dx2 = dx/2; a = precalc_atan;
        //   t = a+dy - dx*(int)((a+dy)/dx);
        //   if (t>dx2) a-=dx2 else a+=dx2; r = w*sqrt;
        //   p0 += r*sa; p1 += r*ca   (sin on x, cos on y).
        t["fan2"] = { p, w, par, _ in
            let fan2x = resolve("fan2", "fan2_x", par)
            let fan2y = resolve("fan2", "fan2_y", par)
            let dy = fan2y
            let dx = .pi * (fan2x*fan2x + eps)
            let dx2 = 0.5 * dx
            var a = atan2(p.x, p.y)                            // precalc_atan
            let r = w * (p.x*p.x + p.y*p.y).squareRoot()
            let tt = a + dy - dx * Double(Int((a + dy) / dx))  // (int) truncates toward zero
            if tt > dx2 { a = a - dx2 } else { a = a + dx2 }
            return SIMD2(r * sin(a), r * cos(a))               // sa on p0, ca on p1
        }
        // var26_rings2 (variations.c:641-658).
        //   r = precalc_sqrt; dx = rings2_val²+EPS;
        //   r += -2*dx*(int)((r+dx)/(2*dx)) + r*(1-dx);
        //   p0 += w*sina*r; p1 += w*cosa*r   (sin on x, cos on y).
        t["rings2"] = { p, w, par, _ in
            let val = resolve("rings2", "rings2_val", par)
            var r = (p.x*p.x + p.y*p.y).squareRoot()
            let dx = val*val + eps
            r += -2.0*dx*Double(Int((r + dx)/(2.0*dx))) + r*(1.0 - dx)
            let a = atan2(p.x, p.y)
            return SIMD2(w * sin(a) * r, w * cos(a) * r)
        }
        // var30_perspective (variations.c:688-695) + perspective_precalc (L1943-1947).
        //   ang = angle*π/2; vsin=sin(ang); vfcos=dist*cos(ang);
        //   t = 1/(dist - ty*vsin); p0 += w*dist*tx*t; p1 += w*vfcos*ty*t.
        t["perspective"] = { p, w, par, _ in
            let angle = resolve("perspective", "perspective_angle", par)
            let dist  = resolve("perspective", "perspective_dist", par)
            let ang = angle * .pi / 2.0
            let vsin = sin(ang)                               // persp_vsin
            let vfcos = dist * cos(ang)                       // persp_vfcos
            let t = 1.0 / (dist - p.y * vsin)
            return SIMD2(w * dist * p.x * t, w * vfcos * p.y * t)
        }
        // var38_ngon (variations.c:812-831).
        //   r_factor = pow(sumsq, power/2); theta = precalc_atanyx;
        //   b = 2π/sides; phi = theta - b*floor(theta/b); if (phi>b/2) phi-=b;
        //   amp = corners*(1/(cos(phi)+EPS) - 1) + circle; amp /= (r_factor+EPS);
        //   p0 += w*tx*amp; p1 += w*ty*amp.
        t["ngon"] = { p, w, par, _ in
            let sides   = resolve("ngon", "ngon_sides", par)
            let power   = resolve("ngon", "ngon_power", par)
            let circle  = resolve("ngon", "ngon_circle", par)
            let corners = resolve("ngon", "ngon_corners", par)
            let sumsq = p.x*p.x + p.y*p.y
            let rFactor = pow(sumsq, power / 2.0)
            let theta = atan2(p.y, p.x)                       // precalc_atanyx
            let b = 2 * .pi / sides
            var phi = theta - (b * floor(theta / b))
            if phi > b/2 { phi -= b }
            var amp = corners * (1.0/(cos(phi) + eps) - 1.0) + circle
            amp /= (rFactor + eps)
            return SIMD2(w * p.x * amp, w * p.y * amp)
        }
        // var39_curl (variations.c:833-842).
        //   re = 1 + c1*x + c2*(x²-y²); im = c1*y + 2*c2*x*y;
        //   r = w/(re²+im²); p0 += (x*re+y*im)*r; p1 += (y*re-x*im)*r.
        t["curl"] = { p, w, par, _ in
            let c1 = resolve("curl", "curl_c1", par)
            let c2 = resolve("curl", "curl_c2", par)
            let re = 1.0 + c1*p.x + c2*(p.x*p.x - p.y*p.y)
            let im = c1*p.y + 2.0*c2*p.x*p.y
            let r = w / (re*re + im*im)
            return SIMD2((p.x*re + p.y*im)*r, (p.y*re - p.x*im)*r)
        }
        // var40_rectangles (variations.c:844-856).
        //   if (rx==0) p0+=w*tx else p0+=w*((2*floor(tx/rx)+1)*rx - tx);  (same for y).
        t["rectangles"] = { p, w, par, _ in
            let rx = resolve("rectangles", "rectangles_x", par)
            let ry = resolve("rectangles", "rectangles_y", par)
            let nx = rx == 0 ? p.x : ((2*floor(p.x/rx) + 1)*rx - p.x)
            let ny = ry == 0 ? p.y : ((2*floor(p.y/ry) + 1)*ry - p.y)
            return SIMD2(w * nx, w * ny)
        }
        // var79_wedge_sph (variations.c:1690-1709).
        //   r = 1/(sqrt+EPS); a = precalc_atanyx + swirl*r;
        //   c = floor((count*a+π)*(1/π)*0.5); comp_fac = 1-angle*count*(1/π)*0.5;
        //   a = a*comp_fac + c*angle; r = w*(r+hole); (r*cos a, r*sin a).
        t["wedge_sph"] = { p, w, par, _ in
            let angle = resolve("wedge_sph", "wedge_sph_angle", par)
            let count = resolve("wedge_sph", "wedge_sph_count", par)
            let hole  = resolve("wedge_sph", "wedge_sph_hole", par)
            let swirl = resolve("wedge_sph", "wedge_sph_swirl", par)
            let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
            var r = 1.0 / (precalcSqrt + eps)
            var a = atan2(p.y, p.x) + swirl * r                // precalc_atanyx + swirl*r
            let c = floor((count*a + .pi) * (1.0 / .pi) * 0.5)
            let compFac = 1 - angle*count*(1.0 / .pi)*0.5
            a = a*compFac + c*angle
            r = w * (r + hole)
            return SIMD2(r * cos(a), r * sin(a))
        }
        return t
    }()
}

public extension Variations {
    /// Fixed canonical slot order for the Metal kernel's variation table and the
    /// CPU `evaluate` name→slot map. Re-exports `VariationDescriptor.canonicalOrder`
    /// (the 78-name authority: M1's 19 + the 14 special-sauce + bubble + eyefish
    /// + pie + radial_blur + waves/popcorn/power/tangent/cross + pdj/split +
    /// noise/blur/gaussian_blur/arch/square + rays/blade/twintrian +
    /// flower/conic/parabola + secant2/disc2).
    ///
    /// RNG-EQUIVALENCE NOTE: eighteen variations consume the ISAAC stream
    /// (julia/julian/juliascope/super_shape/wedge_julia/pie/radial_blur/noise/
    /// blur/gaussian_blur/arch/square/rays/blade/twintrian/flower/conic/
    /// parabola). CPU `evaluate` walks an xform's variations in ARRAY order,
    /// which the parser sorts ALPHABETICALLY (Flam3Parser.swift:223); Metal
    /// `apply_xform_body` walks them in CANONICAL-SLOT order (the if-chain at
    /// Kernels.metal). For the RNG-alignment coincidence to hold, the canonical
    /// slots of the RNG-consuming set must be in the SAME relative order as
    /// their alphabetical order. Pinned by
    /// `SpecialSauceParityTests.testRngConsumingSlotOrderIsAscending`
    /// (slots ascending) — but that test does NOT pin the alphabetical↔slot
    /// coincidence. The current set {julia(12), julian(25), juliascope(26),
    /// super_shape(30), wedge_julia(31), pie(35), radial_blur(36), blur(45),
    /// gaussian_blur(46), noise(44), arch(47), square(48), rays(49), blade(50),
    /// twintrian(51), flower(52), conic(53), parabola(54)} is alphabetical ==
    /// slot order EXCEPT for pie, radial_blur, and the rays/blade/twintrian
    /// trio: pie sits alphabetically between juliascope and super_shape but at
    /// slot 35 (after wedge_julia); radial_blur sits alphabetically between pie
    /// and super_shape but at slot 36 (also after wedge_julia); blade (slot 50)
    /// sits alphabetically BEFORE blur (slot 45); rays (slot 49) sits
    /// alphabetically BETWEEN radial_blur (slot 36) and square (slot 48);
    /// twintrian (slot 51) sits alphabetically BETWEEN square (48) and
    /// wedge_julia (31). The new flower(52)/conic(53)/parabola(54) trio sits
    /// AFTER parabola alphabetically — flower alphabetically BETWEEN fisheye and
    /// gaussian_blur, conic BETWEEN cosine and curl, parabola BETWEEN ngon and
    /// pdj — so an xform combining any of the 3 with an EARLIER-SLOT RNG
    /// variation (e.g. parabola + linear → parabola draws AFTER linear
    /// alphabetically AND at slot 54 vs 13 → consistent; but parabola + noise
    /// would draw parabola AFTER noise alphabetically yet at slot 54 vs 44 →
    /// still consistent; the divergence cases are {conic + curl}, {flower +
    /// fisheye/gaussian_blur}, {parabola + ngon/pdj} where the alphabetical
    /// order puts the new one AFTER its companion but the slot order is also
    /// after — but the alphabetical-vs-slot coincidence still holds for any
    /// pair where alphabetical order matches slot order). The two orderings
    /// diverge for an xform containing pie AND {super_shape,wedge_julia,julia,
    /// julian,juliascope}, OR radial_blur AND the same set, OR any of
    /// {rays,blade,twintrian} AND any earlier-slot RNG variation — no
    /// frozen/fuzz/real-fixture genome has any of these combinations (the new 6
    /// are not yet used by any fixture genome). The divergence is the
    /// load-bearing assumption to re-check if a future genome violates it.
    ///
    /// ASSUMPTIONS (verified against the 6 frozen genomes + the M2 fuzz genome;
    /// revisit if a future genome violates them):
    /// (1) Each xform has AT MOST ONE variation of each name. The Metal host
    ///     folds repeated names into one canonical slot by summing weights
    ///     (`base[slot] += weight`), which is algebraically identical for
    ///     non-RNG variations but changes RNG consumption for `julia`: two
    ///     julia entries on the CPU consume TWO ISAAC words and produce two
    ///     terms, whereas Metal would consume ONE word and produce one summed
    ///     term. No frozen/fuzz genome has repeated names, so this is safe.
    /// (2) Each xform has ≤2 active variations. With ≤2 nonzero terms the
    ///     float sum is bit-identical regardless of summation order (float
    ///     addition is commutative; zero terms contribute exactly). Genomes
    ///     with ≥3 active variations would diverge from CPU by FP-associativity
    ///     ULPs — still inside the statistical-parity envelope, not a bug.
    ///
    /// Slots 19..32 are the special-sauce set; slot 33 is `bubble` (var28,
    /// paramless), slot 34 is `eyefish` (var27, paramless, NOT a fisheye alias),
    /// slot 35 is `pie` (var37, RNG-consuming, 3 ordered isaac_01 draws),
    /// slot 36 is `radial_blur` (var36, RNG-consuming, 4 isaac_01 draws summed
    /// left-to-right). Slots 37..41 are the corpus-variations paramless non-RNG
    /// set: `waves` (var15, needs affine c,d,e,f), `popcorn` (var17, e,f),
    /// `power` (var19, precalc sina/cosa), `tangent` (var42), `cross` (var48).
    /// Slots 42..43 are the corpus-variations parametric non-RNG set:
    /// `pdj` (var24, 4 params all default 0), `split` (var74, 2 params default 0;
    /// p1 branch first in C source, tx controls p1 / ty controls p0).
    /// Slots 44..48 are the corpus-variations RNG simple set: `noise` (var31,
    /// 2 draws, INPUT-SCALED — multiplies tx,ty), `blur` (var34, 2 draws, NOT
    /// input-scaled — the only difference from noise), `gaussian_blur` (var35,
    /// 5 draws: 1 angle + 4-sum into w*(Σ-2)), `arch` (var41, 1 draw, un-guarded
    /// sinr²/cosr — NO per-term guard, matches flam3), `square` (var43, 2 draws,
    /// bounded in [-w/2, w/2]²; RNG not paramless despite the name).
    /// Slots 49..51 are the corpus-variations RNG + Inf/badvalue care set:
    /// `rays` (var44, 1 draw, un-guarded tan(ang) — ang=w*d1*π has a pole at
    /// ang=π/2+kπ; no per-term guard, matches flam3), `blade` (var45, 1 draw;
    /// both p0 and p1 use tx, NOT ty for p1), `twintrian` (var47, 1 draw,
    /// badvalue-guarded log10(sinr²)+cosr → -30.0 when NaN/Inf/|x|>1e10 —
    /// the load-bearing care item, mirrored verbatim in BOTH CPU+Metal).
    /// Slots 52..54 are the corpus-variations parametric + RNG hybrid set:
    /// `flower` (var51, 1 draw, params flower_holes + flower_petals [NOT
    /// flower_freq]; r = w*(d1-holes)*cos(petals*θ)/sqrt — /sqrt NO EPS, origin
    /// → 0/0 → NaN; match flam3), `conic` (var52, 1 draw, params
    /// conic_eccentricity + conic_holes; TWO /sqrt NO EPS — ct = tx/sqrt, then
    /// r = w*(d1-holes)*ecc/(1+ecc*ct)/sqrt), `parabola` (var53, 2 per-axis
    /// draws, params parabola_height + parabola_width; draw #1 → p0 via
    /// height*sin²*r, draw #2 → p1 via width*cos*r — separate isaac01()
    /// statements in that order).
    /// Slots 55..56 are the corpus-variations final pair (CV7): `secant2`
    /// (var46, paramless, un-guarded 1/cos — cr=0 → Inf, match flam3; the chaos
    /// game's post-affine badvalue check handles Inf downstream), `disc2`
    /// (var49, parametric disc2_rot/disc2_twist default 0; disc2_precalc —
    /// timespi=rot·π, sincos(twist)→sinadd/cosadd with cosadd-=1 and |twist|>2π
    /// scaling branches — is inlined into the closure + MSL function, NOT
    /// exposed as XML params; precalc_atan = atan2(tx,ty) flam3 order). Both
    /// non-RNG → live in the table closures / w-guarded MSL dispatch chain.
    /// `apply_xform_body` reads them positionally and pulls
    /// their params from `varParams[slot*8 + idx]`. The MSL if-chain is now
    /// 57 lines (`Kernels.metal`); the trig family var82–95 (slots 57..70) grew
    /// it to 71 lines + 14 more `v_<name>` functions (Work A batch 1); the
    /// paramless non-trig family var57/61/62/64/66/70/72 (slots 71..77) grew
    /// it to 78 lines + 7 more `v_<name>` functions (Work A batch 2).
    static let canonicalOrder: [String] = VariationDescriptor.canonicalOrder
}
