import XCTest
@testable import FlameRenderer
import FlameKit

/// Parity pins for the off-main DE/display refactor (M6.1 slice 2, T5).
///
/// `DensityEstimationMetal.applyCore` and `DisplayPipelineMetal.renderCore` are
/// the `nonisolated` extractions of the former `@MainActor apply`/`render`
/// bodies — all Metal handles (device/queue/PSO) passed in, no `MetalRenderer`
/// singletons. `MetalRenderer.renderSmoothedDisplayOffMain` composes
/// `applyCore`+`renderCore` on `offMainQueue` (sourcing PSOs from
/// `offMainCache`), and is the path T8's smoothing display step drives on the
/// GUI export (off-main, no UI freeze).
///
/// The GPU computation is thread-independent (already pinned for the fused path
/// by `OffMainTemporalParityTests`); these tests pin that invariant for the
/// unfused DE+display composition:
///   1. DE passthrough (radius=0) — off-main renderCore == @MainActor render.
///   2. DE>0 (forced radius=2) — off-main applyCore+renderCore == @MainActor
///      apply+render.
/// The pre-DE histogram is built via the existing `ChaosGameMetal.iterate` (no
/// T6 dependency — `MetalRenderer.histogram` is a separate task).
@MainActor
final class OffMainDisplayParityTests: XCTestCase {

    /// `#filePath`-relative loader for frozen goldens in `Tests/Goldens/genomes/`
    /// (same form as `OffMainTemporalParityTests.loadFrozen`).
    private func loadFrozen(_ name: String) throws -> Flame {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name).flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture missing: \(url.path)")
        }
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }

    /// DE passthrough (deRadius=0): the off-main orchestrator must skip DE and
    /// run `renderCore` alone, byte-identical to `@MainActor
    /// DisplayPipelineMetal.render` (which never applies DE). Pins the
    /// display-only extraction.
    func testOffMainSmoothedDisplayMatchesMainActor_noDE() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try loadFrozen("sierpinski")
        let params = RenderParams(seed: 1, width: 64, height: 64,
                                  oversample: 1, samplesPerPixel: 8)
        let p = params.settingSpatialFilterRadius(flame.quality.filterRadius)
        let hist = try ChaosGameMetal.iterate(flame: flame, params: p)

        let mainImg = try DisplayPipelineMetal.render(
            histogram: hist, width: p.width, height: p.height, oversample: p.oversample,
            gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
            vibrancy: flame.quality.vibrancy, brightness: flame.quality.brightness,
            sampleDensity: Double(p.samplesPerPixel),
            pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom),
            highlightPower: flame.quality.highlightPower,
            spatialFilterRadius: p.spatialFilterRadius)

        let offImg = try XCTUnwrap(MetalRenderer.renderSmoothedDisplayOffMain(
            histogram: hist, deRadius: 0, deMinimum: 0, deCurve: 0,
            width: p.width, height: p.height, oversample: p.oversample,
            gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
            vibrancy: flame.quality.vibrancy, brightness: flame.quality.brightness,
            sampleDensity: Double(p.samplesPerPixel),
            pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom),
            highlightPower: flame.quality.highlightPower,
            spatialFilterRadius: p.spatialFilterRadius),
            "off-main smoothed display must succeed (Metal available)")

        XCTAssertEqual(offImg, mainImg,
            "renderSmoothedDisplayOffMain (no DE) must be byte-identical to @MainActor DisplayPipelineMetal.render")
    }

    /// DE>0 (forced radius=2): the off-main orchestrator must run `applyCore`
    /// then `renderCore`, byte-identical to `@MainActor` `apply`+`render`. Pins
    /// the DE+display composition (the path T8 drives after the EMA on H_acc).
    func testOffMainSmoothedDisplayMatchesMainActor_withDE() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try loadFrozen("sierpinski")
        let params = RenderParams(seed: 1, width: 64, height: 64,
                                  oversample: 1, samplesPerPixel: 8)
        let p = params.settingSpatialFilterRadius(flame.quality.filterRadius)
        let hist = try ChaosGameMetal.iterate(flame: flame, params: p)

        let deRadius = 2.0, deMinimum = 1.0, deCurve = 0.6
        let deHist = try DensityEstimationMetal.apply(
            hist, radius: deRadius, minimum: deMinimum, curve: deCurve)
        let mainImg = try DisplayPipelineMetal.render(
            histogram: deHist, width: p.width, height: p.height, oversample: p.oversample,
            gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
            vibrancy: flame.quality.vibrancy, brightness: flame.quality.brightness,
            sampleDensity: Double(p.samplesPerPixel),
            pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom),
            highlightPower: flame.quality.highlightPower,
            spatialFilterRadius: p.spatialFilterRadius)

        let offImg = try XCTUnwrap(MetalRenderer.renderSmoothedDisplayOffMain(
            histogram: hist, deRadius: deRadius, deMinimum: deMinimum, deCurve: deCurve,
            width: p.width, height: p.height, oversample: p.oversample,
            gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
            vibrancy: flame.quality.vibrancy, brightness: flame.quality.brightness,
            sampleDensity: Double(p.samplesPerPixel),
            pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom),
            highlightPower: flame.quality.highlightPower,
            spatialFilterRadius: p.spatialFilterRadius),
            "off-main smoothed display (DE>0) must succeed")

        XCTAssertEqual(offImg, mainImg,
            "renderSmoothedDisplayOffMain (DE>0) must be byte-identical to @MainActor apply+render")
    }
}
