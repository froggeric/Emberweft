import XCTest
@testable import FlameExport
import FlameKit

/// T1′ — `TemporalBoxWindow` (centered box window, replaces the causal EMA).
///
/// The window math is the crux of the revision. Every test uses the `frameHist(_:)`
/// helper, which builds a histogram whose every channel equals the frame index `f`
/// (counts == f, colors == (f, 2f, 3f), alpha == f). The average of frames `a…b`
/// is then `(a+b)/2` per channel (arithmetic-sequence mean), which makes every
/// window average trivial to verify by hand against the spec's boundary rules:
///   - frame 0          → avg [0, h]            (h+1 frames; start boundary)
///   - steady m         → avg [m−h, m+h]        (2h+1 frames)
///   - end m (N−h…N−1)  → avg [m−h, N−1]        (shrinking; clipped upper)
///   - N ≤ h            → avg [0, N−1]          (every frame; clipped both ends)
final class TemporalBoxWindowTests: XCTestCase {

    /// Histogram whose counts==f, colors==(f,2f,3f), alpha==f (one row of `g` cells).
    private func frameHist(_ f: Double, gridWidth g: Int = 3) -> Histogram {
        var h = Histogram(gridWidth: g, gridHeight: 1)
        for i in 0..<g { h.counts[i] = f }
        h.colors = (0..<g).map { _ in SIMD3<Double>(f, f * 2, f * 3) }
        h.alpha = Array(repeating: f, count: g)
        return h
    }

    /// Assert every channel of `smoothed` equals `expected` (counts, colors, alpha).
    private func assertChannels(_ smoothed: Histogram, expected v: Double,
                                _ msg: @autoclosure () -> String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<smoothed.counts.count {
            XCTAssertEqual(smoothed.counts[i], v, accuracy: 1e-9, "counts[\(i)] " + msg(), file: file, line: line)
            XCTAssertEqual(smoothed.colors[i].x, v, accuracy: 1e-9, "colors[\(i)].x " + msg(), file: file, line: line)
            XCTAssertEqual(smoothed.colors[i].y, v * 2, accuracy: 1e-9, "colors[\(i)].y " + msg(), file: file, line: line)
            XCTAssertEqual(smoothed.colors[i].z, v * 3, accuracy: 1e-9, "colors[\(i)].z " + msg(), file: file, line: line)
            XCTAssertEqual(smoothed.alpha[i], v, accuracy: 1e-9, "alpha[\(i)] " + msg(), file: file, line: line)
        }
    }

    // MARK: - Start boundary (the whole point: smoothed from frame 0)

    func testFrame0IsAverageOfStartWindowNotRaw() {
        // h=2: frame 0's window = [0,2] → avg (0+2)/2 = 1.0 (NOT raw frame 0 == 0.0).
        var w = TemporalBoxWindow(halfWidth: 2, total: 6, gridWidth: 3, gridHeight: 1)
        XCTAssertNil(w.feed(frameHist(0)))   // n=0 < h → nil (look-ahead filling)
        XCTAssertNil(w.feed(frameHist(1)))   // n=1 < h → nil
        let emit = w.feed(frameHist(2))      // n=2 == h → emit frame 0
        XCTAssertEqual(emit?.frameIndex, 0)
        assertChannels(emit!.smoothed, expected: 1.0, "frame 0 must be avg[0,h]=1.0 not raw 0.0")
    }

    // MARK: - Steady state (full 2h+1 window)

    func testSteadyStateEmitsFullWindowAverage() {
        // h=2, feed frames 0…6. Frame 3 emits after feeding frame 5; window [1,5] → 3.0.
        var w = TemporalBoxWindow(halfWidth: 2, total: 7, gridWidth: 3, gridHeight: 1)
        var emits: [(Int, Double)] = []
        for f in 0...6 {
            if let e = w.feed(frameHist(Double(f))) { emits.append((e.frameIndex, e.smoothed.counts[0])) }
        }
        // Steady-state frame 3: window [1,5] → (1+5)/2 = 3.0
        let f3 = emits.first { $0.0 == 3 }
        XCTAssertNotNil(f3)
        XCTAssertEqual(f3!.1, 3.0, accuracy: 1e-9, "steady frame 3 window [1,5] must average 3.0")
        // Full window width confirmed: frame 3 window [1,5] is 5 == 2h+1 frames.
    }

    // MARK: - End shrink (finish)

