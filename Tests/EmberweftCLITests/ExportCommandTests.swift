import XCTest
import Foundation
@testable import EmberweftCLI
import FlameRenderer   // MetalRenderer.isAvailable for the strict-backend guard

final class ExportCommandTests: XCTestCase {
    private func sierpinski() -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3").path
    }
    private func tmpMP4() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("m6-\(UUID().uuidString).mp4").path
    }

    func testExportsPlayableMP4() async throws {
        let out = tmpMP4()
        // `export` lives on `EmberweftCLI` (an extension in ExportCommand.swift).
        // `--quality 10` keeps the CLI-integration test fast (sierpinski's genome
        // quality is 100 → ~207M samples/frame at the default 1080p, which is the
        // render-quality path already covered by ExportCoordinatorTests; this test
        // only asserts the mp4 is produced + overwriteable).
        let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "4",
                                            "--backend", "cpu", "--quality", "10",
                                            "--resolution", "720p", "--out", out])
        XCTAssertEqual(rc, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: out))
    }
    func testOverwriteNeedsForce() async throws {
        let out = tmpMP4()
        try Data("keep".utf8).write(to: URL(fileURLWithPath: out))
        let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--out", out])
        XCTAssertEqual(rc, 2)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: out), encoding: .utf8), "keep")  // untouched
    }
    func testSegmentsNeedsTwoGenomes() async throws {
        let rc = await EmberweftCLI.export([sierpinski(), "--segments", "3", "--out", tmpMP4()])
        XCTAssertEqual(rc, 2)
    }

    /// Genome-count guard: no genomes -> exit 2 (mirrors `animate`).
    func testEmptyGenomesErrors() async throws {
        let rc = await EmberweftCLI.export(["--segments", "1", "--out", tmpMP4()])
        XCTAssertEqual(rc, 2)
    }

    /// Degenerate-genome AC: a NaN-center genome is skipped; if that leaves no
    /// renderable genomes, exit 1. Uses a literal NaN camera header (the
    /// gen-248 data-integrity class documented in CLAUDE.md).
    func testDegenerateGenomeSkippedToExit1() async throws {
        let dir = FileManager.default.temporaryDirectory
        let g = dir.appendingPathComponent("m6-nan-\(UUID().uuidString).flam3")
        let nan = """
        <flames><flame name="N" size="16 16" scale="nan" center="nan nan" quality="10">
          <xform coefs="1 0 0 1 0 0" linear="1"/>
        </flame></flames>
        """
        try nan.data(using: .utf8)!.write(to: g)
        let rc = await EmberweftCLI.export([g.path, "--segments", "1", "--out", tmpMP4()])
        XCTAssertEqual(rc, 1)
        try? FileManager.default.removeItem(at: g)
    }

    /// `--backend metal --strict-backend` must exit 1 when Metal is unavailable.
    /// On a Metal-capable host the fallback path can't be exercised, so the test
    /// skips — it only asserts on no-Metal machines (the AC is "fallback OR exit 1").
    func testStrictBackendExitsOneWhenMetalUnavailable() async throws {
        let metalOK = await MainActor.run { MetalRenderer.isAvailable }
        try XCTSkipIf(metalOK, "Metal available — strict-backend fallback not exercisable here")
        let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1",
                                            "--backend", "metal", "--strict-backend", "--out", tmpMP4()])
        XCTAssertEqual(rc, 1)
    }
}
