import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

/// Stage-fusion byte-identity gate (Task 23 optimization closeout).
///
/// The production `MetalRenderer.render` path is now the FUSED pipeline: one
/// `MTLCommandBuffer`, histogram GPU-resident across chaos → decode → density →
/// logDensity → display, single commit + single `waitUntilCompleted`. The unfused
/// reference (`MetalRenderer.renderUnfused`) calls the three unchanged stage
/// entry points, each round-tripping the histogram to a Swift `Histogram` of
/// Doubles with its own command-buffer commit/wait.
///
/// Because the chaos kernel still accumulates `uint32` atomics (associative →
/// order-independent) and the new `atomicBinToFloatBin` decode is a pure per-bin
/// map (no atomics, no order dependence), the fused output is byte-identical to
/// the unfused stage-by-stage output. These tests pin that contract.
final class FusedUnfusedParityTests: XCTestCase {
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

    /// Fused `MetalRenderer.render` output must equal the unfused stage-by-stage
    /// output byte-for-byte across the frozen genome set. Any difference would
    /// mean the GPU decode kernel (`atomicBinToFloatBin`) diverged from the host
    /// decode, or the histogram crossed a boundary it shouldn't have.
    @MainActor
    func testFusedEqualsUnfusedByteIdentical() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        for (name, flame) in try loadAll() {
            // estimatorRadius>0 exercises the density encoder in the fused path;
            // most frozen genomes carry the default (>0), but assert across all.
            let p = RenderParams(seed: 0, width: 160, height: 100,
                                 oversample: 1, samplesPerPixel: 100)
            let fused   = MetalRenderer.render(flame: flame, params: p)
            let unfused = MetalRenderer.renderUnfused(flame: flame, params: p)
            XCTAssertEqual(fused.pixels, unfused.pixels,
                "\(name): fused output differs from unfused (radius=\(flame.quality.estimatorRadius))")
        }
    }

    /// The radius==0 branch must also match (density encoder skipped in both
    /// paths → logDensity reads the decode output directly).
    @MainActor
    func testFusedEqualsUnfusedRadiusZero() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let genomes = try loadAll()
        let (_, flame0) = genomes.first { $0.0 == "sierpinski" } ?? genomes.first!
        var flame = flame0
        flame.quality.estimatorRadius = 0   // force the density-skipped branch
        let p = RenderParams(seed: 0, width: 160, height: 100,
                             oversample: 1, samplesPerPixel: 100)
        let fused   = MetalRenderer.render(flame: flame, params: p)
        let unfused = MetalRenderer.renderUnfused(flame: flame, params: p)
        XCTAssertEqual(fused.pixels, unfused.pixels,
            "radius==0: fused output differs from unfused")
    }

    /// Repeat-run determinism of the fused path (uint32 atomic contract). This
    /// overlaps `EndToEndParityTests.testMetalDeterministicAcrossRuns`, now
    /// exercising the fused path at a second resolution.
    @MainActor
    func testFusedDeterministicAcrossRuns() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let genomes = try loadAll()
        let (_, flame) = genomes.first { $0.0 == "sierpinski" } ?? genomes.first!
        let p = RenderParams(seed: 0, width: 200, height: 120, oversample: 1, samplesPerPixel: 80)
        let a = MetalRenderer.render(flame: flame, params: p)
        let b = MetalRenderer.render(flame: flame, params: p)
        XCTAssertEqual(a.pixels, b.pixels, "Fused path is not deterministic across runs")
    }
}
