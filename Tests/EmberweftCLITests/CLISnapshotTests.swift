import XCTest
@testable import EmberweftCLI
import FlameReference
import FlameKit

// Byte-stable PNG snapshot baseline for the CLI's reference render path.
//
// The CPU renderer is a faithful flam3 port (ISAAC RNG, Double precision,
// exact consumption order): the same (genome, seed, params) always yields a
// byte-identical image. This test locks that output as a committed baseline so
// any drift — intentional or not — fails CI until the baseline is reviewed.
//
// Re-goldening procedure (when a deliberate change legitimately alters output):
//   1. Delete Tests/Goldens/cli/snapshot.png.
//   2. Re-run this test: it records the current output and SKIPs.
//   3. Inspect the new PNG, then commit it deliberately with a reason.
//
// NOTE: Swift 6.2 `#file` returns the bare filename (SE-0274), which drops the
// directory prefix and breaks `deletingLastPathComponent()`. Use `#filePath`.
final class CLISnapshotTests: XCTestCase {
    func testSnapshotByteStable() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/cli")
        let genomeURL = dir.appendingPathComponent("snapshot.flam3")
        let pngURL = dir.appendingPathComponent("snapshot.png")

        let flame = try Flam3Parser.parse(Data(contentsOf: genomeURL))[0]
        let rendered = ReferenceRenderer.render(
            flame: flame,
            params: RenderParams(seed: 1, width: 32, height: 32,
                                 oversample: 1, samplesPerPixel: 60))

        if !FileManager.default.fileExists(atPath: pngURL.path) {
            try rendered.writePNG(to: pngURL)    // first-run recording
            throw XCTSkip("recorded baseline snapshot.png — review and commit")
        }

        let baseline = try RGBA8Image.readPNG(from: pngURL)
        XCTAssertEqual(rendered, baseline,
            "CLI PNG drift detected — re-golden deliberately (see header)")
    }
}
