import XCTest
import CoreVideo
import CoreMedia
import AVFoundation
@testable import FlameExport
import FlameKit
import FlameReference

final class RenderFramesInterleavedTests: XCTestCase {
    // Real fixture pattern (ExportLongFormTests.swift:36-41 / LoopRepeatTests.swift:23-28).
    private func genome(_ name: String) throws -> [Flame] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name)")
        return try Flam3Parser.parse(Data(contentsOf: url))
    }
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("m6ilv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    // P5: the real helper is `async throws` at ExportLongFormTests.swift:71.
    private func decodeFrames(_ url: URL) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "RenderFramesInterleavedTests", code: 1)
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
    // P4: NEW helper. Max absolute per-channel BGRA diff over two decoded frames.
    // Two encodes of identical input frames through the same deterministic
    // VideoToolbox session produce byte-identical files → identical decoded frames.
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

    /// Migrated in Task 4: the temporary `_testRenderInterleavedToDisk` wrapper
    /// is deleted now that `runResumable(interval >= total)` covers the
    /// one-chunk case. The byte-identity proof routes through the REAL resumable
    /// path (one chunk = the whole timeline) — same `maxAbsDiff == 0` pin.
    private func renderInterleaved(_ job: ExportJob, backend: ExportCoordinator.Backend) async throws -> URL {
        let coord = ExportCoordinator(backend: backend)
        let stream = await coord.runResumable(job, checkpointIntervalFrames: 999_999, resumeFrom: nil)
        for try await _ in stream {}
        return job.out
    }

    private func runJob(_ job: ExportJob, backend: ExportCoordinator.Backend) async throws {
        let coord = ExportCoordinator(backend: backend)
        let stream = await coord.run(job)
        for try await _ in stream {}
    }

    private func assertInterleavedMatchesRun(loopRepeatCount: Int) async throws {
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.codec = .proRes422HQ; settings.container = .mov
        settings.resolution = .custom(width: 160, height: 100); settings.fps = 30
        settings.quality = .spp(20); settings.temporalSamples = 1
        let mkJob = { (out: URL) in
            ExportJob(settings: settings, flames: flames, framesPerSegment: 8,
                      transitionFramesPerSegment: 8, segmentCount: 2, selector: .sequential,
                      seed: 42, loopCycles: 1, stagger: 0, out: out, loopRepeatCount: loopRepeatCount)
        }
        let dir = tmpDir()
        let outRun = dir.appendingPathComponent("run.mov")
        let outIlv = dir.appendingPathComponent("ilv.mov")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await runJob(mkJob(outRun), backend: .cpu)
        let ilv = try await renderInterleaved(mkJob(outIlv), backend: .cpu)
        let a = try await decodeFrames(outRun), b = try await decodeFrames(ilv)
        XCTAssertEqual(a.count, b.count, "frame count mismatch at loopRepeatCount=\(loopRepeatCount)")
        for i in 0..<a.count {
            XCTAssertLessThanOrEqual(maxAbsDiff(a[i], b[i]), 0, "pixel diff at frame \(i) (loopRepeatCount=\(loopRepeatCount))")
        }
    }

    func testInterleavedMatchesRunAtRepeat1() async throws { try await assertInterleavedMatchesRun(loopRepeatCount: 1) }
    func testInterleavedMatchesRunAtRepeat2() async throws { try await assertInterleavedMatchesRun(loopRepeatCount: 2) }  // F2 headline
}
