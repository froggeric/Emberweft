import Foundation

/// Port of flam3's `flam3_align` (interpolation.c:768-1032): special-sauce padding.
///
/// Given two keyframe genomes, pad both to equal regular-xform and final-xform
/// counts, copy parametric-variation params from the neighbor that has them, and
/// apply the per-variation "rest position" to padding xforms so the blend has a
/// sensible identity to interpolate against:
///
/// - **Group A** (neighbor has spherical/ngon/julian/juliascope/polar/wedge_sph/
///   wedge_julia): a 180°-rotated identity — `linear = -1`, coefs `[-1,0;0,-1;0,0]`.
///   Log-interpolation only. NOT renormalized (`fnd = -1`).
/// - **Group B** (neighbor has rectangles/rings2/fan2/blob/perspective/curl/
///   super_shape): that variation at weight 1 with its REST params (KEPT params
///   such as `perspective_dist` / `super_shape_m` are left at the copied value).
///   Renormalized.
/// - **Group C** (neighbor has fan/rings): that variation at weight 1 AND the
///   swap-affine `[0,1;1,0;0,0]`. Renormalized.
/// - **default**: `linear = 1.0` (plain identity).
///
/// Under `.compat`/`.older` the rest-position block is skipped entirely
/// (flam3_align:801-803): padding xforms keep their `linear = 1` default.
public enum SpecialSauce {

    // MARK: - variation groups (flam3_align:877-997)

    /// Group A — 180° rotated identity, log-only, NOT renormalized.
    private static let groupA: [String] = [
        "spherical", "ngon", "julian", "juliascope", "polar", "wedge_sph", "wedge_julia"
    ]
    /// Group B — var=1 + REST params, renormalized. Order matches the C source.
    private static let groupB: [String] = [
        "rectangles", "rings2", "fan2", "blob", "perspective", "curl", "super_shape"
    ]
    /// Group C — var=1 + swap-affine, renormalized.
    private static let groupC: [String] = ["fan", "rings"]

    /// The 180°-rotated identity affine (flam3_align:887-892).
    /// flam3 storage c[0][0]=a, c[0][1]=b, c[1][0]=c, c[1][1]=d, c[2][0]=e, c[2][1]=f.
    private static let rotatedIdentity = AffineTransform(a: -1, b: 0, c: 0, d: -1, e: 0, f: 0)
    /// The swap-affine (flam3_align:1003-1008).
    private static let swapAffine = AffineTransform(a: 0, b: 1, c: 1, d: 0, e: 0, f: 0)

    // MARK: - public API

    /// Pad `a` and `b` to equal regular + final xform counts and apply the
    /// flam3_align rest-position logic to the padding xforms.
    ///
    /// - Parameter interpolationType: the blend's matrix interpolation type
    ///   (drives the Group-A log-only gate and the compat/older early return).
    public static func align(
        _ a: Flame,
        _ b: Flame,
        interpolationType: MatrixInterpolationType
    ) -> (Flame, Flame) {
        var fa = a
        var fb = b

        let regA = fa.xforms.count
        let regB = fb.xforms.count
        let fxA = fa.finalXform != nil ? 1 : 0
        let fxB = fb.finalXform != nil ? 1 : 0
        let maxNx = max(regA, regB)
        // final-xform presence is OR'd across genomes (flam3_align:789-792).
        let maxFx = (fxA != 0 || fxB != 0) ? 1 : 0
        let alreadyAligned = (regA == regB) && (fxA == fxB)

        // Flatten each genome to [regular (padded to maxNx)] + [final if maxFx]
        // so the per-xf loops can index uniformly like flam3's xform[] array.
        var gx: [[Xform]] = [
            flatten(fa, maxNx: maxNx, maxFx: maxFx),
            flatten(fb, maxNx: maxNx, maxFx: maxFx)
        ]
        let total = maxNx + maxFx
        let nsrc = 2

        // compat/older early return (flam3_align:801-803): skip rest-position.
        if interpolationType != .compat && interpolationType != .older {
            applyLogic(&gx, total: total, nsrc: nsrc,
                       alreadyAligned: alreadyAligned, interp: interpolationType)
        }

        // Write back, splitting regular vs final.
        fa.xforms = Array(gx[0].prefix(maxNx))
        fa.finalXform = (maxFx == 1) ? gx[0].last : nil
        fb.xforms = Array(gx[1].prefix(maxNx))
        fb.finalXform = (maxFx == 1) ? gx[1].last : nil

        return (fa, fb)
    }

    // MARK: - padding

    /// Build a flat `[Xform]` of length `maxNx + maxFx`: the genome's regular
    /// xforms, padded with default padding xforms (linear=1, identity, padding=1),
    /// then the final xform (or a padding one if the genome lacks it).
    private static func flatten(_ f: Flame, maxNx: Int, maxFx: Int) -> [Xform] {
        var arr: [Xform] = []
        arr.append(contentsOf: f.xforms)
        while arr.count < maxNx {
            arr.append(makePaddingXform())
        }
        if maxFx == 1 {
            // flam3's `flam3_copyx` (flam3.c:1255-1266) differentiates the two
            // padding-final cases: if the source has a real final, copy it; else
            // synthesize a padding final with animate=0 and color_speed=0 (the
            // "Interpolated-against final xforms need animate & color_speed set
            // to 0.0" branch). The animate/color_speed overrides are final-only
            // — regular padding keeps `initialize_xforms` defaults (animate=1,
            // color_speed=0.5).
            arr.append(f.finalXform ?? makePaddingFinalXform(at: arr.count))
        }
        return arr
    }

