import Foundation

/// Pure math helpers for genome blending, ported verbatim from
/// `scottdraves/flam3` `interpolation.c`.
///
/// All functions are pure and `Sendable`-friendly (no captured state, no mutation).
public enum BlendMath {

    /// flam3 `smoother` (interpolation.c:339-341).
    ///
    /// Cubic Hermite smoothstep: `3t² − 2t³`. Maps `[0,1] → [0,1]` with zero
    /// derivative at both endpoints, and is its own identity at `0`, `0.5`, `1`.
    @inlinable
    public static func smoother(_ t: Double) -> Double {
        // flam3: `return 3*t*t - 2*t*t*t;`
        return 3 * t * t - 2 * t * t * t
    }

    /// flam3 `get_stagger_coef` (interpolation.c:343-367).
    ///
    /// Computes the per-xform blend fraction for staggered interpolation across
    /// `numXforms` standard (non-final) xforms. Each xform owns a sub-interval
    /// `[st, et]` of `[0,1]`; the contribution is clamped to `0` below `st`,
    /// `1` above `et`, and the smoothstep `smoother((t-st)/(1-stag_scaled))`
    /// is applied inside the window.
    ///
    /// The LAST standard xform (highest `xformIndex`) starts earliest — its
    /// `st` is smallest — so it leads the blend. This is the ACTIVE
    /// `st = stag_scaled * (num_xforms - 1 - this_xform) / (num_xforms-1)`
    /// line (interpolation.c:354), not the commented alternative that would
    /// use `this_xform` directly.
    ///
    /// - Parameters:
    ///   - t: global blend parameter in `[0,1]` (time fraction between keyframes).
    ///   - stagger: the genome `stagger` attribute in `[0,1]`; `0` disables it.
    ///   - numXforms: count of STANDARD xforms, excluding the final/post xform
    ///     (`num_xforms - (final_xform_enable)` per interpolation.c:524). Must be ≥ 2.
    ///   - xformIndex: 0-based index into the standard xform set.
    ///   - isFinal: `true` if this xform is the genome's final/post xform.
    /// - Returns: the per-xform blend fraction. For `stagger <= 0` or a final
    ///   xform, returns `smoother(t)` unchanged (no stagger).
    ///
    /// - Important: The caller is responsible for the `ncp == 2` gate: this
    ///   should only be invoked for two-control-point blends; for `ncp != 2`
    ///   the caller should use `smoother(t)` directly (flam3 gates this in
    ///   `flam3_interpolate_n` before calling `get_stagger_coef`).
    ///
    /// - Note: C division semantics are ported exactly:
    ///   - `max_stag = (double)(num_xforms-1)/num_xforms` — the `(double)` cast
    ///     binds to the numerator `(num_xforms-1)`, so this is floating division:
    ///     `Double(numXforms-1) / Double(numXforms)`.
    ///   - `st = stag_scaled * (num_xforms-1-this_xform) / (num_xforms-1)` — in C,
    ///     `*` and `/` are left-associative with equal precedence and `stag_scaled`
    ///     is `double`, so evaluation is multiply-then-divide:
    ///     `(stag_scaled * Double(numXforms-1-xformIndex)) / Double(numXforms-1)`.
    public static func staggerCoef(
        t: Double,
        stagger: Double,
        numXforms: Int,
        xformIndex: Int,
        isFinal: Bool
    ) -> Double {
        // Gates baked in (per Task 8 acceptance criteria): a final xform or a
        // disabled stagger always blend with the plain smoothstep. The ncp==2
        // gate lives at the caller (see doc comment above).
        if isFinal || stagger <= 0 {
            return smoother(t)
        }
        return staggerCoefUnchecked(
            t: t, stagger: stagger, numXforms: numXforms, xformIndex: xformIndex)
    }

    /// Unchecked port of the `get_stagger_coef` body (interpolation.c:345-366).
    /// Assumes the caller has already applied the stagger>0 / non-final / ncp==2 gates.
    @inlinable
    internal static func staggerCoefUnchecked(
        t: Double, stagger: Double, numXforms: Int, xformIndex: Int
    ) -> Double {
        // max_stag is the spacing between xform start times if stagger_prc = 1.0.
        // C: `double max_stag = (double)(num_xforms-1)/num_xforms;` — floating.
        let maxStag = Double(numXforms - 1) / Double(numXforms)

        // stag_scaled = stagger_prc * max_stag
        let stagScaled = stagger * maxStag

        // st: start of this xform's window. ACTIVE line makes the LAST xform
        // interpolate first. C evaluates `stag_scaled * (nx-1-i) / (nx-1)`
        // left-to-right (multiply before divide).
        let st = (stagScaled * Double(numXforms - 1 - xformIndex)) / Double(numXforms - 1)

        // et: end of this xform's window.
        let et = st + (1 - stagScaled)

        if t <= st {
            return 0
        } else if t >= et {
            return 1
        } else {
            return smoother((t - st) / (1 - stagScaled))
        }
    }
}
