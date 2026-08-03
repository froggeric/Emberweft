import XCTest
import Foundation
@testable import FlameExport
@testable import EmberweftCLI
import FlameKit

/// Task 7 — batch queue. `ExportCoordinator.runBatch(jobs:failFast:)` runs jobs
/// SERIALLY (Metal is single-device → serial = deterministic + thermal-safe),
/// continue-by-default (a failed job is recorded and the batch continues; the
/// batch exit code is nonzero iff any job failed), with `failFast` aborting on
/// the first failure. Cancel scope = CURRENT job (clean up its partial + temps)
/// AND remaining jobs. Per-job + aggregate progress via `BatchProgress`.
///
/// The path-sanitization gate (D13) — `BatchPath.resolve` — rejects manifest
/// `out` names that would escape the batch base dir (`..`, absolute, hidden,
/// illegal characters); accepted names resolve strictly under `base`.
///
/// AC mapping:
/// - AC1 (serial, in-order, all outputs): `testBatchRunsJobsInOrder`.
/// - AC2 (continue-on-failure, exit nonzero): `testBatchContinuesOnFailure`.
/// - AC3 (fail-fast stops remaining): `testBatchFailFastStopsRemaining`.
/// - AC4 (cancel scope = current + remaining; partial cleaned): `testBatchCancelStopsRemaining`.
/// - AC5 (path sanitization): `testBatchPathSanitization`.
final class ExportBatchTests: XCTestCase {
    private func sierpinski() -> String {
        // `#filePath` (not `#file`): in Swift 6.2 `#file` returns a basename,
        // which collapses the directory chain and resolves the genome wrong.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3").path
    }
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("m6batch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Small-res settings (fast): CPU rendering at 48×32 keeps each 4-frame job
    /// well under a second. The ACs are resolution-independent.
    private func fastSettings() -> ExportSettings {
        var s = ExportSettings()
        s.resolution = .custom(width: 48, height: 32); s.fps = 30
        s.temporalSamples = 1; s.quality = .spp(10)
        return s
    }
    private func parseSierpinski() throws -> [Flame] {
        try Flam3Parser.parse(Data(contentsOf: URL(fileURLWithPath: sierpinski())))
    }

    /// AC1: 3 jobs run in input order; all outputs exist. `jobIndex` is
    /// non-decreasing across the stream (serial dispatch in array order).
    func testBatchRunsJobsInOrder() async throws {
        let dir = tmpDir()
        let flames = try parseSierpinski()
        let settings = fastSettings()
        let jobs = (0..<3).map { i in
            ExportJob(settings: settings, flames: flames, framesPerSegment: 4, segmentCount: 1,
                      selector: .sequential, seed: UInt64(i), loopCycles: 1, stagger: 0,
                      out: dir.appendingPathComponent("j\(i).mp4"))
        }
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runBatch(jobs, failFast: false)
        var seen: [Int] = []
        for try await p in stream { seen.append(p.jobIndex) }
        // All three outputs materialized.
        for i in 0..<3 {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("j\(i).mp4").path),
                          "j\(i).mp4 must exist after a successful batch")
        }
        // jobIndex stream is non-decreasing (serial, in input order — never jumps back).
        XCTAssertEqual(seen, seen.sorted(), "jobIndex must be non-decreasing (serial dispatch)")
        try? FileManager.default.removeItem(at: dir)
    }

    /// AC2: a failing job 0 (degenerate genome: all-zero xform weight → not
    /// isRenderable) does NOT abort jobs 1,2 by default. Exactly one failure is
    /// recorded; the two good jobs still produce their outputs.
    func testBatchContinuesOnFailure() async throws {
        let dir = tmpDir()
        let good = try parseSierpinski()
        let settings = fastSettings()
        // `Flame()` defaults to a finite camera (scale 250, center zero) but
        // empty `xforms` → `isRenderable == false` (no xform with weight > 0).
        var badFlame = Flame()
        badFlame.xforms = []
        let jobs = [
            ExportJob(settings: settings, flames: [badFlame], framesPerSegment: 4, segmentCount: 1,
                      selector: .sequential, seed: 0, loopCycles: 1, stagger: 0,
                      out: dir.appendingPathComponent("bad.mp4")),
            ExportJob(settings: settings, flames: good, framesPerSegment: 4, segmentCount: 1,
                      selector: .sequential, seed: 1, loopCycles: 1, stagger: 0,
                      out: dir.appendingPathComponent("g1.mp4")),
            ExportJob(settings: settings, flames: good, framesPerSegment: 4, segmentCount: 1,
                      selector: .sequential, seed: 2, loopCycles: 1, stagger: 0,
                      out: dir.appendingPathComponent("g2.mp4")),
        ]
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runBatch(jobs, failFast: false)
        let failures = try await Self.collectFailures(stream)
        XCTAssertEqual(failures, [0], "only job 0 should be recorded as failed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("g1.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("g2.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bad.mp4").path),
                       "the failed job must not produce a final output")
        try? FileManager.default.removeItem(at: dir)
    }

    /// AC3: `failFast: true` + a failing job 0 stops jobs 1,2 — they never start.
    func testBatchFailFastStopsRemaining() async throws {
        let dir = tmpDir()
        let good = try parseSierpinski()
        let settings = fastSettings()
        var badFlame = Flame()
        badFlame.xforms = []
        let jobs = [
            ExportJob(settings: settings, flames: [badFlame], framesPerSegment: 4, segmentCount: 1,
                      selector: .sequential, seed: 0, loopCycles: 1, stagger: 0,
                      out: dir.appendingPathComponent("bad.mp4")),
            ExportJob(settings: settings, flames: good, framesPerSegment: 4, segmentCount: 1,
                      selector: .sequential, seed: 1, loopCycles: 1, stagger: 0,
                      out: dir.appendingPathComponent("g1.mp4")),
            ExportJob(settings: settings, flames: good, framesPerSegment: 4, segmentCount: 1,
                      selector: .sequential, seed: 2, loopCycles: 1, stagger: 0,
                      out: dir.appendingPathComponent("g2.mp4")),
        ]
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runBatch(jobs, failFast: true)
        var sawLaterJob = false
        for try await p in stream {
            if p.jobIndex >= 1 { sawLaterJob = true }
        }
        XCTAssertFalse(sawLaterJob, "fail-fast must not start jobs 1+ after job 0 fails")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("g1.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("g2.mp4").path))
        try? FileManager.default.removeItem(at: dir)
    }

    /// AC4: cancel during job 0 — the in-flight job's partial is cleaned up
    /// (atomic-handoff invariant) and jobs 1,2 do NOT start. Cancel scope =
    /// current job + remaining.
    ///
    /// Determinism: the actor serializes, so when `renderFrames` yields progress
    /// for frame 1 it SUSPENDS the inner `runJob`, the test's `await coord.cancel()`
    /// is processed on the actor during that suspension (sets `cancelled = true`),
    /// and the next frame's top-of-loop guard throws `ExportError.cancelled`.
    /// With `framesPerSegment: 4` there is a guaranteed yield before completion,
    /// so cancel always lands mid-job (deterministic, not racy).
    func testBatchCancelStopsRemaining() async throws {
        let dir = tmpDir()
        let flames = try parseSierpinski()
        let settings = fastSettings()
        let jobs = (0..<3).map { i in
            ExportJob(settings: settings, flames: flames, framesPerSegment: 4, segmentCount: 1,
                      selector: .sequential, seed: UInt64(i), loopCycles: 1, stagger: 0,
                      out: dir.appendingPathComponent("j\(i).mp4"))
        }
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runBatch(jobs, failFast: false)
        var sawFirstFrame = false
        var didCancel = false
        var threw = false
        do {
            for try await p in stream {
                if p.jobIndex == 0 && p.jobFrame >= 1 {
                    sawFirstFrame = true
                    if !didCancel { await coord.cancel(); didCancel = true }
                }
                XCTAssertLessThan(p.jobIndex, 1, "jobs 1+ must not start after cancel")
            }
        } catch {
            threw = true
        }
        XCTAssertTrue(sawFirstFrame, "job 0 must yield at least one frame before cancel lands")
        XCTAssertTrue(threw, "a cancelled batch must surface an error (cancel scope = current job)")
        // j0.mp4 absent: cancelled before the atomic handoff.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("j0.mp4").path),
                       "cancelled job 0 must not produce a final output")
        // Partial + long-form temps cleaned (atomic-handoff / defer invariants).
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let partials = leftovers.filter { $0.contains(".partial-") || $0.hasPrefix("m6-seg-") }
        XCTAssertTrue(partials.isEmpty, "cancelled job's partial/temps must be cleaned; found \(partials)")
        try? FileManager.default.removeItem(at: dir)
    }

    /// AC5: `BatchPath.resolve` rejects traversal (`..`, absolute paths,
    /// hidden stems) and resolves accepted names strictly under the batch base
    /// dir. Declared subdirs are flattened to the leaf (one component under
    /// `base` — the result can never escape it).
    func testBatchPathSanitization() throws {
        let base = tmpDir()
        XCTAssertThrowsError(try BatchPath.resolve("../../etc/passwd", base: base))
        XCTAssertThrowsError(try BatchPath.resolve("/etc/passwd", base: base))
        XCTAssertThrowsError(try BatchPath.resolve(".hidden", base: base))
        XCTAssertThrowsError(try BatchPath.resolve("..", base: base))
        XCTAssertThrowsError(try BatchPath.resolve("bad name.mp4", base: base))  // space not in allowlist
        // Accepted: clean name resolves strictly under base (never escapes it).
        let ok = try BatchPath.resolve("good-name_1.mp4", base: base)
        XCTAssertEqual(ok.deletingLastPathComponent().path, base.path)
        // Declared subdirs flatten to the leaf (single component under base).
        let flat = try BatchPath.resolve("sub/dir/x.mp4", base: base)
        XCTAssertEqual(flat, base.appendingPathComponent("x.mp4"))
        try? FileManager.default.removeItem(at: base)
    }

    private static func collectFailures<S: AsyncSequence>(_ s: S) async throws -> [Int]
    where S.Element == BatchProgress {
        var f: [Int] = []
        for try await p in s { if p.failed { f.append(p.jobIndex) } }
        return f
    }
}
