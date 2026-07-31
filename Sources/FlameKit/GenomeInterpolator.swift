import Foundation

/// Genome interpolation engine ported verbatim from `scottdraves/flam3`
/// `interpolation.c`. Switches on `MatrixInterpolationType`:
///
/// - `.linear` (and `.compat`/`.older`): per-field linear blend of every xform
///   field (matrices via `lerpAffine`, porting flam3's `sum_matrix`).
/// - `.log`: polar decomposition of each xform's 2×2 matrix
///   (`convert_linear_to_polar` + `interp_and_convert_back`), with the
///   wind-anchored angle unwrap, the per-column magnitude guard, the
///   zero-column angle copy, and the post-identity special case.
///
/// Both modes share ONE variation merge (`mergeVariations`): union by name
/// (zero-weight slots preserved), sorted by name, with per-name per-parameter
/// linear interpolation using descriptor defaults when a side lacks a param.
/// This is faithful to flam3: in `flam3_interpolate_n` the
/// `INTERP(xform[i].var[j])` loop and ALL parametric `INTERP`s
/// (interpolation.c:543-655) execute BEFORE the `.log`/`.linear` matrix branch
/// (line 657), so variation + parameter interpolation is IDENTICAL for both
/// types — only the 2×2 matrices differ. An earlier split (`mergeLinear`
/// dropping params + zero-weight vs `mergeLog` carrying them) was an
/// unfaithful asymmetry: the `.linear` path silently lost every parametric
/// variation's parameters at interpolate time.
public enum GenomeInterpolator {

    /// Interpolate two keyframe genomes at parameter `t ∈ [0,1]`.
    ///
    /// - Parameters:
    ///   - stagger: the genome `stagger` attribute in `[0,1]`. When `> 0` and both
    ///     genomes are aligned (2-control-point blend), each non-final xform `i` is
    ///     interpolated at a per-xform blend fraction derived from
    ///     `BlendMath.staggerCoefUnchecked` (porting `flam3_interpolate_n:522-527`),
    ///     so xforms desync across the transition. The final/post xform and ALL scalar
    ///     genome fields (camera, palette, hueShift, time, …) always use the global `t`
    ///     — exactly as in flam3, where stagger lives inside the per-xform loop only.
    ///     `stagger <= 0` (the default) leaves every xform on the same eased curve,
    ///     keeping the `.linear` path byte-identical to the no-stagger behavior.
    public static func interpolate(
        _ a: Flame, _ b: Flame, t: Double, type: MatrixInterpolationType, stagger: Double = 0
    ) -> Flame {
        switch type {
        case .log:
            return blend(a, b, t, stagger: stagger, xformBlend: interpolateLogXform)
        case .linear, .compat, .older:
            return blend(a, b, t, stagger: stagger, xformBlend: interpolateLinearXform)
        }
    }

    // MARK: - Shared skeleton (interpolation.c:464-706, non-matrix fields)

