import Foundation

/// HSV/RGB palette blend + `hue_rotation` interpolation, ported verbatim from
/// `scottdraves/flam3` `interpolation.c` (`flam3_interpolate_n`, palette
/// portion: lines 377-461) and `palettes.c` (`rgb2hsv`/`hsv2rgb`: lines 199-285).
///
/// Faithfulness notes:
/// - Hue is on flam3's **0-6 scale** (not 0-360 or 0-1). The shorter-arc
///   thresholds `+/-3.0` and the wrap adjustment `+/-6.0` depend on this scale.
/// - `rgb_fraction` per mode (interpolation.c:380-384):
///   - `.hsv`         -> `0.0` (plain hsv)
///   - `.rgb`         -> `1.0` (all rgb output)
///   - `.hsvCircular` -> `hsvMix` (the genome's `hsv_rgb_palette_blend`)
/// - The shorter-arc hue adjustment is applied **only** to control point 0,
///   only in `.hsvCircular` (interpolation.c:403-414). A 2-palette blend has
///   `ncp == 2` by construction, so that gate is always satisfied here.
/// - Both the RGB triple and the HSV triple are linearly blended by the
///   `(1-t), t` weights; the blended HSV is converted back to RGB and the two
///   are mixed by `rgb_fraction` (interpolation.c:416-438).
/// - All color channels are clipped to `[0,1]` (interpolation.c:444-449).
///   Emberweft's `Palette` stores only RGB (`SIMD3<Double>`), so the alpha
///   (`color[3]`) and `index` accumulators from the C do not apply here.
/// - `sweep` is the hard-cut branch (interpolation.c:456-462):
///   `j = (i < 256*c[0]) ? 0 : 1`.
public enum PaletteBlend {

    /// Blends two 256-entry palettes `a` -> `b` at parameter `t in [0,1]`,
    /// porting `flam3_interpolate_n`'s palette loop (interpolation.c:377-461).
    ///
    /// - Parameters:
    ///   - a: control point 0 palette (256 entries).
    ///   - b: control point 1 palette (256 entries).
    ///   - t: blend parameter; `c[0] = 1-t`, `c[1] = t`.
    ///   - mode: `PaletteInterpolation` (.sweep / .rgb / .hsv / .hsvCircular).
    ///   - hsvMix: the genome's `hsv_rgb_palette_blend`; used as `rgb_fraction`
    ///     only in `.hsvCircular`. Ignored by the other modes.
    /// - Returns: a new 256-entry `Palette`. At `t=0` -> `a`, at `t=1` -> `b`.
    public static func blend(
        _ a: Palette, _ b: Palette, at t: Double,
        mode: PaletteInterpolation, hsvMix: Double
    ) -> Palette {
        precondition(a.colors.count == 256, "PaletteBlend.blend: palette a must have 256 entries")
        precondition(b.colors.count == 256, "PaletteBlend.blend: palette b must have 256 entries")

        // Blend weights: c[0] = 1-t, c[1] = t (linear in time; temporal
        // smoothing of the scalar is the caller's responsibility, mirroring
        // flam3 where smoother() is applied before flam3_interpolate_n).
        let c0 = 1.0 - t
        let c1 = t

        var out = Palette(colors: Array(repeating: SIMD3<Double>.zero, count: 256))

        // --- sweep: hard-cut (interpolation.c:456-462) -----------------------
        if mode == .sweep {
            for i in 0..<256 {
                // C: `j = (i < (256 * c[0])) ? 0 : 1;`
                let j = (Double(i) < 256.0 * c0) ? 0 : 1
                out.colors[i] = (j == 0 ? a.colors : b.colors)[i]
            }
            return out
        }

        // --- rgb / hsv / hsv_circular (interpolation.c:380-384) -------------
        var rgbFraction: Double = 0.0
        if mode == .rgb {
            rgbFraction = 1.0
        } else if mode == .hsvCircular {
            rgbFraction = hsvMix
        }
        // mode == .hsv => rgbFraction stays 0.0

        for i in 0..<256 {
            let rgbA = a.colors[i]
            let rgbB = b.colors[i]

            // rgb2hsv both control points' colors (interpolation.c:397, 406).
            var hsvA = rgb2hsv(rgbA)
            let hsvB = rgb2hsv(rgbB)

            // Shorter-arc hue adjust on cp0 (interpolation.c:403-414):
            // only in hsv_circular (ncp==2 is implicit in a 2-palette blend).
            if mode == .hsvCircular {
                let delta = hsvB.h - hsvA.h
                if delta > 3.0 {
                    hsvA.h += 6.0
                } else if delta < -3.0 {
                    hsvA.h -= 6.0
                }
            }

            // Accumulate RGB and HSV triples by (1-t), t (interpolation.c:416-418).
            let newRGB = c0 * rgbA + c1 * rgbB
            let newH = c0 * hsvA.h + c1 * hsvB.h
            let newS = c0 * hsvA.s + c1 * hsvB.s
            let newV = c0 * hsvA.v + c1 * hsvB.v

            // hsv2rgb the blended HSV (interpolation.c:434).
            let newHSVRGB = hsv2rgb(h: newH, s: newS, v: newV)

            // Mix by rgb_fraction (interpolation.c:437-438).
            let mix0 = rgbFraction * newRGB.x + (1.0 - rgbFraction) * newHSVRGB.x
            let mix1 = rgbFraction * newRGB.y + (1.0 - rgbFraction) * newHSVRGB.y
            let mix2 = rgbFraction * newRGB.z + (1.0 - rgbFraction) * newHSVRGB.z

            // Clip to [0,1] (interpolation.c:444-449).
            out.colors[i] = SIMD3<Double>(
                min(max(mix0, 0.0), 1.0),
                min(max(mix1, 0.0), 1.0),
                min(max(mix2, 0.0), 1.0)
            )
        }
        return out
    }

