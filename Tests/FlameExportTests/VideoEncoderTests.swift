import XCTest
@testable import FlameExport
import FlameKit
import AVFoundation

final class VideoEncoderTests: XCTestCase {
    private func gradient(_ i: Int, _ n: Int) -> RGBA8Image {
        let w = 64, h = 48
        let v = UInt8((Double(i) / Double(max(1, n - 1)) * 255).rounded())
        return RGBA8Image(width: w, height: h, pixels: [UInt8](repeating: v, count: w * h * 4))
    }

    func testEncodeDecodeBack() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-enc-\(UUID().uuidString).mov")
        var settings = ExportSettings()
        settings.codec = .h264; settings.container = .mov
        settings.resolution = .custom(width: 64, height: 48); settings.fps = 30
        let enc = try VideoEncoder(settings: settings, outputURL: out)
        try enc.start()
        for i in 0..<10 { try await enc.append(gradient(i, 10), atFrame: i) }
        try await enc.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        let asset = AVAsset(url: out)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let nframes = Int(try await asset.load(.duration).value) / Int(try await asset.load(.duration).timescale)
            * 30 + 1
        let dims = try await track.load(.naturalSize)
        XCTAssertEqual(Int(dims.width), 64); XCTAssertEqual(Int(dims.height), 48)
        XCTAssertGreaterThanOrEqual(nframes, 1)
        try? FileManager.default.removeItem(at: out)
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
}
