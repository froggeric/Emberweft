import Foundation
import FlameKit

/// Centered (non-causal) box-window smoother for across-frame histogram flicker
/// (M6.1 slice 2, REVISED 2026-08-10). Replaces the causal `HistogramEMA`, which
/// suffered a startup transient (frame 0 emitted sharp; smoothing ramped in over
/// ~τ frames). The export is OFFLINE (stored video), so the industry-standard fix
/// is a non-causal centered filter: per output frame `m`, the smoothed histogram
/// is the uniform average over the centered window `[m−h, m+h]`, clipped at the
/// timeline boundaries `[0, N−1]`. This smooths from frame 1 with zero phase lag.
///
/// Streaming API. Frames are fed in order 0…N−1. To emit frame `m` the window must
/// reach `m+h` (look-ahead `h`), so `feed` emits frame `n−h` once frame `n ≥ h`
/// has been fed (latency `h`, irrelevant offline). After all `N` frames are fed,
/// `finish()` returns the trailing `h` frames whose windows are clipped at the end.
///
/// Boundary windows (the crux):
///   - frame 0          → avg [0, h]        (h+1 frames; clipped lower at 0)
///   - steady m         → avg [m−h, m+h]    (2h+1 frames; full window)
///   - end m (N−h…N−1)  → avg [m−h, N−1]    (shrinking; clipped upper at N−1)
///   - N ≤ h            → avg [0, N−1]      (every frame; clipped both ends)
///
/// Determinism (rule #2): a contiguous ring buffer + an elementwise running sum.
/// No `Dict`/`Set` float sums. Memory is bounded to `2h+1` buffer histograms + 1
/// running-sum histogram (`2h+2` total). `Histogram` has `accumulate` but no
/// `subtract`; `FlameKit` stays frozen, so eviction subtracts inline.
///
/// `halfWidth == 0` ⇒ smoothing OFF: `feed` emits each frame verbatim and
/// `finish()` is empty (T8′ routes `h == 0` to the existing byte-identical
/// `renderImage`).
public struct TemporalBoxWindow {
    private let halfWidth: Int
    private let total: Int
    private let gridWidth: Int
    private let gridHeight: Int
    private let capacity: Int            // 2h + 1

    /// Ring buffer of the last `capacity` fed histograms. Physical slot for the
    /// i-th valid element (oldest=0) is `(head + i) % capacity`. Grown lazily
    /// (append) during the fill phase; overwritten in place once full, so no
    /// large-histogram copies occur on eviction.
    private var buffer: [Histogram]
    private var head: Int                // physical slot of the oldest valid element
    private var bufferCount: Int         // valid elements (≤ capacity)
    private var runningSum: Histogram    // elementwise sum of the valid buffer
    private var fedCount: Int            // frames fed so far (0…N)

    public init(halfWidth: Int, total: Int, gridWidth: Int, gridHeight: Int) {
        precondition(halfWidth >= 0, "TemporalBoxWindow: halfWidth must be >= 0")
        precondition(total >= 0, "TemporalBoxWindow: total must be >= 0")
        self.halfWidth = halfWidth
        self.total = total
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.capacity = 2 * halfWidth + 1
        self.buffer = []
        self.buffer.reserveCapacity(self.capacity)
        self.head = 0
        self.bufferCount = 0
        self.runningSum = Histogram(gridWidth: gridWidth, gridHeight: gridHeight)
        self.fedCount = 0
    }

    /// Physical slot for the `i`-th valid (oldest-first) buffer element.
    /// `head == 0` throughout the fill phase, so this is just `i` until full.
    @inline(__always)
    private func slot(_ i: Int) -> Int { (head + i) % capacity }

