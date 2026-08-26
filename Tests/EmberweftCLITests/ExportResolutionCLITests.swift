import XCTest
import FlameKit
import FlameReference   // RGBA8Image.readPNG lives here (FlameReference extension)
import FlameExport      // ExportSettings.Resolution (compile bridge the brief's import list omitted)
@testable import EmberweftCLI

/// M6.7 D9: --resolution named tokens + WxH + error-on-unknown (replacing the
/// silent .p1080 fallback). Odd WxH dims are SILENTLY CROPPED by VideoToolbox
/// (probe-verified: 1081×1921 encodes as a 1080×1920 track) — parse-time
/// rejection is the only clean guard.
final class ExportResolutionCLITests: XCTestCase {
    private func sierpinski() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3").path
    }
    private func tmp(_ s: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("m67-\(s)-\(UUID().uuidString).png")
    }
    /// One full PNG-mastering invocation at a resolution value (`export`
    /// returns Int32 — bind it, don't widen).
    private func rc(_ res: String) async -> Int32 {
        await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "2",
                                   "--frame", "1", "--png", "--resolution", res,
                                   "--out", tmp(res).path])
    }

    /// The four social tokens + one WxH spelling go through the full render
    /// (the spec §8 mastering surface). Landscape tokens are parsing-only
    /// today's behavior — pin them CHEAPLY below, not with 1440p/4K renders.
    func testSocialTokensAccepted() async {
        for res in ["vertical720", "vertical1080", "portrait4x5", "square1080", "1080x1920"] {
            let code = await rc(res)
            XCTAssertEqual(code, 0, "--resolution \(res) must be accepted")
        }
    }

    /// Landscape tokens resolve through the shared wrapper (no render) —
    /// mirrors testBatchSettingsBuildHonorsFraming's cheap pinning style.
    func testLandscapeTokensResolve() {
        for (token, expected) in [("720p", ExportSettings.Resolution.p720),
                                  ("1080p", .p1080), ("1440p", .p1440), ("4k", .p4k)] {
            let s = EmberweftCLI.resolveExportSettings(
                codec: "h264", container: "mp4", fps: 30, quality: "genome",
                temporalSamples: 1, bitrate: "auto", resolution: token,
                segmentFrames: 0, renderable: [], fallbackFlame: Flame(),
                backend: "cpu", framing: "normalized")
            XCTAssertEqual(s.resolution, expected, token)
        }
    }

    func testBadValuesRejected() async {
        for res in ["wide", "1080x1921", "1081x1920", "0x1920", "-5x100", "1080x",
                    "80000x100", "1080xx1920", "1080", "vertical2160"] {
            let code = await rc(res)
            XCTAssertEqual(code, 2, "--resolution \(res) must exit 2")
        }
    }

    func testPortraitPngDims() async throws {
        for (res, w, h) in [("vertical1080", 1080, 1920), ("1080x1920", 1080, 1920),
                            ("square1080", 1080, 1080), ("portrait4x5", 1080, 1350)] {
            let out = tmp("dims-\(res)")
            let code = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "2",
                                                  "--frame", "1", "--png", "--resolution", res,
                                                  "--out", out.path])
            XCTAssertEqual(code, 0)
            let img = try RGBA8Image.readPNG(from: out)
            XCTAssertEqual(img.width, w, res)
            XCTAssertEqual(img.height, h, res)
        }
    }

    /// The batch wrapper resolves the SAME parser (a typo'd token must fail
    /// the batch at parse time upstream; valid tokens thread through).
    func testBatchSettingsBuildHonorsVerticalResolution() {
        let s = EmberweftCLI.resolveExportSettings(
            codec: "h264", container: "mp4", fps: 30, quality: "genome",
            temporalSamples: 1, bitrate: "auto", resolution: "vertical1080",
            segmentFrames: 0, renderable: [], fallbackFlame: Flame(),
            backend: "cpu", framing: "normalized")
        XCTAssertEqual(s.resolution, .vertical1080)
    }
}
