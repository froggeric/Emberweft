import Foundation
import FlameKit

public struct RGBA8Image: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]    // RGBA, row-major
    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }
}

/// Display pipeline matching flam3's `render_rectangle` (rect.c + palettes.c).
///
/// Stages, in order (all mirrored from the flam3 oracle source — behavior
/// matched by reading, no GPL code copied):
///
/// 1. **Log-density scaling** (rect.c:947-974, `de.max_filter_index==0` path):
///    `ls = k1·log(1 + c3·k2) / c3` where c3 is the per-bin hit count scaled to
///    flam3's 255-unit. Produces an accumulator `(rgb, alpha)` per grid cell.
/// 2. **Spatial filter** (rect.c:1137-1160, filters.c:217-269): a normalized
///    Gaussian kernel (`spatial_filter_radius=0.5`, `gaussian` kernel) convolved
///    over the accumulator. For oversample=1 the kernel is near-identity.
/// 3. **Gamma + vibrancy + background** (rect.c:1167-1202, `!earlyclip` path):
///    `flam3_calc_alpha` (palettes.c:274) for the opacity curve, then the
///    vibrancy-weighted channel blend with `pow(channel, 1/gamma)`.
public enum ToneMapping {
    /// flam3 defaults (genomes here don't override these).
    private static let contrast: Float = 1.0
    private static let brightness: Float = 4.0
    private static let highlightPower: Float = -1.0
    private static let prefilterWhite: Float = 255
    private static let whiteLevel: Float = 255
    private static let background: SIMD3<Float> = .zero

    public static func render(histogram: Histogram, width: Int, height: Int, oversample: Int,
                              gamma: Float, gammaThreshold: Float, vibrancy: Float,
                              sampleDensity: Float, pixelsPerUnit: Float) -> RGBA8Image {
        let gw = histogram.gridWidth, gh = histogram.gridHeight

        // --- k1 / k2 (rect.c:933-937) ---
        // k1 = contrast * brightness * PREFILTER_WHITE * 268 / 256
        let k1 = contrast * brightness * prefilterWhite * 268.0 / 256.0
        // area = image_w * image_h / (ppux * ppuy); ppux = pixelsPerUnit (zoom=0, aspect=1).
        // image dimensions include oversample (fic.width = cp.width * oversample).
        let imageW = width * oversample
        let imageH = height * oversample
        let area = Float(imageW * imageH) / (pixelsPerUnit * pixelsPerUnit)
        let nbatches = 1
        let sumfilt: Float = 1.0   // spatial filter is normalized to sum 1
        let k2 = Float(oversample * oversample * nbatches) /
                 (contrast * area * whiteLevel * sampleDensity * sumfilt)

        // --- Stage 1: log-density scaling (rect.c:949-973, de==0 path) ---
        // Emberweft counts = hits; flam3 bucket[3] = whiteLevel * hits. Scale to match.
        var accumRGB = [SIMD3<Float>](repeating: .zero, count: gw * gh)
        var accumA = [Float](repeating: 0, count: gw * gh)
        for j in 0..<gh {
            for i in 0..<gw {
                let idx = i + j * gw
                let count = histogram.counts[idx]
                if count <= 0 { continue }
                let c3 = whiteLevel * count                       // flam3 bucket[3]
                let ls = k1 * log(1 + c3 * k2) / c3                // rect.c:963
                let col = histogram.colors[idx] * whiteLevel       // flam3 bucket[0..2]
                accumRGB[idx] = col * ls
                accumA[idx] = c3 * ls
            }
        }

        // --- Stage 2: spatial filter (Gaussian, filters.c:217-269) ---
        let (fw, kernel) = makeSpatialKernel(oversample: oversample, radius: 0.5)

        // --- Stage 3: gamma output (rect.c:1167-1202, !earlyclip) ---
        let g = 1.0 / gamma
        let linrange = gammaThreshold

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // flam3 emits a fully opaque frame.
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }

