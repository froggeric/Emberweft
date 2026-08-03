import XCTest
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
@testable import FlameExport
@testable import EmberweftCLI
import FlameKit
import FlameReference

/// Task 6 — long-form segment + concat. `ExportCoordinator.runLongForm` chunks
/// the timeline on Schedule-segment edges, encodes each chunk to a temp `.mov`
/// beside `out`, and concatenates via `AVMutableComposition` + passthrough (no
/// re-encode). Temps are registered at creation and removed in a `defer` that
/// runs on success, cancel, AND failure.
///
/// Most tests drive the coordinator directly at a small custom resolution
/// (160×100, spp 10–20) so the gate runs in seconds — the render-quality path
/// is pinned by `ExportCoordinatorTests`; here we only assert chunking + concat
/// + duration + cleanup, which are resolution-independent. One CLI smoke test
/// verifies the `--segment-frames` wiring end-to-end at minimal cost.
///
/// AC mapping:
/// - AC1 (duration == sum of chunks): `testLongFormDurationIsSumOfChunks`.
/// - AC2 (seam continuity — no dup/drop/black at splices): `testLongFormSeamContinuity`.
/// - AC3 (temps cleaned on success/cancel/failure): the three `…TempsCleaned…` tests.
/// - Wiring: `testSegmentFramesFlagDispatchesLongForm` (CLI smoke).
final class ExportLongFormTests: XCTestCase {
    private func sierpinski() -> String {
        // `#filePath` (not `#file`): in Swift 6.2 `#file` returns a basename /
        // file ID, which collapses the directory chain and resolves the genome
        // against the wrong root. The rest of the test suite uses `#filePath`.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3").path
    }
    private func genome(_ name: String) throws -> [Flame] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name)")
        return try Flam3Parser.parse(Data(contentsOf: url))
    }
    /// A fresh per-test dir under the system temp. Temps live beside `out`, so
    /// scanning this dir after the run detects any leaked `m6-seg-*` segment.
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("m6lf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Standard small-res job: 6 segments × 8 frames = 48 frames. `budget`
    /// controls chunk size (8 → 1 segment/chunk → 6 chunks; 16 → 2 → 3 chunks).
    private func longFormJob(budget: Int, width: Int = 160, height: Int = 100, spp: Int = 20,
                             out: URL) throws -> ExportJob {
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.resolution = .custom(width: width, height: height); settings.fps = 30
        settings.quality = .spp(spp)
        settings.segmentFrameBudget = budget
        return ExportJob(settings: settings, flames: flames, framesPerSegment: 8,
                         segmentCount: 6, selector: .sequential, seed: 7,
                         loopCycles: 1, stagger: 0, out: out)
    }

    private func decodedDurationSeconds(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let t = try await asset.load(.duration)
        return CMTimeGetSeconds(t)
    }

    /// Decode every video frame as 32BGRA via `AVAssetReader` (mirrors
    /// `VideoEncoderTests.decodeFrames`). Returns CVPixelBuffers in PTS order.
    private func decodeFrames(_ url: URL) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        guard let track else {
            throw NSError(domain: "ExportLongFormTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no video track"])
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "ExportLongFormTests", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "startReading failed"])
        }
        var frames: [CVPixelBuffer] = []
        while let sb = output.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sb) { frames.append(pb) }
        }
        return frames
    }

    /// Max channel value over a decoded frame (sparse grid sample; > 10 ⇒ not black).
    private func maxChannel(_ pb: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        var mx: UInt8 = 0
        let step = max(1, w / 32)
        for y in 0..<h {
            let rowBase = y * rowBytes
            var x = 0
            while x < w {
                let p = rowBase + x * 4      // BGRA
                mx = max(mx, base.load(fromByteOffset: p, as: UInt8.self))
                mx = max(mx, base.load(fromByteOffset: p + 1, as: UInt8.self))
                mx = max(mx, base.load(fromByteOffset: p + 2, as: UInt8.self))
                x += step
            }
        }
        return Int(mx)
    }

    // MARK: AC1 — duration == sum of chunk durations (no gap/overlap)

    /// 6 segments × 8 frames = 48 frames / 30 fps = 1.6 s. `budget = 16` →
    /// `chunkSegments = max(1, 16/8) = 2` → 3 chunks of 2 segments (16 frames)
    /// each. A gap or overlap at a splice would make the decoded duration ≠ 1.6 s.
    func testLongFormDurationIsSumOfChunks() async throws {
        let out = tmpDir().appendingPathComponent("concat.mp4")
        let job = try longFormJob(budget: 16, out: out)
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runLongForm(job)
        for try await _ in stream {}
        let total = try await decodedDurationSeconds(out)
        XCTAssertEqual(total, 1.6, accuracy: 0.05,
                       "3 chunks × 16 frames / 30 fps = 1.6 s (no gap/overlap at splices)")
        try? FileManager.default.removeItem(at: out)
    }

    // MARK: AC2 — seam continuity (no dup/drop/black at splices)

    /// Passthrough concat preserves the per-chunk encoded frames exactly (no
    /// re-encode), and all chunks share identical `ExportSettings` → a splice
    /// frame is byte-identical to what the encoder produced for that global
    /// frame. So the practical seam-continuity check is:
    ///   - decoded count == totalFrames (a dup or drop at a splice shifts count)
    ///   - every decoded frame non-black (an encode failure at a splice is black)
    /// `budget = 8`, `framesPerSegment = 8` → 1 segment/chunk → 6 chunks of 8
    /// frames, exercising 5 splices.
    func testLongFormSeamContinuity() async throws {
        let out = tmpDir().appendingPathComponent("seam.mp4")
        let job = try longFormJob(budget: 8, out: out)
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runLongForm(job)
        for try await _ in stream {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "concat output must exist")

        let frames = try await decodeFrames(out)
        XCTAssertEqual(frames.count, 48, "no dup/drop at splices: 6 chunks × 8 frames = 48")
        for (i, f) in frames.enumerated() {
            XCTAssertGreaterThan(maxChannel(f), 10, "frame \(i) is black — encode failure at a splice")
        }
        try? FileManager.default.removeItem(at: out)
    }

    // MARK: AC3 — temps cleaned on every exit path

    /// Success: after a full 3-chunk run, no `m6-seg-*` temp remains beside `out`.
    func testLongFormTempsCleanedAfterSuccess() async throws {
        let tmpRoot = tmpDir()
        let out = tmpRoot.appendingPathComponent("concat.mp4")
        let job = try longFormJob(budget: 16, out: out)
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runLongForm(job)
        for try await _ in stream {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: tmpRoot.path)) ?? []
        let leaks = leftover.filter { $0.hasPrefix("m6-seg-") }
        XCTAssertTrue(leaks.isEmpty, "long-form temp segment leaked after success: \(leftover)")
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    /// Cancel: a mid-flight cancel leaves no temp. Cancels AFTER chunk 1
    /// completes (so a completed-segment temp exists and must be cleaned) and
    /// during chunk 2; the throw lands in chunk 2. `currentFrame` is the global
    /// frame +1, so chunk 2's first frame (global 8) yields `currentFrame == 9`.
    func testLongFormTempsCleanedAfterCancel() async throws {
        let tmpRoot = tmpDir()
        let out = tmpRoot.appendingPathComponent("concat.mp4")
        let job = try longFormJob(budget: 8, width: 128, height: 80, spp: 10, out: out)
        let coord = ExportCoordinator(backend: .cpu)
        var threw = false
        do {
            let stream = await coord.runLongForm(job)
            for try await p in stream {
                if p.currentFrame >= 9 { await coord.cancel() }
            }
        } catch { threw = true }
        XCTAssertTrue(threw, "a cancelled long-form run must throw")
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: tmpRoot.path)) ?? []
        let leaks = leftover.filter { $0.hasPrefix("m6-seg-") }
        XCTAssertTrue(leaks.isEmpty, "temp leaked after mid-flight cancel: \(leftover)")
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    /// Forced failure (pre-cancel): aborts before any chunk completes; no temp
    /// remains. Cancel and encoder-failure share the same `do/catch + defer`
    /// cleanup path in `runLongFormJob`, so this + the mid-flight-cancel test
    /// together cover the generic failure exit (with and without a created temp).
    func testLongFormTempsCleanedAfterFailure() async throws {
        let tmpRoot = tmpDir()
        let out = tmpRoot.appendingPathComponent("concat.mp4")
        let job = try longFormJob(budget: 16, width: 128, height: 80, spp: 10, out: out)
        let coord = ExportCoordinator(backend: .cpu)
        await coord.cancel()   // pre-cancel: the first chunk's first frame throws
        var threw = false
        do {
            let stream = await coord.runLongForm(job)
            for try await _ in stream {}
        } catch { threw = true }
        XCTAssertTrue(threw, "a pre-cancelled long-form run must throw")
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: tmpRoot.path)) ?? []
        let leaks = leftover.filter { $0.hasPrefix("m6-seg-") }
        XCTAssertTrue(leaks.isEmpty, "temp leaked after failure: \(leftover)")
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // MARK: CLI wiring

    /// Smoke test: `--segment-frames N > 0` dispatches the long-form path
    /// end-to-end through the CLI (parse → settings.segmentFrameBudget →
    /// coord.runLongForm → concat → file at `out`). Tiny sizing (3 segments × 2
    /// frames = 6 frames, spp 5, 720p) keeps it cheap; the coordinator-level
    /// tests above carry the correctness load. Verifies AC: dispatch + output.
    func testSegmentFramesFlagDispatchesLongForm() async throws {
        let out = tmpDir().appendingPathComponent("cli.mp4")
        let rc = await EmberweftCLI.export([sierpinski(), sierpinski(),
                                            "--frames", "2", "--segments", "3",
                                            "--segment-frames", "4",
                                            "--backend", "cpu", "--quality", "5",
                                            "--resolution", "720p", "--out", out.path])
        XCTAssertEqual(rc, 0, "CLI long-form export must succeed (rc 0)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        // chunkSegments = max(1, 4/2) = 2 → 2 chunks (2 segments + 1 segment).
        // 6 frames / 30 fps = 0.2 s.
        let total = try await decodedDurationSeconds(out)
        XCTAssertEqual(total, 0.2, accuracy: 0.03)
        // No temp leak via the CLI path either.
        let dir = out.deletingLastPathComponent()
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let leaks = leftover.filter { $0.hasPrefix("m6-seg-") }
        XCTAssertTrue(leaks.isEmpty, "CLI long-form leaked a temp: \(leftover)")
        try? FileManager.default.removeItem(at: out)
    }
}
