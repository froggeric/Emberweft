import Foundation
import Metal
import FlameKit

/// Nonisolated host-side decode for the Stage-1 chaos-game atomic histogram.
///
/// Extracted verbatim from `ChaosGameMetal.decode` so that both the
/// `@MainActor`-isolated `ChaosGameMetal.iterate` and the off-main temporal
/// smoothing readback core (T6) share the SAME parity-proven decode path. This
/// is pure host work (pointer read + per-bin Double conversion) — no Metal
/// command recording, no actor-isolated state — so the enum is naturally
/// nonisolated and safe to call from any context under Swift 6 strict
/// concurrency.
enum MetalHistogramDecode {

    /// Host mirror of MSL `AtomicBin` (5×uint32 per bin). Layout must match the
    /// device struct field-for-field; both are 5 × 4 bytes, 4-byte aligned.
    struct AtomicBinHost {
        var count: UInt32 = 0
        var r: UInt32 = 0
        var g: UInt32 = 0
        var b: UInt32 = 0
        var a: UInt32 = 0
    }

    /// Read the flat `AtomicBin` array and divide r/g/b/a by `colorScale` to
    /// recover dmap-units Doubles matching CPU `hist.colors`/`alpha`. `counts`
    /// are exact (1 per hit).
    static func decode(histBuf: MTLBuffer, binCount: Int,
                       gridWidth: Int, gridHeight: Int,
                       colorScale: Double) -> Histogram {
        var hist = Histogram(gridWidth: gridWidth, gridHeight: gridHeight)
        let bins = histBuf.contents().assumingMemoryBound(to: AtomicBinHost.self)
        let invScale = 1.0 / colorScale
        for i in 0..<binCount {
            let bin = bins[i]
            hist.counts[i] = Double(bin.count)
            hist.colors[i] = SIMD3(Double(bin.r) * invScale,
                                   Double(bin.g) * invScale,
                                   Double(bin.b) * invScale)
            hist.alpha[i] = Double(bin.a) * invScale
        }
        return hist
    }
}
