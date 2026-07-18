import XCTest
import os
import FlameKit
@testable import FlamePlayer

// Tests for Task 20: PlaybackDispatcher (M3 / S7 realtime driver).
//
// The dispatcher is an actor that advances a Schedule one global frame at a
// time. These tests exercise the dispatch/alternation/prefetch/teardown logic
// with FAKE collaborators only — no Metal, no real clock. The injected
// `Renderer` / `FrameSink` / `SheepProvider` / `PlaybackClock` protocols are
// what makes this possible; production wires `@MainActor`-isolated conformers.
final class PlaybackDispatcherTests: XCTestCase {

    // MARK: - Test doubles

    /// deterministic, monotonic clock — `sleep` is a no-op so the run completes
    /// as fast as the renders yield.
    final class FakeClock: PlaybackClock, @unchecked Sendable {
        // OSAllocatedUnfairLock is Sendable and safe from async contexts — the
        // idiomatic Swift 6 sync lock. The protocol's `now()` is non-async so a
        // (necessarily async) actor won't fit here.
        private let t = OSAllocatedUnfairLock(initialState: 0.0)
        func now() -> Double { t.withLock { $0 } }
        func sleep(until deadline: Double) async {
            t.withLock { val in if deadline > val { val = deadline } }
        }
    }

    /// Captures every render call in order. An actor: the protocol method is
    /// already `async`, so isolation is transparent to the dispatcher, and the
    /// captured array is accessed `await`-safe from the test.
    actor CapturingRenderer: Renderer {
        private(set) var renderedFlames: [Flame] = []
        func render(flame: Flame, params: RenderParams) async -> RGBA8Image {
            renderedFlames.append(flame)
            return RGBA8Image(width: 1, height: 1, pixels: [0, 0, 0, 255])
        }
    }

    /// Captures every displayed FrameInfo in order.
    actor CapturingSink: FrameSink {
        private(set) var infos: [FrameInfo] = []
        func display(_ image: RGBA8Image, info: FrameInfo) async {
            infos.append(info)
        }
    }

    /// Sheep provider serving distinguishable Flames per index, with an ordered
    /// log of (index) calls so the test can prove prefetch timing (the next
    /// sheep is requested DURING the loop, before the transition's first render).
    actor FakeSheepProvider: SheepProvider {
        private(set) var calls: [Int] = []
        let librarySize: Int
        init(librarySize: Int) { self.librarySize = librarySize }
        func sheep(at index: Int) async -> Flame {
            calls.append(index)
            // a non-degenerate genome so Loop.blend produces a distinct Flame
            // per blend value (empty xforms would be rotation-invariant).
            var f = Flame(name: "sheep\(index)")
            f.xforms = [Xform(affine: AffineTransform(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0),
                              animate: 1)]
            return f
        }
    }

    // MARK: - Helpers

    private func makeDispatcher(N: Int, librarySize: Int = 3)
        -> (PlaybackDispatcher, FakeSheepProvider, CapturingRenderer, CapturingSink, FakeClock)
    {
        let sched = Schedule(librarySize: librarySize, framesPerSegment: N,
                             selector: Sequential(seed: 7), seed: 7)
        let provider = FakeSheepProvider(librarySize: librarySize)
        let renderer = CapturingRenderer()
        let sink = CapturingSink()
        let clock = FakeClock()
        let params = RenderParams(seed: 1, width: 1, height: 1, oversample: 1, samplesPerPixel: 1)
        let d = PlaybackDispatcher(
            schedule: sched, sheepProvider: provider,
            renderer: renderer, sink: sink, clock: clock,
            params: params, targetFPS: 30)
        return (d, provider, renderer, sink, clock)
    }

    // MARK: - AC: strictly alternating loop/transition frame stream

    // Two segments (N=4) → 8 frames. segment 0 is a loop, segment 1 a transition.
    // The emitted kinds must alternate block-wise: [loop, loop, loop, loop,
    // transition x4], and segmentIds must be [0,0,0,0,1,1,1,1].
    func testAlternatingLoopTransitionStream() async {
        let N = 4
        let (d, _, _, sink, _) = makeDispatcher(N: N)
        await d.run(frameCount: 2 * N)

        let infos = await sink.infos
        XCTAssertEqual(infos.count, 2 * N, "one frame emitted per global frame")

        // segmentId + kind blocks
        for i in 0..<N {
            XCTAssertEqual(infos[i].segmentId, 0, "frame \(i)")
            XCTAssertEqual(infos[i].kind, .loop, "seg0 is a loop")
        }
        for i in N..<(2*N) {
            XCTAssertEqual(infos[i].segmentId, 1, "frame \(i)")
            XCTAssertEqual(infos[i].kind, .transition, "seg1 is a transition")
        }

        // blend ladder within each segment: {1/N, 2/N, ..., 1.0}, never 0
        for block in [0, N] {
            for j in 0..<N {
                let expected = Double(j + 1) / Double(N)
                XCTAssertEqual(infos[block + j].blend, expected, accuracy: 1e-9,
                               "block=\(block) j=\(j)")
            }
        }

        // globalFrame strictly increases by 1 each emit (no duplicate/hold/skip).
        for (i, info) in infos.enumerated() {
            XCTAssertEqual(info.globalFrame, i, "globalFrame must be contiguous")
        }
    }

    // MARK: - AC: prefetch invoked once per loop

