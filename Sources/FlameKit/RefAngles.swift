import Foundation

/// Reference-angle establishment for the `.log` matrix unwrap.
///
/// Faithful port of flam3 `establish_asymmetric_refangles`
/// (`interpolation.c:710-766`). For each non-final xform, computes the two
/// column angles of the pre-affine 2×2 across every control point, unwraps
/// the ±π discontinuity pairwise, and — for a pair that is symmetric on
/// exactly one side (symmetric ⇒ `animate == 0`) — stores the animating
/// (non-symmetric) side's adjusted column angle plus 2π into `xform.wind[col]`.
///
/// Column→field mapping (see `AffineTransform`, `tx = a·x + c·y + e`,
/// `ty = b·x + d·y + f`): flam3 `c[col][row]` corresponds to
/// column 0 = (a, b) and column 1 = (c, d), so
/// `cxang[k][0] = atan2(b, a)` and `cxang[k][1] = atan2(d, c)`.
///
/// `wind` is written ONLY; affine coefficients are never modified.
public enum RefAngles {

    /// EPS matching flam3 (`interpolation.c` uses `EPS = 1e-10`).
    private static let eps: Double = 1e-10

    /// Port of `establish_asymmetric_refangles(cp, ncps)`.
    ///
    /// - Parameters:
    ///   - cps: Control-point genomes (aligned: every cp must have at least as
    ///     many xforms as `cps[0]`). Mutated in place — only `xform.wind` is written.
    ///   - ncp: Number of control points to consider (`<= cps.count`).
    public static func establish(_ cps: inout [Flame], ncp: Int) {
        precondition(ncp >= 0 && ncp <= cps.count, "ncp out of range")
        if ncp < 2 { return }

        // Iterate over cp[0]'s xform count (flam3 loops `xfi < cp[0].num_xforms`).
        // Final xforms live in `Flame.finalXform` (separate from `xforms`), so the
        // `xforms` array already excludes them — no final-index skip is needed.
        let nxforms = cps[0].xforms.count

        for xfi in 0..<nxforms {

            // cxang[k][col] — per-cp column angles (flam3 `double cxang[4][2]`).
            var cxang = Array(repeating: SIMD2<Double>.zero, count: ncp)

            for k in 0..<ncp {
                let aff = cps[k].xforms[xfi].affine
                // col 0 = (a, b) ; col 1 = (c, d)  (flam3 c[col][0], c[col][1]).
                cxang[k] = SIMD2<Double>(
                    atan2(aff.b, aff.a),
                    atan2(aff.d, aff.c))
            }

            for k in 1..<ncp {
                for col in 0..<2 {

                    // Adjust to avoid the -π/π discontinuity (interpolation.c:745-748).
                    // Note the asymmetric thresholds: `π+EPS` and `-(π-EPS)`.
                    var ck = cxang[k][col]
                    let d = ck - cxang[k - 1][col]
                    if d > Double.pi + eps {
                        ck -= 2 * Double.pi
                    } else if d < -(Double.pi - eps) {
                        ck += 2 * Double.pi
                    }
                    cxang[k][col] = ck

                    // padsymflag is hardcoded 0 inside the loop (interpolation.c:753),
                    // so `(padding==1 && padsymflag)` is always false ⇒ the effective
                    // symmetry test is `animate == 0` ONLY. Padding is NOT symmetry.
                    let sym0 = cps[k - 1].xforms[xfi].animate == 0
                    let sym1 = cps[k].xforms[xfi].animate == 0

                    // Store the NON-symmetric side's angle in the second cp
                    // (interpolation.c:758-761) — "store in the second to avoid
                    // overwriting if asymmetric on both sides".
                    if sym1 && !sym0 {
                        cps[k].xforms[xfi].wind[col] = cxang[k - 1][col] + 2 * Double.pi
                    } else if sym0 && !sym1 {
                        cps[k].xforms[xfi].wind[col] = cxang[k][col] + 2 * Double.pi
                    }
                    // Both symmetric or both animated ⇒ no-op (wind keeps its default).
                }
            }
        }
    }
}
