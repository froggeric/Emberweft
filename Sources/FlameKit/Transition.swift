import Foundation

/// Port of flam3's `sheep_edge` (flam3.c:10582-10650) — the edge/transition blend
/// between two keyframe genomes. This is the central M3 orchestration: it composes
/// `SpecialSauce.align`, `RefAngles.establish`, the Task-13 `Loop` rotation,
/// `GenomeInterpolator.interpolate` (.log matrix blend + per-xform stagger), and
/// `PaletteBlend` (HSV-circular palette + linear `hue_rotation`).
///
/// The 8-step `sheep_edge` contract (flam3.c, verbatim order):
///
/// 1. **Clone both parents** — `Flame` is a value type, so `var spun0 = a` clones.
/// 2. **Fold motion elements** — Emberweft genomes carry no motion elements
///    (`Xform` has no `motion` field), so this is a documented no-op (flam3's
///    `apply_motion_parameters` loop at :10609-10616 has nothing to iterate).
/// 3. **`flam3_align`** — `SpecialSauce.align` pads both genomes to equal regular +
///    final xform counts and applies the per-variation rest positions. Note flam3
///    writes the aligned genomes into `spun`; Emberweft's `align` returns them.
/// 4. **Normalize times to {0, 1}** — `spun[0].time = 0; spun[1].time = 1`, so the
///    blend is over `[0,1]` regardless of the parents' original timestamps.
/// 5. **`establish_asymmetric_refangles`** — `RefAngles.establish(&cps, ncp: 2)`
///    writes the per-xform `wind[col]` anchors used by the `.log` unwrap. Called on
///    the PRE-rotation affines (flam3 order: establish at :10627, rotate at :10630).
/// 6. **Rotate BOTH endpoints** by `rotT·360°` via `Loop.blend(genome, t: rotT)`, where
///    `rotT = rotationCurve(t, r)` — an OPTIONAL velocity-matched ease (`r=1` ⇒
///    `rotT=t`, the flam3-faithful linear rotation; see `blend(rotationVelocityRatio:)`
///    + the owner decision of 2026-08-04). `Loop.blend` applies `flam3_rotate(genome,
///    rotT*360, type)` exactly (θ = rotT·2π, columns-not-rows convention, `animate != 0`
///    / final-skip / `padding`-under-`.linear`/`.compat`/`.older` gates). flam3 uses
///    `spun[0].interpolation_type` for BOTH rotations (flam3.c:10631); we sync
///    `spun1.interpolationType = spun0.interpolationType` before rotating so the
///    padding gate is identical for both endpoints.
/// 7. **`flam3_interpolate(spun, 2, smoother(t), stagger)`** —
///    `GenomeInterpolator.interpolate(spun0, spun1, t: smoother(t), type: .log,
///    stagger:)` with per-xform stagger (option (a): stagger lives inside the
///    interpolator's per-xform loop, matching `flam3_interpolate_n:522-527`). The
///    palette is blended via `PaletteBlend.blend(..., mode: paletteInterpolation,
///    hsvMix: hsvRgbPaletteBlend)` — NOT the interpolator's internal linear RGB blend
///    — and `hueRotation` via `PaletteBlend.interpolateHueRotation` (linear).
/// 8. **Strip motion elements** — no-op (see step 2); Emberweft has no motion elements.
///
/// Stagger design choice: **option (a)** — stagger is a parameter on
/// `GenomeInterpolator.interpolate`, applied per non-final xform inside the
/// interpolator's per-xform loop. This matches flam3's structure (stagger lives in
/// `flam3_interpolate_n`'s per-xform loop, not in `sheep_edge` itself) and keeps
/// `Transition.blend` thin. `stagger <= 0` (default) leaves every xform on the same
/// eased curve; the `.linear` path is byte-identical to the pre-stagger behavior.
public enum Transition {