    /// Common genome blend skeleton. All scalar fields, camera, palette, and the
    /// xform-count mismatch handling are identical between `.linear` and `.log`;
    /// only the per-xform callback differs.
    private static func blend(
        _ a: Flame, _ b: Flame, _ t: Double, stagger: Double,
        xformBlend: (_ a: Xform, _ b: Xform, _ t: Double) -> Xform
    ) -> Flame {
        var f = Flame()
        f.name = t < 0.5 ? a.name : b.name
        f.size = t < 0.5 ? a.size : b.size
        f.camera = Camera(
            center: lerp(a.camera.center, b.camera.center, t),
            // INTENTIONAL divergence from flam3: `INTERP(pixels_per_unit)` is
            // linear (interpolation.c:489), but magnification is perceived
            // logarithmically (Weber-Fechner) — a geometric/log-space blend
            // yields constant PERCEIVED zoom velocity and a perceptually-
            // symmetric midpoint, the seamless choice for ambient playback.
            // `zoom`/`rotation` stay linear: `zoom` is already log-coded in the
            // projection (`pixelsPerUnit = scale * 2^zoom`, so linear-in-zoom is
            // geometric-in-magnification), and angle is perceived linearly.
            // Pinned by `testCameraScaleInterpolatedLogSpace`; see CLAUDE.md.
            scale: pow(a.camera.scale, 1 - t) * pow(b.camera.scale, t),
            zoom: (1 - t) * a.camera.zoom + t * b.camera.zoom,
            rotation: (1 - t) * a.camera.rotation + t * b.camera.rotation)
        f.quality = interpolateQuality(a.quality, b.quality, t)
        f.hueShift = (1 - t) * a.hueShift + t * b.hueShift
        f.time = (1 - t) * a.time + t * b.time
        f.palette = blendPalette(a.palette, b.palette, t)
        // flam3 `flam3_interpolate_n` copies these enum/scalar genome fields from
        // cpi[0] (interpolation.c:466-468: `result->{palette_mode, interpolation,
        // interpolation_type, palette_interpolation} = cpi[0].<field>`). `f = Flame()`
        // above zero-initializes them to defaults, so without these copies the
        // transition result silently reverts to `.step` palette_mode even when both
        // parents are `.linear` — a rendering-affecting bug for the chaos game's
        // dmap sampler (ChaosGame.swift branches on `flame.paletteMode`).
        // `hsv_rgb_palette_blend` likewise copies from cpi[0] (it's a single
        // per-genome scalar, not interpolated).
        f.paletteMode = a.paletteMode
        f.interpolation = a.interpolation
        f.interpolationType = a.interpolationType
        f.paletteInterpolation = a.paletteInterpolation
        f.hsvRgbPaletteBlend = a.hsvRgbPaletteBlend

        let n = max(a.xforms.count, b.xforms.count)
        // stagger: nx = standard (non-final) xform count. After align both genomes share
        // this count; when unaligned we use the max. flam3 gates stagger on ncp==2 &&
        // stagger>0 && i != final_xform_index (interpolation.c:522). The final xform is
        // handled separately below with the global t (never staggered).
        let staggerActive = stagger > 0 && n >= 2

        f.xforms = (0..<n).map { i in
            if i >= a.xforms.count { return b.xforms[i] }
            if i >= b.xforms.count { return a.xforms[i] }
            let ti = staggerActive
                ? perXformBlendT(globalT: t, stagger: stagger, nx: n, xformIndex: i)
                : t
            return xformBlend(a.xforms[i], b.xforms[i], ti)
        }
        // Final/post xform: NO stagger (flam3 gate i != final_xform_index).
        if let fa = a.finalXform, let fb = b.finalXform {
            f.finalXform = xformBlend(fa, fb, t)
        } else {
            f.finalXform = (a.finalXform ?? b.finalXform)
        }
        return f
    }

    /// Per-xform blend fraction (cp1 weight) with stagger applied, porting
    /// `flam3_interpolate_n:522-527`.
    ///
    /// flam3 computes the cp0 weight `c[0] = 1 - t`, calls
    /// `get_stagger_coef(c[0], stagger, nx, i)` to derive the staggered cp0 weight,
    /// then sets `c[1] = 1 - c[0]`. `BlendMath.staggerCoefUnchecked` is a verbatim
    /// port of `get_stagger_coef` — its `t` argument IS flam3's `c[0]` (the cp0
    /// weight), so we pass `1 - t` and return `1 - result` to recover the cp1 weight
    /// (the blend fraction the per-xform callback expects).
    private static func perXformBlendT(
        globalT t: Double, stagger: Double, nx: Int, xformIndex i: Int
    ) -> Double {
        let c0 = 1.0 - t
        let staggeredC0 = BlendMath.staggerCoefUnchecked(
            t: c0, stagger: stagger, numXforms: nx, xformIndex: i)
        return 1.0 - staggeredC0
    }

    // MARK: - .linear xform

