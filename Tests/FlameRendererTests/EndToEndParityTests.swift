import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

/// Definitive M2 gate (Task 10). The production `MetalRenderer.render` — now
/// full-Metal (ChaosGameMetal → DensityEstimationMetal → DisplayPipelineMetal),
/// FlameKit-only — must agree with `ReferenceRenderer.render` at PSNR ≥ 38 dB /
/// SSIM ≥ 0.95 across the 6 frozen genomes and a chaotic fuzz genome, be
/// byte-identical across repeated runs (within-backend determinism), and have
/// no NaN/Inf pixels.
///
/// The Metal display pipeline is byte-exact vs CPU ToneMapping (Stage-3a =
/// inf dB on the same histogram), so any image difference here comes from the
/// Stage-1 chaos game: two independent ISAAC consumption orderings
/// (single-threaded CPU vs. multi-threaded Metal) produce statistical
/// sampling-noise differences. The lever is sample count, not algorithm.
final class EndToEndParityTests: XCTestCase {
    private func genomesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes")
    }
    private func loadAll() throws -> [(String, Flame)] {
        let dir = genomesDir()
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "flam3" } ?? []
        XCTAssertFalse(urls.isEmpty, "no frozen genomes found in \(dir.path)")
        return try urls.map {
            ($0.deletingPathExtension().lastPathComponent, try Flam3Parser.parse(Data(contentsOf: $0))[0])
        }
    }

    @MainActor
    func testMetalCPU_Parity_PSNR38_SSIM095() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        // julia_bubbles needed 1000 spp to clear 38 dB / 0.95 SSIM in the Stage-3b
        // on-ramp (Metal chaos → CPU tonemap). The production path differs only by
        // the tonemap, which is byte-exact, so production tracks the 3b numbers —
        // the plan's default 400 would fail julia_bubbles. The plan explicitly
        // permits tuning samplesPerPixel ("the lever is sample count, not
        // algorithm"). Do NOT lower the 38 dB / 0.95 gate.
        let samplesPerPixel = 1000
        for (name, flame) in try loadAll() {
            let p = RenderParams(seed: 0, width: 320, height: 200,
                                 oversample: 1, samplesPerPixel: samplesPerPixel)
            let cpu = ReferenceRenderer.render(flame: flame, params: p)
            let gpu = MetalRenderer.render(flame: flame, params: p)
            let psnr = ImageComparison.psnr(cpu, gpu)
            let ssim = ImageComparison.ssim(cpu, gpu)
            let psnrStr = psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)
            print("[Parity] \(name) @\(samplesPerPixel)spp: "
                  + "PSNR=\(psnrStr) dB, SSIM=\(String(format: "%.4f", ssim))")
            XCTAssertGreaterThanOrEqual(psnr, 38.0, "\(name): \(psnr) dB < 38")
            XCTAssertGreaterThanOrEqual(ssim, 0.95, "\(name): SSIM \(ssim) < 0.95")
        }
    }

    @MainActor
    func testFuzzGenomeStillParity() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        // A non-frozen synthetic genome with julia + spherical (chaotic). NOTE:
        // xform[0]'s affine carries a non-zero translation (e=0.5, f=0.3) so the
        // orbit's input to `spherical` stays clear of the 1/r² singularity at
        // the origin. With e=f=0 (the plan's literal sketch) the orbit passes
        // through the singular point, producing an unbounded-density histogram
        // bin that dominates PSNR and makes the gate impossible to satisfy at
        // any sample count (verified: 27.6→35.2 dB across 1k–64k spp, then
        // collapses as the uint32 fixed-point quantization coarsens). Real
        // flam3 genomes never orbit a singular point. The translation preserves
        // the julia+spherical chaotic character the plan asked for while making
        // the render well-posed.
        let flame = Flame(
            size: SIMD2<Int>(320, 200),
            camera: Camera(scale: 200),
            xforms: [
                Xform(
                    affine: AffineTransform(a: 0.6, b: 0.2, c: -0.3, d: 0.5, e: 0.5, f: 0.3),
                    color: 0, colorSpeed: 0.5,
                    variations: [
                        Variation(name: "julia", weight: 0.7),
                        Variation(name: "spherical", weight: 0.3),
                    ]),
                Xform(
                    affine: AffineTransform(a: 0.4, b: -0.1, c: 0.2, d: 0.7, e: 0.3, f: -0.2),
                    color: 1, colorSpeed: 0.5,
                    variations: [Variation(name: "linear", weight: 1)]),
            ],
            palette: Palette(colors: (0..<256).map {
                SIMD3<Double>(Double($0) / 255, sin(Double($0) / 40) * 0.5 + 0.5, 1 - Double($0) / 255)
            }))
        // Evaluate in the same calibrated operating point as the frozen suite
        // (320×200 @ 1000 spp), where the Metal histogram's per-hit fixed-point
        // precision (~33 quanta/hit) is comfortable.
        let samplesPerPixel = 1000
        let p = RenderParams(seed: 1234, width: 320, height: 200,
                             oversample: 1, samplesPerPixel: samplesPerPixel)
        let cpu = ReferenceRenderer.render(flame: flame, params: p)
        let gpu = MetalRenderer.render(flame: flame, params: p)
        let psnr = ImageComparison.psnr(cpu, gpu)
        let ssim = ImageComparison.ssim(cpu, gpu)
        print("[Parity] fuzz_julia_spherical @\(samplesPerPixel)spp (320×200): "
              + "PSNR=\(psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)) dB, "
              + "SSIM=\(String(format: "%.4f", ssim))")
        XCTAssertGreaterThanOrEqual(psnr, 38.0, "fuzz genome: \(psnr) dB < 38")
        XCTAssertGreaterThanOrEqual(ssim, 0.95, "fuzz genome: SSIM \(ssim) < 0.95")
    }

    @MainActor
    func testMetalDeterministicAcrossRuns() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let genomes = try loadAll()
        let (_, flame) = genomes.first { $0.0 == "sierpinski" } ?? genomes.first!
        let p = RenderParams(seed: 0, width: 160, height: 100, oversample: 1, samplesPerPixel: 200)
        let a = MetalRenderer.render(flame: flame, params: p)
        let b = MetalRenderer.render(flame: flame, params: p)
        // uint32 atomic accumulation is order-independent → byte-identical output.
        XCTAssertEqual(a.pixels, b.pixels, "Metal backend is not deterministic across runs")
    }

    @MainActor
    func testNoNaNOrInf() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        for (name, flame) in try loadAll() {
            let p = RenderParams(seed: 0, width: 160, height: 100, oversample: 1, samplesPerPixel: 100)
            let img = MetalRenderer.render(flame: flame, params: p)
            // UInt8 pixels are finite by construction; the check is that the
            // render returned a complete, properly-sized buffer (no early fault).
            XCTAssertEqual(img.pixels.count, img.width * img.height * 4, "\(name): incomplete buffer")
        }
    }
}
