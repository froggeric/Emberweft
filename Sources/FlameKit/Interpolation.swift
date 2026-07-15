import Foundation

/// Temporal genome interpolation following the flam3 convention.
///
/// Linear interpolation is used for affine coefficients, xform weights, color,
/// color-speed, opacity, and camera center/zoom/rotation. Camera `scale`
/// interpolates in log space (geometric mean at the midpoint), matching flam3.
public enum Interpolation {
    /// Interpolate two keyframe genomes at parameter `t ∈ [0,1]`.
    public static func interpolate(_ a: Flame, _ b: Flame, at t: Double) -> Flame {
        let tf = t
        var f = Flame()
        f.name = t < 0.5 ? a.name : b.name
        f.size = t < 0.5 ? a.size : b.size
        f.camera = Camera(
            center: lerp(a.camera.center, b.camera.center, tf),
            scale: pow(a.camera.scale, 1 - tf) * pow(b.camera.scale, tf),   // log-space
            zoom: (1 - tf) * a.camera.zoom + tf * b.camera.zoom,
            rotation: (1 - tf) * a.camera.rotation + tf * b.camera.rotation)
        f.quality = t < 0.5 ? a.quality : b.quality
        f.hueShift = (1 - tf) * a.hueShift + tf * b.hueShift
        f.time = (1 - t) * a.time + t * b.time
        f.palette = blendPalette(a.palette, b.palette, tf)

        let n = max(a.xforms.count, b.xforms.count)
        f.xforms = (0..<n).map { i in
            if i >= a.xforms.count { return b.xforms[i] }
            if i >= b.xforms.count { return a.xforms[i] }
            return interpolateXform(a.xforms[i], b.xforms[i], tf)
        }
        if let fa = a.finalXform, let fb = b.finalXform {
            f.finalXform = interpolateXform(fa, fb, tf)
        } else {
            f.finalXform = (a.finalXform ?? b.finalXform)
        }
        return f
    }

    private static func interpolateXform(_ a: Xform, _ b: Xform, _ t: Double) -> Xform {
        var x = Xform()
        x.weight = (1 - t) * a.weight + t * b.weight
        x.color = (1 - t) * a.color + t * b.color
        x.colorSpeed = (1 - t) * a.colorSpeed + t * b.colorSpeed
        x.opacity = (1 - t) * a.opacity + t * b.opacity
        x.affine = lerpAffine(a.affine, b.affine, t)
        x.postAffine = lerpAffine(a.postAffine, b.postAffine, t)
        x.variations = mergeVariations(a.variations, b.variations, t)
        x.chaos = (a.chaos != nil && b.chaos != nil)
            ? zip(a.chaos!, b.chaos!).map { (1 - t) * $0 + t * $1 } : (a.chaos ?? b.chaos)
        return x
    }

    private static func mergeVariations(_ a: [Variation], _ b: [Variation], _ t: Double) -> [Variation] {
        var byName = [String: Double]()
        for v in a { byName[v.name, default: 0] += (1 - t) * v.weight }
        for v in b { byName[v.name, default: 0] += t * v.weight }
        return byName
            .filter { $0.value != 0 }
            .sorted { $0.key < $1.key }
            .map { Variation(name: $0.key, weight: $0.value) }
    }

    private static func lerp(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ t: Double) -> SIMD2<Double> {
        a * (1 - t) + b * t
    }
    private static func lerpAffine(_ a: AffineTransform, _ b: AffineTransform, _ t: Double) -> AffineTransform {
        AffineTransform(a: (1-t)*a.a + t*b.a, b: (1-t)*a.b + t*b.b, c: (1-t)*a.c + t*b.c,
                        d: (1-t)*a.d + t*b.d, e: (1-t)*a.e + t*b.e, f: (1-t)*a.f + t*b.f)
    }
    private static func blendPalette(_ a: Palette, _ b: Palette, _ t: Double) -> Palette {
        Palette(colors: zip(a.colors, b.colors).map { $0 * (1 - t) + $1 * t })
    }
}