    /// Per-xform linear blend: matrices via `lerpAffine` (flam3 `sum_matrix`),
    /// variations + parameters via the shared `mergeVariations`. Identical to
    /// the `.log` path except for the matrix interpolation.
    private static func interpolateLinearXform(_ a: Xform, _ b: Xform, _ t: Double) -> Xform {
        var x = Xform()
        x.weight = (1 - t) * a.weight + t * b.weight
        x.color = (1 - t) * a.color + t * b.color
        x.colorSpeed = (1 - t) * a.colorSpeed + t * b.colorSpeed
        x.opacity = (1 - t) * a.opacity + t * b.opacity
        x.animate = (1 - t) * a.animate + t * b.animate   // flam3 INTERP(xform[i].animate) (interpolation.c:542)
        x.affine = lerpAffine(a.affine, b.affine, t)
        x.postAffine = lerpAffine(a.postAffine, b.postAffine, t)
        x.variations = mergeVariations(a.variations, b.variations, t)
        x.chaos = (a.chaos != nil && b.chaos != nil)
            ? zip(a.chaos!, b.chaos!).map { (1 - t) * $0 + t * $1 } : (a.chaos ?? b.chaos)
        return x
    }

    // MARK: - .log xform (polar matrix decomposition)

    /// Per-xform `.log` blend: affine + post via polar decomposition, variations
    /// via the shared `mergeVariations` (union + parameter carry, zero-weight
    /// slots preserved).
    private static func interpolateLogXform(_ a: Xform, _ b: Xform, _ t: Double) -> Xform {
        var x = Xform()
        x.weight = (1 - t) * a.weight + t * b.weight
        x.color = (1 - t) * a.color + t * b.color
        x.colorSpeed = (1 - t) * a.colorSpeed + t * b.colorSpeed
        x.opacity = (1 - t) * a.opacity + t * b.opacity
        x.animate = (1 - t) * a.animate + t * b.animate   // flam3 INTERP(xform[i].animate) (interpolation.c:542)

        // affine part: polar (cflag=0 => wind-anchored unwrap applies).
        x.affine = interpolateAffineLog(a.affine, b.affine, windB: b.wind, cflag: false, t: t)

        // post part: flam3_interpolate_n:668 — if both parents' post is identity,
        // force result post to identity; otherwise polar (cflag=1 => wind ignored).
        if isIdentity(a.postAffine) && isIdentity(b.postAffine) {
            x.postAffine = .identity
        } else {
            x.postAffine = interpolateAffineLog(
                a.postAffine, b.postAffine, windB: b.wind, cflag: true, t: t)
        }

        x.variations = mergeVariations(a.variations, b.variations, t)
        x.chaos = (a.chaos != nil && b.chaos != nil)
            ? zip(a.chaos!, b.chaos!).map { (1 - t) * $0 + t * $1 } : (a.chaos ?? b.chaos)
        return x
    }

