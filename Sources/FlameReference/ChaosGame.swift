import Foundation
import FlameKit

public enum ChaosGame {
    private static let fuse = 20
    private static let reseedEvery = 1024

    public static func iterate(flame: Flame, params: RenderParams) -> Histogram {
        let gw = params.gridWidth, gh = params.gridHeight
        var hist = Histogram(gridWidth: gw, gridHeight: gh)

        let weights = flame.xforms.map { max(0, $0.weight) }
        let totalW = weights.reduce(0, +)
        guard totalW > 0 else { return hist }
        let cum = prefixSums(weights)

        // Camera transform: world -> supersample-grid pixel.
        let cosR = cos(flame.camera.rotation * .pi / 180)
        let sinR = sin(flame.camera.rotation * .pi / 180)
        let pixelsPerUnit = flame.camera.scale * pow(2, flame.camera.zoom) * Float(params.oversample)
        let cx = flame.camera.center.x, cy = flame.camera.center.y

        var rng = PCG32(seed: params.seed, stream: 0x4d595df4d0f33173)
        var p = SIMD2<Float>(rng.nextFloat() * 2 - 1, rng.nextFloat() * 2 - 1)
        var colorT: Float = 0.5

        var produced = 0
        var sinceReseed = 0
        // Hard safety cap: a degenerate (non-contracting) genome could otherwise
        // loop forever trying to reach `totalSamples`. Allow 32× overshoot before
        // bailing; this never trips for well-formed flames.
        let hardCap = max(1, params.totalSamples) * 32
        var iterations = 0
        while produced < params.totalSamples && iterations < hardCap {
            iterations += 1
            // Scale the uniform draw into the (un-normalized) CDF range, otherwise
            // every xform after index 0 is never selected when sum(weights) > 1.
            let i = pickIndex(cdf: cum, r: rng.nextFloat() * totalW)
            let x = flame.xforms[i]
            p = applyXform(x, p, rng: &rng)
            if let fin = flame.finalXform { p = applyXform(fin, p, rng: &rng) }

            // color blend toward this xform's color index
            colorT = (1 - x.colorSpeed) * colorT + x.colorSpeed * x.color

            if !(p.x.isFinite && p.y.isFinite) {
                p = SIMD2<Float>(rng.nextFloat() * 2 - 1, rng.nextFloat() * 2 - 1)  // deterministic recovery
                continue
            }

            // world -> grid. Use floor (not Int truncation, which is wrong for
            // negative coordinates — a point at gx=-0.5 must NOT land in bin 0).
            let dx = p.x - cx, dy = p.y - cy
            let rx = dx * cosR - dy * sinR
            let ry = dx * sinR + dy * cosR
            let gx = rx * pixelsPerUnit + Float(gw) / 2
            let gy = ry * pixelsPerUnit + Float(gh) / 2

            sinceReseed += 1
            // Safe Int conversion: a diverging (non-contracting) genome can
            // produce grid coordinates far outside the Int representable range,
            // which would trap in `Int(gx)`. Guard in float space — such a bin
            // would be out of bounds anyway, so skipping is observationally
            // identical to the bounds check below.
            if gx.isFinite, gy.isFinite,
               abs(gx) <= Float(Int.max), abs(gy) <= Float(Int.max) {
                let u = Int(gx.rounded(.down)), v = Int(gy.rounded(.down))
                if sinceReseed > fuse, u >= 0, u < gw, v >= 0, v < gh {
                    let pal = samplePalette(flame.palette, t: colorT, hue: flame.hueShift)
                    let idx = hist[u, v]
                    hist.counts[idx] += 1
                    hist.colors[idx] += pal
                    produced += 1
                }
            }
            if sinceReseed > (fuse + reseedEvery) {
                p = SIMD2<Float>(rng.nextFloat() * 2 - 1, rng.nextFloat() * 2 - 1)
                sinceReseed = 0
            }
        }
        return hist
    }

    static func applyXform(_ x: Xform, _ p: SIMD2<Float>, rng: inout PCG32) -> SIMD2<Float> {
        let pre = x.affine.apply(p)
        let v = Variations.evaluate(x.variations, at: pre, rng: &rng)
        return x.postAffine.apply(v)
    }

    static func pickIndex(cdf: [Float], r: Float) -> Int {
        var lo = 0, hi = cdf.count - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if r < cdf[mid] { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    static func prefixSums(_ w: [Float]) -> [Float] {
        var s = [Float](); var acc: Float = 0
        for v in w { acc += v; s.append(acc) }
        return s
    }
}

/// Linear-interpolated palette sample at t∈[0,1] with optional hue rotation.
public func samplePalette(_ palette: Palette, t: Float, hue: Float) -> SIMD3<Float> {
    var tt = t + hue
    tt -= tt.rounded(.down)            // wrap to [0,1)
    let f = tt * 255
    let i0 = Int(f) & 255
    let i1 = (i0 + 1) & 255
    let frac = f - Float(i0)
    return palette.colors[i0] * (1 - frac) + palette.colors[i1] * frac
}
