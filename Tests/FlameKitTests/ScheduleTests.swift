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
}
