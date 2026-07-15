import XCTest
@testable import FlameKit

/// Guards the frozen golden genome set (Task 12). Each committed genome under
/// `Tests/Goldens/genomes/*.flam3` must parse to exactly one `Flame` with at
/// least one xform, must use only variation names in `Variations.knownNames`,
/// and must bake `size="320 200" quality="100" estimator_radius="0"` so the
/// `flam3-render` oracle (dev-only) and `FlameReference` agree on framing.
///
/// The reference PNGs they produce are committed under `Tests/Goldens/reference`
/// via `make regen-goldens`; CI therefore never needs the GPL `flam3` oracle.
final class GoldenGenomeTests: XCTestCase {
    private func genomesDir() -> URL {
        // Tests/FlameKitTests/<this file> -> Tests/Goldens/genomes
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return here.deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
            .appendingPathComponent("genomes", isDirectory: true)
    }

    private func genomeNames() throws -> [String] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: genomesDir(), includingPropertiesForKeys: nil)
        return urls
            .filter { $0.pathExtension == "flam3" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func testAtLeastSixFrozenGenomes() throws {
        let names = try genomeNames()
        XCTAssertGreaterThanOrEqual(names.count, 6, "expected ≥6 frozen golden genomes")
        XCTAssertEqual(
            Set(names),
            ["sierpinski", "swirl_field", "julia_bubbles", "heart_disc", "final_warp", "rich"],
            "unexpected frozen genome set: \(names)")
    }

    func testEachGenomeParsesCleanly() throws {
        let dir = genomesDir()
        let names = try genomeNames()
        for name in names {
            let url = dir.appendingPathComponent("\(name).flam3")
            let data = try Data(contentsOf: url)
            let flames = try Flam3Parser.parse(data)
            XCTAssertEqual(flames.count, 1, "\(name): expected exactly one <flame>")
            let f = flames[0]
            XCTAssertGreaterThanOrEqual(f.xforms.count, 1, "\(name): needs ≥1 xform")
            XCTAssertEqual(f.size, SIMD2<Int>(320, 200), "\(name): size must be 320 200")
            XCTAssertEqual(f.quality.samplesPerPixel, 100, "\(name): quality must be 100")
            XCTAssertEqual(f.quality.estimatorRadius, 0, "\(name): estimator_radius must be 0")
            // Palette must not be all-zero (palettes must actually load).
            let nonzero = f.palette.colors.contains { $0 != .zero }
            XCTAssertTrue(nonzero, "\(name): palette parsed as all zeros")
            // Every variation name must be in the implemented M1 set.
            let used = Set(f.xforms.flatMap { $0.variations.map { $0.name } }
                           + (f.finalXform.map { $0.variations.map { $0.name } } ?? []))
            for v in used {
                XCTAssertTrue(Variations.knownNames.contains(v),
                              "\(name): variation '\(v)' not in knownNames")
            }
        }
    }

    func testGenomeSetCoversRequiredShapes() throws {
        let dir = genomesDir()
        func flame(_ name: String) throws -> Flame {
            let data = try Data(contentsOf: dir.appendingPathComponent("\(name).flam3"))
            return try Flam3Parser.parse(data)[0]
        }
        // pure-linear genome exists.
        let sierp = try flame("sierpinski")
        XCTAssertTrue(sierp.xforms.allSatisfy {
            $0.variations.count == 1 && $0.variations.first?.name == "linear"
        }, "sierpinski should be pure-linear")

        // multi-xform genome exists.
        XCTAssertGreaterThanOrEqual(try flame("rich").xforms.count, 5, "rich should have ≥5 xforms")

        // final xform genome exists.
        XCTAssertNotNil(try flame("final_warp").finalXform, "final_warp must define a final xform")

        // ≥3 distinct variations across the set.
        let allVars = Set(try genomeNames().map { try flame($0) }.flatMap {
            $0.xforms + ($0.finalXform.map { [$0] } ?? [])
        }.flatMap { $0.variations.map { $0.name } })
        XCTAssertGreaterThanOrEqual(allVars.count, 3, "set must cover ≥3 distinct variations; got \(allVars)")
    }
}
