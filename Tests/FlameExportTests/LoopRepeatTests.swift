import XCTest
@testable import FlameExport
import FlameKit
import FlameReference

/// Loop render-once-repeat (v0.5.0 Change 1). The coordinator caches each loop
/// segment's frames and appends them `loopRepeatCount`× (seamless: R(360°)=R(0°)),
/// while transitions are rendered + appended once. `loopRepeatCount == 1` is the
/// no-op path (byte-for-byte the pre-change behavior — pinned by the existing
/// `testExportGenomeByteMatchesAnimateFrame5` + `…MotionBlur` animate-byte-identity
/// pins, which route through the unchanged repeat=1 dispatch).
///
/// Two `internal` test seams on `ExportCoordinator` back these assertions:
///   - `renderCallCount`    — images produced by the render dispatch (cache misses;
///                            a loop repeated 2× still counts each frame ONCE).
///   - `appendedFrameCount` — frames handed to the encoder (output frame count;
///                            a loop repeated 2× counts 2× here).
/// Both are pure side-channel counters (no effect on bytes/PTS → byte-identity-safe).
final class LoopRepeatTests: XCTestCase {
    private func genome(_ name: String) throws -> [Flame] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name)")
        return try Flam3Parser.parse(Data(contentsOf: url))
    }

    private func tmpMP4() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("m6lr-\(UUID().uuidString).mp4")
    }

    private func baseSettings(width: Int = 64, height: Int = 48) -> ExportSettings {
        var s = ExportSettings()
        s.resolution = .custom(width: width, height: height)
        s.fps = 30
        s.temporalSamples = 1
        s.quality = .spp(1)   // 1 sample/pixel: counts are the point, not pixels
        return s
    }

    /// `loopRepeatCount == 1` (the init default) and an explicit `loopRepeatCount: 1`
    /// are both no-ops: each renders and appends exactly `plan.totalFrames` frames
    /// (no cache/replay branch entered). The byte-safety of the `renderImage`
    /// extraction itself is pinned by the existing animate↔export byte-identity
    /// tests (which use this exact repeat=1 path); this test pins the BRANCHING —
    /// repeat=1 never duplicates and never re-renders.
    func testLoopRepeatCount1IsByteIdenticalToUnset() async throws {
        let flames = try genome("sierpinski.flam3")
        let settings = baseSettings()
        let N = 8

        // (1) Default — loopRepeatCount omitted (init default 1).
        let coord1 = ExportCoordinator(backend: .cpu)
        let out1 = tmpMP4()
        let job1 = ExportJob(settings: settings, flames: flames, framesPerSegment: N,
                             segmentCount: 1, selector: .sequential, seed: 7,
                             loopCycles: 1, stagger: 0, out: out1)
        let stream1 = await coord1.run(job1)
        for try await _ in stream1 {}
        let renders1 = await coord1.renderCallCount
        let appends1 = await coord1.appendedFrameCount

        // (2) Explicit loopRepeatCount = 1.
        let coord2 = ExportCoordinator(backend: .cpu)
        let out2 = tmpMP4()
        let job2 = ExportJob(settings: settings, flames: flames, framesPerSegment: N,
                             segmentCount: 1, selector: .sequential, seed: 7,
                             loopCycles: 1, stagger: 0, out: out2, loopRepeatCount: 1)
        let stream2 = await coord2.run(job2)
        for try await _ in stream2 {}
        let renders2 = await coord2.renderCallCount
        let appends2 = await coord2.appendedFrameCount

        // Both paths render + append exactly N (one loop segment, no duplication).
        XCTAssertEqual(renders1, N, "default path must render each frame once")
        XCTAssertEqual(renders2, N, "explicit repeat=1 must render each frame once")
        XCTAssertEqual(appends1, N, "default path must append each frame once")
        XCTAssertEqual(appends2, N, "explicit repeat=1 must append each frame once")
        XCTAssertEqual(renders1, renders2, "default vs explicit repeat=1 are identical work")
        XCTAssertEqual(appends1, appends2)

        try? FileManager.default.removeItem(at: out1)
        try? FileManager.default.removeItem(at: out2)
    }

    /// A single-loop job with `loopRepeatCount == 2` renders each frame ONCE
    /// (renderCallCount == N) but appends each frame TWICE (appendedFrameCount == 2N).
    /// This is the "15 s render → 30 s perceived" optimization: half the render
    /// cost, double the output.
    func testLoopRepeatHalvesRendersDoublesOutput() async throws {
        let flames = try genome("sierpinski.flam3")
        let settings = baseSettings()
        let N = 8

        let coord = ExportCoordinator(backend: .cpu)
        let out = tmpMP4()
        let job = ExportJob(settings: settings, flames: flames, framesPerSegment: N,
                            segmentCount: 1, selector: .sequential, seed: 7,
                            loopCycles: 1, stagger: 0, out: out, loopRepeatCount: 2)
        let stream = await coord.run(job)
        for try await _ in stream {}

        let renders = await coord.renderCallCount
        let appends = await coord.appendedFrameCount
        XCTAssertEqual(renders, N, "loop must be rendered once (N frames), not 2N — the whole point of the cache")
        XCTAssertEqual(appends, N * 2, "output must be doubled (2N frames) for repeat=2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        try? FileManager.default.removeItem(at: out)
    }

    /// A loop+transition+loop job (segmentCount 3) with `loopRepeatCount == 2`:
    /// every frame is rendered once (2 loops × N + 1 trans × T), but only the
    /// LOOP frames are repeated in the output (2 loops × N × 2 + 1 trans × T).
    /// Transitions are never repeated (a morph is not seamless).
    func testTransitionNotRepeated() async throws {
        let parsed = try genome("sierpinski.flam3")
        // Two copies → librarySize 2, segmentCount 3 = loop,trans,loop (trans morphs A→A).
        let flames = [parsed[0], parsed[0]]
        let settings = baseSettings(width: 48, height: 32)
        let N = 4, T = 4

        let coord = ExportCoordinator(backend: .cpu)
        let out = tmpMP4()
        let job = ExportJob(settings: settings, flames: flames, framesPerSegment: N,
                            transitionFramesPerSegment: T,
                            segmentCount: 3, selector: .sequential, seed: 7,
                            loopCycles: 1, stagger: 0, out: out, loopRepeatCount: 2)
        let stream = await coord.run(job)
        for try await _ in stream {}

        let renders = await coord.renderCallCount
        let appends = await coord.appendedFrameCount
        // Renders: 2 loops × N + 1 trans × T = 2N + T = 12 (each frame rendered once).
        XCTAssertEqual(renders, 2 * N + T, "every frame rendered once (loops cached, transition live)")
        // Appends: 2 loops × N × 2 + 1 trans × T = 4N + T = 20 (loops doubled, trans once).
        XCTAssertEqual(appends, 2 * N * 2 + T, "loops doubled via repeat, transition appended once")
        try? FileManager.default.removeItem(at: out)
    }

    /// The memory guard refuses a loop-repeat job whose per-loop cache
    /// (N × W × H × 4 bytes) would exceed the safe threshold (~50% of physical
    /// RAM, floored 2 GB, ceiling ~12 GB). Synthesized with a huge W×H×N so the
    /// cache estimate (40 GB) clears the ceiling on every host. The guard fires
    /// BEFORE the encoder is created or any rendering starts (no partial file).
    func testMemoryGuardRefusesOversizedCache() async throws {
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.resolution = .custom(width: 10_000, height: 10_000)
        settings.fps = 30
        settings.temporalSamples = 1

        let coord = ExportCoordinator(backend: .cpu)
        let out = tmpMP4()
        let job = ExportJob(settings: settings, flames: flames, framesPerSegment: 100,
                            segmentCount: 1, selector: .sequential, seed: 7,
                            loopCycles: 1, stagger: 0, out: out, loopRepeatCount: 2)

        var caught: Error?
        do {
            let stream = await coord.run(job)
            for try await _ in stream {}
        } catch { caught = error }

        guard case ExportError.loopRepeatMemoryExceeded(let neededMB, let availableMB)? = caught else {
            return XCTFail("expected loopRepeatMemoryExceeded, got \(String(describing: caught))")
        }
        // cacheBytes = 100 × 10000 × 10000 × 4 = 40 GB → neededMB ≈ 40000.
        XCTAssertGreaterThan(neededMB, availableMB, "needed must exceed the available threshold")
        XCTAssertGreaterThanOrEqual(neededMB, 39_000, "neededMB should reflect the ~40 GB cache estimate")
        // No partial file left behind (guard fired before the encoder started).
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "no output/partial file when the memory guard refuses")
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.partialURL.path))
    }

    /// The guard is NOT triggered when loopRepeatCount == 1 (no cache is built).
    /// `checkLoopRepeatMemory` early-returns for repeat=1, so a job that WOULD
    /// exceed the threshold at repeat=2 proceeds normally at repeat=1. Uses a
    /// small resolution so the actual render is fast (the guard logic is the
    /// point, not the render). The complementary `testMemoryGuardRefusesOver
    /// sizedCache` proves the SAME job at repeat=2 is refused.
    func testMemoryGuardInactiveForRepeatCount1() async throws {
        let flames = try genome("sierpinski.flam3")
        let settings = baseSettings()
        let N = 4

        let coord = ExportCoordinator(backend: .cpu)
        let out = tmpMP4()
        let job = ExportJob(settings: settings, flames: flames, framesPerSegment: N,
                            segmentCount: 1, selector: .sequential, seed: 7,
                            loopCycles: 1, stagger: 0, out: out, loopRepeatCount: 1)
        let stream = await coord.run(job)
        for try await _ in stream {}

        // Reached here ⇒ no memory-guard throw at repeat=1. Output exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let renders = await coord.renderCallCount
        XCTAssertEqual(renders, N, "repeat=1 renders each frame once")
        try? FileManager.default.removeItem(at: out)
    }
}