    /// Shared variation merge for BOTH `.linear` and `.log` (the per-mode
    /// split is matrix-only in flam3 — see the file header). Union by name
    /// (zero-weight slots preserved, so align-created padding entries survive),
    /// sorted by name, with **per-param linear interpolation** of every
    /// parameter (variation weight AND each parameter value). This is a
    /// faithful port of flam3's `INTERP(x)` macro (interpolation.h:24) as
    /// applied per parametric field in `flam3_interpolate_n`
    /// (interpolation.c:543-655 — `INTERP(xform[i].blob_low)`,
    /// `INTERP(xform[i].curl_c1)`, …, then the `INTERP(xform[i].var[j])` loop):
    /// the result for each field is `(1-t)*cp[0].field + t*cp[1].field`. When
    /// a side lacks the parameter, the variation's descriptor default is used
    /// (`initialize_xforms` defaults, variations.c:2424-2700); for unknown
    /// parameters the default is 0.
    ///
    /// History: this rule supersedes TWO earlier faithfulness gaps.
    /// (1) `mergeLog` v0.1.4 used an "A's params win, B fills gaps" carry,
    /// which at t=1.0 kept source-A's parametric values instead of returning
    /// destination-B's (broke transition endpoints; fixed v0.1.5, 052dcceaf).
    /// (2) `mergeLinear` (the `.linear`/`.compat`/`.older` path) dropped ALL
    /// parameters via `Variation(name:weight:)` and filtered zero-weight
    /// entries — an asymmetry with no flam3 basis (flam3 INTERPs every
    /// parametric field identically for both types). For `.linear`
    /// transitions involving any parametric variation (curl, blob, julian, …)
    /// the merged xform arrived at the renderer with empty `parameters`, so
    /// the variation executed at descriptor-default instead of the
    /// interpolated value — a rendering-affecting divergence from flam3.
    /// Consolidated into this single shared merge (both paths now identical,
    /// matching flam3's pre-branch INTERP block).
    private static func mergeVariations(_ a: [Variation], _ b: [Variation], _ t: Double) -> [Variation] {
        var weight = [String: Double]()
        var aParams = [String: [String: Double]]()
        var bParams = [String: [String: Double]]()
        var aRaw = [String: Double]()
        var bRaw = [String: Double]()
        for v in a {
            weight[v.name, default: 0] += (1 - t) * v.weight
            aRaw[v.name, default: 0] += v.weight
            var p = aParams[v.name] ?? [:]
            for (k, val) in v.parameters { p[k] = val }
            aParams[v.name] = p
        }
        for v in b {
            weight[v.name, default: 0] += t * v.weight
            bRaw[v.name, default: 0] += v.weight
            var p = bParams[v.name] ?? [:]
            for (k, val) in v.parameters { p[k] = val }
            bParams[v.name] = p
        }
        // Per-param linear interp using descriptor defaults when a side lacks
        // the parameter (flam3 INTERP + initialize_xforms defaults).
        var params = [String: [String: Double]]()
        for name in weight.keys {
            let ap = aParams[name] ?? [:]
            let bp = bParams[name] ?? [:]
            let descriptor = VariationDescriptor.descriptor(for: name)
            // Use the descriptor's canonical param list + defaults when this is
            // a known variation; otherwise fall back to the union of both sides'
            // keys (preserves round-trip for unknown/synthetic params).
            let keys = (descriptor?.parameters.isEmpty == false)
                ? descriptor!.parameters
                : Array(Set(ap.keys).union(bp.keys)).sorted()
            let defs = descriptor?.defaults ?? [:]
            var merged: [String: Double] = [:]
            for k in keys {
                let av = ap[k] ?? defs[k] ?? 0
                let bv = bp[k] ?? defs[k] ?? 0
                merged[k] = (1 - t) * av + t * bv
            }
            params[name] = merged
        }
        // SEAMLESSNESS DIVERGENCE (per owner): flam3's INTERP emits tiny nonzero
        // weights (≈ t·B.weight) for one-sided variations (present in only one
        // genome). On spiky attractors these chaotic "leaks" redecorate the canvas
        // — e.g. 05915→37205 slot 2 (horseshoe/fan2/lazysusan/cot/mobius) fills
        // ~30% more histogram bins at the boundary, raising luma ~38% (the loop,
        // which doesn't interpolate, is clean → a visible "elements appearing"
        // jump). Clip one-sided variations whose interpolated weight is below ε so
        // the transition's endpoint frame matches the loop; two-sided (principal)
        // variations are always kept; one-sided leaks fade in once weight ≥ ε.
        // flam3 does NOT clip (its own INTERP artifact, confirmed via the oracle) —
        // a deliberate divergence for seamless loop↔transition boundaries, like the
        // `.log` det guard + the Camera.scale log-space decision.
        let leakEps = 1e-3
        return weight
            .filter { name, w in
                // drop one-sided leaks: a variation whose raw weight is 0 on
                // EXACTLY one side (absent, OR a weight-0 parametric-copy slot)
                // contributes only `t·other` — a chaotic "leak" on spiky
                // attractors. Clip it below ε. Both-zero slots (preserved — flam3
                // keeps the full var[] array) and both-nonzero (two-sided) are kept.
                // (Name-presence alone is defeated by `align`'s parametric-param
                // copy, which adds B's parametric variations to A at weight 0, so
                // the per-side RAW weight — not name membership — is the test.)
                let az = (aRaw[name] ?? 0) == 0
                let bz = (bRaw[name] ?? 0) == 0
                return !((az != bz) && abs(w) < leakEps)
            }
            .sorted { $0.key < $1.key }
            .map { Variation(name: $0.key, weight: $0.value, parameters: params[$0.key] ?? [:]) }
    }

    // MARK: - Polar matrix interpolation (verbatim flam3 port)

