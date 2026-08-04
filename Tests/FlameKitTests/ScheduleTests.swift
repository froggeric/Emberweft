import XCTest
@testable import FlameKit

// Tests for Task 15: PairSelector (Sequential) + Schedule (two-level seek).
//
// Frame-counting convention (pinned, off-by-one hazard):
//   segmentId = globalFrame / N
//   local     = globalFrame % N
//   blend     = Double(local + 1) / Double(N)   // 1-indexed; blend ∈ (0,1]; NEVER 0
// Total PNGs emitted over k segments = k * N (no duplicate/drop at boundaries).
final class ScheduleTests: XCTestCase {

    // MARK: - Loop→transition boundary (flam3 seqflag shortcut routing)

    /// The loop→transition boundary is the first frame of each transition segment
    /// (globalFrame % N == 0 with kind == .transition). Callers render the
    /// fromSheep genome directly here, porting flam3's `seqflag && blend==0`
    /// shortcut (flam3.c:476-477). For N=8: seg0 loop = frames 0..7, seg1
    /// transition = frames 8..15 (frame 8 is a boundary), seg2 loop = 16..23,
    /// seg3 transition = 24..31 (frame 24 is a boundary).
    func testLoopToTransitionBoundary() {
        let sched = Schedule(librarySize: 4, framesPerSegment: 8,
                             selector: Sequential(seed: 42), seed: 42)
        // Loop-segment first frames are NOT boundaries.
        XCTAssertFalse(sched.isLoopToTransitionBoundary(globalFrame: 0), "seg0 loop start")
        XCTAssertFalse(sched.isLoopToTransitionBoundary(globalFrame: 16), "seg2 loop start")
        // Interior loop / transition frames are NOT boundaries.
        XCTAssertFalse(sched.isLoopToTransitionBoundary(globalFrame: 3), "mid seg0 loop")
        XCTAssertFalse(sched.isLoopToTransitionBoundary(globalFrame: 10), "mid seg1 transition")
        XCTAssertFalse(sched.isLoopToTransitionBoundary(globalFrame: 15), "seg1 last frame")
        // Transition-segment first frames ARE boundaries.
        XCTAssertTrue(sched.isLoopToTransitionBoundary(globalFrame: 8), "seg1 transition start")
        XCTAssertTrue(sched.isLoopToTransitionBoundary(globalFrame: 24), "seg3 transition start")
    }

    // MARK: - N=8 ladder pin (the load-bearing off-by-one check)

    // Segment 0 emits blends {1/8, 2/8, ..., 8/8 = 1.0} over global frames 0..7.
    func testN8Segment0Ladder() {
        let sched = Schedule(librarySize: 4, framesPerSegment: 8,
                             selector: Sequential(seed: 42), seed: 42)
        for local in 0..<8 {
            let m = sched.frameToBlend(globalFrame: local)
            XCTAssertEqual(m.segmentId, 0, "local=\(local)")
            XCTAssertEqual(m.kind, .loop, "seg0 should be a loop")
            XCTAssertEqual(m.blend, Double(local + 1) / 8.0, accuracy: 1e-9, "local=\(local)")
        }
        // Boundary frames: last frame of seg0 is blend=1.0, first of seg1 is 1/8.
        XCTAssertEqual(sched.frameToBlend(globalFrame: 7).blend, 1.0, accuracy: 1e-9)
        XCTAssertEqual(sched.frameToBlend(globalFrame: 8).segmentId, 1)
        XCTAssertEqual(sched.frameToBlend(globalFrame: 8).blend, 1.0 / 8.0, accuracy: 1e-9)
    }

    // Segment 1 walks the same ladder over global frames 8..15.
    func testN8Segment1Ladder() {
        let sched = Schedule(librarySize: 4, framesPerSegment: 8,
                             selector: Sequential(seed: 42), seed: 42)
        for local in 0..<8 {
            let m = sched.frameToBlend(globalFrame: 8 + local)
            XCTAssertEqual(m.segmentId, 1, "local=\(local)")
            XCTAssertEqual(m.kind, .transition, "seg1 should be a transition")
            XCTAssertEqual(m.blend, Double(local + 1) / 8.0, accuracy: 1e-9, "local=\(local)")
        }
    }