    /// Feed the next frame's histogram (frames MUST be fed in order 0,1,…,N−1).
    /// Returns the smoothed frame `n − h` once `n ≥ h` (its centered window
    /// `[max(0, n−2h), n]` is exactly the current buffer); returns `nil` while
    /// `n < h` (look-ahead still filling).
    public mutating func feed(_ histogram: Histogram) -> (frameIndex: Int, smoothed: Histogram)? {
        precondition(gridWidth == histogram.gridWidth && gridHeight == histogram.gridHeight,
                     "TemporalBoxWindow.feed: grid dimension mismatch")
        let n = fedCount

        if bufferCount < capacity {
            // Fill phase: head stays 0, append at the tail (slot == bufferCount).
            buffer.append(histogram)
        } else {
            // Ring phase: evict the oldest (at `head`), subtract it from the
            // running sum, then overwrite its slot with the new frame.
            subtractInline(into: &runningSum, buffer[head])
            buffer[head] = histogram
            head = (head + 1) % capacity
        }
        addInline(into: &runningSum, histogram)
        bufferCount = min(bufferCount + 1, capacity)
        fedCount &+= 1

        if n >= halfWidth {
            let m = n - halfWidth
            return (m, scaledCopy(of: runningSum, by: 1.0 / Double(bufferCount)))
        }
        return nil
    }

    /// Call after all `total` frames have been fed. Returns the trailing frames
    /// (`total−h … total−1`, or all `total` if `total ≤ h`) whose windows are
    /// clipped at the end `[m−h, total−1]`, in ascending frameIndex order.
    ///
    /// Computed by reverse-accumulating suffixes of the buffer: frame `total−1`'s
    /// window is the last `h+1` buffer entries; frame `total−2`'s extends one
    /// further back; … Each suffix differs from the next by one element, so the
    /// reverse walk accumulates one element per step and emits the average. Bounded
    /// memory: only a single suffix-sum histogram is materialized.
    public mutating func finish() -> [(frameIndex: Int, smoothed: Histogram)] {
        let K = bufferCount
        guard K > 0 else { return [] }                 // nothing fed
        // Buffer holds frames [bufferStartFrame, total−1].
        let bufferStartFrame = total - K               // == max(0, total − capacity)
        // Trailing frames not yet emitted by feed (ascending): emittedCount … total−1,
        // where emittedCount == max(0, total − h). Walk them DESCENDING (total−1 … ),
        // accumulating a growing suffix, then reverse to ascending.
        let firstTrailing = max(0, total - halfWidth)

        // Reuse `runningSum`'s storage as the suffix accumulator (feeding is done,
        // so the whole-buffer sum is no longer needed). Keeps retained memory at
        // buffer (2h+1) + this one accumulator = 2h+2 histograms (the AC bound).
        runningSum = Histogram(gridWidth: gridWidth, gridHeight: gridHeight)
        var suffixCount = 0
        var idx = K - 1                                 // current buffer index to absorb
        var results: [(frameIndex: Int, smoothed: Histogram)] = []
        var m = total - 1
        while m >= firstTrailing {
            // Extend the suffix left until it reaches frame max(0, m − h).
            let lowerFrame = max(0, m - halfWidth)
            let lowerIdx = lowerFrame - bufferStartFrame
            while idx >= lowerIdx {
                addInline(into: &runningSum, buffer[slot(idx)])
                suffixCount += 1
                idx -= 1
            }
            results.append((m, scaledCopy(of: runningSum, by: 1.0 / Double(suffixCount))))
            m -= 1
        }
        return results.reversed()
    }

    // MARK: - Elementwise running-sum helpers (Histogram has no `subtract`)

    @inline(__always)
    private func addInline(into acc: inout Histogram, _ other: Histogram) {
        for i in 0..<acc.counts.count {
            acc.counts[i] += other.counts[i]
            acc.colors[i] += other.colors[i]
            acc.alpha[i]  += other.alpha[i]
        }
    }

    @inline(__always)
    private func subtractInline(into acc: inout Histogram, _ other: Histogram) {
        for i in 0..<acc.counts.count {
            acc.counts[i] -= other.counts[i]
            acc.colors[i] -= other.colors[i]
            acc.alpha[i]  -= other.alpha[i]
        }
    }

    /// A fresh histogram = `source * factor` (elementwise over counts/colors/alpha).
    private func scaledCopy(of source: Histogram, by factor: Double) -> Histogram {
        var out = Histogram(gridWidth: gridWidth, gridHeight: gridHeight)
        for i in 0..<out.counts.count {
            out.counts[i] = source.counts[i] * factor
            out.colors[i] = source.colors[i] * factor
            out.alpha[i]  = source.alpha[i]  * factor
        }
        return out
    }
}
