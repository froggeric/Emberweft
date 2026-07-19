import XCTest
@testable import FlameReference
@testable import FlameKit

/// End-to-end regression guard for the real-genome all-black render bug. Real
/// Electric Sheep genomes (decimal `<color rgb>` palettes, DE on, non-default
/// camera/brightness) must render non-black. The synthetic goldens (palette-less,
/// default camera) never exercised this, so it's gated on a real genome fixture.
final class RealGenomeRenderTests: XCTestCase {

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    func testRealGenomeRendersNonBlack() throws {
        let url = repoRoot().appendingPathComponent("Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("real-genome fixture missing: \(url.path)")
        }
        let flame = try XCTUnwrap(Flam3Parser.parse(Data(contentsOf: url)).first, "parse failed")
        // 00256 has 12 xforms + finalxform + DE; render on CPU (available everywhere).
        let img = ReferenceRenderer.render(
            flame: flame,
            params: RenderParams(seed: 0, width: 320, height: 240, oversample: 1, samplesPerPixel: 200)
        )
        var maxChannel: UInt8 = 0
        var nonBlack = 0
        let px = img.pixels
        var i = 0
        while i + 3 < px.count {
            let m = max(px[i], px[i + 1], px[i + 2])
            if m > maxChannel { maxChannel = m }
            if m > 4 { nonBlack += 1 }
            i += 4
        }
        let pixels = px.count / 4
        XCTAssertGreaterThan(maxChannel, 0, "real genome rendered ALL-black (palette-parse regression)")
        XCTAssertGreaterThan(Double(nonBlack) / Double(pixels), 0.10,
                             "real genome rendered mostly black (\(nonBlack)/\(pixels) non-zero)")
    }
}
