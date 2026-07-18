import Foundation

/// Port of flam3's `sheep_loop` (flam3.c:396) + `flam3_rotate` (flam3.c:512).
///
/// `sheep_loop` clones the genome and calls `flam3_rotate(result, blend*360.0, type)`,
/// which left-multiplies the pre-affine 2×2 of every animating, non-final xform by
/// `R(θ)` with `θ = blend·2π`. Translation (`e`,`f`), post-affine, palette, weight,
/// color, opacity and chaos are untouched. Final xforms are never rotated.
public enum Loop {

    /// Produce frame `t` of the seamless loop for `sheep`.
    ///
    /// - Parameter sheep: the keyframe genome (loop base).
    /// - Parameter t: normalized loop time in `[0,1]`. `0` is the input; `1` closes
    ///   the loop within rotation-matrix FP residual (≈1e-16 per coefficient), NOT
    ///   bit-equal — `cos(2π)` is `1 − 5e-16` in `Double`.
    /// - Returns: a rotated clone; `sheep` is never mutated.
    public static func blend(_ sheep: Flame, t: Double) -> Flame {
        var result = sheep

        // θ = t * 2 * π  — pinned exactly (flam3_rotate: `by*360` then `DEG2RAD`,
        // i.e. `t*360*2π/360 = t*2π`). NOT reduced mod 2π: flam3 feeds `2π` straight
        // into sin/cos, so `R(2π)·M ≠ M` bit-for-bit; the seam is closed only within
        // the rotation-matrix ULP residual (≈1e-16), not by `==`.
        let theta = t * 2 * Double.pi
        let cs = cos(theta)
        let sn = sin(theta)

        for i in 0..<result.xforms.count {
            // animate == 0 ⇒ symmetry xform, never rotated (flam3_rotate:529).
            guard result.xforms[i].animate != 0 else { continue }
            // Final xforms live in `finalXform`, never in `xforms`; skip defensively
            // regardless. (flam3_rotate: "Do NOT rotate final xforms".)
            // Padding xforms rotate only under `.log` (flam3_rotate:532-545).
            if result.xforms[i].padding != 0 && result.interpolationType != .log {
                continue
            }
            // Rotate the pre-affine 2×2's basis vectors by R(θ). This matches
            // flam3's `mult_matrix` (interpolation.c:110), which is NON-standard:
            // `mult_matrix(s1,s2,d)` computes d[i][j] = s1[0][j]*s2[i][0] +
            // s1[1][j]*s2[i][1], i.e. d = s2·s1. flam3 calls `mult_matrix(R, T, U)`
            // so U = T·R, with R = [[cos, sin], [-sin, cos]] and flam3 storage
            // c[0][0]=a, c[0][1]=b, c[1][0]=c, c[1][1]=d (i.e. T's stored rows are
            // (a,b) and (c,d)). Equivalently — and what's actually being computed
            // here — the math matrix M = [[a,c],[b,d]] (per AffineTransform.apply:
            // tx = a·x + c·y + e, ty = b·x + d·y + f) has its COLUMNS (a,b) and
            // (c,d) each rotated by R(θ) = [[cos,-sin],[sin,cos]]:
            //   a' =  cos·a − sin·b
            //   b' =  sin·a + cos·b
            //   c' =  cos·c − sin·d
            //   d' =  sin·c + cos·d
            // NOTE: do NOT "simplify" back to rotating the row pairs (a,c)/(b,d) —
            // that is the WRONG convention and only appeared correct because the
            // t=0 identity case is identical under both formulations. Translation
            // (e,f) is NOT part of the 2×2 and is left untouched.
            let m = result.xforms[i].affine
            result.xforms[i].affine.a = cs * m.a - sn * m.b
            result.xforms[i].affine.b = sn * m.a + cs * m.b
            result.xforms[i].affine.c = cs * m.c - sn * m.d
            result.xforms[i].affine.d = sn * m.c + cs * m.d
        }

        return result
    }
}
