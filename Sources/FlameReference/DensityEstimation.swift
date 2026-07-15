import Foundation

public enum DensityEstimation {
    /// M1 density-estimation approximation.
    ///
    /// This is NOT flam3's density estimator. It performs a per-bin adaptive-kernel
    /// smoothing of the AVERAGE bin color (shrinking the kernel where a bin is dense,
    /// growing it where sparse) and writes the smoothed color back to the SAME bin,
    /// scaled by that bin's (unchanged) count. It does NOT convolve energy into
    /// neighboring output bins, so an isolated non-zero bin is left effectively
    /// unchanged. `radius == 0` is an exact passthrough.
    ///
    /// Count mass is preserved exactly (out.counts == hist.counts for populated bins).
    /// Color mass is approximately preserved for smooth fields but is NOT guaranteed
    /// within 5% at high-contrast boundaries.
    ///
    /// TODO(M2): replace with true flam3 density estimation (energy convolution into
    /// neighbor bins), implemented once and shared with the Metal renderer. The frozen
    /// golden genomes all set estimator_radius="0", so this approximation does not
    /// affect oracle parity today.
    public static func apply(_ hist: Histogram, radius: Double, minimum: Double, curve: Double) -> Histogram {
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
                let r = max(0, min(Double(maxR), adapt))
                let ri = Int(r.rounded(.up))
                let colorAvg = hist.colors[idx] / cnt
                let alphaAvg = hist.alpha[idx] / cnt
                var wsum: Double = 0
                var acc = SIMD3<Double>.zero
                var accA: Double = 0
                for dy in -ri...ri {
                    for dx in -ri...ri {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < gw, ny >= 0, ny < gh else { continue }
                        let d2 = Double(dx*dx + dy*dy)
                        let w = max(0, 1 - (d2.squareRoot() / max(r, 1)))   // conical kernel
                        let ni = hist.binIndex(nx, ny)
                        let populated = hist.counts[ni] > 0
                        let localAvg = populated ? hist.colors[ni] / hist.counts[ni] : colorAvg
                        acc += localAvg * w
                        accA += (populated ? hist.alpha[ni] / hist.counts[ni] : alphaAvg) * w
                        wsum += w
                    }
                }
                guard wsum > 0 else {
                    out.counts[idx] = cnt
                    out.colors[idx] = colorAvg * cnt
                    out.alpha[idx] = alphaAvg * cnt
                    continue
                }
                out.counts[idx] = cnt
                out.colors[idx] = (acc / wsum) * cnt
                out.alpha[idx] = (accA / wsum) * cnt
            }
        }
        return out
    }
}
