import Foundation

/// Image-quality metrics used by the golden parity tests.
///
/// Pure functions over `RGBA8Image`; no I/O, no global state, deterministic.
public enum ImageComparison {
    /// Peak signal-to-noise ratio in decibels between two equally-sized images.
    /// Identical images have MSE 0 and return `.infinity`.
    public static func psnr(_ a: RGBA8Image, _ b: RGBA8Image) -> Float {
        precondition(a.width == b.width && a.height == b.height,
                     "ImageComparison.psnr requires equal dimensions")
        var mse: Float = 0
        let n = a.pixels.count
        for i in 0..<n {
            let d = Float(Int(a.pixels[i]) - Int(b.pixels[i]))
            mse += d * d
        }
        guard n > 0 else { return .infinity }
        mse /= Float(n)
        if mse == 0 { return .infinity }
        return 10 * log10((255 * 255) / mse)
    }

    /// Mean SSIM over an 8×8 non-overlapping block grid (coarse but stable and cheap).
    /// Converts each pixel to luma (Rec.601) before computing block statistics.
    public static func ssim(_ a: RGBA8Image, _ b: RGBA8Image) -> Float {
        precondition(a.width == b.width && a.height == b.height,
                     "ImageComparison.ssim requires equal dimensions")
        let c1: Float = (0.01 * 255) * (0.01 * 255)
        let c2: Float = (0.03 * 255) * (0.03 * 255)
        var sum: Float = 0
        var blocks = 0
        let bs = 8
        for by in stride(from: 0, to: a.height, by: bs) {
            for bx in stride(from: 0, to: a.width, by: bs) {
                var sa: Float = 0, sb: Float = 0, saa: Float = 0, sbb: Float = 0, sab: Float = 0
                var n = 0
                let ye = min(by + bs, a.height), xe = min(bx + bs, a.width)
                for y in by..<ye {
                    for x in bx..<xe {
                        let i = (y * a.width + x) * 4
                        let va = 0.299*Float(a.pixels[i])   + 0.587*Float(a.pixels[i+1]) + 0.114*Float(a.pixels[i+2])
                        let vb = 0.299*Float(b.pixels[i])   + 0.587*Float(b.pixels[i+1]) + 0.114*Float(b.pixels[i+2])
                        sa += va; sb += vb; saa += va*va; sbb += vb*vb; sab += va*vb; n += 1
                    }
                }
                guard n > 0 else { continue }
                let nf = Float(n)
                let mu1 = sa/nf, mu2 = sb/nf
                let var1 = saa/nf - mu1*mu1
                let var2 = sbb/nf - mu2*mu2
                let cov  = sab/nf - mu1*mu2
                let s = ((2*mu1*mu2 + c1) * (2*cov + c2)) /
                        ((mu1*mu1 + mu2*mu2 + c1) * (var1 + var2 + c2))
                sum += s
                blocks += 1
            }
        }
        return blocks > 0 ? sum / Float(blocks) : 1
    }
}
