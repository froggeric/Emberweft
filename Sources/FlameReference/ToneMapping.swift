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

public enum ToneMapping {
    public static func render(histogram: Histogram, width: Int, height: Int, oversample: Int,
                              gamma: Float, gammaThreshold: Float, vibrancy: Float) -> RGBA8Image {
        let gw = histogram.gridWidth, gh = histogram.gridHeight
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let maxCount = histogram.counts.max() ?? 1
        let logMax = log(1 + maxCount)

        for oy in 0..<height {
            for ox in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0, n: Float = 0
                for sy in 0..<oversample {
                    for sx in 0..<oversample {
                        let gx = ox * oversample + sx
                        let gy = oy * oversample + sy
                        guard gx < gw, gy < gh else { continue }
                        let idx = histogram.binIndex(gx, gy)
                        let cnt = histogram.counts[idx]
                        if cnt <= 0 { continue }
                        let alpha = log(1 + cnt) / logMax
                        let color = histogram.colors[idx] / cnt
                        r += color.x * alpha
                        g += color.y * alpha
                        b += color.z * alpha
                        a += alpha
                        n += 1
                    }
                }
                guard n > 0, a > 0 else { continue }
                let ar = r / a, ag = g / a, ab = b / a
                let linA = a / n                       // average alpha in [0,1]
                let bytes = gammaCorrect(rgb: SIMD3(ar, ag, ab), alpha: linA,
                                         gamma: gamma, threshold: gammaThreshold, vibrancy: vibrancy)
                let base = (oy * width + ox) * 4
                pixels[base]   = clamp8(bytes.x)
                pixels[base+1] = clamp8(bytes.y)
                pixels[base+2] = clamp8(bytes.z)
                pixels[base+3] = 255
            }
        }
        return RGBA8Image(width: width, height: height, pixels: pixels)
    }

    private static func gammaCorrect(rgb: SIMD3<Float>, alpha: Float, gamma: Float,
                                     threshold: Float, vibrancy: Float) -> SIMD3<Float> {
        let ginv = 1 / gamma
        func channel(_ c: Float) -> Float {
            if alpha < threshold {
                // linear ramp below threshold (flam3 gamma_threshold behavior)
                return pow(c, ginv) * (alpha / threshold)
            }
            return vibrancy * pow(c, ginv) + (1 - vibrancy) * c
        }
        return SIMD3(channel(rgb.x), channel(rgb.y), channel(rgb.z))
    }
    private static func clamp8(_ x: Float) -> UInt8 {
        UInt8(max(0, min(255, x * 255)).rounded())
    }
}