    // blend = 0 must NEVER appear for any emitted frame.
    func testBlendNeverZero() {
        let N = 8
        let sched = Schedule(librarySize: 4, framesPerSegment: N,
                             selector: Sequential(seed: 42), seed: 42)
        for f in 0..<(3 * N) {
            XCTAssertGreaterThan(sched.frameToBlend(globalFrame: f).blend, 0.0, "frame \(f)")
        }
    }

    // Total frames for 3 segments = 24 (= 3*8), NOT 25 or 17.
    func testTotalFramesThreeSegments() {
        let sched = Schedule(librarySize: 4, framesPerSegment: 8,
                             selector: Sequential(seed: 42), seed: 42)
        XCTAssertEqual(sched.totalFrames(segmentCount: 3), 24)
        XCTAssertNotEqual(sched.totalFrames(segmentCount: 3), 25)
        XCTAssertNotEqual(sched.totalFrames(segmentCount: 3), 17)
    }

    // MARK: - Tier spot-checks N = 160 / 320 / 900

    func testTierN160() {
        let N = 160
        let sched = Schedule(librarySize: 10, framesPerSegment: N,
                             selector: Sequential(seed: 7), seed: 7)
        // First frame of segment 0.
        var m = sched.frameToBlend(globalFrame: 0)
        XCTAssertEqual(m.segmentId, 0)
        XCTAssertEqual(m.blend, 1.0 / Double(N), accuracy: 1e-12)
        // A frame well into segment 0.
        m = sched.frameToBlend(globalFrame: 100)
        XCTAssertEqual(m.segmentId, 0)
        XCTAssertEqual(m.blend, 101.0 / Double(N), accuracy: 1e-12)
        // First frame of segment 1.
        m = sched.frameToBlend(globalFrame: N)
        XCTAssertEqual(m.segmentId, 1)
        XCTAssertEqual(m.blend, 1.0 / Double(N), accuracy: 1e-12)
        // Last frame of segment 1 = blend 1.0.
        m = sched.frameToBlend(globalFrame: 2 * N - 1)
        XCTAssertEqual(m.segmentId, 1)
        XCTAssertEqual(m.blend, 1.0, accuracy: 1e-12)
    }

    func testTierN320() {
        let N = 320
        let sched = Schedule(librarySize: 6, framesPerSegment: N,
                             selector: Sequential(seed: 7), seed: 7)
        let m = sched.frameToBlend(globalFrame: N + 5)
        XCTAssertEqual(m.segmentId, 1)
        XCTAssertEqual(m.blend, 6.0 / Double(N), accuracy: 1e-12)
    }

    func testTierN900() {
        let N = 900
        let sched = Schedule(librarySize: 12, framesPerSegment: N,
                             selector: Sequential(seed: 7), seed: 7)
        // Frame at the boundary between seg 2 and seg 3.
        let lastOfSeg2 = sched.frameToBlend(globalFrame: 3 * N - 1)
        XCTAssertEqual(lastOfSeg2.segmentId, 2)
        XCTAssertEqual(lastOfSeg2.blend, 1.0, accuracy: 1e-12)
        let firstOfSeg3 = sched.frameToBlend(globalFrame: 3 * N)
        XCTAssertEqual(firstOfSeg3.segmentId, 3)
        XCTAssertEqual(firstOfSeg3.blend, 1.0 / Double(N), accuracy: 1e-12)
    }

    // MARK: - Alternation invariant over a 50-segment prefix

    func testAlternationNoTwoTransitionsAdjacent() {
        var sched = Schedule(librarySize: 5, framesPerSegment: 8,
                             selector: Sequential(seed: 99), seed: 99)
        var prev: Segment.Kind = .loop
        for id in 0..<50 {
            let seg = sched.segment(at: id)
            XCTAssertEqual(seg.id, id)
            if id == 0 {
                XCTAssertEqual(seg.kind, .loop)
            } else {
                XCTAssertFalse(prev == .transition && seg.kind == .transition,
                               "two consecutive transitions at seg \(id-1) and \(id)")
            }
            // Even ids are loops, odd ids are transitions (documented scheme).
            XCTAssertEqual(seg.kind, id.isMultiple(of: 2) ? .loop : .transition,
                           "seg \(id)")
            prev = seg.kind
        }
    }

    // MARK: - Sequential reproducibility under fixed seed

