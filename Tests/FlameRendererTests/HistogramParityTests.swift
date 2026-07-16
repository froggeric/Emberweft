import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

final class HistogramParityTests: XCTestCase {
    private func sierpinski() -> Flame {
        Flame(size: SIMD2(64, 64), camera: Camera(scale: 64),
              xforms: [
                Xform(affine: AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, e: -0.15, f: -0.1), color: 0,
                      variations: [Variation(name: "linear", weight: 1)]),
                Xform(affine: AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, e: 0.15, f: -0.1), color: 0.5,
                      variations: [Variation(name: "linear", weight: 1)]),
                Xform(affine: AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, e: 0, f: 0.175), color: 1,
                      variations: [Variation(name: "linear", weight: 1)])
              ])
    }

    private func compare(_ cpu: Histogram, _ gpu: Histogram) -> (countRelL1: Double, colorRelL1: Double, corr: Double) {
        precondition(cpu.counts.count == gpu.counts.count)
        var cL1 = 0.0, colL1 = 0.0
        var sumC = 0.0, sumG = 0.0, sumCG = 0.0, sumC2 = 0.0, sumG2 = 0.0
        for i in 0..<cpu.counts.count {
            cL1 += abs(cpu.counts[i] - gpu.counts[i])
            colL1 += abs(cpu.colors[i].x - gpu.colors[i].x)
                     + abs(cpu.colors[i].y - gpu.colors[i].y)
                     + abs(cpu.colors[i].z - gpu.colors[i].z)
            let c = cpu.counts[i], g = gpu.counts[i]
            sumC += c; sumG += g; sumCG += c*g; sumC2 += c*c; sumG2 += g*g
        }
        let total = max(cpu.sampleSum, gpu.sampleSum, 1)
        let n = Double(cpu.counts.count)
        let num = n*sumCG - sumC*sumG
        let den = (sqrt(n*sumC2 - sumC*sumC) * sqrt(n*sumG2 - sumG*sumG))
        let corr = den > 0 ? num/den : 1
        return (cL1/total, colL1/(3*total*255), corr)
    }

    @MainActor func testSierpinskiHistogramMatches() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let f = sierpinski()
        let p = RenderParams(seed: 7, width: 64, height: 64, oversample: 1, samplesPerPixel: 500)
        let cpu = ChaosGame.iterate(flame: f, params: p)
        let gpu = try ChaosGameMetal.iterate(flame: f, params: p)
        XCTAssertEqual(cpu.counts.count, gpu.counts.count)
        XCTAssertEqual(Int(gpu.sampleSum), p.totalSamples, "Metal did not produce exactly totalSamples")
        let m = compare(cpu, gpu)
        XCTAssertLessThan(m.countRelL1, 0.05, "count L1 too high: \(m)")
        XCTAssertGreaterThan(m.corr, 0.99, "count correlation too low: \(m)")
        XCTAssertLessThan(m.colorRelL1, 0.05, "color L1 too high: \(m)")
    }

    @MainActor func testFrozenGenomeHistogramsMatch() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let genomesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes")
        let genomes = (try? FileManager.default.contentsOfDirectory(at: genomesDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "flam3" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        // samplesPerPixel=500: FP32 chaos trajectories diverge per-thread from the
        // CPU's Double path, so the invariant measure converges statistically rather
        // than bin-exact. The sparse julia genome needs the extra samples to settle
        // its L1 under threshold; correlation is the load-bearing parity signal.
        for g in genomes {
            let flame = try Flam3Parser.parse(Data(contentsOf: g))[0]
            let p = RenderParams(seed: 0, width: 160, height: 100, oversample: 1, samplesPerPixel: 500)
            let cpu = ChaosGame.iterate(flame: flame, params: p)
            let gpu = try ChaosGameMetal.iterate(flame: flame, params: p)
            let m = compare(cpu, gpu)
            XCTAssertLessThan(m.countRelL1, 0.08, "\(g.lastPathComponent): count L1 \(m)")
            XCTAssertGreaterThan(m.corr, 0.98, "\(g.lastPathComponent): corr \(m)")
            XCTAssertLessThan(m.colorRelL1, 0.08, "\(g.lastPathComponent): color L1 \(m)")
        }
    }
}
