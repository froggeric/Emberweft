import XCTest
import CoreVideo
import CoreMedia
import AVFoundation
import CryptoKit
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
        let stream = await coord.runResumable(jobResumable, sources: [], checkpointIntervalFrames: interval, resumeFrom: nil)
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
        let stream = await coord.runResumable(job, sources: [], checkpointIntervalFrames: 8, resumeFrom: nil)
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
        let stream = await coord.runResumable(job, sources: [], checkpointIntervalFrames: 8, resumeFrom: nil)
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
        let stream = await coord.runResumable(job, sources: [], checkpointIntervalFrames: 4, resumeFrom: nil)
        for try await _ in stream {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "out must exist on success")
        let cp = ExportCheckpoint.checkpointURL(out: out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cp.path),
                       "checkpoint must be deleted on success")
        let dirEntries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let chunkTemps = dirEntries.filter { $0.contains(".emberweft-chunk-") }
        XCTAssertTrue(chunkTemps.isEmpty, "all chunk temps must be deleted on success, found \(chunkTemps)")
    }

    // MARK: - Task 5: resume + source verification + crash recovery

    /// Hex SHA-256 of a file's bytes (CryptoKit — mirrors the coordinator's
    /// resume verification).
    private func sha256hex(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", Int($0)) }.joined()
    }

    /// Build a checkpoint from scratch (for hand-seeded resume scenarios). Uses
    /// the same recipe as `makeJob` (16 global frames, 2 chunks at interval 8).
    private func makeCheckpoint(out: URL, completed: Set<Int>, interval: Int = 8,
                                sources: [ExportCheckpoint.Source]) throws -> ExportCheckpoint {
        var settings = ExportSettings()
        settings.codec = .proRes422HQ; settings.container = .mov
        settings.resolution = .custom(width: 160, height: 100); settings.fps = 30
        settings.quality = .spp(20); settings.temporalSamples = 1
        return ExportCheckpoint(
            settings: settings, framesPerSegment: 8, transitionFramesPerSegment: 8,
            segmentCount: 2, selector: .sequential, seed: 42, loopCycles: 1, stagger: 0,
            out: out, loopRepeatCount: 1, checkpointIntervalFrames: interval,
            totalGlobalFrames: 16, completedChunkIndexes: completed, sources: sources)
    }

    /// Seed a paused state: run with `_testPauseAfterChunk = 1` (interval 8 → 2
    /// chunks) so chunk 0 completes + is checkpointed, then pause fires at chunk
    /// 1's top. Leaves chunk-0000 + the checkpoint on disk — exactly what a
    /// clean pause OR a crash leaves (the resume code path is identical). Returns
    /// the decoded checkpoint for inspection.
    @discardableResult
    private func seedPaused(out: URL, loopRepeatCount: Int = 1) async throws -> ExportCheckpoint {
        let job = try makeJob(out: out, loopRepeatCount: loopRepeatCount)
        let coord = ExportCoordinator(backend: .cpu)
        await coord._setTestPauseAfterChunk(1)
        let stream = await coord.runResumable(job, sources: [], checkpointIntervalFrames: 8, resumeFrom: nil)
        do {
            for try await _ in stream {}
            XCTFail("expected ExportError.paused")
        } catch ExportError.paused {
            // expected — checkpoint + chunk-0000 remain on disk
        } catch {
            XCTFail("expected ExportError.paused, got \(error)")
        }
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        return try JSONDecoder().decode(ExportCheckpoint.self, from: Data(contentsOf: cpURL))
    }

    /// Resume pixel-identity: pause after chunk 0, resume via
    /// `runResumable(resumeFrom:)` → final output pixel-identical to a no-pause
    /// `run` of the same job; frame counts equal. (Determinism pin, rule #2.)
    func testResumePixelIdentity() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outFresh = dir.appendingPathComponent("fresh.mov")
        let outResume = dir.appendingPathComponent("resume.mov")

        try await runJob(try makeJob(out: outFresh, loopRepeatCount: 1), backend: .cpu)
        let cp = try await seedPaused(out: outResume, loopRepeatCount: 1)
        XCTAssertEqual(cp.completedChunkIndexes, [0], "chunk 0 must be recorded completed")

        let resumeCoord = ExportCoordinator(backend: .cpu)
        let cpURL = ExportCheckpoint.checkpointURL(out: outResume)
        let stream = await resumeCoord.runResumable(try makeJob(out: outResume, loopRepeatCount: 1),
                                                     sources: [], checkpointIntervalFrames: 8, resumeFrom: cpURL)
        for try await _ in stream {}

        let a = try await decodeFrames(outFresh), b = try await decodeFrames(outResume)
        XCTAssertEqual(a.count, b.count, "frame count mismatch")
        for i in 0..<a.count {
            XCTAssertLessThanOrEqual(maxAbsDiff(a[i], b[i]), 0,
                                     "resume pixel diff at frame \(i)")
        }
    }

    /// Crash recovery = the same resume path (a crash leaves the same on-disk
    /// state as a clean pause). Asserts: skips the completed chunk, renders the
    /// rest, concats → pixel-identical to no-pause.
    func testCrashRecoveryResumesFromCheckpoint() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outFresh = dir.appendingPathComponent("fresh.mov")
        let outCrash = dir.appendingPathComponent("crash.mov")

        try await runJob(try makeJob(out: outFresh, loopRepeatCount: 1), backend: .cpu)
        // Simulate a crash: the pause-seed leaves a real checkpoint + chunk-0000
        // (the body never ran its success cleanup — exactly a kill -9 mid-run).
        let cp = try await seedPaused(out: outCrash, loopRepeatCount: 1)
        XCTAssertEqual(cp.completedChunkIndexes, [0])

        let resumeCoord = ExportCoordinator(backend: .cpu)
        let cpURL = ExportCheckpoint.checkpointURL(out: outCrash)
        let stream = await resumeCoord.runResumable(try makeJob(out: outCrash, loopRepeatCount: 1),
                                                     sources: [], checkpointIntervalFrames: 8, resumeFrom: cpURL)
        for try await _ in stream {}

        let a = try await decodeFrames(outFresh), b = try await decodeFrames(outCrash)
        XCTAssertEqual(a.count, b.count)
        for i in 0..<a.count {
            XCTAssertLessThanOrEqual(maxAbsDiff(a[i], b[i]), 0,
                                     "crash-recovery pixel diff at frame \(i)")
        }
    }

    /// D9: on a resumed run the FIRST progress event has
    /// `currentFrame == Σ completed-chunk frame counts` (NOT 0). Chunk 0 = 8
    /// frames → first event must seed at 8.
    func testResumeProgressSeedIsCompletedChunkFrameCount() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("d9.mov")
        _ = try await seedPaused(out: out, loopRepeatCount: 1)  // chunk 0 (8 frames) done

        let resumeCoord = ExportCoordinator(backend: .cpu)
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        let stream = await resumeCoord.runResumable(try makeJob(out: out, loopRepeatCount: 1),
                                                     sources: [], checkpointIntervalFrames: 8, resumeFrom: cpURL)
        var first: ExportProgress?
        for try await p in stream {
            if first == nil { first = p }
        }
        XCTAssertEqual(first?.currentFrame, 8,
                       "D9: first progress event must seed at 8 (Σ completed-chunk frames), not 0")
        XCTAssertEqual(first?.phase, .rendering)
    }

    /// Source hash mismatch: the source file's bytes changed since pause →
    /// `.checkpointSourceChanged(index:)`.
    func testResumeSourceHashMismatch() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("hash.mov")

        let fileURL = dir.appendingPathComponent("src.flam3")
        try Flam3Serializer.serialize(try genome("sierpinski.flam3")).write(
            to: fileURL, atomically: true, encoding: .utf8)
        let hash = try sha256hex(fileURL)
        let cp = try makeCheckpoint(out: out, completed: [], sources: [
            ExportCheckpoint.Source(fileURL: fileURL, flameIndex: 0, sha256: hash,
                                    serializedText: nil, displayName: "flame 0")])
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try enc.encode(cp).write(to: cpURL)

        // Tamper: append bytes → SHA-256 changes.
        var bytes = try Data(contentsOf: fileURL)
        bytes.append(Data("<!-- tampered -->".utf8))
        try bytes.write(to: fileURL)

        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runResumable(try makeJob(out: out, loopRepeatCount: 1),
                                              sources: [], checkpointIntervalFrames: 8, resumeFrom: cpURL)
        do {
            for try await _ in stream {}
            XCTFail("expected ExportError.checkpointSourceChanged")
        } catch ExportError.checkpointSourceChanged(let index) {
            XCTAssertEqual(index, 0, "mismatch must report the offending source index")
        } catch {
            XCTFail("expected ExportError.checkpointSourceChanged, got \(error)")
        }
    }

    /// schemaVersion ≠ 1 → checkpoint ignored, fresh start (never crash; D12).
    func testResumeSchemaMismatchIgnoresCheckpoint() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("schema.mov")

        let cp = try makeCheckpoint(out: out, completed: [], sources: [
            ExportCheckpoint.Source(fileURL: nil, flameIndex: 0, sha256: nil,
                                    serializedText: Flam3Serializer.serialize(try genome("sierpinski.flam3")),
                                    displayName: "flame 0")])
        // Rewrite schemaVersion = 2 via JSONSerialization (the init hard-codes 1).
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cp)) as! [String: Any]
        json["schemaVersion"] = 2
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        try JSONSerialization.data(withJSONObject: json).write(to: cpURL)

        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runResumable(try makeJob(out: out, loopRepeatCount: 1),
                                              sources: [], checkpointIntervalFrames: 8, resumeFrom: cpURL)
        for try await _ in stream {}  // fresh start, completes normally
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                      "schema mismatch → fresh start must still produce output")
        // Success cleanup ran (fresh path).
        XCTAssertFalse(FileManager.default.fileExists(atPath: cpURL.path),
                       "checkpoint must be cleaned up on the fresh-start success path")
    }

    /// Missing completed-chunk file → dropped from `completed` and re-rendered
    /// (output still pixel-identical to no-pause).
    func testResumeDropsMissingCompletedChunk() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outFresh = dir.appendingPathComponent("fresh.mov")
        let outResume = dir.appendingPathComponent("missing.mov")

        try await runJob(try makeJob(out: outFresh, loopRepeatCount: 1), backend: .cpu)
        _ = try await seedPaused(out: outResume, loopRepeatCount: 1)

        // Delete chunk-0000 (simulating a lost chunk file).
        let chunk0 = ExportCheckpoint.chunkURL(out: outResume, index: 0, container: .mov)
        try FileManager.default.removeItem(at: chunk0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk0.path))

        let resumeCoord = ExportCoordinator(backend: .cpu)
        let cpURL = ExportCheckpoint.checkpointURL(out: outResume)
        let stream = await resumeCoord.runResumable(try makeJob(out: outResume, loopRepeatCount: 1),
                                                     sources: [], checkpointIntervalFrames: 8, resumeFrom: cpURL)
        for try await _ in stream {}

        let a = try await decodeFrames(outFresh), b = try await decodeFrames(outResume)
        XCTAssertEqual(a.count, b.count)
        for i in 0..<a.count {
            XCTAssertLessThanOrEqual(maxAbsDiff(a[i], b[i]), 0,
                                     "missing-chunk re-render pixel diff at frame \(i)")
        }
    }

    /// Multi-flame source: a 2-flame file with `flameIndex == 1` re-parses to
    /// the SAME flame on resume (identity via the resume pixel pin vs a fresh
    /// run sourcing that flame directly).
    func testResumeMultiFlameSourceSelectsCorrectFlame() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let flameA = try genome("sierpinski.flam3")[0]
        let flameB = try genome("swirl_field.flam3")[0]
        // A 2-flame file: sierpinski at index 0, swirl_field at index 1.
        let twoFlameFile = dir.appendingPathComponent("two.flam3")
        try Flam3Serializer.serialize([flameA, flameB]).write(
            to: twoFlameFile, atomically: true, encoding: .utf8)
        let hash = try sha256hex(twoFlameFile)
        // Both fresh + resume source flameB from the SAME 2-flame file parse →
        // identical bytes → identical flame → identical pixels.
        let twoFlameParsed = try Flam3Parser.parse(Data(contentsOf: twoFlameFile))
        XCTAssertEqual(twoFlameParsed.count, 2)
        let flameBFromFile = twoFlameParsed[1]

        var settings = ExportSettings()
        settings.codec = .proRes422HQ; settings.container = .mov
        settings.resolution = .custom(width: 160, height: 100); settings.fps = 30
        settings.quality = .spp(20); settings.temporalSamples = 1

        let outFresh = dir.appendingPathComponent("fresh.mov")
        let outResume = dir.appendingPathComponent("multi.mov")
        try await runJob(ExportJob(settings: settings, flames: [flameBFromFile],
                                   framesPerSegment: 8, transitionFramesPerSegment: 8,
                                   segmentCount: 2, selector: .sequential, seed: 42,
                                   loopCycles: 1, stagger: 0, out: outFresh, loopRepeatCount: 1),
                         backend: .cpu)

        // Checkpoint sources flameIndex 1 from the 2-flame file.
        let cp = try makeCheckpoint(out: outResume, completed: [], sources: [
            ExportCheckpoint.Source(fileURL: twoFlameFile, flameIndex: 1, sha256: hash,
                                    serializedText: nil, displayName: "flame 1")])
        let cpURL = ExportCheckpoint.checkpointURL(out: outResume)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try enc.encode(cp).write(to: cpURL)

        let resumeCoord = ExportCoordinator(backend: .cpu)
        let stream = await resumeCoord.runResumable(
            ExportJob(settings: settings, flames: [flameBFromFile],
                      framesPerSegment: 8, transitionFramesPerSegment: 8,
                      segmentCount: 2, selector: .sequential, seed: 42,
                      loopCycles: 1, stagger: 0, out: outResume, loopRepeatCount: 1),
            sources: [], checkpointIntervalFrames: 8, resumeFrom: cpURL)
        for try await _ in stream {}

        let a = try await decodeFrames(outFresh), b = try await decodeFrames(outResume)
        XCTAssertEqual(a.count, b.count)
        for i in 0..<a.count {
            XCTAssertLessThanOrEqual(maxAbsDiff(a[i], b[i]), 0,
                                     "multi-flame flameIndex=1 pixel diff at frame \(i)")
        }
    }

    // MARK: - T8′ resume byte-identity for temporal smoothing (centered box window)

    /// Build a smoothing-ON job (α = 0.1 ⇒ centered-box-window half-width
    /// h = round(1/0.1) = 10) matching `makeJob`'s fixture (sierpinski, 160x100,
    /// ProRes, spp 20, ts 1). `segmentCount: 2` → 1 loop (8 frames) + 1 transition
    /// (8 frames) = 16 global frames.
    private func makeSmoothingJob(out: URL, loopRepeatCount: Int) throws -> ExportJob {
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.codec = .proRes422HQ; settings.container = .mov
        settings.resolution = .custom(width: 160, height: 100); settings.fps = 30
        settings.quality = .spp(20); settings.temporalSamples = 1
        settings.smoothingAlpha = 0.1   // smoothing ON — h ≈ 10 frames
        return ExportJob(settings: settings, flames: flames, framesPerSegment: 8,
                         transitionFramesPerSegment: 8, segmentCount: 2, selector: .sequential,
                         seed: 42, loopCycles: 1, stagger: 0, out: out,
                         loopRepeatCount: loopRepeatCount)
    }

    /// §9.5 resume byte-identity pin (smoothing ON): a smoothing-ON export paused
    /// DEEP (after chunks 0,1 of 4; chunk size 4, h=10) and resumed produces
    /// byte-identical frames to a never-paused export of the same job. T8′ (centered
    /// box window) makes this trivial: each chunk builds a FRESH per-call window fed
    /// an h-frame-margin extended range, so each chunk is self-contained — resume
    /// simply re-renders the chunk and its margins reconstruct the identical window.
    /// There is NO run-scoped accumulator and NO warmup (the old causal-EMA
    /// `[0,F)` full-window warmup is gone).
    func testResumeSmoothingByteIdentity() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outFresh = dir.appendingPathComponent("fresh.mov")
        let outResume = dir.appendingPathComponent("resume.mov")

        // Never-paused: run the smoothing-ON job through runResumable (same path
        // as the resume, so both use renderFramesInterleaved with smoothing).
        let coordFresh = ExportCoordinator(backend: .cpu)
        let streamFresh = await coordFresh.runResumable(
            try makeSmoothingJob(out: outFresh, loopRepeatCount: 1),
            sources: [], checkpointIntervalFrames: 4, resumeFrom: nil)
        for try await _ in streamFresh {}

        // Paused DEEP: interval 4 → 4 chunks (4 frames each); pause at chunk-top
        // of 2 (chunks 0,1 complete → F = 2*4 = 8 ≈ τ at α=0.1).
        let coordPause = ExportCoordinator(backend: .cpu)
        await coordPause._setTestPauseAfterChunk(2)
        let streamPause = await coordPause.runResumable(
            try makeSmoothingJob(out: outResume, loopRepeatCount: 1),
            sources: [], checkpointIntervalFrames: 4, resumeFrom: nil)
        do {
            for try await _ in streamPause {}
            XCTFail("expected ExportError.paused")
        } catch ExportError.paused {
            // expected — checkpoint + chunks 0,1 remain on disk
        } catch {
            XCTFail("expected ExportError.paused, got \(error)")
        }

        // Resume from the checkpoint.
        let cpURL = ExportCheckpoint.checkpointURL(out: outResume)
        let resumeCoord = ExportCoordinator(backend: .cpu)
        let streamResume = await resumeCoord.runResumable(
            try makeSmoothingJob(out: outResume, loopRepeatCount: 1),
            sources: [], checkpointIntervalFrames: 4, resumeFrom: cpURL)
        for try await _ in streamResume {}

        // Byte-identity: resumed output == never-paused output.
        let a = try await decodeFrames(outFresh), b = try await decodeFrames(outResume)
        XCTAssertEqual(a.count, b.count,
                       "frame count mismatch (smoothing resume byte-identity)")
        for i in 0..<a.count {
            XCTAssertLessThanOrEqual(maxAbsDiff(a[i], b[i]), 0,
                                     "smoothing resume pixel diff at frame \(i) "
                                     + "(per-chunk window margins must reconstruct the identical window)")
        }
    }
}
