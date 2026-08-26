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

    // MARK: - ProRes 422 HQ (encoding overhaul)

    /// `canEncode(.proRes422HQ)` must return true on Apple Silicon (ProRes 422 HQ
    /// encode is supported). XCTSkip if the host can't — but every target machine
    /// (Apple Silicon, macOS 26) has it. This is the capability gate the CLI/GUI
    /// rely on to decide whether to offer ProRes.
    func testCanEncodeProRes422HQ() throws {
        try XCTSkipUnless(VideoEncoder.canEncode(.proRes422HQ),
                          "ProRes 422 HQ encode is not available on this host")
    }

    /// ProRes in a `.mp4` container must throw `ExportError.proResRequiresMOV` at
    /// `start()` (AVAssetWriter rejects ProRes in `.mp4`; fail fast with a
    /// descriptive error rather than a deep encoder failure). No file is created.
    func testProResInMP4ContainerThrows() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-prores-mp4-\(UUID().uuidString).mp4")
        var settings = ExportSettings()
        settings.codec = .proRes422HQ
        settings.container = .mp4   // wrong container for ProRes
        settings.resolution = .custom(width: 64, height: 48); settings.fps = 30
        let enc = try VideoEncoder(settings: settings, outputURL: out)
        XCTAssertThrowsError(try enc.start()) { error in
            XCTAssertEqual(error as? ExportError, .proResRequiresMOV,
                           "ProRes + .mp4 must throw proResRequiresMOV, got \(error)")
        }
        // No partial file left by the guard (it fires before writer creation).
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "guard must fire before any file is written")
    }

    /// ProRes in a `.mov` container must round-trip: encode + decode N frames at
    /// the codec's native data rate (no `AVVideoAverageBitRateKey` set). Pins
    /// that the ProRes path actually encodes on this host (skipped if not).
    func testProResEncodeDecodeBack() async throws {
        try XCTSkipUnless(VideoEncoder.canEncode(.proRes422HQ),
                          "ProRes 422 HQ encode is not available on this host")
        let w = 64, h = 48, fps = 30, n = 5
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-prores-\(UUID().uuidString).mov")
        var settings = ExportSettings()
        settings.codec = .proRes422HQ; settings.container = .mov
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

        let frames = try await decodeFrames(out)
        XCTAssertEqual(frames.count, n, "decoded ProRes frame count must equal appended count")
    }

    // MARK: - M6.7 portrait preset dims

    /// One uniform frame at arbitrary dims (the portrait sweep below builds
    /// frames at each preset size; `gradient` above is fixed at 64×48). Same
    /// `RGBA8Image` construction as `gradient`.
    private static func blackFrame(width: Int, height: Int) -> RGBA8Image {
        RGBA8Image(width: width, height: height,
                   pixels: [UInt8](repeating: 0, count: width * height * 4))
    }

    /// M6.7: one-frame round-trip at each portrait preset dim × codec —
    /// asserts writer completion AND track naturalSize == requested dims (a
    /// fleet-variance pin; all four dims verified encoding cleanly on this
    /// machine 2026-08-25, including the even-not-mod-4 1350).
    func testPortraitPresetDimsRoundTrip() async throws {
        let dims: [(w: Int, h: Int)] = [(720, 1280), (1080, 1920), (1080, 1350), (1080, 1080)]
        for codec in [ExportSettings.Codec.h264, .hevc] {
            try XCTSkipUnless(VideoEncoder.canEncode(codec), "\(codec) unavailable on this host")
            for d in dims {
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("m67-sweep-\(d.w)x\(d.h)-\(codec.rawValue)-\(UUID().uuidString).mov")
                defer { try? FileManager.default.removeItem(at: out) }
                var s = ExportSettings()
                s.codec = codec; s.container = .mov
                s.resolution = .custom(width: d.w, height: d.h); s.fps = 30
                let enc = try VideoEncoder(settings: s, outputURL: out)
                try enc.start()
                try await enc.append(Self.blackFrame(width: d.w, height: d.h), atFrame: 0)
                try await enc.finish()
                let track = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first
                let size = try await XCTUnwrap(track).load(.naturalSize)
                XCTAssertEqual(Int(size.width), d.w, "\(codec) \(d.w)x\(d.h)")
                XCTAssertEqual(Int(size.height), d.h, "\(codec) \(d.w)x\(d.h)")
            }
        }
    }
}
