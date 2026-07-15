import Foundation

public enum DensityEstimation {
    /// flam3-style adaptive kernel. radius==0 disables the filter (passthrough).
    public static func apply(_ hist: Histogram, radius: Float, minimum: Float, curve: Float) -> Histogram {
        guard radius > 0 else { return hist }
        var out = Histogram(gridWidth: hist.gridWidth, gridHeight: hist.gridHeight)
        let gw = hist.gridWidth, gh = hist.gridHeight
        let maxR = Int(radius.rounded(.up))
        for y in 0..<gh {
            for x in 0..<gw {
                let idx = hist.binIndex(x, y)
                let cnt = hist.counts[idx]
                if cnt <= 0 { continue }
                // adaptive radius: shrinks where dense, grows where sparse
                let adapt = radius * pow(minimum / (cnt + minimum), curve)
                let r = max(0, min(Float(maxR), adapt))
                let ri = Int(r.rounded(.up))
                let colorAvg = hist.colors[idx] / cnt
                var wsum: Float = 0
                var acc = SIMD3<Float>.zero
                for dy in -ri...ri {
                    for dx in -ri...ri {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < gw, ny >= 0, ny < gh else { continue }
                        let d2 = Float(dx*dx + dy*dy)
                        let w = max(0, 1 - (d2.squareRoot() / max(r, 1)))   // conical kernel
                        let ni = hist.binIndex(nx, ny)
                        let localAvg = hist.counts[ni] > 0 ? hist.colors[ni] / hist.counts[ni] : colorAvg
                        acc += localAvg * w
                        wsum += w
                    }
                }
                guard wsum > 0 else { out.counts[idx] = cnt; out.colors[idx] = colorAvg * cnt; continue }
                out.counts[idx] = cnt
                out.colors[idx] = (acc / wsum) * cnt
            }
        }
        return out
    }
}
