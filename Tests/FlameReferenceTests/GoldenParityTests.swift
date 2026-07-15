import XCTest
@testable import FlameReference
import FlameKit

final class GoldenParityTests: XCTestCase {
    func testIdenticalImagesMaxPSNR() {
        let img = RGBA8Image(width: 2, height: 2, pixels: [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16])
        // Identical images => MSE 0 => psnr returns .infinity. Do NOT use
        // XCTAssertEqual(accuracy:) here: abs(inf - inf) is NaN and would fail.
        XCTAssertTrue(ImageComparison.psnr(img, img).isInfinite)
    }

    func testIdenticalImagesSSIMOne() {
        let img = RGBA8Image(width: 4, height: 4, pixels: [UInt8](repeating: 0, count: 64))
        XCTAssertEqual(ImageComparison.ssim(img, img), 1.0, accuracy: 1e-6)
    }

    func testFrozenGenomesMatchGoldens() throws {
        let genomesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes")
        let refDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/reference")
        let fm = FileManager.default
        guard let genomes = try? fm.contentsOfDirectory(at: genomesDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "flam3" }), !genomes.isEmpty else {
            throw XCTSkip("No frozen genomes found")
        }

        // ALL 6 frozen genomes are asserted strict ≥30 dB AND ≥0.95 SSIM.
        // The julia-containing genomes (final_warp, rich, julia_bubbles) are
        // no longer excluded — Double-precision iteration closes the chaotic-
        // trajectory divergence gap that Float caused.
        for g in genomes {
            let name = g.deletingPathExtension().lastPathComponent
            let goldenURL = refDir.appendingPathComponent("\(name).png")
            guard fm.fileExists(atPath: goldenURL.path) else {
                throw XCTSkip("golden \(name).png missing — run make regen-goldens")
            }
            let flame = try Flam3Parser.parse(Data(contentsOf: g))[0]
            let params = RenderParams(seed: 0, width: 320, height: 200, oversample: 1, samplesPerPixel: 100)
            let rendered = ReferenceRenderer.render(flame: flame, params: params)
            let golden = try RGBA8Image.readPNG(from: goldenURL)
            let p = ImageComparison.psnr(rendered, golden)
            let s = ImageComparison.ssim(rendered, golden)
            let pStr = p.isInfinite ? "inf" : String(format: "%.2f", p)
            print("[GoldenParity] \(name): PSNR=\(pStr) dB, SSIM=\(String(format: "%.4f", s))")
            XCTAssertGreaterThanOrEqual(p, 30, "PSNR too low for \(name): \(p)")
            XCTAssertGreaterThanOrEqual(s, 0.95, "SSIM too low for \(name): \(s)")
        }
    }
}
