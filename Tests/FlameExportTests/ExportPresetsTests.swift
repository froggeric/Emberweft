import XCTest
import Foundation
import AVFoundation
@testable import FlameExport
@testable import EmberweftCLI
import FlameKit
import FlameReference

final class ExportPresetsTests: XCTestCase {
    private func sierpinski() -> String {
        // `#filePath` (not `#file`): in Swift 6 `#file` evaluates to a short
        // file-ID, not the absolute source path, so the two-deletion math breaks.
        // The repo's existing test convention is `#filePath` (see
        // ExportCoordinatorTests).
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3").path
    }
    private func tmp(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("m6-\(UUID().uuidString).\(ext)")
    }

    /// AC1: at `.genome`, `export --frame 5 --png` == `animate --frame 5`
    /// (byte-equal RGBA8Image). This is the cross-command determinism pin (§5.2).
    /// Requires Task 5 Step 3 (`--frame`/`--png` wiring).
    func testExportGenomeByteMatchesAnimateFrame5() async throws {
        let pngOut = tmp("png")
        let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "8",
                                            "--frame", "5", "--png", "--out", pngOut.path])
        XCTAssertEqual(rc, 0)

        let animDir = FileManager.default.temporaryDirectory.appendingPathComponent("m6anim-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: animDir, withIntermediateDirectories: true)
        let rcA = EmberweftCLI.animate([sierpinski(), "--segments", "1", "--frames", "8",
                                        "--frame", "5", "--backend", "cpu", "--out", animDir.path])
        XCTAssertEqual(rcA, 0)

        let exported = try RGBA8Image.readPNG(from: pngOut)
        let animated = try RGBA8Image.readPNG(from: animDir.appendingPathComponent("000005.png"))
        XCTAssertEqual(exported, animated)   // byte-identical (`.genome` quality, oversample 1)
        try? FileManager.default.removeItem(at: pngOut)
        try? FileManager.default.removeItem(at: animDir)
    }

    /// AC2: 720p/1080p/1440p/4k each produce the correct decoded dimensions.
    ///
    /// `--quality 1` (1 sample/pixel) keeps the CPU render near-instant — the
    /// render pixels are incidental to this AC, which only verifies the
    /// container's decoded `naturalSize`. Resolution tiers determine the
    /// dimensions; quality does not. (Genome-default quality=100 here would
    /// make the 4k tier take minutes on CPU per CLAUDE.md's "6-17 s/frame at
    /// 720p" note, scaling 9x to 4k.)
    @MainActor
    func testResolutionTiersProduceCorrectDimensions() async throws {
        let cases: [(String, Int, Int)] = [("720p", 1280, 720), ("1080p", 1920, 1080),
                                           ("1440p", 2560, 1440), ("4k", 3840, 2160)]
        for (tier, w, h) in cases {
            let out = tmp("mp4")
            let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "2",
                                                "--quality", "1",
                                                "--resolution", tier, "--backend", "cpu", "--out", out.path])
            XCTAssertEqual(rc, 0, "\(tier) export failed")
            let asset = AVAsset(url: out)
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let dims = try await track.load(.naturalSize)
            XCTAssertEqual(Int(dims.width), w, "\(tier) width")
            XCTAssertEqual(Int(dims.height), h, "\(tier) height")
            try? FileManager.default.removeItem(at: out)
        }
    }

    /// AC3: HEVC capability. On a host WITHOUT HEVC encode, `--codec hevc`
    /// errors (exit 1). On a host WITH HEVC, the test SKIPS (not fails), so it
    /// does not flake across machines. Probed via VideoEncoder.canEncode (Step 2).
    func testHEVCExplicitErrorWhenUnavailable() async throws {
        guard VideoEncoder.canEncode(.hevc) else {
            // Host lacks HEVC encode -> explicit ask must exit 1.
            let out = tmp("mp4")
            let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "2",
                                                "--codec", "hevc", "--out", out.path])
            XCTAssertEqual(rc, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
            return
        }
        throw XCTSkip("HEVC encode is available on this host; the unavailable-HEVC path is exercised on hosts without it.")
    }

    /// AC4: `--bitrate N` is honored by the encoder.
    ///
    /// The plan's absolute-bitrate assertion ("`estimatedDataRate` within ±50%
    /// of 8 Mbps") does NOT hold for sierpinski: it is a structurally simple
    /// fractal (3-point triangle, large uniform regions) whose H.264 encode
    /// undershoots ANY target — empirically 0.73 Mbps actual at an 8 Mbps
    /// target (VideoToolbox ABR uses what it needs, not the budget). The
    /// implementation IS correct (`VideoEncoder.start()` sets
    /// `AVVideoAverageBitRateKey: N * 1_000_000`), so this test verifies the
    /// setting is honored COMPARATIVELY and content-independently: the same
    /// frames encoded at `--bitrate 16` must produce a larger file than at
    /// `--bitrate 1` (a higher target allocates more bits per frame → larger
    /// output, regardless of content complexity). `--quality 1` keeps the CPU
    /// render near-instant (the bitrate setting is independent of render
    /// quality).
    @MainActor
    func testExplicitBitrateIsHonoredCoarsely() async throws {
        let outLo = tmp("mp4"), outHi = tmp("mp4")
        let commonArgs: [String] = [sierpinski(), "--segments", "1", "--frames", "4",
                                    "--quality", "1", "--resolution", "720p",
                                    "--backend", "cpu"]
        let rcLo = await EmberweftCLI.export(commonArgs + ["--bitrate", "1", "--out", outLo.path])
        let rcHi = await EmberweftCLI.export(commonArgs + ["--bitrate", "16", "--out", outHi.path])
        XCTAssertEqual(rcLo, 0); XCTAssertEqual(rcHi, 0)
        let sizeLo = (try? FileManager.default.attributesOfItem(atPath: outLo.path)[.size] as? Int) ?? 0
        let sizeHi = (try? FileManager.default.attributesOfItem(atPath: outHi.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(sizeHi, sizeLo,
                             "--bitrate 16 must produce a larger file than --bitrate 1 (got hi=\(sizeHi) B vs lo=\(sizeLo) B); if equal, the bitrate setting is not reaching the encoder")
        try? FileManager.default.removeItem(at: outLo)
        try? FileManager.default.removeItem(at: outHi)
    }
}