    /// A flam3 default padding xform: `linear = 1`, identity coefs, `padding = 1`,
    /// and **structural `weight = 0`** (invisible in the chaos game).
    ///
    /// Faithful to flam3's `initialize_xforms` (variations.c:2401-2417), which
    /// every padding xform passes through before `flam3_copy_xform` overwrites
    /// the real-xform slots: `density = 0.0` (line 2406), `var[VAR_LINEAR] = 1.0`
    /// (line 2411), identity coefs (lines 2418-2423). flam3's
    /// `flam3_create_chaos_distrib` (flam3.c:179) draws directly from
    /// `xform[i].density`, so weight-0 padding xforms are NEVER selected; and
    /// `INTERP(xform[i].density)` (interpolation.c:530) interpolates it, so the
    /// real xform's weight fades out across the blend and reaches exactly 0 at
    /// t=1 — making the transition→loop boundary seamless (align(B) renders
    /// identically to raw B).
    ///
    /// NOTE: the variation weight `linear = 1.0` is distinct from this structural
    /// `weight = 0`. flam3_align:854 ("Remove linear") and the rest-position
    /// logic below operate on VARIATION weights (linear/spherical/…); the
    /// structural weight (chaos-game density) is what makes the xform selectable.
    /// Leaving structural weight at `Xform.init`'s default 1.0 caused the
    /// real-genome transition→loop seam: 9 weight-1.0 padding xforms rendered at
    /// t=1, distorting align(B) relative to raw B.
    private static func makePaddingXform() -> Xform {
        Xform(affine: .identity,
              weight: 0.0,
              variations: [Variation(name: "linear", weight: 1.0)],
              padding: 1)
    }

    /// A flam3 default padding **final** xform. Same structural skeleton as
    /// `makePaddingXform` (weight 0, identity, padding 1, linear=1), but with
    /// `animate = 0` and `colorSpeed = 0` per flam3's `flam3_copyx`
    /// (flam3.c:1262-1266: "Interpolated-against final xforms need animate &
    /// color_speed set to 0.0"). The `color` field follows
    /// `initialize_xforms`'s `color = i & 1` rule (variations.c:2407) — the
    /// padding final's color is set to match what flam3 leaves on the slot at
    /// `dest->num_xforms - 1` after `flam3_add_xforms` runs `initialize_xforms`
    /// from `old_num` upward.
    ///
    /// `colorSpeed = 0` is the load-bearing override for transition-endpoint
    /// seamlessness: it makes `ChaosGame.blendColor(fin, …)` a no-op
    /// (`(1-0)*colorT + 0*fin.color = colorT`), so the padding final — which is
    /// geometrically identity once `applyLogic` rest-positions its variations to
    /// defaults (e.g. `curl_c1=0, curl_c2=0` is identity curl) — neither
    /// transforms points nor shifts their palette index. With the default
    /// `colorSpeed = 0.5`, the bin color was being half-mixed with the padding
    /// final's `color`, dimming the entire frame.
    private static func makePaddingFinalXform(at index: Int) -> Xform {
        Xform(affine: .identity,
              weight: 0.0,
              color: Double(index & 1),   // flam3 initialize_xforms: `color = i & 1`
              colorSpeed: 0.0,            // flam3_copyx padding-final override (flam3.c:1265)
              variations: [Variation(name: "linear", weight: 1.0)],
              opacity: 1.0,
              animate: 0.0,               // flam3_copyx padding-final override (flam3.c:1266)
              padding: 1)
    }

    // MARK: - core logic (flam3_align:812-1030)