    func testFinishReturnsEndShrinkingWindows() {
        // N=6, h=2. feed emits frames 0,1,2,3; finish() returns 4,5.
        // frame 5 window [3,5] → (3+5)/2 = 4.0 ; frame 4 window [2,5] → (2+5)/2 = 3.5.
        var w = TemporalBoxWindow(halfWidth: 2, total: 6, gridWidth: 3, gridHeight: 1)
        for f in 0..<6 { _ = w.feed(frameHist(Double(f))) }
        let trailing = w.finish()
        XCTAssertEqual(trailing.map(\.frameIndex), [4, 5], "finish must return trailing h frames in ascending order")
        assertChannels(trailing[0].smoothed, expected: 3.5, "frame 4 window [2,5] → 3.5")
        assertChannels(trailing[1].smoothed, expected: 4.0, "frame 5 window [3,5] → 4.0")
    }

    // MARK: - N ≤ h (export shorter than the window)

    func testTotalLEHalfWidthClipsEveryFrame() {
        // N=2, h=5: feed emits nothing; finish() returns 0,1 both = avg[0,1] = 0.5.
        var w = TemporalBoxWindow(halfWidth: 5, total: 2, gridWidth: 3, gridHeight: 1)
        XCTAssertNil(w.feed(frameHist(0)))
        XCTAssertNil(w.feed(frameHist(1)))
        let trailing = w.finish()
        XCTAssertEqual(trailing.map(\.frameIndex), [0, 1])
        assertChannels(trailing[0].smoothed, expected: 0.5, "frame 0 = avg[0,1] = 0.5")
        assertChannels(trailing[1].smoothed, expected: 0.5, "frame 1 = avg[0,1] = 0.5 (symmetric)")
    }

    func testTotalEqualsHalfWidth() {
        // N == h boundary: N=3, h=3. feed emits nothing (n < 3 for all). finish() = all 3.
        // every frame window = [0,2] → avg 1.0.
        var w = TemporalBoxWindow(halfWidth: 3, total: 3, gridWidth: 3, gridHeight: 1)
        for f in 0..<3 { XCTAssertNil(w.feed(frameHist(Double(f)))) }
        let trailing = w.finish()
        XCTAssertEqual(trailing.map(\.frameIndex), [0, 1, 2])
        for t in trailing { assertChannels(t.smoothed, expected: 1.0) }
    }

    // MARK: - h == 0 (smoothing OFF → identity)

    func testHalfWidthZeroIsIdentityFeed() {
        // h=0: every feed emits that same frame unchanged, finish() is empty.
        var w = TemporalBoxWindow(halfWidth: 0, total: 4, gridWidth: 3, gridHeight: 1)
        for f in 0..<4 {
            let e = w.feed(frameHist(Double(f)))
            XCTAssertEqual(e?.frameIndex, f)
            assertChannels(e!.smoothed, expected: Double(f), "h=0 must emit frame verbatim (OFF)")
        }
        XCTAssertTrue(w.finish().isEmpty, "h=0 finish() must be empty (all frames emitted by feed)")
    }

    // MARK: - Feed/emit ordering & coverage (no gaps, no dups, ascending)

    func testFeedEmitProducesAscendingContiguousFrameIndices() {
        // h=2, N=10. All 10 frames must emit exactly once across feed + finish,
        // in ascending order, with the h-frame latency.
        var w = TemporalBoxWindow(halfWidth: 2, total: 10, gridWidth: 3, gridHeight: 1)
        var feedEmits: [Int] = []
        for f in 0..<10 {
            if let e = w.feed(frameHist(Double(f))) { feedEmits.append(e.frameIndex) }
        }
        let finishEmits = w.finish().map(\.frameIndex)
        // feed emits frames 0…7 (after h-frame latency); finish emits 8,9.
        XCTAssertEqual(feedEmits, Array(0...7), "feed must emit 0…N−1−h ascending")
        XCTAssertEqual(finishEmits, [8, 9], "finish must emit N−h…N−1 ascending")
        let all = feedEmits + finishEmits
        XCTAssertEqual(all, Array(0..<10), "every frame emitted exactly once, contiguously, ascending")
    }

    // MARK: - Determinism (rule #2)

    func testDeterministicAcrossInstances() {
        func run() -> [(Int, Double)] {
            var w = TemporalBoxWindow(halfWidth: 3, total: 9, gridWidth: 3, gridHeight: 1)
            var out: [(Int, Double)] = []
            for f in 0..<9 {
                if let e = w.feed(frameHist(Double(f))) { out.append((e.frameIndex, e.smoothed.counts[0])) }
            }
            for e in w.finish() { out.append((e.frameIndex, e.smoothed.counts[0])) }
            return out
        }
        let a = run()
        let b = run()
        XCTAssertEqual(a.count, b.count)
        for i in a.indices {
            XCTAssertEqual(a[i].0, b[i].0)
            XCTAssertEqual(a[i].1, b[i].1, accuracy: 0.0, "must be bit-stable across instances")
        }
    }

