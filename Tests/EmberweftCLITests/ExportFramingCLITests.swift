import XCTest
@testable import EmberweftCLI

/// M6.6 Task 4: `export --framing faithful|normalized` CLI surface.
/// Default `normalized`; bad value → exit 2; recipe flag for the resume gate.
final class ExportFramingCLITests: XCTestCase {
    private func sierpinski() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3").path
    }
    private func tmp(_ s: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("m66-\(s)-\(UUID().uuidString).png")
    }

    func testBadFramingValueRejected() async {
        let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "2",
                                            "--frame", "1", "--png",
                                            "--framing", "wide", "--out", tmp("x").path])
        XCTAssertEqual(rc, 2)
    }

    func testBothValuesAccepted() async {
        for v in ["faithful", "normalized"] {
            let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "2",
                                                "--frame", "1", "--png",
                                                "--framing", v, "--out", tmp(v).path])
            XCTAssertEqual(rc, 0, "--framing \(v) must be accepted")
        }
    }

    /// `--framing` is a RECIPE flag (D11): `--resume` + `--framing` → exit 2
    /// (the checkpoint's stored framing is authoritative on resume, same rule
    /// as the other 12 recipe flags). The resume gate fires before genome
    /// loading, so this needs no real checkpoint.
    func testFramingIsRecipeFlagForResume() async {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("m66-resume-\(UUID().uuidString).mp4")
        let rc = await EmberweftCLI.export(["--resume", out.path, "--framing", "normalized"])
        XCTAssertEqual(rc, 2, "--resume + --framing must be rejected (checkpoint is authoritative)")
    }
}
