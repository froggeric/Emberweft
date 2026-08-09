import Foundation
import FlameKit

/// Across-frame histogram EMA (M6.1 slice 2). Pure + deterministic (rule #2:
/// iterates contiguous `Histogram` arrays — no Dict/Set float sums). Shared by
/// the CPU and Metal smoothing paths, both of which produce/consume a Double
/// `Histogram`. Lives in `FlameExport` (NOT `FlameKit`) so the `animate`
/// PNG-mastering path — which has no `FlameExport` dependency — can never reach
/// it, preserving animate↔export byte-identity.
public enum HistogramEMA {
    /// In-place EMA: `acc = (1−α)·acc + α·current`.
    ///
    /// - Cold start (`acc == nil`) ⇒ `acc = current` (the first rendered frame
    ///   is shown sharp; pinned byte-equal to the OFF path for frame 0). This is
    ///   a copy, NOT a zero-biased blend.
    /// - α = 1.0 ⇒ `acc` becomes `current` exactly (OFF equivalence).
    /// - α = 0.0 ⇒ `acc` is frozen exactly (0.0 and 1.0 multiplies are exact
    ///   for finite Doubles, so neither boundary introduces FP error).
    ///
    /// Mutates through `acc!` so only the single `inout` value-type writeback
    /// occurs — no second full copy of the (up to ~332 MB at 4K) histogram.
    public static func update(_ acc: inout Histogram?, current: Histogram, alpha: Double) {
        if acc == nil { acc = current; return }
        precondition(acc!.colors.count == current.colors.count
                     && acc!.alpha.count == current.alpha.count
                     && acc!.counts.count == current.counts.count,
                     "HistogramEMA.update: grid dimension mismatch")
        let oneMinusA = 1.0 - alpha
        let n = acc!.counts.count
        for i in 0..<n {
            acc!.counts[i]  = acc!.counts[i]  * oneMinusA + current.counts[i]  * alpha
            acc!.colors[i]  = acc!.colors[i]  * oneMinusA + current.colors[i]  * alpha
            acc!.alpha[i]   = acc!.alpha[i]   * oneMinusA + current.alpha[i]   * alpha
        }
    }
}
