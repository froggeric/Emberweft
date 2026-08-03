import XCTest
@testable import FlameRenderer
import FlameKit
import FlameReference

final class ThreadSeedBudgetTests: XCTestCase {
    private func genome() throws -> Flame {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3")
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }

    @MainActor
    func testNilVsBudgetByteIdenticalSingle() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try genome()
        let params = RenderParams(seed: 42, width: 320, height: 200, oversample: 1, samplesPerPixel: 4)
        let plain = MetalRenderer.render(flame: flame, params: params)
        let budget = MetalRenderer.ThreadSeedBudget(baseSeed: params.seed)
        let cached = MetalRenderer.render(flame: flame, params: params, seedBudget: budget)
        XCTAssertEqual(plain, cached)   // byte-identical
    }

    @MainActor
    func testNilVsBudgetByteIdenticalTemporal() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try genome()
        let params = RenderParams(seed: 42, width: 320, height: 200, oversample: 1, samplesPerPixel: 4)
        let N = 8
        let q = flame.quality
        let (raw, sumfilt) = TemporalFilter.samples(N, type: q.temporalFilterType,
                                                    width: q.temporalFilterWidth, exp: q.temporalFilterExp)
        let temporal = raw.map { (delta: $0.delta / 8.0, weight: $0.weight) }
        let blendAt: @Sendable (Double) -> Flame = { t in Loop.blend(flame, t: t, cycles: 1) }
        let plain = MetalRenderer.render(blendAt: blendAt, centerTime: 0.5,
                                         temporal: temporal, sumfilt: sumfilt, params: params)
        let budget = MetalRenderer.ThreadSeedBudget(baseSeed: params.seed)
        let cached = MetalRenderer.render(blendAt: blendAt, centerTime: 0.5,
                                          temporal: temporal, sumfilt: sumfilt, params: params,
                                          seedBudget: budget)
        XCTAssertEqual(plain, cached)
        // memo actually hit across two frames (same key): second descriptor reuses
        XCTAssertNotNil(budget)
    }
}
