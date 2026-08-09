import XCTest
import FlameKit
@testable import FlameReference

/// T3 (M6.1 slice 2 — temporal smoothing): pins `ReferenceRenderer.histogram(...)`
/// as a PRE-DE extraction of the chaos / temporal-accumulate stage.
///
/// The S1 invariant under test: DE must NOT run inside `histogram(...)` — the
/// smoothing coordinator EMAs the PRE-DE accumulator, then DE+display run ONCE
/// on `H_acc`. The no-DE case (a) alone would pass whether DE lives in
/// `histogram` or `render` (DE is a passthrough when `estimatorRadius == 0`),
/// so it does NOT pin pre-DE; the DE>0 case (b) is the S4 pin that catches a
/// double-DE bug (DE-in-histogram ⇒ manual apply double-DEs ⇒ brightness shift).
final class ReferenceRendererHistogramTests: XCTestCase {
    private func load(_ name: String) throws -> Flame {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name).flam3")
        return try Flam3Parser.parse(Data(contentsOf: url))[0]
    }

    /// Shared tone-map stage — mirrors `ReferenceRenderer.render(flame:params:)`'s
    /// display args exactly (filter radius threaded into params, gamma/vibrancy/
    /// brightness/pixelsPerUnit from the flame, `sampleDensity = spp`).
    private func toneMap(_ hist: Histogram, _ flame: Flame, _ params: RenderParams) -> RGBA8Image {
        let p = params.settingSpatialFilterRadius(flame.quality.filterRadius)
        return ToneMapping.render(histogram: hist,
            width: p.width, height: p.height, oversample: p.oversample,
            gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
            vibrancy: flame.quality.vibrancy, brightness: flame.quality.brightness,
            sampleDensity: Double(p.samplesPerPixel),
            pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom),
            highlightPower: flame.quality.highlightPower,
            spatialFilterRadius: p.spatialFilterRadius)
    }

    /// (a) No-DE fixture: `histogram` + ToneMapping == `render` (DE is passthrough).
    func testNoDE_HistogramPlusToneMapEqualsRender() throws {
        let flame = try load("sierpinski")          // estimatorRadius == 0
        XCTAssertEqual(flame.quality.estimatorRadius, 0)
        let params = RenderParams(seed: 1, width: 64, height: 64, oversample: 1, samplesPerPixel: 4)
        let direct = ReferenceRenderer.render(flame: flame, params: params)
        let rebuilt = toneMap(ReferenceRenderer.histogram(flame: flame, params: params), flame, params)
        XCTAssertEqual(direct, rebuilt)
    }

    /// (b) DE fixture: `histogram` + manual DE + ToneMapping == `render`.
    /// Would FAIL under the S1 bug (DE inside `histogram` ⇒ manual apply
    /// double-DEs ⇒ brightness shift). Synthesizes a DE fixture by forcing
    /// `estimatorRadius = 2` on sierpinski.
    func testWithDE_HistogramPlusManualDEPlusToneMapEqualsRender() throws {
        var flame = try load("sierpinski")
        flame.quality.estimatorRadius = 2           // force DE on
        XCTAssertGreaterThan(flame.quality.estimatorRadius, 0)
        let params = RenderParams(seed: 1, width: 64, height: 64, oversample: 1, samplesPerPixel: 4)
        let direct = ReferenceRenderer.render(flame: flame, params: params)
        var hist = ReferenceRenderer.histogram(flame: flame, params: params)   // PRE-DE
        hist = DensityEstimation.apply(hist,
            radius: flame.quality.estimatorRadius,
            minimum: flame.quality.estimatorMinimum,
            curve: flame.quality.estimatorCurveRate)
        let rebuilt = toneMap(hist, flame, params)
        XCTAssertEqual(direct, rebuilt)
    }
}