    /// Drives `convertLinearToPolar` + `interpAndConvertBack` for the 2-parent
    /// case. `coefs = [1-t, t]` matches flam3's 2-point linear blend scalar.
    ///
    /// SEAMLESSNESS DIVERGENCE (per owner): when A and B have opposite
    /// handedness (`det(A)·det(B) < 0`), the `.log` polar interpolation —
    /// continuous in t by construction — necessarily crosses `det = 0` at some
    /// t (typically the midpoint), collapsing 2D→1D for that xform. flam3 has
    /// no guard here and produces the same singular matrix; at high sample
    /// density this piles chaos-game hits on a 1D attractor and the tone
    /// mapper amplifies it into a uniform colour/brightness pop (the Class A
    /// seg9 midpoint symptom — xform[5] interpolates from a det=−1 reflection
    /// `[-1,0;0,1]` to a det=+1 rotation `[0.935,0.355;-0.355,0.935]`,
    /// landing at det=2.2e−16 with identical columns at t=0.5). Fall back to
    /// the `.linear` matrix blend (`lerpAffine`, porting flam3's `sum_matrix`)
    /// for opposite-handedness pairs. Same-handedness pairs are unaffected and
    /// stay byte-identical to flam3.
    private static func interpolateAffineLog(
        _ a: AffineTransform, _ b: AffineTransform,
        windB: SIMD2<Double>, cflag: Bool, t: Double
    ) -> AffineTransform {
        let detA = a.a * a.d - a.b * a.c
        let detB = b.a * b.d - b.b * b.c
        if detA * detB < 0 {
            // Opposite-handedness pair: polar interp would cross det=0.
            return lerpAffine(a, b, t)
        }
        let coefs = [1 - t, t]
        let polar = convertLinearToPolar(a, b, windB: windB, cflag: cflag)
        return interpAndConvertBack(coefs, polar.ang, polar.mag, polar.trn)
    }

    /// Port of `convert_linear_to_polar` (interpolation.c:247-324) for ncp=2.
    ///
    /// Per column col∈{0,1}: `cxang[k][col]=atan2(c1[1],c1[0])`,
    /// `cxmag[k][col]=sqrt(c1[0]²+c1[1]²)`, translation kept linear. The
    /// zero-column rule (line 274): if a column's magnitude is exactly 0, copy
    /// the angle from the non-zero column. Wind unwrap (line 293): when
    /// `wind[col]>0 && cflag==0`, fold both angles into `[wind-2π, wind]`;
    /// otherwise apply the normal ±π discontinuity fix (clockwise at ±π).
    private static func convertLinearToPolar(
        _ a: AffineTransform, _ b: AffineTransform,
        windB: SIMD2<Double>, cflag: Bool
    ) -> (ang: [[Double]], mag: [[Double]], trn: [[Double]]) {
        let ms = [a, b]
        var ang = Array(repeating: Array(repeating: 0.0, count: 2), count: 2)
        var mag = Array(repeating: Array(repeating: 0.0, count: 2), count: 2)
        var trn = Array(repeating: Array(repeating: 0.0, count: 2), count: 2)

        // Establish angles, magnitudes, and translations per cp/column.
        for k in 0..<2 {
            var zlm = [0, 0]
            for col in 0..<2 {
                let c0 = column(ms[k], col).x
                let c1 = column(ms[k], col).y
                let t = translation(ms[k], col)
                ang[k][col] = atan2(c1, c0)
                mag[k][col] = sqrt(c0 * c0 + c1 * c1)
                if mag[k][col] == 0.0 { zlm[col] = 1 }
                trn[k][col] = t
            }
            // Zero-column angle copy (interpolation.c:280-283).
            if zlm[0] == 1 && zlm[1] == 0 {
                ang[k][0] = ang[k][1]
            } else if zlm[0] == 0 && zlm[1] == 1 {
                ang[k][1] = ang[k][0]
            }
        }

        // Shorter-rotation adjustment (interpolation.c:289-323).
        let eps = 1e-6   // flam3 EPS
        for col in 0..<2 {
            for k in 1..<2 {
                if windB[col] > 0 && !cflag {
                    // Asymmetric case: fold into [wind-2π, wind].
                    let refang = windB[col] - 2 * .pi
                    while ang[k - 1][col] < refang { ang[k - 1][col] += 2 * .pi }
                    while ang[k - 1][col] > refang + 2 * .pi { ang[k - 1][col] -= 2 * .pi }
                    while ang[k][col] < refang { ang[k][col] += 2 * .pi }
                    while ang[k][col] > refang + 2 * .pi { ang[k][col] -= 2 * .pi }
                } else {
                    // Normal ±π discontinuity fix; clockwise at exactly ±π.
                    let d = ang[k][col] - ang[k - 1][col]
                    if d > .pi + eps {
                        ang[k][col] -= 2 * .pi
                    } else if d < -(.pi - eps) {
                        ang[k][col] += 2 * .pi
                    }
                }
            }
        }
        return (ang, mag, trn)
    }

