import XCTest
import Foundation
import CoreVideo
import CoreMedia
import AVFoundation
@testable import EmberweftCLI
@testable import FlameExport
import FlameKit
import FlameReference
import FlameRenderer

/// M6.1 Task 9 — CLI `--checkpoint-frames` / `--resume` / `--discard` smoke tests.
///
/// These exercise the CLI WIRING (arg parsing, dispatch to `runResumable`,
/// checkpoint `out` validation, D11 conflicting-recipe-flag rejection,
/// `--discard` removal, success auto-delete). They mirror the existing
/// `await EmberweftCLI.export([...])` pattern in `ExportCommandTests`.
///
/// What is NOT tested here (per the plan):
/// - SIGINT itself (sending SIGINT to the XCTest process is unsafe/fragile).
///   The cancel-KEEPS-checkpoint BEHAVIOR is pinned at the coordinator level
///   (`RunResumableTests.testCancelKeepsCheckpointAtCoordinatorLevel`); the
///   SIGINT WIRING (`DispatchSource.makeSignalSource`) is manual.
/// - Resume pixel-identity (pinned at the coordinator level by
///   `RunResumableTests.testResumePixelIdentity`). The CLI resume test asserts
///   completion + frame count only.
///
/// Pixel-decode helpers (`decodeFrames`/`maxAbsDiff`) are duplicated from
/// `RunResumableTests` — they are tiny, and extracting a shared test-support
/// file is out of scope for this task (same call the coordinator tests made).
final class ExportCheckpointCLITests: XCTestCase {
    private func sierpinskiPath() -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3").path
    }
    private func sierpinskiURL() -> URL {
        URL(fileURLWithPath: sierpinskiPath())
    }
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-cli-resume-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - Pixel-decode helpers (duplicated from RunResumableTests)

    private func decodeFrames(_ url: URL) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "ExportCheckpointCLITests", code: 1)
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

    // MARK: - Checkpoint seeding via the coordinator pause-seam

    /// Build a small, fast job for seeding a paused checkpoint (160×100 ProRes,
    /// spp20, 2 segments = 16 frames). The seed goes through the coordinator
    /// DIRECTLY (not the CLI), so it can use a tiny custom resolution — the
    /// resume/discard/conflict tests check WIRING, not pixel resolution. Mirrors
    /// `RunResumableTests.makeJob`. The CLI `--resume` reads the recipe (incl.
    /// this 160×100 size) from the checkpoint.
    private func makeSeedJob(out: URL) throws -> ExportJob {
        let flames = try Flam3Parser.parse(Data(contentsOf: sierpinskiURL()))
        var settings = ExportSettings()
        settings.codec = .proRes422HQ; settings.container = .mov
        settings.resolution = .custom(width: 160, height: 100); settings.fps = 30
        settings.quality = .spp(20); settings.temporalSamples = 1
        return ExportJob(settings: settings, flames: flames, framesPerSegment: 8,
                         transitionFramesPerSegment: 8, segmentCount: 2, selector: .sequential,
                         seed: 42, loopCycles: 1, stagger: 0, out: out)
    }

    /// Seed a paused checkpoint beside `out`: run the coordinator with
    /// `_testPauseAfterChunk = 0` (interval 8 → 2 chunks) so chunk 0 completes +
    /// is checkpointed, then pause fires at chunk 1's top. Leaves chunk-0000 +
    /// the checkpoint on disk — exactly what a Ctrl-C mid-run leaves. Uses a
    /// file-backed source (mirrors the CLI's URL+SHA-256 path).
    @discardableResult
    private func seedPausedCheckpoint(out: URL) async throws -> ExportCheckpoint {
        let job = try makeSeedJob(out: out)
        let coord = ExportCoordinator(backend: .cpu)
        // `_testPauseAfterChunk = 1` fires `paused = true` at chunk 1's TOP —
        // AFTER chunk 0 fully completes + is checkpointed (interval 8 → 2 chunks).
        // (Using 0 would pause before any render → no checkpoint. Mirrors
        // RunResumableTests.seedPaused.)
        await coord._setTestPauseAfterChunk(1)
        let source = ExportCheckpoint.Source(fileURL: sierpinskiURL(), flameIndex: 0,
                                              sha256: nil, serializedText: nil, displayName: "sierpinski")
        let stream = await coord.runResumable(job, sources: [source],
                                              checkpointIntervalFrames: 8, resumeFrom: nil)
        do {
            for try await _ in stream {}
            XCTFail("expected ExportError.paused from seed")
        } catch ExportError.paused {
            // expected — checkpoint + chunk-0000 remain on disk
        } catch {
            XCTFail("expected ExportError.paused from seed, got \(error)")
        }
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        return try JSONDecoder().decode(ExportCheckpoint.self, from: Data(contentsOf: cpURL))
    }

    // MARK: - AC: `--checkpoint-frames` output is pixel-identical to no-flag export

    /// Determinism pin (rule #2): routing through `runResumable` (via
    /// `--checkpoint-frames`) must produce pixel-identical output to the plain
    /// `run` path (no `--checkpoint-frames`). Uses ProRes (intra-frame) so the
    /// comparison is meaningful; the same coordinator-level identity is pinned
    /// by `RunResumableTests.testFreshRunOneChunkMatchesRunRepeat1`, this pins
    /// the CLI WIRING (that `--checkpoint-frames > 0` routes to `runResumable`
    /// and builds sources from the input file paths).
    func testCheckpointFramesPixelMatchesNoFlag() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outPlain = dir.appendingPathComponent("plain.mov")
        let outCkpt = dir.appendingPathComponent("ckpt.mov")

        // Single genome (sierpinski) → `--segments 1` (CLI requires 2 genomes
        // for transitions). 1 loop segment × 4 frames = 4 global frames. spp10
        // keeps the 720p pixel comparison fast.
        let args = [sierpinskiPath(), "--codec", "prores-422-hq", "--container", "mov",
                    "--resolution", "720p", "--quality", "10",
                    "--segments", "1", "--frames", "4", "--backend", "cpu"]
        let rc1 = await EmberweftCLI.export(args + ["--out", outPlain.path])
        XCTAssertEqual(rc1, 0, "plain export failed (rc=\(rc1))")
        // `--checkpoint-frames 2` over 4 global frames → 2 chunks (multi-chunk path).
        let rc2 = await EmberweftCLI.export(args + ["--checkpoint-frames", "2", "--out", outCkpt.path])
        XCTAssertEqual(rc2, 0, "checkpoint export failed (rc=\(rc2))")

        let a = try await decodeFrames(outPlain), b = try await decodeFrames(outCkpt)
        XCTAssertEqual(a.count, b.count, "frame count mismatch (plain=\(a.count), ckpt=\(b.count))")
        for i in 0..<a.count {
            XCTAssertLessThanOrEqual(maxAbsDiff(a[i], b[i]), 0,
                                     "pixel diff at frame \(i): --checkpoint-frames must pixel-match no-flag")
        }
    }

    // MARK: - AC: a completed `--checkpoint-frames` run auto-deletes its checkpoint

    /// Success cleanup: on a clean completion the coordinator deletes the
    /// checkpoint + chunk temps (Task 4). The CLI inherits this (it does not
    /// touch the checkpoint on success). Asserts NO `.emberweft-export.json` or
    /// `.emberweft-chunk-` files remain beside `out`.
    func testCompletedRunAutoDeletesCheckpoint() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("auto.mov")
        let rc = await EmberweftCLI.export([sierpinskiPath(), "--codec", "prores-422-hq",
                                            "--container", "mov", "--resolution", "720p",
                                            "--quality", "10", "--segments", "1", "--frames", "4",
                                            "--checkpoint-frames", "2", "--backend", "cpu",
                                            "--out", out.path])
        XCTAssertEqual(rc, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "out must exist")
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cpURL.path),
                       "checkpoint must be auto-deleted on clean completion")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let chunkTemps = entries.filter { $0.contains(".emberweft-chunk-") }
        XCTAssertTrue(chunkTemps.isEmpty, "chunk temps must be cleaned on success, found \(chunkTemps)")
    }

    // MARK: - AC: `--resume` completes a previously-checkpointed run

    /// Seeds a paused checkpoint (chunk 0 done) via the coordinator pause-seam,
    /// then `emberweft export --resume <out>` must complete the run (exit 0,
    /// output exists, correct frame count). Pixel-identity of resume itself is
    /// pinned at the coordinator level; this asserts the CLI resume WIRING.
    func testResumeCompletesPausedRun() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("resume.mov")
        let cp = try await seedPausedCheckpoint(out: out)
        XCTAssertEqual(cp.completedChunkIndexes, [0], "seed: chunk 0 must be completed")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ExportCheckpoint.checkpointURL(out: out).path), "seed: checkpoint must exist")

        let rc = await EmberweftCLI.export(["--resume", out.path])
        XCTAssertEqual(rc, 0, "--resume must complete the paused run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "output must exist after resume")
        // Success auto-deletes the checkpoint (no leftover state).
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ExportCheckpoint.checkpointURL(out: out).path),
                       "checkpoint must be deleted after a completed resume")

        let frames = try await decodeFrames(out)
        // 2 segments (8 frames each) = 16 global frames.
        XCTAssertEqual(frames.count, 16, "resume must produce the full 16-frame timeline")
    }

    // MARK: - AC: conflicting recipe flag + `--resume` ⇒ exit 2 (D11)

    /// D11: on `--resume` the checkpoint recipe is AUTHORITATIVE — passing any
    /// recipe flag alongside `--resume` must error with exit 2 and the
    /// authoritative-recipe message, without running. Covers one flag per
    /// recipe category (encoder / framing / identity / source).
    func testConflictingRecipeFlagsWithResumeExit2() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("conflict.mov")
        _ = try await seedPausedCheckpoint(out: out)

        // One representative from each recipe category. All must exit 2.
        let recipeFlags: [[String]] = [
            ["--codec", "h264"],
            ["--container", "mp4"],
            ["--fps", "30"],
            ["--resolution", "720p"],
            ["--quality", "20"],
            ["--frames", "8"],
            ["--transition-frames", "8"],
            ["--segments", "2"],
            ["--seed", "42"],
            ["--loop-cycles", "1"],
            ["--stagger", "0"],
        ]
        for flag in recipeFlags {
            let rc = await EmberweftCLI.export(["--resume", out.path] + flag)
            XCTAssertEqual(rc, 2, "--resume + \(flag.joined(separator: " ")) must exit 2 (D11)")
        }
        // The checkpoint must be untouched (no run happened).
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ExportCheckpoint.checkpointURL(out: out).path),
                      "D11 rejection must not delete the checkpoint")
    }

    /// The checkpoint's stored `out` must match the `--resume <path>` arg
    /// (else error). Seeds a real checkpoint whose `out` is `real.mov`, plants a
    /// COPY of it beside `other.mov` (so `other.emberweft-export.json` exists but
    /// its stored `out` is still `real.mov`), then `--resume other.mov` must
    /// reject the mismatch. Also covers the no-checkpoint path via a third path.
    func testResumeOutMismatchErrors() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realOut = dir.appendingPathComponent("real.mov")
        let otherOut = dir.appendingPathComponent("other.mov")
        let missingOut = dir.appendingPathComponent("missing.mov")
        // Seed a real checkpoint (out = real.mov) + chunk-0000.
        _ = try await seedPausedCheckpoint(out: realOut)

        // Plant a copy beside other.mov: its stored `out` is still real.mov, so
        // `--resume other.mov` must reject the mismatch (the checkpoint belongs
        // to a different output path).
        let realCP = ExportCheckpoint.checkpointURL(out: realOut)
        let otherCP = ExportCheckpoint.checkpointURL(out: otherOut)
        try FileManager.default.copyItem(at: realCP, to: otherCP)
        let rcMismatch = await EmberweftCLI.export(["--resume", otherOut.path])
        XCTAssertNotEqual(rcMismatch, 0,
                          "--resume against a checkpoint whose stored out differs must error")

        // No-checkpoint path: missing.mov has nothing beside it → error too.
        let rcMissing = await EmberweftCLI.export(["--resume", missingOut.path])
        XCTAssertNotEqual(rcMissing, 0,
                          "--resume against a path with no checkpoint must error")
        // The real checkpoint is untouched (no run happened on either reject).
        XCTAssertTrue(FileManager.default.fileExists(atPath: realCP.path),
                      "mismatch/missing rejection must not delete the real checkpoint")
    }

    // MARK: - AC: `--discard` removes the checkpoint + chunk files

    /// `--discard <out>` deletes the checkpoint + all chunk temps beside `out`.
    /// Seeds a paused state (checkpoint + chunk-0000 present), runs `--discard`,
    /// asserts both are gone and the exit code is 0.
    func testDiscardRemovesCheckpointAndChunks() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("discard.mov")
        _ = try await seedPausedCheckpoint(out: out)
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        let chunk0 = ExportCheckpoint.chunkURL(out: out, index: 0, container: .mov)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cpURL.path), "seed: checkpoint must exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk0.path), "seed: chunk-0000 must exist")

        let rc = await EmberweftCLI.export(["--discard", out.path])
        XCTAssertEqual(rc, 0, "--discard must exit 0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cpURL.path),
                       "--discard must remove the checkpoint")
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk0.path),
                       "--discard must remove completed chunks")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let leftovers = entries.filter { $0.contains(".emberweft-chunk-") || $0.contains(".emberweft-export.json") }
        XCTAssertTrue(leftovers.isEmpty, "--discard must remove all checkpoint artifacts, found \(leftovers)")
    }
}
