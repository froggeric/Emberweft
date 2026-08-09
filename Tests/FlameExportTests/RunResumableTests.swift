import XCTest
import CoreVideo
import CoreMedia
import AVFoundation
@testable import FlameExport
import FlameKit
import FlameReference

/// M6.1 Task 4 — `runResumable` fresh-run path: pixel-identity vs `run`, pause
/// keeps checkpoint + completed chunks, cancel KEEPS checkpoint at the
/// coordinator level (P3 — the coordinator never discards; discard is the
/// caller's job), success cleans up. Helpers `genome`/`decodeFrames`/`maxAbsDiff`
/// mirror `RenderFramesInterleavedTests` (kept duplicated — they are tiny, and
/// extracting a shared test-support file is out of scope for this task).
final class RunResumableTests: XCTestCase {
    // Real fixture pattern (ExportLongFormTests.swift:36-41 / LoopRepeatTests.swift:23-28).
    private func genome(_ name: String) throws -> [Flame] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name)")
        return try Flam3Parser.parse(Data(contentsOf: url))
    }
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("m6resumable-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    // P5: the real helper is `async throws` at ExportLongFormTests.swift:71.
    private func decodeFrames(_ url: URL) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "RunResumableTests", code: 1)
        }
        let reader = try AVAssetReader(asset: asset)
        reader.add(AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]))
        try reader.startReading()
        var frames: [CVPixelBuffer] = []
        while let sb = reader.outputs.first?.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sb) { frames.append(pb) }
        return frames
    }
    // P4: max absolute per-channel BGRA diff over two decoded frames.
    private func maxAbsDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Int {
        precondition(CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b)
                     && CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b))
        CVPixelBufferLockBaseAddress(a, []); CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(a, []); CVPixelBufferUnlockBaseAddress(b, []) }
        guard let ba = CVPixelBufferGetBaseAddress(a), let bb = CVPixelBufferGetBaseAddress(b) else { return Int.max }
        let h = CVPixelBufferGetHeight(a), rb = CVPixelBufferGetBytesPerRow(a), w = CVPixelBufferGetWidth(a)
        var mx = 0
        for y in 0..<h {
            let ra = ba.advanced(by: y * rb), rb2 = bb.advanced(by: y * rb)
            for x in 0..<(w * 4) {
                let d = abs(Int(ra.load(fromByteOffset: x, as: UInt8.self)) - Int(rb2.load(fromByteOffset: x, as: UInt8.self)))
                if d > mx { mx = d }
            }
        }
        return mx
    }

    /// Build a job matching `RenderFramesInterleavedTests`'s fixture (sierpinski,
    /// 160x100, ProRes, spp 20, ts 1). `segmentCount: 2` → 1 loop segment (8
    /// frames) + 1 transition segment (8 frames) = 16 global frames at repeat 1.
    private func makeJob(out: URL, loopRepeatCount: Int) throws -> ExportJob {
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.codec = .proRes422HQ; settings.container = .mov
        settings.resolution = .custom(width: 160, height: 100); settings.fps = 30
        settings.quality = .spp(20); settings.temporalSamples = 1
        return ExportJob(settings: settings, flames: flames, framesPerSegment: 8,
                         transitionFramesPerSegment: 8, segmentCount: 2, selector: .sequential,
                         seed: 42, loopCycles: 1, stagger: 0, out: out,
                         loopRepeatCount: loopRepeatCount)
    }

    private func runJob(_ job: ExportJob, backend: ExportCoordinator.Backend) async throws {
        let coord = ExportCoordinator(backend: backend)
        let stream = await coord.run(job)
        for try await _ in stream {}
    }

    /// Fresh-run pixel-identity: `runResumable` (one or many chunks) must produce
    /// output byte-identical to `run` of the same job. Routes through the real
    /// resumable path (no test wrapper). `loopRepeatCount == 2` is the F2
    /// headline case (boundary-spanning chunks must not corrupt repeat output).
    private func freshMatchesRun(loopRepeatCount: Int, interval: Int) async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outRun = dir.appendingPathComponent("run.mov")
        let outResumable = dir.appendingPathComponent("resumable.mov")
        let jobRun = try makeJob(out: outRun, loopRepeatCount: loopRepeatCount)
        let jobResumable = try makeJob(out: outResumable, loopRepeatCount: loopRepeatCount)

        try await runJob(jobRun, backend: .cpu)
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runResumable(jobResumable, checkpointIntervalFrames: interval, resumeFrom: nil)
        for try await _ in stream {}

        let a = try await decodeFrames(outRun), b = try await decodeFrames(outResumable)
        XCTAssertEqual(a.count, b.count,
                       "frame count mismatch (loopRepeatCount=\(loopRepeatCount), interval=\(interval))")
        for i in 0..<a.count {
            XCTAssertLessThanOrEqual(maxAbsDiff(a[i], b[i]), 0,
                                     "pixel diff at frame \(i) (loopRepeatCount=\(loopRepeatCount), interval=\(interval))")
        }
    }

    func testFreshRunOneChunkMatchesRunRepeat1() async throws {
        try await freshMatchesRun(loopRepeatCount: 1, interval: 999_999)
    }
    func testFreshRunOneChunkMatchesRunRepeat2() async throws {
        try await freshMatchesRun(loopRepeatCount: 2, interval: 999_999)
    }
    /// Boundary-spanning chunks (interval 2 over 16 global frames → 8 chunks).
    /// Chunk 4 starts at global frame 8 = first transition frame, so chunks span
    /// the loop→transition boundary (the F2 case). Interleaved per-frame `reps`
    /// keeps it byte-identical to `run`.
    func testBoundarySpanningChunk() async throws {
        try await freshMatchesRun(loopRepeatCount: 2, interval: 2)
    }

    /// Pause between chunks (after chunk 0 completes) → throws `.paused`;
    /// checkpoint + completed chunk-0000 REMAIN on disk; the in-progress
    /// chunk-0001 temp is gone. The coordinator did NOT discard (P3).
    /// `_testPauseAfterChunk = 1` fires `paused = true` at the chunk-top of
    /// chunk 1 (chunk 0 has fully completed + been checkpointed by then).
    func testPauseKeepsCheckpointCompletedChunks() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("pause.mov")
        let job = try makeJob(out: out, loopRepeatCount: 1)  // 16 global frames
        let coord = ExportCoordinator(backend: .cpu)
        await coord._setTestPauseAfterChunk(1)  // pause at chunk-top of 1 (interval 8 → 2 chunks)
        let stream = await coord.runResumable(job, checkpointIntervalFrames: 8, resumeFrom: nil)
        do {
            for try await _ in stream {}
            XCTFail("expected ExportError.paused")
        } catch ExportError.paused {
            // expected
        } catch {
            XCTFail("expected ExportError.paused, got \(error)")
        }
        let cp = ExportCheckpoint.checkpointURL(out: out)
        let chunk0 = ExportCheckpoint.chunkURL(out: out, index: 0, container: .mov)
        let chunk1 = ExportCheckpoint.chunkURL(out: out, index: 1, container: .mov)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cp.path),
                      "checkpoint must survive pause")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk0.path),
                      "completed chunk-0000 must survive pause")
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk1.path),
                       "in-progress chunk-0001 temp must be removed on pause")
    }

    /// P3: at the COORDINATOR level, cancel does NOT discard the checkpoint or
    /// completed chunks — discard is the CALLER's job (the coordinator cannot
    /// distinguish GUI Cancel from CLI SIGINT). Cancel after chunk 0 completes
    /// (via the `_testCancelAfterChunk` seam, which sets the same `cancelled` flag
    /// `cancel()` sets); assert checkpoint + chunk-0000 still on disk after the
    /// stream throws `.cancelled`. (The VM's discard is a separate Task-6 test.)
    func testCancelKeepsCheckpointAtCoordinatorLevel() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("cancel.mov")
        let job = try makeJob(out: out, loopRepeatCount: 1)
        let coord = ExportCoordinator(backend: .cpu)
        await coord._setTestCancelAfterChunk(1)
        let stream = await coord.runResumable(job, checkpointIntervalFrames: 8, resumeFrom: nil)
        do {
            for try await _ in stream {}
            XCTFail("expected ExportError.cancelled")
        } catch ExportError.cancelled {
            // expected
        } catch {
            XCTFail("expected ExportError.cancelled, got \(error)")
        }
        let cp = ExportCheckpoint.checkpointURL(out: out)
        let chunk0 = ExportCheckpoint.chunkURL(out: out, index: 0, container: .mov)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cp.path),
                      "coordinator must NOT discard checkpoint on cancel (P3)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk0.path),
                      "coordinator must NOT discard completed chunks on cancel (P3)")
    }

    /// On success: checkpoint + ALL chunk temps are deleted; `out` exists.
    func testSuccessCleansUp() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("ok.mov")
        let job = try makeJob(out: out, loopRepeatCount: 1)
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runResumable(job, checkpointIntervalFrames: 4, resumeFrom: nil)
        for try await _ in stream {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "out must exist on success")
        let cp = ExportCheckpoint.checkpointURL(out: out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cp.path),
                       "checkpoint must be deleted on success")
        let dirEntries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let chunkTemps = dirEntries.filter { $0.contains(".emberweft-chunk-") }
        XCTAssertTrue(chunkTemps.isEmpty, "all chunk temps must be deleted on success, found \(chunkTemps)")
    }
}