    /// Produce frame `t` of the transition blend from genome `a` (t=0) to genome `b`
    /// (t=1), porting `sheep_edge`.
    ///
    /// - Parameters:
    ///   - a: the source (t=0) keyframe genome.
    ///   - b: the destination (t=1) keyframe genome.
    ///   - t: normalized transition time in `[0,1]`. `0` is `a` (after align), `1` is
    ///     `b` (after align, within rotation-matrix FP residual ≈1e-16 at the 2π seam).
    ///   - stagger: the genome `stagger` attribute in `[0,1]`; `0` disables per-xform
    ///     desync. Applied only to non-final xforms (final/post xform uses global t).
    ///   - rotationVelocityRatio: ratio of transition duration to loop duration
    ///     (`r = transFrames / loopFrames`). The rotation parameter fed to `Loop.blend`
    ///     in step 6 is `rotationCurve(t, r)` (see that helper). `r = 1.0` (default) ⇒
    ///     linear `t`, the flam3-faithful behavior, byte-identical to every pre-existing
    ///     caller that omits it. `r < 1` (a short transition between longer loops) eases
    ///     the rotation so its real-time angular velocity at BOTH boundaries matches the
    ///     adjacent loops, eliminating the loop↔transition rotation-velocity ("jarring
    ///     jerk") jump — an intentional divergence from flam3's linear transition
    ///     rotation (owner decision, 2026-08-04: animation is no longer flam3-parity-bound).
    /// - Returns: a new interpolated genome; inputs are never mutated (value semantics).
    public static func blend(
        _ a: Flame, _ b: Flame, t: Double, stagger: Double = 0,
        rotationVelocityRatio r: Double = 1.0
    ) -> Flame {
        // --- Step 1: clone both parents (value-typing makes assignment a clone). ---
        // --- Step 2: motion fold — no-op (Emberweft has no motion elements). ---

        // Record B's native final-xform presence BEFORE align pads it (used by
        // the endpoint seamlessness divergence near the end of this function).
        let bHadFinal = (b.finalXform != nil)

        // --- Step 3: flam3_align (SpecialSauce.align) → padded, rest-positioned genomes. ---
        // flam3_align writes into `spun`; Emberweft returns the aligned pair. `a`/`b`
        // are value types so passing them by value is the clone (step 1).
        var (spun0, spun1) = SpecialSauce.align(a, b, interpolationType: a.interpolationType)

        // --- Step 4: normalize the two control points' times to {0, 1}. ---
        spun0.time = 0.0
        spun1.time = 1.0

        // --- Step 5: establish_asymmetric_refangles on the 2 cps (writes wind[col]). ---
        // Establish on the PRE-rotation affines, before step 6 rotates them — the wind
        // anchors are then used by the .log unwrap inside GenomeInterpolator with the
        // post-rotation affines, exactly as in flam3 (establish:10627, rotate:10630,
        // interpolate:10640).
        var cps = [spun0, spun1]
        RefAngles.establish(&cps, ncp: 2)
        spun0 = cps[0]
        spun1 = cps[1]

        // --- Step 6: rotate BOTH endpoints by rotT·360° (flam3_rotate, via Loop.blend). ---
        // flam3 rotates spun[1] with spun[0].interpolation_type (flam3.c:10631), so the
        // padding-xform gate uses the SAME type for both endpoints. Sync spun1 to spun0's
        // type before rotating (this is a local copy — the inputs `a`/`b` are untouched).
        //
        // Velocity-matched ease (intentional divergence from flam3's linear rotation;
        // owner decision 2026-08-04 — animation is no longer flam3-parity-bound). The
        // rotation parameter is `rotT = rotationCurve(t, r) = r·t + (1−r)·smoother(t)`,
        // NOT the raw `t`. `r=1` ⇒ `rotT = t` (linear, byte-identical to the old path).
        // `r = transFrames/loopFrames` makes the real-time angular velocity at both
        // boundaries (rotT'(0) = rotT'(1) = r, since smoother'(0)=smoother'(1)=0) equal
        // `360°·r/transDuration = 360°/loopDuration` — the adjacent loops' velocity —
        // eliminating the rotation-velocity jump. The total rotation is unchanged
        // (rotT(0)=0, rotT(1)=1 ⇒ 0°→360°, so R(360°)=R(0°) keeps the next-loop seam
        // seamless). ONLY the rotation is eased; the morph (step 7) and palette stay on
        // `smoother(t)` (UNCHANGED).
        spun1.interpolationType = spun0.interpolationType
        let rotT = rotationCurve(t, rotationVelocityRatio: r)
        let spun0Rotated = Loop.blend(spun0, t: rotT)
        let spun1Rotated = Loop.blend(spun1, t: rotT)

        // --- Step 7: flam3_interpolate(spun, 2, smoother(t), stagger) + HSV palette. ---
        // Matrix/via .log with per-xform stagger; temporal smoothing via smoother(t).
        let easedT = BlendMath.smoother(t)
        var result = GenomeInterpolator.interpolate(
            spun0Rotated, spun1Rotated, t: easedT,
            type: spun0.interpolationType, stagger: stagger)

        // The palette is blended via PaletteBlend (HSV-circular + hsvRgbPaletteBlend),
        // NOT GenomeInterpolator's internal linear RGB blend — flam3 does the palette
        // loop in flam3_interpolate_n (:377-455) using the genome's palette mode.
        // Stagger does NOT affect the palette (flam3 applies it in the per-xform loop
        // only, :522); the palette always uses the global eased t.
        result.palette = PaletteBlend.blend(
            spun0Rotated.palette, spun1Rotated.palette, at: easedT,
            mode: spun0.paletteInterpolation, hsvMix: spun0.hsvRgbPaletteBlend)
        // hue_rotation interpolates linearly (INTERP(hue_rotation), interpolation.c:478).
        result.hueRotation = PaletteBlend.interpolateHueRotation(
            spun0Rotated.hueRotation, spun1Rotated.hueRotation, at: easedT)

        // SEAMLESSNESS DIVERGENCE (per owner): endpoint padding-final drop.
        // If B had NO final xform (`b.finalXform == nil` before align), the
        // result inherits a SpecialSauce padding final (align's `maxFx`
        // OR-rule, SpecialSauce.swift:65). After Group A/B/C rest-positioning
        // that padding final is NOT identity — e.g. seg3 02632→15729: A's real
        // final has rings2, so the padding final becomes `rings2=1.0` and
        // transforms every iterated point. flam3's sheep_edge has the same
        // align+pad behavior (interpolation.c:779-806 + 846 rest-position loop
        // runs over the final slot too), while sheep_loop does not — so flam3
        // exhibits the same Transition→Loop endpoint discontinuity. This is a
        // deliberate divergence for endpoint seamlessness: at t==1.0 drop the
        // padding final so `Transition(A,B,1.0)` matches `Loop(B,0)` (no
        // final). Same-handedness pairs where B has a real final are
        // unaffected (the `!bHadFinal` gate). The near-endpoint (t<1) keeps
        // flam3 semantics. Note: the `Xform.padding` field is not propagated
        // by the interpolator (it constructs a fresh `Xform()` per slot), so
        // we gate on `!bHadFinal` alone — at t==1.0 any non-nil final in the
        // result must be the align-synthesized padding final (B had none).
        if !bHadFinal, t >= 1.0, result.finalXform != nil {
            result.finalXform = nil
        }

        // --- Step 8: strip motion elements — no-op (Emberweft has no motion elements). ---

        return result
    }

