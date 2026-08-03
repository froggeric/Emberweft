import XCTest
import AVFoundation
import CoreVideo
@testable import FlameExport
import FlameKit
import FlameRenderer

/// M6-G.2: pins that `ExportCoordinator(backend: .metal, useOffMainMetal: true)`
/// dispatches Metal off-main (the GUI path) and produces byte-identical output to
/// the default MainActor path (the CLI path). Off-main-ness itself is already
/// pinned by `MetalFrameRendererSmokeTests` (single-pass) + M6-G.1's
/// `OffMainTemporalParityTests` (temporal); THIS suite proves the coordinator
/// WIRING — the flag selects the off-main branch and the resulting encoded frame
/// matches the MainActor branch's frame byte-for-byte (same Flame/seed/params/plan
/// → same decoded pixels). The default `useOffMainMetal: false` keeps the CLI path
/// byte-for-byte unchanged (re-verified by re-running the full `FlameExportTests`
/// suite after the change).
@MainActor
final class OffMainDispatchTests: XCTestCase {

    private func sierpinski() throws -> [Flame] {
        // `#filePath` (not `#file`): in Swift 6 `#file` is a short file-ID, not
        // the absolute source path (ExportCoordinatorTests convention).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3")
        return try Flam3Parser.parse(Data(contentsOf: url))
    }

    private func tmpMP4() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("m6offmain-\(UUID().uuidString).mp4")
    }

    /// Decode the first frame of `url` as raw 32BGRA bytes — the encoder's native
    /// sink format (`PixelBufferPool` fills 32BGRA via an R<->B swap). Running BOTH
    /// decodes through the same `AVAssetReader` + 32BGRA path makes the byte
    /// comparison a true pixel equality (any decoder transform applies identically
    /// to both sides). Row-by-row copy honors `bytesPerRow` padding (the decoder
    /// may pad rows to a multiple of alignment; naively reading `w*h*4` contiguous
    /// bytes would read past the row stride).
    private func firstFrameBGRABytes(of url: URL) async throws -> [UInt8] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "OffMainDispatchTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetReader failed to start"])
        }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer() else {
            throw NSError(
                domain: "OffMainDispatchTests", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no decoded frame"])
        }
        guard let pb = CMSampleBufferGetImageBuffer(sample) else {
            throw NSError(
                domain: "OffMainDispatchTests", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "no pixel buffer in sample"])
        }
        CVPixelBufferLockBaseAddress(pb, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(pb, [.readOnly]) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            throw NSError(
                domain: "OffMainDispatchTests", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "no base address"])
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(w * h * 4)
        for row in 0..<h {
            let rowStart = base.advanced(by: row * bpr)
            bytes.append(contentsOf: UnsafeBufferPointer(
                start: rowStart.assumingMemoryBound(to: UInt8.self), count: w * 4))
        }
        return bytes
    }

    /// AC: a 1-frame Metal job with `useOffMainMetal: true` completes and its
    /// decoded frame's pixels equal the `useOffMainMetal: false` (MainActor) run's
    /// pixels at the same seed/params. Transitively proves the off-main branch is
    /// wired (the flag is accepted, the run succeeds via the off-main path) AND
    /// byte-identical to the CLI path. Single-pass (`temporalSamples=1`) exercises
    /// the `renderOffMain` sub-branch; the temporal sub-branch
    /// (`renderTemporalOffMain`) is byte-identity-pinned by M6-G.1's
    /// `OffMainTemporalParityTests` against the same fused cores this coordinator
    /// branch dispatches to.
    func testExportCoordinatorOffMainMetalDispatchesOffMain() async throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flames = try sierpinski()
        var settings = ExportSettings()
        settings.resolution = .custom(width: 128, height: 80)
        settings.fps = 30
        settings.temporalSamples = 1
        settings.quality = .spp(2)   // low spp keeps the 1-frame Metal render fast

        let outMain = tmpMP4()
        let outOff = tmpMP4()
        defer {
            try? FileManager.default.removeItem(at: outMain)
            try? FileManager.default.removeItem(at: outOff)
        }

        // Same job, two coordinators differing ONLY in useOffMainMetal. The
        // @MainActor test method suspends at each `await`, so the coordinator's
        // internal `await MainActor.run { MetalRenderer.render(…) }` (the
        // useOffMainMetal==false path) can re-enter the MainActor without
        // deadlock — the same way ExportPresetsTests drive the CLI export path.
        func runCoord(useOffMain: Bool, out: URL) async throws {
            let coord = ExportCoordinator(backend: .metal, useOffMainMetal: useOffMain)
            let job = ExportJob(settings: settings, flames: flames, framesPerSegment: 1,
                                segmentCount: 1, selector: .sequential, seed: 7,
                                loopCycles: 1, stagger: 0, out: out)
            let stream = await coord.run(job)
            for try await _ in stream {}
        }
        try await runCoord(useOffMain: false, out: outMain)   // CLI / MainActor path
        try await runCoord(useOffMain: true, out: outOff)     // GUI / off-main path

        XCTAssertTrue(FileManager.default.fileExists(atPath: outMain.path),
                      "MainActor-path export must produce a file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outOff.path),
                      "off-main-path export must produce a file")

        let mainBytes = try await firstFrameBGRABytes(of: outMain)
        let offBytes = try await firstFrameBGRABytes(of: outOff)
        XCTAssertGreaterThan(mainBytes.max() ?? 0, 0,
                             "MainActor-path frame must be non-empty (not solid black/transparent)")
        XCTAssertEqual(mainBytes, offBytes,
                       "off-main-path decoded frame must equal MainActor-path decoded frame (byte-identical pixels)")
    }
}