    func testSequentialReproducibleUnderFixedSeed() {
        var a = Schedule(librarySize: 7, framesPerSegment: 8,
                         selector: Sequential(seed: 1234), seed: 1234)
        var b = Schedule(librarySize: 7, framesPerSegment: 8,
                         selector: Sequential(seed: 1234), seed: 1234)
        var aWalk: [Segment] = []
        var bWalk: [Segment] = []
        for id in 0..<50 {
            aWalk.append(a.segment(at: id))
            bWalk.append(b.segment(at: id))
        }
        XCTAssertEqual(aWalk, bWalk, "same seed must yield identical 50-segment walk")
    }

    // The Sequential walk visits sheep in a fixed, library-cyclic order.
    func testSequentialVisitsSheepInFixedCyclicOrder() {
        let librarySize = 4
        var sched = Schedule(librarySize: librarySize, framesPerSegment: 8,
                             selector: Sequential(seed: 1), seed: 1)
        XCTAssertEqual(sched.segment(at: 0), Segment(id: 0, kind: .loop,
            fromSheep: 0, toSheep: 0, framesPerSegment: 8))
        XCTAssertEqual(sched.segment(at: 1), Segment(id: 1, kind: .transition,
            fromSheep: 0, toSheep: 1, framesPerSegment: 8))
        XCTAssertEqual(sched.segment(at: 2), Segment(id: 2, kind: .loop,
            fromSheep: 1, toSheep: 1, framesPerSegment: 8))
        XCTAssertEqual(sched.segment(at: 3), Segment(id: 3, kind: .transition,
            fromSheep: 1, toSheep: 2, framesPerSegment: 8))
        XCTAssertEqual(sched.segment(at: 7), Segment(id: 7, kind: .transition,
            fromSheep: 3, toSheep: 0, framesPerSegment: 8))
        // Wraps around: seg 8 loops sheep 0 again.
        XCTAssertEqual(sched.segment(at: 8), Segment(id: 8, kind: .loop,
            fromSheep: 0, toSheep: 0, framesPerSegment: 8))
    }

    // Loop segments have fromSheep == toSheep; transitions differ.
    func testLoopAndTransitionShape() {
        var sched = Schedule(librarySize: 5, framesPerSegment: 4,
                             selector: Sequential(seed: 1), seed: 1)
        for id in 0..<20 {
            let seg = sched.segment(at: id)
            XCTAssertEqual(seg.framesPerSegment, 4)
            if seg.kind == .loop {
                XCTAssertEqual(seg.fromSheep, seg.toSheep, "loop seg \(id)")
            } else {
                XCTAssertNotEqual(seg.fromSheep, seg.toSheep, "transition seg \(id)")
            }
        }
    }

    // MARK: - Separate loop/transition frame counts (shorter edges)

    // Segments carry their OWN framesPerSegment: loops use `framesPerSegment`,
    // transitions use `transitionFramesPerSegment` (the per-kind N).
    func testPerSegmentFramesPerSegmentVariable() {
        var sched = Schedule(librarySize: 4, framesPerSegment: 8,
                             transitionFramesPerSegment: 4,
                             selector: Sequential(seed: 1), seed: 1)
        for id in 0..<10 {
            let seg = sched.segment(at: id)
            if seg.kind == .loop {
                XCTAssertEqual(seg.framesPerSegment, 8, "loop seg \(id) must use loop N")
            } else {
                XCTAssertEqual(seg.framesPerSegment, 4, "transition seg \(id) must use transition N")
            }
        }
    }