    /// Velocity-matched rotation curve for transition endpoints:
    /// `rotT(t) = r·t + (1−r)·smoother(t)` where `smoother(t) = 3t² − 2t³`.
    ///
    /// At `r = 1.0` this is the identity `t` (linear, flam3-faithful — every caller that
    /// omits `rotationVelocityRatio` is byte-identical to the pre-ease behavior). At
    /// `r < 1` (a transition shorter than its adjacent loops), the smoothstep term eases
    /// the rotation so the angular velocity is `r` (not 1) at both boundaries — matching
    /// the loops' velocity and eliminating the loop↔transition rotation-velocity jump.
    ///
    /// Properties: `rotT(0) = 0`, `rotT(1) = 1` (total rotation unchanged ⇒ seam with the
    /// next loop preserved via `R(360°)=R(0°)`); `rotT'(0) = rotT'(1) = r` (because
    /// `smoother'(0)=smoother'(1)=0`). Monotonic for `r < 3`: `rotT'(t) = r + (1−r)·6t(1−t)`,
    /// whose minimum over `[0,1]` is `1.5 − 0.5r > 0`; `r ≥ 3` goes non-monotonic and is
    /// out of scope (loops are never >3× longer than their transitions in practice).
    public static func rotationCurve(_ t: Double, rotationVelocityRatio r: Double) -> Double {
        r * t + (1.0 - r) * BlendMath.smoother(t)
    }
}
