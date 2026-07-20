import XCTest
@testable import FlameKit

/// Real Electric Sheep genomes specify palettes as `<color index="i" rgb="r g b"/>`
/// DIRECT children of `<flame>` (decimal 0–255), NOT inside a `<palette>` element
/// and NOT hex. The parser must read these; otherwise the palette is all-zero and
/// every frame renders black (the real-genome black-render bug).
final class RealGenomePaletteTests: XCTestCase {

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }
    private func fixture(_ name: String) -> URL {
        repoRoot().appendingPathComponent("Tests/Goldens/genomes_real/\(name)")
    }

    func testRealGenomePaletteParsesNonZero() throws {
        // (fixture, expected palette[0], expected brightness, expected temporal_samples)
        // All 5 real ES fixtures carry temporal_samples="1000" temporal_filter_type="box"
        // temporal_filter_width="1.2" — pin those through parsing too.
        let cases: [(String, SIMD3<Double>, Double, Int)] = [
            ("electricsheep.248.00038.flam3", SIMD3(141.0/255, 196.0/255, 173.0/255), 4.0,     1000),
            ("electricsheep.248.00084.flam3", SIMD3(255.0/255, 145.0/255,  41.0/255), 4.0,     1000),
            ("electricsheep.248.00256.flam3", SIMD3(255.0/255, 145.0/255,  41.0/255), 81.0696, 1000),
            ("electricsheep.248.00268.flam3", SIMD3(109.0/255, 0.0,        31.0/255), 13.5913, 1000),
            ("electricsheep.248.00000.flam3", SIMD3(168.0/255, 168.0/255,  0.0),      5.29287, 1000),
        ]
        for (name, expected0, expectedBrightness, expectedTemporalSamples) in cases {
            let url = fixture(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("fixture missing: \(url.path)")
            }
            let data = try Data(contentsOf: url)
            let flame = try XCTUnwrap(Flam3Parser.parse(data).first, "parse failed: \(name)")
            XCTAssertEqual(flame.palette.colors.count, 256, "\(name): palette size")
            // index 0 must match the source decimal rgb (→ [0,1])
            XCTAssertEqual(flame.palette.colors[0].x, expected0.x, accuracy: 1e-3, "\(name) idx0.r")
            XCTAssertEqual(flame.palette.colors[0].y, expected0.y, accuracy: 1e-3, "\(name) idx0.g")
            XCTAssertEqual(flame.palette.colors[0].z, expected0.z, accuracy: 1e-3, "\(name) idx0.b")
            // brightness must parse (was hardcoded to 4.0 — real genomes carry up to ~81)
            XCTAssertEqual(flame.quality.brightness, expectedBrightness, accuracy: 1e-3,
                           "\(name): brightness not parsed (would render tonally wrong)")
            // motion-blur attrs (flam3 temporal_filter_*) must round-trip — these
            // are present on every real ES genome and required for faithful
            // motion-blur parity (Task 1).
            XCTAssertEqual(flame.quality.temporalSamples, expectedTemporalSamples,
                           "\(name): temporal_samples not parsed")
            XCTAssertEqual(flame.quality.temporalFilterType, .box,
                           "\(name): temporal_filter_type not parsed")
            XCTAssertEqual(flame.quality.temporalFilterWidth, 1.2, accuracy: 1e-9,
                           "\(name): temporal_filter_width not parsed")
            // the black-render guard: a substantively all-zero palette renders black
            let nonzero = flame.palette.colors.filter { ($0.x + $0.y + $0.z) > 1e-6 }.count
            XCTAssertGreaterThan(nonzero, 200, "\(name): palette only \(nonzero)/256 non-zero → renders black")
        }
    }
}
