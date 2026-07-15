import Foundation

public enum Variations {
    // Swift 6 strict concurrency: mutable static state must be annotated. The
    // CPU reference is single-threaded by design (constraint #2), and access is
    // additionally guarded by `lock`, so `nonisolated(unsafe)` is sound here.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _warnings = Set<String>()

    /// Names rendered to output in M1. Each formula was verified term-by-term
    /// against flam3 `variations.c` (scottdraves/flam3@master), so the CPU
    /// reference matches the oracle. `julia` is handled in `evaluate` directly
    /// because it draws a random bit from the RNG (see flam3 `var13_julia`).
    ///
    /// Variations that depend on the xform's affine coefficients
    /// (`waves`, `popcorn`, `rings`, `fan`, …) or draw multiple random samples
    /// (`square`/noise/blur family) are **deferred to M2**, which introduces an
    /// affine-and-RNG variation context shared with the Metal kernels. They are
    /// deliberately omitted here so every name in `knownNames` is fully and
    /// correctly implemented rather than stubbed with wrong constants.
    public static let knownNames: Set<String> = [
        "linear", "sinusoidal", "spherical", "swirl", "horseshoe", "polar",
        "handkerchief", "heart", "disc", "spiral", "hyperbolic", "diamond",
        "ex", "julia", "bent", "fisheye", "exponential", "cosine", "cylinder"
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
    /// `rng` is threaded for julia (`flam3_random_isaac_bit`, variations.c:364).
    public static func evaluate(_ variations: [Variation], at p: SIMD2<Double>,
                                rng: inout ISAAC) -> SIMD2<Double> {
        var acc = SIMD2<Double>.zero
        for v in variations {
            guard v.weight != 0 else { continue }
            let term: SIMD2<Double>
            if v.name == "julia" {
                term = julia(p, weight: v.weight, rng: &rng)
            } else if let fn = table[v.name] {
                term = fn(p, v.weight)
            } else {
                warnUnknown(v.name)
                continue
            }
            acc += term
        }
        return acc
    }

    /// flam3 `var13_julia` (variations.c:350-368). Operation order matches the C
    /// source line-for-line so the chaotic julia map reproduces the oracle's
    /// trajectory bit-for-bit:
    ///   a   = 0.5 * precalc_atan            (precalc_atan = atan2(tx,ty) = atan2(x,y))
    ///   if (isaac_bit) a += M_PI
    ///   r   = weight * sqrt(precalc_sqrt)   (precalc_sqrt = sqrt(x²+y²); weight HERE)
    ///   sincos(a, &sa, &ca)
    ///   p0 += r * ca                        (NOT weight * (r4 * ca))
    ///   p1 += r * sa
    /// The weight multiply binds to `sqrt(precalc_sqrt)` BEFORE the cos/sin product,
    /// which is the ULP-order the oracle uses. `precalc_sqrt = sqrt(sumsq)` so
    /// `sqrt(precalc_sqrt) = (x²+y²)^¼`.
    private static func julia(_ p: SIMD2<Double>, weight: Double, rng: inout ISAAC) -> SIMD2<Double> {
        let sumsq = p.x*p.x + p.y*p.y
        let precalcSqrt = sumsq.squareRoot()        // sqrt(x²+y²) — flam3 precalc
        let a = 0.5 * atan2(p.x, p.y)               // 0.5 * precalc_atan
        let r = weight * precalcSqrt.squareRoot()   // weight * sqrt(precalc_sqrt)
        var aa = a
        if rng.bit() { aa += .pi }                   // flam3_random_isaac_bit (1 word)
        return SIMD2(r * cos(aa), r * sin(aa))      // r * ca , r * sa
    }

    // `nonisolated(unsafe)` is sound: `table` is a `let` initialized once at
    // first access and never mutated; the closures it holds are pure (no shared
    // mutable state). The CPU reference path is single-threaded by design.
    //
    // Each closure takes `(p, weight)` and returns the term that flam3 would add
    // to `f.p0`/`f.p1`, with weight folded in at flam3's exact position. Formulas
    // are line-for-line ports of flam3 variations.c (varN_*), using flam3's
    // `precalc_atan = atan2(tx, ty)` = atan2(x, y) and `EPS = 1e-10` (private.h:47).
    private nonisolated(unsafe) static let table: [String: (SIMD2<Double>, Double) -> SIMD2<Double>] = {
        var t: [String: (SIMD2<Double>, Double) -> SIMD2<Double>] = [:]
        let eps = 1e-10
        // var0_linear (variations.c:159-160): p0 += weight*tx
        t["linear"]      = { p, w in SIMD2(w * p.x, w * p.y) }
        // var1_sinusoidal: p0 += weight*sin(tx)
        t["sinusoidal"]  = { p, w in SIMD2(w * sin(p.x), w * sin(p.y)) }
        // var2_spherical: r2 = weight/(sumsq+EPS); p0 += r2*tx
        t["spherical"]   = { p, w in
            let sumsq = p.x*p.x + p.y*p.y
            let r2 = w / (sumsq + eps)
            return SIMD2(r2 * p.x, r2 * p.y)
        }
        // var3_swirl: sincos(r2,&c1,&c2); nx=c1*tx-c2*ty; p0+=weight*nx
        t["swirl"]       = { p, w in
            let r2 = p.x*p.x + p.y*p.y
            let c1 = sin(r2), c2 = cos(r2)
            return SIMD2(w * (c1*p.x - c2*p.y), w * (c2*p.x + c1*p.y))
        }
        // var4_horseshoe: r = weight/(sqrt+EPS); p0 += (tx-ty)*(tx+ty)*r
        t["horseshoe"]   = { p, w in
            let r = w / ((p.x*p.x + p.y*p.y).squareRoot() + eps)
            return SIMD2((p.x - p.y) * (p.x + p.y) * r, 2.0 * p.x * p.y * r)
        }
        // var5_polar: nx=atan/pi; ny=sqrt-1; p0+=weight*nx
        t["polar"]       = { p, w in
            let nx = atan2(p.x, p.y) / .pi
            let ny = (p.x*p.x + p.y*p.y).squareRoot() - 1.0
            return SIMD2(w * nx, w * ny)
        }
        // var6_handkerchief: a=atan; r=sqrt; p0+=weight*r*sin(a+r)
        t["handkerchief"] = { p, w in
            let a = atan2(p.x, p.y)
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            return SIMD2(w * r * sin(a + r), w * r * cos(a - r))
        }
        // var7_heart: a=sqrt*atan; r=weight*sqrt; p0+=r*sa; p1+=(-r)*ca
        t["heart"]       = { p, w in
            let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
            let a = precalcSqrt * atan2(p.x, p.y)
            let r = w * precalcSqrt
            return SIMD2(r * sin(a), (-r) * cos(a))
        }
        // var8_disc: a=atan/pi; r=pi*sqrt; p0+=weight*sin(r)*a
        t["disc"]        = { p, w in
            let a = atan2(p.x, p.y) / .pi
            let r = .pi * (p.x*p.x + p.y*p.y).squareRoot()
            return SIMD2(w * sin(r) * a, w * cos(r) * a)
        }
        // var9_spiral: r=sqrt+EPS; r1=weight/r; p0+=r1*(cosa+sin(r))
        t["spiral"]      = { p, w in
            let precalcSqrt = (p.x*p.x + p.y*p.y).squareRoot()
            let r = precalcSqrt + eps
            let r1 = w / r
            let a = atan2(p.x, p.y)
            return SIMD2(r1 * (cos(a) + sin(r)), r1 * (sin(a) - cos(r)))
        }
        // var10_hyperbolic: r=sqrt+EPS; p0+=weight*sin(a)/r; p1+=weight*cos(a)*r
        t["hyperbolic"]  = { p, w in
            let r = (p.x*p.x + p.y*p.y).squareRoot() + eps
            let a = atan2(p.x, p.y)
            return SIMD2(w * sin(a) / r, w * cos(a) * r)
        }
        // var11_diamond: p0+=weight*sina*cos(r); p1+=weight*cosa*sin(r)
        t["diamond"]     = { p, w in
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            let a = atan2(p.x, p.y)
            return SIMD2(w * sin(a) * cos(r), w * cos(a) * sin(r))
        }
        // var12_ex: m0=sin(a+r)³*r; p0+=weight*(m0+m1)
        t["ex"]          = { p, w in
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
        t["bent"]        = { p, w in
            let nx = p.x < 0 ? p.x * 2 : p.x
            let ny = p.y < 0 ? p.y / 2 : p.y
            return SIMD2(w * nx, w * ny)
        }
        // var16_fisheye: r=2/(sqrt+1); (r*ty, r*tx)  [axis swap per flam3]
        t["fisheye"]     = { p, w in
            let r = 2.0 / ((p.x*p.x + p.y*p.y).squareRoot() + 1.0)
            return SIMD2(w * r * p.y, w * r * p.x)
        }
        // var18_exponential: e=exp(tx-1); (e*cos(pi*ty), e*sin(pi*ty))
        t["exponential"] = { p, w in
            let e = exp(p.x - 1)
            return SIMD2(w * e * cos(.pi * p.y), w * e * sin(.pi * p.y))
        }
        // var20_cosine: (cos(pi*tx)*cosh(ty), -sin(pi*tx)*sinh(ty))
        t["cosine"]      = { p, w in
            SIMD2(w * cos(p.x * .pi) * cosh(p.y),
                  w * (-sin(p.x * .pi)) * sinh(p.y))
        }
        // var29_cylinder: (sin(tx), ty)
        t["cylinder"]    = { p, w in SIMD2(w * sin(p.x), w * p.y) }
        return t
    }()
}
