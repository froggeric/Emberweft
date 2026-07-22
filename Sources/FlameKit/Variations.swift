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
        "radial_blur"
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
    /// `ef` carries the xform's affine translation coefficients `e`=`c[2][0]` and
    /// `f`=`c[2][1]`, needed by the coefficient-dependent variations `rings`/`fan`
    /// (variations.c:521,543). `rng` is threaded for the seven RNG-consuming
    /// variations (julia/julian/juliascope/super_shape/wedge_julia/pie/radial_blur):
    /// julia/julian/juliascope/super_shape/wedge_julia each draw one
    /// `flam3_random_isaac_01`/`_bit` word when reached; `pie` draws three
    /// `isaac_01` words in flam3's exact order (slice → angular → radial);
    /// `radial_blur` draws four `isaac_01` words summed left-to-right into
    /// `weight*(d1+d2+d3+d4-2.0)`.
    ///
    /// `variations` is walked in ARRAY order — the parser already sorts an xform's
    /// variations alphabetically, so for [julia, julian] julia draws before julian.
    public static func evaluate(_ variations: [Variation], at p: SIMD2<Double>,
                                ef: SIMD2<Double>, rng: inout ISAAC) -> SIMD2<Double> {
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
            case "super_shape":
                term = superShape(p, weight: v.weight, params: v.parameters, rng: &rng)
            case "wedge_julia":
                term = wedgeJulia(p, weight: v.weight, params: v.parameters, rng: &rng)
            default:
                if let fn = table[v.name] {
                    term = fn(p, v.weight, v.parameters, ef)
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
    // Each closure takes `(p, weight, params, ef)` and returns the term that
    // flam3 would add to `f.p0`/`f.p1`, with weight folded in at flam3's exact
    // position. Formulas are line-for-line ports of flam3 variations.c (varN_*),
    // using flam3's `precalc_atan = atan2(tx, ty)` = atan2(x, y),
    // `precalc_atanyx = atan2(ty, tx)` = atan2(y, x), and `EPS = 1e-10`
    // (private.h:47). C source lines cited per closure.
    //
    // NOTE on sina/cosa: flam3 computes `precalc_sina = tx/sqrt`,
    // `precalc_cosa = ty/sqrt` (variations.c:2164-2165). These equal
    // `sin(atan2(x,y))` and `cos(atan2(x,y))` respectively; the existing M1 table
    // (spiral/hyperbolic/diamond/…) uses the `cos(a)`/`sin(a)` form, so the new
    // ports follow that same convention for table-wide consistency. The ULP-level
    // difference is inside the M1 statistical-parity envelope.
    private nonisolated(unsafe) static let table: [String: (SIMD2<Double>, Double, [String: Double], SIMD2<Double>) -> SIMD2<Double>] = {
        var t: [String: (SIMD2<Double>, Double, [String: Double], SIMD2<Double>) -> SIMD2<Double>] = [:]
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

        // ---- 14 special-sauce (M3): line-for-line ports of variations.c ----

        // var21_rings (variations.c:509-527) — ef.x = c[2][0] = e.
        //   dx = e*e + EPS; r = precalc_sqrt;
        //   r = w*(fmod(r+dx,2*dx) - dx + r*(1-dx));
        //   (r*cosa, r*sina) where cosa=cos(atan2(x,y)), sina=sin(atan2(x,y)).
        t["rings"] = { p, w, _, ef in
            let dx = ef.x*ef.x + eps
            var r = (p.x*p.x + p.y*p.y).squareRoot()          // precalc_sqrt
            let a = atan2(p.x, p.y)                            // precalc_atan = atan2(x,y)
            r = w * (fmod(r + dx, 2*dx) - dx + r * (1 - dx))
            return SIMD2(r * cos(a), r * sin(a))               // r*cosa, r*sina
        }
        // var22_fan (variations.c:529-556) — ef.x=e=c[2][0], ef.y=f=c[2][1].
        //   dx = π*(e*e+EPS); dy = f; dx2 = dx/2; a = precalc_atan;
        //   a += (fmod(a+dy,dx) > dx2) ? -dx2 : dx2;
        //   r = w*precalc_sqrt; (r*cos a, r*sin a).
        t["fan"] = { p, w, _, ef in
            let dx = .pi * (ef.x*ef.x + eps)
            let dy = ef.y
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
    /// (the 37-name authority: M1's 19 + the 14 special-sauce + bubble + eyefish
    /// + pie + radial_blur).
    ///
    /// RNG-EQUIVALENCE NOTE: seven variations consume the ISAAC stream
    /// (julia/julian/juliascope/super_shape/wedge_julia/pie/radial_blur). CPU
    /// `evaluate` walks an xform's variations in ARRAY order, which the parser
    /// sorts ALPHABETICALLY (Flam3Parser.swift:223); Metal `apply_xform_body`
    /// walks them in CANONICAL-SLOT order (the if-chain at Kernels.metal). For
    /// the RNG-alignment coincidence to hold, the canonical slots of the RNG-
    /// consuming set must be in the SAME relative order as their alphabetical
    /// order. Pinned by `SpecialSauceParityTests.testRngConsumingSlotOrderIsAscending`
    /// (slots ascending) — but that test does NOT pin the alphabetical↔slot
    /// coincidence. The current set {julia(12), julian(25), juliascope(26),
    /// super_shape(30), wedge_julia(31), pie(35), radial_blur(36)} is alphabetical
    /// == slot order EXCEPT for pie and radial_blur: pie sits alphabetically
    /// between juliascope and super_shape but at slot 35 (after wedge_julia);
    /// radial_blur sits alphabetically between pie and super_shape but at slot
    /// 36 (also after wedge_julia). The two orderings therefore diverge for an
    /// xform containing pie AND {super_shape,wedge_julia,julia,julian,juliascope},
    /// OR radial_blur AND {super_shape,wedge_julia,julia,julian,juliascope} —
    /// no frozen/fuzz/real-fixture genome has either combination (verified: in
    /// the real genome 00000 the only pie xform is [linear, pie] and the only
    /// radial_blur xform is [linear, eyefish, bubble, radial_blur]). The
    /// divergence is the load-bearing assumption to re-check if a future genome
    /// violates it.
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
    /// left-to-right). `apply_xform_body` reads them positionally and pulls
    /// their params from `varParams[slot*8 + idx]`. The MSL if-chain is now
    /// 37 lines (`Kernels.metal`) and the 14 `v_<name>` functions landed in Task 6.
    public static let canonicalOrder: [String] = VariationDescriptor.canonicalOrder
}