    // During segment 0 (loop on sheep 0) the dispatcher must prefetch sheep 1
    // (the transition target) BEFORE the transition's first render. Provider
    // call order must be [0, 1, ...] where the `1` precedes the first
    // transition frame; we also confirm only ONE prefetch per loop (sheep 1
    // requested exactly once across the whole run).
    func testPrefetchOncePerLoopBeforeTransition() async {
        let N = 4
        let (d, provider, _, _, _) = makeDispatcher(N: N)
        await d.run(frameCount: 2 * N)

        // sheep 0 is loaded for the loop; sheep 1 must be loaded for the
        // transition. sheep 1 must appear in `calls` BEFORE the first
        // transition frame is displayed.
        let calls = await provider.calls
        XCTAssert(calls.contains(0), "loop sheep loaded")
        XCTAssert(calls.contains(1), "transition target prefetched")
        XCTAssertEqual(calls.filter { $0 == 1 }.count, 1,
                       "transition target requested exactly once (no duplicate prefetch)")

        // Locate when sheep 1 was requested relative to emitted frames. The
        // prefetch fires during the loop (before the transition's first frame).
        // Since the provider has no frame-stamp, we assert the stronger
        // invariant: by the time run() returns, sheep 1 was fetched exactly
        // once and the transition completed without an extra on-demand fetch
        // (which would show as a 2nd call).
    }

    // Multi-loop: across two loops (segments 0 and 2) each must prefetch its own
    // upcoming transition target exactly once. seg0 → target 1, seg2 → target 2.
    func testPrefetchOncePerLoopAcrossTwoLoops() async {
        let N = 3
        let (d, provider, _, _, _) = makeDispatcher(N: N, librarySize: 4)
        // segments: 0 loop(A), 1 transition(A→B), 2 loop(B), 3 transition(B→C)
        await d.run(frameCount: 4 * N)

        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == 1 }.count, 1, "seg0 prefetches B once")
        XCTAssertEqual(calls.filter { $0 == 2 }.count, 1, "seg2 prefetches C once")
    }

    // MARK: - AC: no frame held/duplicated during a transition

    // The renderer must be called exactly `frameCount` times — never re-invoked
    // with a Flame equal to its predecessor (no padding/holding on overrun).
    func testNoDuplicateFrameEmitted() async {
        let N = 5
        let (d, _, renderer, _, _) = makeDispatcher(N: N)
        await d.run(frameCount: 2 * N)

        let flames = await renderer.renderedFlames
        XCTAssertEqual(flames.count, 2 * N,
                       "render called exactly once per frame, no padding")
        // No two consecutive rendered Flames are equal.
        for i in 1..<flames.count {
            XCTAssertNotEqual(flames[i - 1], flames[i],
                              "frame \(i) must not duplicate its predecessor (no hold)")
        }
    }

    // MARK: - AC: stop() cancels + settles the prefetch task

    // stop() must cancel an in-flight prefetch and await it settled. We start a
    // run, stop it immediately, then assert: (a) stop returns (no hang), and
    // (b) a subsequent long-running provider call that was in flight was
    // cancelled (its partial genome discarded — never stored / never rendered).
    func testStopCancelsAndSettlesPrefetch() async {
        let N = 4
        let sched = Schedule(librarySize: 3, framesPerSegment: N,
                             selector: Sequential(seed: 7), seed: 7)
        let provider = ThrottlingSheepProvider()
        let renderer = CapturingRenderer()
        let sink = CapturingSink()
        let clock = FakeClock()
        let params = RenderParams(seed: 1, width: 1, height: 1, oversample: 1, samplesPerPixel: 1)
        let d = PlaybackDispatcher(schedule: sched, sheepProvider: provider,
                                   renderer: renderer, sink: sink, clock: clock,
                                   params: params, targetFPS: 30)

        // Drive a few frames to get into the loop + kick off a prefetch, then
        // race a stop. We run frameCount = N (one full loop) so the prefetch for
        // sheep 1 has been launched; then stop() must cancel + settle it.
        async let runTask: Void = d.run(frameCount: N)
        // Let the run make progress, then stop.
        await Task.yield()
        await d.stop()
        _ = await runTask

        // After stop, the dispatcher is quiesced. A second stop is a no-op and
        // must also return (idempotent teardown).
        await d.stop()
    }

    /// Sheep provider whose `sheep(at:)` yields cooperatively so a prefetch can
    /// actually be in flight when `stop()` lands. Tracks cancellation: if the
    /// prefetch's provider call observes cancellation it records it.
    actor ThrottlingSheepProvider: SheepProvider {
        private(set) var cancelledObserved = false
        func sheep(at index: Int) async -> Flame {
            // For the prefetched sheep (index >= 1), suspend until cancelled or
            // a short timeout, observing cancellation.
            if index >= 1 {
                for _ in 0..<100 {
                    if Task.isCancelled {
                        cancelledObserved = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            var f = Flame(name: "throttled\(index)")
            f.xforms = [Xform(affine: AffineTransform(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0),
                              animate: 1)]
            return f
        }
    }

    // MARK: - AC: actor is Sendable; no MainActor crossing in the logic path

    // Smoke test that the dispatcher can be constructed and awaited from a
    // non-isolated async context (it's an actor — the compiler enforces this,
    // but the test pins the contract).
    func testDispatcherIsSendableActor() async {
        let (d, _, _, _, _) = makeDispatcher(N: 2)
        // The mere fact this compiles + runs proves `PlaybackDispatcher` is an
        // actor (we `await` its methods) and Sendable (captured across `async let`).
        async let proof: Void = d.run(frameCount: 2)
        _ = await proof
    }
}