        for oy in 0..<height {
            for ox in 0..<width {
                // Gather filter_width × filter_width accumulator cells, CENTERED on the
                // output pixel (flam3 uses a gutter so the kernel is centered; rect.c:1138).
                // For oversample=1, fw=3 → taps at offsets {-1, 0, +1} from (ox, oy).
                let halfFw = (fw - oversample) / 2   // gutter offset
                let gx0 = ox * oversample - halfFw
                let gy0 = oy * oversample - halfFw
                var tRGB = SIMD3<Float>.zero
                var tA: Float = 0
                for jj in 0..<fw {
                    for ii in 0..<fw {
                        let x = gx0 + ii, y = gy0 + jj
                        guard x >= 0, x < gw, y >= 0, y < gh else { continue }
                        let k = kernel[ii + jj * fw]
                        let idx = x + y * gw
                        tRGB += k * accumRGB[idx]
                        tA += k * accumA[idx]
                    }
                }
                if tA <= 0 { continue }   // rect.c:1171

                // rect.c:1169-1178
                let tmp = tA / prefilterWhite
                let alpha = calcAlpha(density: tmp, gamma: g, linrange: linrange)
                let ls2 = vibrancy * 256.0 * alpha / tmp           // rect.c:1176

                // rect.c:1181 + palettes.c:292 (calc_newrgb)
                let newrgb = calcNewRGB(cbuf: tRGB, ls: ls2, highpow: highlightPower)

                let base = (oy * width + ox) * 4
                for rgbi in 0..<3 {
                    // rect.c:1184-1187
                    var a = newrgb[rgbi]
                    a += (1 - vibrancy) * 256.0 * pow(tRGB[rgbi] / prefilterWhite, g)
                    a += (1 - alpha) * background[rgbi]
                    a = max(0, min(255, a))
                    pixels[base + rgbi] = UInt8(a.rounded())
                }
                // alpha channel already set to 255 above (opaque output)
            }
        }
        return RGBA8Image(width: width, height: height, pixels: pixels)
    }

    // MARK: - flam3 display math (palettes.c)

    /// `flam3_calc_alpha` (palettes.c:274-289).
    private static func calcAlpha(density: Float, gamma: Float, linrange: Float) -> Float {
        let dnorm = density
        let funcval = pow(linrange, gamma)
        if dnorm > 0 {
            if dnorm < linrange {
                let frac = dnorm / linrange
                return (1 - frac) * dnorm * (funcval / linrange) + frac * pow(dnorm, gamma)
            } else {
                return pow(dnorm, gamma)
            }
        }
        return 0
    }

    /// `flam3_calc_newrgb` (palettes.c:292-348). With the default `highlightPower = -1`
    /// the saturated-highlight branch is never taken and this reduces to
    /// `newrgb = ls · cbuf / PREFILTER_WHITE`; the full form is kept for parity.
    private static func calcNewRGB(cbuf: SIMD3<Float>, ls: Float, highpow: Float) -> SIMD3<Float> {
        if ls == 0 || (cbuf.x == 0 && cbuf.y == 0 && cbuf.z == 0) {
            return .zero
        }
        var maxa: Float = -1
        var maxc: Float = 0
        for rgbi in 0..<3 {
            let a = ls * (cbuf[rgbi] / prefilterWhite)
            if a > maxa { maxa = a; maxc = cbuf[rgbi] / prefilterWhite }
        }
        if maxa > 255 && highpow >= 0 {
            // Highlight anti-shift (palettes.c:318-332) — unreachable at default
            // highlightPower=-1, but kept for parity. HSV desaturation.
            let newls = 255.0 / maxc
            let lsratio = pow(newls / ls, highpow)
            var newrgb = SIMD3<Float>(newls * cbuf.x / prefilterWhite / 255.0,
                                      newls * cbuf.y / prefilterWhite / 255.0,
                                      newls * cbuf.z / prefilterWhite / 255.0)
            let h = rgb2hsv(newrgb)
            newrgb = hsv2rgb(SIMD3<Float>(h.x, h.y * lsratio, h.z))
            return newrgb * 255.0
        } else {
            let newls = 255.0 / maxc
            var adjhlp = -highpow
            if adjhlp > 1 { adjhlp = 1 }
            if maxa <= 255 { adjhlp = 1 }
            let blend = (1 - adjhlp) * newls + adjhlp * ls
            return SIMD3<Float>(blend * cbuf.x / prefilterWhite,
                                blend * cbuf.y / prefilterWhite,
                                blend * cbuf.z / prefilterWhite)
        }
    }
}

// MARK: - Spatial filter kernel (filters.c)

private func makeSpatialKernel(oversample: Int, radius: Float) -> (width: Int, coeffs: [Float]) {
    let support: Float = 1.5       // flam3_spatial_support[gaussian] (filters.c:31)
    let fwRaw = 2.0 * support * Float(oversample) * radius
    var fwidth = Int(fwRaw) + 1
    if ((fwidth ^ oversample) & 1) != 0 { fwidth += 1 }
    let adjust = fwRaw > 0 ? support * Float(fwidth) / fwRaw : 1.0

    var c = [Float](repeating: 0, count: fwidth * fwidth)
    var sum: Float = 0
    for i in 0..<fwidth {
        for j in 0..<fwidth {
            let ii = ((2.0 * Float(i) + 1.0) / Float(fwidth) - 1.0) * adjust
            let jj = ((2.0 * Float(j) + 1.0) / Float(fwidth) - 1.0) * adjust
            let v = gaussian(ii) * gaussian(jj)    // filters.c:259-260
            c[i + j * fwidth] = v
            sum += v
        }
    }
    if sum > 0 { for k in c.indices { c[k] /= sum } }   // normalize_vector
    return (fwidth, c)
}

/// `flam3_gaussian_filter` (filters.c:156-158).
private func gaussian(_ x: Float) -> Float {
    exp(-2.0 * x * x) * (2.0 / .pi).squareRoot()
}

// MARK: - HSV (for calc_newrgb highlight path; unused at default highlightPower)

private func rgb2hsv(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
    let mx = max(rgb.x, max(rgb.y, rgb.z))
    let mn = min(rgb.x, min(rgb.y, rgb.z))
    let d = mx - mn
    let s: Float = mx > 0 ? d / mx : 0
    var h: Float = 0
    if d > 0 {
        if mx == rgb.x {
            h = (rgb.y - rgb.z) / d
        } else if mx == rgb.y {
            h = (rgb.z - rgb.x) / d + 2
        } else {
            h = (rgb.x - rgb.y) / d + 4
        }
        h /= 6
        if h < 0 { h += 1 }
    }
    return SIMD3<Float>(h, s, mx)
}

private func hsv2rgb(_ hsv: SIMD3<Float>) -> SIMD3<Float> {
    let h6 = hsv.x * 6
    let c = hsv.y * hsv.z
    let x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1))
    let m = hsv.z - c
    let (r, g, b): (Float, Float, Float)
    switch h6 {
    case ..<1:   (r, g, b) = (c, x, 0)
    case ..<2:   (r, g, b) = (x, c, 0)
    case ..<3:   (r, g, b) = (0, c, x)
    case ..<4:   (r, g, b) = (0, x, c)
    case ..<5:   (r, g, b) = (x, 0, c)
    default:     (r, g, b) = (c, 0, x)
    }
    return SIMD3<Float>(r + m, g + m, b + m)
}
