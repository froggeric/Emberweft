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

        // Partition into deterministic (gated) and julia-containing (pending
        // ISAAC wiring — the julia variation draws a per-iteration random bit;
        // until ISAAC replaces PCG32 in the chaos game these cannot pixel-parity).
        var deterministic: [(name: String, flame: Flame, goldenURL: URL)] = []
        var skippedJulia: [String] = []
        for g in genomes {
            let name = g.deletingPathExtension().lastPathComponent
            let goldenURL = refDir.appendingPathComponent("\(name).png")
            guard fm.fileExists(atPath: goldenURL.path) else {
                throw XCTSkip("golden \(name).png missing — run make regen-goldens")
            }
            let flame = try Flam3Parser.parse(Data(contentsOf: g))[0]
            let usesJulia = flame.xforms.contains { xf in
                xf.variations.contains { $0.name == "julia" }
            } || (flame.finalXform?.variations.contains { $0.name == "julia" } ?? false)
            if usesJulia {
                skippedJulia.append(name)
            } else {
                deterministic.append((name, flame, goldenURL))
            }
        }

        guard !deterministic.isEmpty else {
            throw XCTSkip("No deterministic (non-julia) frozen genomes to test")
        }

        for (name, flame, goldenURL) in deterministic {
            let params = RenderParams(seed: 0, width: 320, height: 200, oversample: 1, samplesPerPixel: 100)
            let rendered = ReferenceRenderer.render(flame: flame, params: params)
            let golden = try RGBA8Image.readPNG(from: goldenURL)
            let p = ImageComparison.psnr(rendered, golden)
            let s = ImageComparison.ssim(rendered, golden)
            XCTAssertGreaterThanOrEqual(p, 30, "PSNR too low for \(name): \(p)")
            XCTAssertGreaterThanOrEqual(s, 0.95, "SSIM too low for \(name): \(s)")
        }

        if !skippedJulia.isEmpty {
            // Attach context so the skip is visible without failing the test.
            // The deterministic genomes above MUST pass; julia genomes are excluded.
            print("[GoldenParity] skipped julia genomes (pending ISAAC): \(skippedJulia.joined(separator: ", "))")
        }
    }
}
