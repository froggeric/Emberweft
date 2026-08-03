import XCTest
@testable import FlameExport
import FlameKit
import AVFoundation
import CoreMedia
import CoreVideo

final class VideoEncoderTests: XCTestCase {
    private func gradient(_ i: Int, _ n: Int) -> RGBA8Image {
        let w = 64, h = 48
        let v = UInt8((Double(i) / Double(max(1, n - 1)) * 255).rounded())
        return RGBA8Image(width: w, height: h, pixels: [UInt8](repeating: v, count: w * h * 4))
    }

    /// Decode every video frame from `url` as 32BGRA via `AVAssetReader`.
    /// Returns the CVPixelBuffers in PTS order (CF-managed; retained by the array).
    /// Throws if the asset has no video track or the reader fails to start.
    private func decodeFrames(_ url: URL) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        guard let track else {
            throw NSError(domain: "VideoEncoderTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no video track"])
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoEncoderTests", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "startReading failed"])
        }
        var frames: [CVPixelBuffer] = []
        while let sb = output.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sb) { frames.append(pb) }
        }
        return frames
    }

    /// Mean per-channel luma (0...255) of a decoded BGRA row. Used by the
    /// orientation test to compare top vs bottom brightness without depending
    /// on exact H.264 quantization (lossy -> tolerant thresholds).
    private func rowMeanLuma(_ pb: CVPixelBuffer, row: Int) -> Int {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        precondition(row >= 0 && row < h, "row out of range")
        var sum = 0
        for x in 0..<w {
            let p = row * rowBytes + x * 4      // BGRA
            sum += Int(base[p]) + Int(base[p + 1]) + Int(base[p + 2])
        }
        return sum / (w * 3)
    }

    func testEncodeDecodeBack() async throws {
        let w = 64, h = 48, fps = 30, n = 10
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-enc-\(UUID().uuidString).mov")
        var settings = ExportSettings()
        settings.codec = .h264; settings.container = .mov
        settings.resolution = .custom(width: w, height: h); settings.fps = fps
        let enc = try VideoEncoder(settings: settings, outputURL: out)
        try enc.start()
        for i in 0..<n { try await enc.append(gradient(i, n), atFrame: i) }
        try await enc.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        defer { try? FileManager.default.removeItem(at: out) }

        let asset = AVURLAsset(url: out)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let dims = try await track.load(.naturalSize)
        XCTAssertEqual(Int(dims.width), w, "naturalSize width")
        XCTAssertEqual(Int(dims.height), h, "naturalSize height")

        // CFR is written at exact CMTime(value: i, timescale: fps), so the
        // track's nominal frame rate must equal the requested fps.
        let nominalFPS = try await track.load(.nominalFrameRate)
        XCTAssertEqual(nominalFPS, Float(fps), accuracy: 1.0, "nominalFrameRate ≈ fps")

        // Actual decode — count must equal the number of appended frames. The
        // prior `value/timescale*30+1` formula integer-divided to 0 for any
        // sub-second clip, so `>= 1` passed even for zero decoded frames.
        let frames = try await decodeFrames(out)
        XCTAssertEqual(frames.count, n, "decoded frame count must equal appended count")
    }

    func testCancelDeletesPartial() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-cancel-\(UUID().uuidString).mov")
        var settings = ExportSettings()
        settings.codec = .h264; settings.container = .mov
        settings.resolution = .custom(width: 64, height: 48); settings.fps = 30
        let enc = try VideoEncoder(settings: settings, outputURL: out)
        try enc.start()
        try await enc.append(gradient(0, 10), atFrame: 0)
        try await enc.append(gradient(1, 10), atFrame: 1)
        enc.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    /// AC3 orientation pin. `RGBA8Image` is top-first and `PixelBufferPool.fill`
    /// does no flip, so a marker frame whose TOP row is bright and BOTTOM row is
    /// dark must decode back UPRIGHT (decoded top bright, bottom dark). This is
    /// the pin against the M4 thumbnail-vs-playback flip gotcha resurfacing in
    /// the export path. Tolerant thresholds because H.264 is lossy; the flipped
    /// case would put ~255 in the bottom row and ~0 in the top, missing both
    /// assertions by a wide margin.
    func testOrientationTopBrightBottomDark() async throws {
        let w = 64, h = 48
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-orient-\(UUID().uuidString).mov")
        var settings = ExportSettings()
        settings.codec = .h264; settings.container = .mov
        settings.resolution = .custom(width: w, height: h); settings.fps = 30
        // Marker: top row white, bottom row black, middle gray. All opaque.
        var pixels = [UInt8](repeating: 128, count: w * h * 4)   // gray middle (RGBA)
        for x in 0..<w {
            let t = (0 * w + x) * 4                 // top row (y = 0): RGBA 255,255,255,255
            pixels[t] = 255; pixels[t + 1] = 255; pixels[t + 2] = 255; pixels[t + 3] = 255
            let b = ((h - 1) * w + x) * 4           // bottom row (y = h-1): RGBA 0,0,0,255
            pixels[b] = 0; pixels[b + 1] = 0; pixels[b + 2] = 0; pixels[b + 3] = 255
        }
        let img = RGBA8Image(width: w, height: h, pixels: pixels)
        let enc = try VideoEncoder(settings: settings, outputURL: out)
        try enc.start()
        try await enc.append(img, atFrame: 0)
        try await enc.finish()
        defer { try? FileManager.default.removeItem(at: out) }

        let frames = try await decodeFrames(out)
        XCTAssertEqual(frames.count, 1, "1-frame marker clip must decode exactly 1 frame")
        let pb = frames[0]
        let topLuma = rowMeanLuma(pb, row: 0)
        let bottomLuma = rowMeanLuma(pb, row: h - 1)
        XCTAssertGreaterThan(topLuma, 200, "decoded TOP row must be bright (upright, no flip)")
        XCTAssertLessThan(bottomLuma, 40, "decoded BOTTOM row must be dark (upright, no flip)")
    }
}