    // Pair math (L=8, T=4): pairFrames=12. seg0 loop = frames 0..7, seg1 trans =
    // frames 8..11, seg2 loop = frames 12..19, seg3 trans = frames 20..23.
    func testPairMathVariableTransitionCount() {
        let sched = Schedule(librarySize: 4, framesPerSegment: 8,
                             transitionFramesPerSegment: 4,
                             selector: Sequential(seed: 1), seed: 1)
        // seg0 loop: frames 0..7
        for local in 0..<8 {
            let m = sched.frameToBlend(globalFrame: local)
            XCTAssertEqual(m.segmentId, 0, "local=\(local)")
            XCTAssertEqual(m.kind, .loop)
            XCTAssertEqual(m.blend, Double(local + 1) / 8.0, accuracy: 1e-9, "local=\(local)")
        }
        // seg1 transition: frames 8..11
        for local in 0..<4 {
            let m = sched.frameToBlend(globalFrame: 8 + local)
            XCTAssertEqual(m.segmentId, 1, "local=\(local)")
            XCTAssertEqual(m.kind, .transition)
            XCTAssertEqual(m.blend, Double(local + 1) / 4.0, accuracy: 1e-9, "local=\(local)")
        }
        // seg2 loop: frames 12..19
        for local in 0..<8 {
            let m = sched.frameToBlend(globalFrame: 12 + local)
            XCTAssertEqual(m.segmentId, 2, "local=\(local)")
            XCTAssertEqual(m.kind, .loop)
            XCTAssertEqual(m.blend, Double(local + 1) / 8.0, accuracy: 1e-9, "local=\(local)")
        }
        // seg3 transition: frames 20..23
        for local in 0..<4 {
            let m = sched.frameToBlend(globalFrame: 20 + local)
            XCTAssertEqual(m.segmentId, 3, "local=\(local)")
            XCTAssertEqual(m.kind, .transition)
            XCTAssertEqual(m.blend, Double(local + 1) / 4.0, accuracy: 1e-9, "local=\(local)")
        }
    }

    // Trailing loop: segmentCount=5 (ends on loop seg 4). Total = 3*8 + 2*4 = 32.
    // The final loop (seg 4) occupies frames [28, 32); frame 31 is blend 8/8=1.0.
    func testTrailingLoopMapsCorrectly() {
        let sched = Schedule(librarySize: 4, framesPerSegment: 8,
                             transitionFramesPerSegment: 4,
                             selector: Sequential(seed: 1), seed: 1)
        // frameOffset: seg 4 starts at frameOffset(ofSegment: 4) = 2*8 + 2*4 = 24.
        XCTAssertEqual(sched.frameOffset(ofSegment: 4), 24)
        XCTAssertEqual(sched.totalFrames(segmentCount: 5), 32)
        // seg4 loop: frames 24..31
        for local in 0..<8 {
            let m = sched.frameToBlend(globalFrame: 24 + local)
            XCTAssertEqual(m.segmentId, 4, "local=\(local) — trailing loop must map to seg 4")
            XCTAssertEqual(m.kind, .loop, "local=\(local)")
            XCTAssertEqual(m.blend, Double(local + 1) / 8.0, accuracy: 1e-9, "local=\(local)")
        }
        // Last frame of the timeline (frame 31) = blend 1.0.
        XCTAssertEqual(sched.frameToBlend(globalFrame: 31).blend, 1.0, accuracy: 1e-9)
        // The frame AFTER the trailing loop (32) would map to a transition slot,
        // but it is beyond totalFrames so callers never request it.
        let beyond = sched.frameToBlend(globalFrame: 32)
        XCTAssertEqual(beyond.segmentId, 5)  // hypothetical seg 5 (doesn't exist in a 5-seg timeline)
        XCTAssertEqual(beyond.kind, .transition)
    }

    // blend ∈ (0, 1] never 0, with variable transition count.
    func testBlendNeverZeroVariable() {
        let sched = Schedule(librarySize: 4, framesPerSegment: 8,
                             transitionFramesPerSegment: 4,
                             selector: Sequential(seed: 1), seed: 1)
        for f in 0..<sched.totalFrames(segmentCount: 5) {
            let b = sched.frameToBlend(globalFrame: f).blend
            XCTAssertGreaterThan(b, 0.0, "frame \(f)")
            XCTAssertLessThanOrEqual(b, 1.0, "frame \(f)")
        }
    }

    // totalFrames sums per-kind: loops = ceil(k/2), transitions = floor(k/2).
    func testTotalFramesPerKindSum() {
        let sched = Schedule(librarySize: 4, framesPerSegment: 8,
                             transitionFramesPerSegment: 4,
                             selector: Sequential(seed: 1), seed: 1)
        // segmentCount=1 (loop only): 1*8 + 0*4 = 8
        XCTAssertEqual(sched.totalFrames(segmentCount: 1), 8)
        // segmentCount=2 (loop+trans): 1*8 + 1*4 = 12
        XCTAssertEqual(sched.totalFrames(segmentCount: 2), 12)
        // segmentCount=3 (2 loops + 1 trans): 2*8 + 1*4 = 20
        XCTAssertEqual(sched.totalFrames(segmentCount: 3), 20)
        // segmentCount=5 (3 loops + 2 trans): 3*8 + 2*4 = 32
        XCTAssertEqual(sched.totalFrames(segmentCount: 5), 32)
        // Full N=4 genome pass = 2N-1 = 7 segments: 4 loops + 3 trans = 4*8 + 3*4 = 44
        XCTAssertEqual(sched.totalFrames(segmentCount: 7), 44)
    }