    // MARK: - Eviction correctness (running-sum add/subtract)

    func testEvictionKeepsRunningSumConsistent() {
        // h=1 (window 3). feed 0,1,2,3,4,5. Steady frame 2 window [1,3] → 2.0;
        // frame 3 window [2,4] → 3.0. Confirms oldest is subtracted on eviction.
        var w = TemporalBoxWindow(halfWidth: 1, total: 6, gridWidth: 3, gridHeight: 1)
        var emits: [Int: Double] = [:]
        for f in 0..<6 {
            if let e = w.feed(frameHist(Double(f))) { emits[e.frameIndex] = e.smoothed.counts[0] }
        }
        // frame 0: window [0,1] → 0.5 (start boundary, h+1=2 frames)
        XCTAssertEqual(emits[0]!, 0.5, accuracy: 1e-9)
        // frame 1: window [0,2] → 1.0 (still filling, 3 frames)
        XCTAssertEqual(emits[1]!, 1.0, accuracy: 1e-9)
        // frame 2: window [1,3] → 2.0 (steady, full 2h+1=3)
        XCTAssertEqual(emits[2]!, 2.0, accuracy: 1e-9, "eviction must subtract frame 0 here")
        // frame 3: window [2,4] → 3.0 (steady; eviction of frame 1 verified)
        XCTAssertEqual(emits[3]!, 3.0, accuracy: 1e-9)
        // frame 4: window [3,5] → 4.0
        XCTAssertEqual(emits[4]!, 4.0, accuracy: 1e-9)
        let trailing = w.finish()
        // frame 5: window [4,5] → 4.5 (end shrink, h+1=2 frames)
        XCTAssertEqual(trailing.map(\.frameIndex), [5])
        XCTAssertEqual(trailing[0].smoothed.counts[0], 4.5, accuracy: 1e-9)
    }

    // MARK: - halfWidth(for:) mapping

    func testHalfWidthMapping() {
        // off / genome → 0 (OFF). ON (.spp) tiers use the UNIFORM centeredHalfWidth
        // (= 5), decoupled from α/spp (RETUNED 2026-08-11; was round(1/α) from a
        // ramp, which gave 10/5/3 for spp 2/8/30 and clamped to 0 at spp ≥ 64).
        XCTAssertEqual(TemporalSmoothing.off.halfWidth(for: .genome), 0)
        XCTAssertEqual(TemporalSmoothing.off.halfWidth(for: .spp(2)), 0)
        XCTAssertEqual(TemporalSmoothing.auto.halfWidth(for: .genome), 0)
        XCTAssertEqual(TemporalSmoothing.centeredHalfWidth, 5)
        // Every .spp tier → uniform h = centeredHalfWidth = 5 (no spp≥64 OFF clamp).
        XCTAssertEqual(TemporalSmoothing.auto.halfWidth(for: .spp(2)), 5)
        XCTAssertEqual(TemporalSmoothing.auto.halfWidth(for: .spp(8)), 5)
        XCTAssertEqual(TemporalSmoothing.auto.halfWidth(for: .spp(30)), 5)
        XCTAssertEqual(TemporalSmoothing.auto.halfWidth(for: .spp(64)), 5)
        XCTAssertEqual(TemporalSmoothing.auto.halfWidth(for: .spp(100)), 5)   // new High tier
        XCTAssertEqual(TemporalSmoothing.auto.halfWidth(for: .spp(128)), 5)
        XCTAssertEqual(TemporalSmoothing.auto.halfWidth(for: .spp(200)), 5)
    }

    // MARK: - Empty / degenerate

    func testEmptyTotalFinishIsEmpty() {
        var w = TemporalBoxWindow(halfWidth: 2, total: 0, gridWidth: 3, gridHeight: 1)
        XCTAssertTrue(w.finish().isEmpty)
    }

    func testTotalOneEmitsFromFinish() {
        // N=1, h=2: feed emits nil; finish returns frame 0 = avg[0,0] = 0.0 (just itself).
        var w = TemporalBoxWindow(halfWidth: 2, total: 1, gridWidth: 3, gridHeight: 1)
        let e = w.feed(frameHist(7))
        XCTAssertNil(e)
        let trailing = w.finish()
        XCTAssertEqual(trailing.map(\.frameIndex), [0])
        assertChannels(trailing[0].smoothed, expected: 7.0, "single frame → itself")
    }
}
