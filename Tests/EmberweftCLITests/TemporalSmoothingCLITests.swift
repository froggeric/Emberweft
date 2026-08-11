import XCTest
import Foundation
@testable import EmberweftCLI
@testable import FlameExport
import FlameKit

/// M6.1 slice 2 / Task 11 — CLI `--temporal-smoothing on|off` wiring pins.
///
/// Two concerns:
///  - **R7 recipe-flag classification:** `--temporal-smoothing` is a recipe flag,
///    so `--resume --temporal-smoothing off` must be rejected by the existing D11
///    gate (the checkpoint's stored `settings.smoothingAlpha` is authoritative on
///    resume). Pinned via the stderr + exit-code capture pattern.
///  - **quality⇒α threading:** `resolveExportSettings(...)` gains a
///    `temporalSmoothing:` param and threads it into `ExportSettings.resolve(...)`,
///    so `--quality 8` + `.auto` ⇒ α=0.20 (flat α for any .spp tier), and `.off`
///    ⇒ α=1.0 (OFF / byte-identical to the unsmoothed path).
final class TemporalSmoothingCLITests: XCTestCase {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-cli-smoothing-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - AC: `--temporal-smoothing off` + `--resume` ⇒ D11 recipe-flag error

    /// R7: `--temporal-smoothing` is a RECIPE flag, so the D11 gate (which fires
    /// BEFORE the checkpoint is read, ExportCommand.swift:215) must reject
    /// `--resume <out> --temporal-smoothing off` with exit 2 and the
    /// authoritative-recipe message. No checkpoint seed is needed because the gate
    /// precedes the checkpoint read (and precedes genome loading).
    func testTemporalSmoothingOffWithResumeIsRejectedAsRecipeFlag() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("gate.mov")

        // Capture stderr via the injectable `EmberweftCLI.err` hook.
        var captured = ""
        let originalErr = EmberweftCLI.err
        EmberweftCLI.err = { captured += $0 }
        defer { EmberweftCLI.err = originalErr }

        let rc = await EmberweftCLI.export(["--resume", out.path,
                                            "--temporal-smoothing", "off"])
        XCTAssertEqual(rc, 2, "--resume + --temporal-smoothing off must exit 2 (D11)")
        XCTAssertTrue(captured.contains("do not combine --resume with recipe flags"),
                      "expected D11 recipe-flag error; got: \(captured)")
    }

    /// `on` is also a recipe flag (it still sets `anyRecipeFlagExplicit`), so the
    /// D11 gate rejects it too. Confirms the flag is classified as a recipe flag
    /// regardless of the value.
    func testTemporalSmoothingOnWithResumeIsRejectedAsRecipeFlag() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("gate-on.mov")

        var captured = ""
        let originalErr = EmberweftCLI.err
        EmberweftCLI.err = { captured += $0 }
        defer { EmberweftCLI.err = originalErr }

        let rc = await EmberweftCLI.export(["--resume", out.path,
                                            "--temporal-smoothing", "on"])
        XCTAssertEqual(rc, 2, "--resume + --temporal-smoothing on must exit 2 (D11)")
        XCTAssertTrue(captured.contains("do not combine --resume with recipe flags"),
                      "expected D11 recipe-flag error; got: \(captured)")
    }

    // MARK: - AC: `resolveExportSettings` threads temporalSmoothing into α

    /// `--quality 8` (default-on `.auto`) ⇒ resolved `smoothingAlpha == 0.20`
    /// (flat α for any .spp tier). Pins that the flag's `.auto` value
    /// is threaded through `resolveExportSettings` → `ExportSettings.resolve`.
    func testResolveExportSettingsAutoQuality8Alpha020() {
        let f = Flame()
        let s = EmberweftCLI.resolveExportSettings(
            codec: "h264", container: "mp4", fps: 30, quality: "8",
            temporalSamples: 1, bitrate: "auto", resolution: "1080p",
            segmentFrames: 0, renderable: [f], fallbackFlame: f, backend: "cpu",
            temporalSmoothing: .auto)
        XCTAssertEqual(s.smoothingAlpha, 0.20, accuracy: 1e-9,
                       "quality 8 + .auto ⇒ flat α=0.20")
        XCTAssertEqual(s.temporalSmoothing, .auto)
    }

    /// `--quality 8` + `.off` ⇒ resolved `smoothingAlpha == 1.0` (OFF). Pins that
    /// the flag's `.off` value forces α to 1.0 regardless of the quality tier.
    func testResolveExportSettingsOffAlpha1() {
        let f = Flame()
        let s = EmberweftCLI.resolveExportSettings(
            codec: "h264", container: "mp4", fps: 30, quality: "8",
            temporalSamples: 1, bitrate: "auto", resolution: "1080p",
            segmentFrames: 0, renderable: [f], fallbackFlame: f, backend: "cpu",
            temporalSmoothing: .off)
        XCTAssertEqual(s.smoothingAlpha, 1.0, accuracy: 1e-9,
                       ".off ⇒ α=1.0 regardless of quality")
        XCTAssertEqual(s.temporalSmoothing, .off)
    }
}