    /// Port of `interp_and_convert_back` (interpolation.c:194-245) for ncp=2.
    ///
    /// PER-COLUMN magnitude guard (line 214): for each column, if
    /// `log(cxmag[i][col]) < -10` for ANY cp i, that column's `accmode[col]=1`
    /// and its magnitude accumulates LINEARLY (`accmag += c[i]*cxmag[i][col]`,
    /// `expmag = accmag` — NOT `exp(accmag)`). The angle still polar-blends; the
    /// OTHER column and the translation are UNAFFECTED; the xform does NOT fall
    /// back to `.linear`. There is NO determinant guard, NO NaN guard here.
    private static func interpAndConvertBack(
        _ coefs: [Double],
        _ ang: [[Double]], _ mag: [[Double]], _ trn: [[Double]]
    ) -> AffineTransform {
        var accang = [0.0, 0.0]
        var accmag = [0.0, 0.0]
        var accmode = [0, 0]
        var storeTrn = [0.0, 0.0]   // translation per column

        // Per-column magnitude guard (default logarithmic; linear only if a
        // column is near-degenerate in ANY cp).
        for col in 0..<2 {
            for i in 0..<2 {
                if log(mag[i][col]) < -10 {
                    accmode[col] = 1
                }
            }
        }

        // Accumulate angle, magnitude, and translation per column.
        for i in 0..<2 {
            for col in 0..<2 {
                accang[col] += coefs[i] * ang[i][col]
                if accmode[col] == 0 {
                    accmag[col] += coefs[i] * log(mag[i][col])
                } else {
                    accmag[col] += coefs[i] * mag[i][col]
                }
                storeTrn[col] += coefs[i] * trn[i][col]
            }
        }

        // Convert (mag, ang) back to rectangular per column.
        var colX = [0.0, 0.0]   // colX[col] = entry [col][0]
        var colY = [0.0, 0.0]   // colY[col] = entry [col][1]
        for col in 0..<2 {
            let expmag: Double = (accmode[col] == 0) ? exp(accmag[col]) : accmag[col]
            colX[col] = expmag * cos(accang[col])
            colY[col] = expmag * sin(accang[col])
        }

        // Column 0 = (a, b); column 1 = (c, d); translation = (e, f).
        return AffineTransform(
            a: colX[0], b: colY[0],
            c: colX[1], d: colY[1],
            e: storeTrn[0], f: storeTrn[1])
    }

    // MARK: - Helpers

    /// flam3 `id_matrix` (interpolation.c:60-68) — exact identity test.
    private static func isIdentity(_ m: AffineTransform) -> Bool {
        m.a == 1.0 && m.b == 0.0 && m.c == 0.0 && m.d == 1.0 && m.e == 0.0 && m.f == 0.0
    }

    /// Column access matching flam3's `c[col][0/1]` layout:
    /// column 0 = (a, b) — x coefficients; column 1 = (c, d) — y coefficients.
    private static func column(_ m: AffineTransform, _ col: Int) -> SIMD2<Double> {
        col == 0 ? SIMD2(m.a, m.b) : SIMD2(m.c, m.d)
    }

    /// Translation access matching flam3's `c[2][col]`: column 0 = e, column 1 = f.
    private static func translation(_ m: AffineTransform, _ col: Int) -> Double {
        col == 0 ? m.e : m.f
    }

    private static func lerp(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ t: Double) -> SIMD2<Double> {
        a * (1 - t) + b * t
    }

