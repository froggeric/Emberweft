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

    /// Sum of `weight_j * V_j(p)` over the given variations.
    ///
    /// `rng` is threaded so variations that consume randomness (notably
    /// `julia`, which adds π with probability ½ per flam3 `var13_julia`) draw
    /// from the single deterministic stream. Pure variations ignore it. M2
    /// will widen this to a full affine+RNG context for dependent variations.
    public static func evaluate(_ variations: [Variation], at p: SIMD2<Float>,
                                rng: inout PCG32) -> SIMD2<Float> {
        var acc = SIMD2<Float>.zero
        for v in variations {
            guard v.weight != 0 else { continue }
            let term: SIMD2<Float>
            if let fn = table[v.name] {
                term = v.weight * fn(p)
            } else if v.name == "julia" {
                term = v.weight * julia(p, rng: &rng)
            } else {
                warnUnknown(v.name)
                continue
            }
            // Per-variation guard: a single overflowing variation must not poison
            // valid sibling contributions — drop only the offending term.
            if term.x.isFinite && term.y.isFinite { acc += term }
        }
        // Defense-in-depth backstop (should be unreachable given the per-term guard).
        if !acc.x.isFinite || !acc.y.isFinite { return .zero }
        return acc
    }

    /// flam3 `var13_julia`: r_out = (x²+y²)^¼, a = θ/2 + (bit ? π : 0).
    /// `precalc_atan` in flam3 is atan2(y, x) (see `precalc_atanyx`).
    private static func julia(_ p: SIMD2<Float>, rng: inout PCG32) -> SIMD2<Float> {
        let r2 = p.x*p.x + p.y*p.y
        let r = r2.squareRoot().squareRoot()      // (x²+y²)^¼
        var a = atan2(p.y, p.x) * 0.5
        if (rng.next() & 1) != 0 { a += .pi }
        return SIMD2(r * cos(a), r * sin(a))
    }

    // `nonisolated(unsafe)` is sound: `table` is a `let` initialized once at
    // first access and never mutated; the closures it holds are pure (no shared
    // mutable state). The CPU reference path is single-threaded by design.
    private nonisolated(unsafe) static let table: [String: (SIMD2<Float>) -> SIMD2<Float>] = {
        var t: [String: (SIMD2<Float>) -> SIMD2<Float>] = [:]
        let safe: (SIMD2<Float>) -> SIMD2<Float> = { p in
            guard p.x.isFinite, p.y.isFinite else { return .zero }
            return p
        }
        // Each formula below is a line-for-line port of flam3 variations.c
        // (varN_*), using θ = atan2(y, x) and r = √(x²+y²). Constants are NOT
        // invented: variations that need the affine coefs (waves/popcorn/…) are
        // omitted entirely rather than given wrong hard-coded constants.
        t["linear"]      = { safe($0) }
        t["sinusoidal"]  = { safe(SIMD2(sin($0.x), sin($0.y))) }
        t["spherical"]   = { p in
            let d = p.x*p.x + p.y*p.y
            guard d > 1e-12 else { return .zero }      // flam3 uses +EPS in denominator
            return SIMD2(p.x/d, p.y/d)
        }
        t["swirl"]       = { p in                      // var3: c1=sin(r²), c2=cos(r²)
            let r2 = p.x*p.x + p.y*p.y
            let s = sin(r2), c = cos(r2)
            return SIMD2(s*p.x - c*p.y, c*p.x + s*p.y)
        }
        t["horseshoe"]   = { p in                      // var4
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            guard r > 1e-12 else { return .zero }
            let inv = 1 / r
            return SIMD2((p.x - p.y) * (p.x + p.y) * inv, 2 * p.x * p.y * inv)
        }
        t["polar"]       = { p in                      // var5: (θ/π, r-1)
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            return SIMD2(atan2(p.y, p.x) / .pi, r - 1)
        }
        t["handkerchief"] = { p in                      // var6: (r·sin(θ+r), r·cos(θ-r))
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            let a = atan2(p.y, p.x)
            return SIMD2(r * sin(a + r), r * cos(a - r))
        }
        t["heart"]       = { p in                      // var7: a=r·θ; (r·sin a, -r·cos a)
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            let a = r * atan2(p.y, p.x)
            return SIMD2(r * sin(a), -r * cos(a))
        }
        t["disc"]        = { p in                      // var8: a=θ/π, rr=π·r; (a·sin rr, a·cos rr)
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            let a = atan2(p.y, p.x) / .pi
            let rr = .pi * r
            return SIMD2(a * sin(rr), a * cos(rr))
        }
        t["spiral"]      = { p in                      // var9
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            guard r > 1e-12 else { return .zero }
            let a = atan2(p.y, p.x)
            let inv = 1 / r
            return SIMD2((cos(a) + sin(r)) * inv, (sin(a) - cos(r)) * inv)
        }
        t["hyperbolic"]  = { p in                      // var10: (sin θ / r, r·cos θ)
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            guard r > 1e-12 else { return .zero }
            let a = atan2(p.y, p.x)
            return SIMD2(sin(a) / r, r * cos(a))
        }
        t["diamond"]     = { p in                      // var11: (sinθ·cos r, cosθ·sin r)
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            let a = atan2(p.y, p.x)
            return SIMD2(sin(a) * cos(r), cos(a) * sin(r))
        }
        t["ex"]          = { p in                      // var12: n0=sin(θ+r), n1=cos(θ-r)
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            let a = atan2(p.y, p.x)
            let n0 = sin(a + r)
            let n1 = cos(a - r)
            let m0 = n0*n0*n0 * r
            let m1 = n1*n1*n1 * r
            return SIMD2(m0 + m1, m0 - m1)
        }
        // julia (var13) is implemented in `julia(_:rng:)` — it consumes the RNG.
        t["bent"]        = { p in                      // var14: x*2 if x<0, y/2 if y<0
            SIMD2(p.x < 0 ? p.x * 2 : p.x,
                  p.y < 0 ? p.y / 2 : p.y)
        }
        t["fisheye"]     = { p in                      // var16: r=2/(r+1); (r·y, r·x)  [note axis swap, per flam3]
            let r = (p.x*p.x + p.y*p.y).squareRoot()
            let f = 2 / (r + 1)
            return SIMD2(f * p.y, f * p.x)
        }
        t["exponential"] = { p in                      // var18: e=exp(x-1); (e·cos(πy), e·sin(πy))
            let e = exp(p.x - 1)
            guard e.isFinite else { return .zero }
            return SIMD2(e * cos(.pi * p.y), e * sin(.pi * p.y))
        }
        t["cosine"]      = { p in                      // var20: (cos(πx)·cosh y, -sin(πx)·sinh y)
            SIMD2(cos(p.x * .pi) * cosh(p.y),
                  -sin(p.x * .pi) * sinh(p.y))
        }
        t["cylinder"]    = { SIMD2(sin($0.x), $0.y) }  // var29
        return t
    }()
}
