import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

/// Stage-3a display-pipeline parity gate.
///
/// Feeds the SAME synthetic `Histogram` into CPU `ToneMapping.render` and Metal
/// `DisplayPipelineMetal.render` and asserts the resulting RGBA8 images match
/// at PSNR ≥ 50 dB. This isolates the display math (log-density, spatial filter,
/// gamma, vibrancy/background) from the chaos kernel's sampling noise: with a
/// shared histogram, CPU and Metal see bit-identical input, so the only
/// residual difference is Float-vs-Double math (the MSL path computes in
/// `float`, the CPU in `Double`).
final class Stage3aParityTests: XCTestCase {
    @MainActor
    func testDisplayPipelineMatchesCpuToneMap() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        var h = Histogram(gridWidth: 12, gridHeight: 12)
        for i in 0..<h.counts.count {
            let cx = i % 12, cy = i / 12
            let d2 = (cx - 6) * (cx - 6) + (cy - 6) * (cy - 6)
            let c = max(0, 20 - d2)
            h.counts[i] = Double(c)
            h.colors[i] = SIMD3(Double(c) * 100, Double(c) * 40, Double(c) * 200)
            h.alpha[i]  = Double(c) * 255
        }
        let cpu = ToneMapping.render(histogram: h, width: 6, height: 6, oversample: 2,
                                     gamma: 2.2, gammaThreshold: 0.01, vibrancy: 1,
                                     sampleDensity: 100, pixelsPerUnit: 50)
        let gpu = try DisplayPipelineMetal.render(histogram: h, width: 6, height: 6, oversample: 2,
                                     gamma: 2.2, gammaThreshold: 0.01, vibrancy: 1,
                                     sampleDensity: 100, pixelsPerUnit: 50)
        let p = ImageComparison.psnr(cpu, gpu)
        print("[Stage3a] same-histogram PSNR=\(p) dB")
        XCTAssertGreaterThanOrEqual(p, 50.0,
            "Stage 3a (same histogram) below 50 dB: \(p)")
    }
}