    private static func lerpAffine(_ a: AffineTransform, _ b: AffineTransform, _ t: Double) -> AffineTransform {
        AffineTransform(a: (1 - t) * a.a + t * b.a, b: (1 - t) * a.b + t * b.b, c: (1 - t) * a.c + t * b.c,
                        d: (1 - t) * a.d + t * b.d, e: (1 - t) * a.e + t * b.e, f: (1 - t) * a.f + t * b.f)
    }

    private static func blendPalette(_ a: Palette, _ b: Palette, _ t: Double) -> Palette {
        Palette(colors: zip(a.colors, b.colors).map { $0 * (1 - t) + $1 * t })
    }

    /// Faithful `Quality` field blend, porting `flam3_interpolate_n`'s
    /// `INTERP(...)` block (interpolation.c:473-501) for the numeric display
    /// pipeline + estimator fields. flam3 INTERP-linearly blends each of
    /// brightness / highlight_power / gamma / vibrancy / spatial_filter_radius
    /// / temporal_filter_exp / temporal_filter_width / sample_density /
    /// estimator{,_minimum,_curve} / gam_lin_thresh. Emberweft previously
    /// hard-cut the whole `Quality` struct at `t < 0.5`, which made every
    /// display-pipeline parameter (notably `brightness`, `gamma`) jump
    /// discontinuously at the blend midpoint whenever two keyframes carried
    /// different values (real ES genomes do — e.g. seg3 brightness 19.13→4,
    /// gamma 2.94→4; seg13 brightness 40→18.93, gamma 4→2.65). The jump is a
    /// uniform brightness/colour pop with no shape change — exactly the
    /// Class A "mid-transition colour/intensity jump" symptom, with magnitude
    /// proportional to the brightness/gamma delta.
    ///
    /// Enum / structural fields (`filterShape`, `temporalFilterType`) and int
    /// counts (`oversample`, `temporalSamples`) are NOT in flam3's INTERP
    /// block — they're either part of the `cpi[0]` enum copy block
    /// (interpolation.c:466-472) or left untouched by the interpolate path.
    /// We copy them from `a` (= cpi[0]), matching flam3's cpi[0]-copy rule.
    private static func interpolateQuality(_ a: Quality, _ b: Quality, _ t: Double) -> Quality {
        // Inherit enum / int / structural fields from cpi[0] (flam3's copy rule).
        var q = a
        // Numeric fields flam3 INTERPs (interpolation.c:473-501):
        q.brightness          = (1 - t) * a.brightness          + t * b.brightness            // INTERP(brightness) :473
        q.highlightPower      = (1 - t) * a.highlightPower      + t * b.highlightPower        // INTERP(highlight_power) :475
        q.gamma               = (1 - t) * a.gamma               + t * b.gamma                 // INTERP(gamma) :476
        q.vibrancy            = (1 - t) * a.vibrancy            + t * b.vibrancy              // INTERP(vibrancy) :477
        q.gammaThreshold      = (1 - t) * a.gammaThreshold      + t * b.gammaThreshold        // INTERP(gam_lin_thresh) :501
        q.filterRadius        = (1 - t) * a.filterRadius        + t * b.filterRadius          // INTERP(spatial_filter_radius) :490
        q.temporalFilterExp   = (1 - t) * a.temporalFilterExp   + t * b.temporalFilterExp     // INTERP(temporal_filter_exp) :491
        q.temporalFilterWidth = (1 - t) * a.temporalFilterWidth + t * b.temporalFilterWidth   // INTERP(temporal_filter_width) :492
        // sample_density is stored as double in flam3; Emberweft's is `Int`, so
        // round the interpolated value (CLI overrides via --quality for offline
        // animation; mainly load-bearing for the display-pipeline fields above).
        q.samplesPerPixel     = max(1, Int(((1 - t) * Double(a.samplesPerPixel)
                                          +        t * Double(b.samplesPerPixel)).rounded()))   // INTERP(sample_density) :493
        q.estimatorRadius     = (1 - t) * a.estimatorRadius     + t * b.estimatorRadius       // INTERP(estimator) :498
        q.estimatorMinimum    = (1 - t) * a.estimatorMinimum    + t * b.estimatorMinimum      // INTERP(estimator_minimum) :499
        q.estimatorCurveRate  = (1 - t) * a.estimatorCurveRate  + t * b.estimatorCurveRate    // INTERP(estimator_curve) :500
        return q
    }
}
