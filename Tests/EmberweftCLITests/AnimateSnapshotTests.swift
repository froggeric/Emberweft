import XCTest
@testable import EmberweftCLI
import FlameKit
import FlameReference

/// Byte-identity guard for the M6 FramePlan refactor of `animate`. The snapshot
/// PNG was captured from the PRE-refactor `animate --frame 5` output and committed
/// under `Snapshots/animate-frame5-sierpinski.png`. After the refactor, the same
/// invocation must produce byte-identical pixels (rule #2 — pure extraction).
final class AnimateSnapshotTests: XCTestCase {

    /// Resolve a repo-relative path robustly: try CWD-relative first (swift test
    /// runs from the package root), then `#file`-relative (absolute-#file
    /// toolchains). `#file` may be relative under Swift 6, which breaks naive
    /// `#file`-relative navigation (mirrors FlameKitTests/SimilarityTests).
    private func resolve(_ repoRelative: String) -> URL {
        let candidates: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(repoRelative),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(repoRelative)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    func testFrame5MatchesSnapshot() throws {
        let genome = resolve("Tests/Goldens/genomes/sierpinski.flam3")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("m6snap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let rc = EmberweftCLI.animate(["\(genome.path)", "--segments", "1", "--frames", "8",
                                       "--frame", "5", "--backend", "cpu", "--out", out.path])
        XCTAssertEqual(rc, 0)
        let produced = try RGBA8Image.readPNG(from: out.appendingPathComponent("000005.png"))
        let snapshotURL = resolve("Tests/EmberweftCLITests/Snapshots/animate-frame5-sierpinski.png")
        let snapshot = try RGBA8Image.readPNG(from: snapshotURL)
        XCTAssertEqual(produced, snapshot)   // byte-identical pre/post refactor
    }
}
