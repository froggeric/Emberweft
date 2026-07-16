import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

/// First end-to-end image-level parity gate (Stage-3b on-ramp).
///
/// Metal chaos kernel → decoded `Histogram` (dmap-units, same as CPU) →
/// CPU `DensityEstimation` + `ToneMapping` → `RGBA8Image`. Compared against
/// the pure-CPU `ReferenceRenderer.render` twin. Two independent ISAAC
/// consumption orderings (single-threaded CPU vs. multi-threaded Metal)
/// produce sampling-noise differences; the gate asserts they stay below
/// 38 dB PSNR / 0.95 SSIM — the parity-bisect on-ramp before any Metal
/// display or DE kernel exists.
final class EndToEndParity3bTests: XCTestCase {
    private func genomesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes")
    }

    @MainActor
    func testMetalCPU_PSNR_3b() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let genomes = (try? FileManager.default.contentsOfDirectory(
            at: genomesDir(), includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "flam3" } ?? []
        XCTAssertFalse(genomes.isEmpty, "no frozen genomes")

        // Higher sample count: two independent ISAAC orderings need enough
        // samples for their sampling-noise floor to drop below 38 dB.
        let samplesPerPixel = 1000
        let p = RenderParams(seed: 0, width: 320, height: 200,
                             oversample: 1, samplesPerPixel: samplesPerPixel)

        for g in genomes {
            let flame = try Flam3Parser.parse(Data(contentsOf: g))[0]
            let cpu = ReferenceRenderer.render(flame: flame, params: p)
            let gpu = MetalRenderer.render(flame: flame, params: p)
            let psnr = ImageComparison.psnr(cpu, gpu)
            let ssim = ImageComparison.ssim(cpu, gpu)
            let psnrStr = psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)
            print("[Parity3b] \(g.lastPathComponent): "
                  + "PSNR=\(psnrStr) dB, SSIM=\(String(format: "%.4f", ssim))")
            XCTAssertGreaterThanOrEqual(psnr, 38.0,
                "\(g.lastPathComponent): \(psnr) dB < 38")
            XCTAssertGreaterThanOrEqual(ssim, 0.95,
                "\(g.lastPathComponent): SSIM \(ssim) < 0.95")
        }
    }
}