    /// Linear `hue_rotation` interpolation, porting `INTERP(hue_rotation)`
    /// (interpolation.c:478). `INTERP(x)` expands to
    /// `result.x = c[0]*cp[0].x + c[1]*cp[1].x + ...`; for two control points
    /// this is `(1-t)*a + t*b`.
    @inlinable
    public static func interpolateHueRotation(_ a: Double, _ b: Double, at t: Double) -> Double {
        (1.0 - t) * a + t * b
    }
}

// MARK: - rgb2hsv / hsv2rgb (flam3 palettes.c:199-285)

/// HSV triple with hue on flam3's 0-6 scale, s and v on 0-1.
@usableFromInline
internal struct HSV {
    @usableFromInline var h: Double
    @usableFromInline var s: Double
    @usableFromInline var v: Double

    @usableFromInline
    init(h: Double, s: Double, v: Double) {
        (self.h, self.s, self.v) = (h, s, v)
    }
}

/// Verbatim port of `rgb2hsv` (palettes.c:199-241).
/// Input rgb in [0,1]^3; output hue in [0,6), s,v in [0,1].
@inlinable
internal func rgb2hsv(_ rgb: SIMD3<Double>) -> HSV {
    let rd = rgb.x
    let gd = rgb.y
    let bd = rgb.z

    // compute maximum of rd,gd,bd
    let max: Double
    if rd >= gd {
        if rd >= bd { max = rd } else { max = bd }
    } else {
        if gd >= bd { max = gd } else { max = bd }
    }

    // compute minimum of rd,gd,bd
    let min: Double
    if rd <= gd {
        if rd <= bd { min = rd } else { min = bd }
    } else {
        if gd <= bd { min = gd } else { min = bd }
    }

    let del = max - min
    let v = max
    let s = (max != 0.0) ? del / max : 0.0

    var h: Double = 0
    if s != 0.0 {
        let rc = (max - rd) / del
        let gc = (max - gd) / del
        let bc = (max - bd) / del

        if rd == max {
            h = bc - gc
        } else if gd == max {
            h = 2 + rc - bc
        } else if bd == max {
            h = 4 + gc - rc
        }

        if h < 0 {
            h += 6
        }
    }

    return HSV(h: h, s: s, v: v)
}

/// Verbatim port of `hsv2rgb` (palettes.c:242-285).
/// Input hue in [0,6] (wrapped), s,v in [0,1]; output rgb in [0,1]^3.
@inlinable
internal func hsv2rgb(h hIn: Double, s: Double, v: Double) -> SIMD3<Double> {
    var h = hIn
    while h >= 6.0 { h -= 6.0 }
    while h < 0.0 { h += 6.0 }

    let j = Int(floor(h))
    let f = h - Double(j)
    let p = v * (1 - s)
    let q = v * (1 - (s * f))
    let t = v * (1 - (s * (1 - f)))

    switch j {
    case 0:  return SIMD3<Double>(v, t, p)
    case 1:  return SIMD3<Double>(q, v, p)
    case 2:  return SIMD3<Double>(p, v, t)
    case 3:  return SIMD3<Double>(p, q, v)
    case 4:  return SIMD3<Double>(t, p, v)
    case 5:  return SIMD3<Double>(v, p, q)
    default: return SIMD3<Double>(v, t, p)
    }
}