    // frameOffset(ofSegment:) = cumulative frames before segment s.
    func testFrameOffsetCumulative() {
        let sched = Schedule(librarySize: 4, framesPerSegment: 8,
                             transitionFramesPerSegment: 4,
                             selector: Sequential(seed: 1), seed: 1)
        XCTAssertEqual(sched.frameOffset(ofSegment: 0), 0)   // nothing before seg 0
        XCTAssertEqual(sched.frameOffset(ofSegment: 1), 8)   // seg0 loop (8) before seg 1
        XCTAssertEqual(sched.frameOffset(ofSegment: 2), 12)  // seg0 loop (8) + seg1 trans (4)
        XCTAssertEqual(sched.frameOffset(ofSegment: 3), 20)  // + seg2 loop (8)
        XCTAssertEqual(sched.frameOffset(ofSegment: 4), 24)  // + seg3 trans (4)
        // totalFrames(segmentCount:) == frameOffset(ofSegment: segmentCount)
        XCTAssertEqual(sched.totalFrames(segmentCount: 5), sched.frameOffset(ofSegment: 5))
    }

    // Loop→transition boundary with variable transition count: the first frame of
    // each transition slot (within == framesPerSegment). L=8, T=4 → pairFrames=12.
    func testLoopToTransitionBoundaryVariable() {
        let sched = Schedule(librarySize: 4, framesPerSegment: 8,
                             transitionFramesPerSegment: 4,
                             selector: Sequential(seed: 1), seed: 1)
        // seg1 transition starts at frame 8 (within=8==L → boundary)
        XCTAssertTrue(sched.isLoopToTransitionBoundary(globalFrame: 8))
        // seg3 transition starts at frame 20 (pairIndex=1, within=20%12=8==L → boundary)
        XCTAssertTrue(sched.isLoopToTransitionBoundary(globalFrame: 20))
        // Loop starts / interior frames are NOT boundaries
        XCTAssertFalse(sched.isLoopToTransitionBoundary(globalFrame: 0))    // seg0 loop start
        XCTAssertFalse(sched.isLoopToTransitionBoundary(globalFrame: 12))   // seg2 loop start
        XCTAssertFalse(sched.isLoopToTransitionBoundary(globalFrame: 5))    // mid seg0 loop
        XCTAssertFalse(sched.isLoopToTransitionBoundary(globalFrame: 10))   // mid seg1 trans
        XCTAssertFalse(sched.isLoopToTransitionBoundary(globalFrame: 11))   // seg1 last frame
        XCTAssertFalse(sched.isLoopToTransitionBoundary(globalFrame: 24))   // seg4 loop (trailing)
    }

    // Default (omitted transitionFramesPerSegment) == uniform timeline (today's behavior).
    func testDefaultTransitionCountIsUniform() {
        let a = Schedule(librarySize: 4, framesPerSegment: 8,
                         selector: Sequential(seed: 1), seed: 1)
        let b = Schedule(librarySize: 4, framesPerSegment: 8,
                         transitionFramesPerSegment: 8,
                         selector: Sequential(seed: 1), seed: 1)
        XCTAssertEqual(a.transitionFramesPerSegment, 8)
        XCTAssertEqual(a.transitionFramesPerSegment, b.transitionFramesPerSegment)
        // frameToBlend matches between default and explicit-uniform
        for f in 0..<24 {
            XCTAssertEqual(a.frameToBlend(globalFrame: f), b.frameToBlend(globalFrame: f), "frame \(f)")
        }
        // totalFrames matches (uniform: segmentCount * N)
        for k in 1...5 {
            XCTAssertEqual(a.totalFrames(segmentCount: k), k * 8)
        }
    }
}
