import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

final class DensityEstimationParityTests: XCTestCase {

    @MainActor func testMetalDEMatchesCpuApprox() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        var h = Histogram(gridWidth: 16, gridHeight: 16)
        for y in 6..<9 {
            for x in 6..<9 {
                let i = h.binIndex(x, y)
                h.counts[i] = 50
                h.colors[i] = SIMD3(50 * 100, 50 * 0, 50 * 200)
                h.alpha[i] = 50 * 255
            }
        }
        let radius = 4.0, minimum = 1.0, curve = 0.6
        let cpu = DensityEstimation.apply(h, radius: radius, minimum: minimum, curve: curve)
        let gpu = try DensityEstimationMetal.apply(h, radius: radius, minimum: minimum, curve: curve)
        XCTAssertEqual(cpu.counts, gpu.counts, "DE must preserve counts exactly")

        var maxDiff: Double = 0
        for i in 0..<cpu.colors.count {
            maxDiff = max(maxDiff, abs(cpu.colors[i].x - gpu.colors[i].x))
            maxDiff = max(maxDiff, abs(cpu.colors[i].y - gpu.colors[i].y))
            maxDiff = max(maxDiff, abs(cpu.colors[i].z - gpu.colors[i].z))
        }
        XCTAssertLessThan(maxDiff, 1.0, "DE color drift too large: \(maxDiff)")
    }

    @MainActor func testRadiusZeroIsPassthrough() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let h = Histogram(gridWidth: 4, gridHeight: 4)
        let out = try DensityEstimationMetal.apply(h, radius: 0, minimum: 0, curve: 0)
        XCTAssertEqual(out.counts, h.counts)
    }
}