    private static func applyLogic(
        _ gx: inout [[Xform]],
        total: Int,
        nsrc: Int,
        alreadyAligned: Bool,
        interp: MatrixInterpolationType
    ) {
        // Parametric variations = those with at least one parameter slot.
        // flam3_align comment "no parametric variations < 23" (line 818) — the
        // param flag is exactly `descriptor.parameters.isEmpty == false`.
        let parametric = VariationDescriptor.canonicalOrder.filter {
            (VariationDescriptor.descriptor(for: $0)?.parameters.isEmpty == false)
        }

        for i in 0..<nsrc {
            for xf in 0..<total {

                // --- parametric-param copy (flam3_align:812-844) ---
                // If this xform's variation weight is 0 and a neighbor (i-1, else
                // i+1) has it nonzero, copy that variation's params here so the
                // blend has defined params on both sides.
                for name in parametric {
                    if weight(of: name, in: gx[i][xf]) == 0 {
                        if i > 0 && weight(of: name, in: gx[i - 1][xf]) != 0 {
                            copyParams(into: &gx[i][xf], name: name, from: gx[i - 1][xf])
                        } else if i < nsrc - 1 && weight(of: name, in: gx[i + 1][xf]) != 0 {
                            copyParams(into: &gx[i][xf], name: name, from: gx[i + 1][xf])
                        }
                    }
                }

                // --- rest-position (flam3_align:846-1028), padding xforms only ---
                guard gx[i][xf].padding == 1, !alreadyAligned else { continue }

                // Remove linear (flam3_align:854).
                setWeight(into: &gx[i][xf], name: "linear", weight: 0.0)
                var fnd = 0

                // Group A — log only (flam3_align:859-897).
                if interp == .log {
                    for ii in [-1, 1] {
                        let ni = i + ii
                        if ni < 0 || ni >= nsrc { continue }
                        if gx[ni][xf].padding == 1 { continue }
                        if groupA.contains(where: { weight(of: $0, in: gx[ni][xf]) > 0 }) {
                            setWeight(into: &gx[i][xf], name: "linear", weight: -1.0)
                            gx[i][xf].affine = rotatedIdentity
                            fnd = -1   // NOT renormalized
                        }
                    }
                }

                // Group B (flam3_align:899-971).
                if fnd == 0 {
                    for ii in [-1, 1] {
                        let ni = i + ii
                        if ni < 0 || ni >= nsrc { continue }
                        if gx[ni][xf].padding == 1 { continue }
                        for name in groupB where weight(of: name, in: gx[ni][xf]) > 0 {
                            applyRest(into: &gx[i][xf], name: name)
                            fnd += 1
                        }
                    }
                }

                // Group C (flam3_align:975-1010).
                if fnd == 0 {
                    for ii in [-1, 1] {
                        let ni = i + ii
                        if ni < 0 || ni >= nsrc { continue }
                        if gx[ni][xf].padding == 1 { continue }
                        for name in groupC where weight(of: name, in: gx[ni][xf]) > 0 {
                            setWeight(into: &gx[i][xf], name: name, weight: 1.0)
                            fnd += 1
                        }
                    }
                    if fnd > 0 {
                        gx[i][xf].affine = swapAffine
                    }
                }

                // default / renormalize (flam3_align:1013-1027).
                if fnd == 0 {
                    setWeight(into: &gx[i][xf], name: "linear", weight: 1.0)
                } else if fnd > 0 {
                    let sum = gx[i][xf].variations.reduce(0.0) { $0 + $1.weight }
                    if sum != 0 {
                        gx[i][xf].variations = gx[i][xf].variations.map {
                            Variation(name: $0.name, weight: $0.weight / sum, parameters: $0.parameters)
                        }
                    }
                }
                // fnd == -1 (Group A): linear stays -1, no renormalize.
            }
        }
    }

    // MARK: - xform variation helpers
    //
    // `Variation.weight` is immutable, so weight changes replace the array
    // element with a freshly constructed `Variation` carrying the same params.

    private static func weight(of name: String, in x: Xform) -> Double {
        x.variations.first { $0.name == name }?.weight ?? 0
    }

    private static func setWeight(into x: inout Xform, name: String, weight: Double) {
        if let idx = x.variations.firstIndex(where: { $0.name == name }) {
            let old = x.variations[idx]
            x.variations[idx] = Variation(name: old.name, weight: weight, parameters: old.parameters)
        } else {
            x.variations.append(Variation(name: name, weight: weight))
        }
    }

    /// `flam3_copy_params`: overwrite this variation's params with the source's
    /// params. Weight is left untouched (0 for a padding slot).
    private static func copyParams(into x: inout Xform, name: String, from src: Xform) {
        guard let srcV = src.variations.first(where: { $0.name == name }) else { return }
        if let idx = x.variations.firstIndex(where: { $0.name == name }) {
            x.variations[idx] = Variation(name: name, weight: x.variations[idx].weight,
                                          parameters: srcV.parameters)
        } else {
            x.variations.append(Variation(name: name, weight: 0, parameters: srcV.parameters))
        }
    }

    /// Set this variation's weight to 1 and apply its REST params (overriding
    /// only the keys in `descriptor.rest`; KEPT params — e.g. `perspective_dist`,
    /// `super_shape_m` — are intentionally absent from `rest` and stay as-is).
    private static func applyRest(into x: inout Xform, name: String) {
        guard let d = VariationDescriptor.descriptor(for: name) else { return }
        if let idx = x.variations.firstIndex(where: { $0.name == name }) {
            let old = x.variations[idx]
            var p = old.parameters
            for (k, v) in d.rest { p[k] = v }
            x.variations[idx] = Variation(name: old.name, weight: 1.0, parameters: p)
        } else {
            // Defensive: unreachable for padding xforms (param-copy creates the
            // entry first), but provide defaults+rest so behavior is sane.
            var params = d.defaults
            for (k, v) in d.rest { params[k] = v }
            x.variations.append(Variation(name: name, weight: 1.0, parameters: params))
        }
    }
}
