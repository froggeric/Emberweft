import Foundation
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

/// Stage-3b parity-bisect helper (test-only): Metal chaos + CPU tone-map.
///
/// Composes `ChaosGameMetal.iterate` with CPU `DensityEstimation`/`ToneMapping`.
/// This was the Task-7 production on-ramp; Task 9 replaced the production
/// `MetalRenderer.render` with the full-Metal pipeline and moved this composition
/// here so the 3b parity-bisect gate stays a permanent test.
@MainActor
enum OnRamp3b {
    static func render(flame: Flame, params: RenderParams) -> RGBA8Image {
        var hist = try! ChaosGameMetal.iterate(flame: flame, params: params)
        if flame.quality.estimatorRadius > 0 {
            hist = DensityEstimation.apply(hist,
                radius: flame.quality.estimatorRadius,
                minimum: flame.quality.estimatorMinimum,
                curve: flame.quality.estimatorCurveRate)
        }
        return ToneMapping.render(histogram: hist,
            width: params.width, height: params.height, oversample: params.oversample,
            gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
            vibrancy: flame.quality.vibrancy,
            sampleDensity: Double(params.samplesPerPixel),
            pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom))
    }
}
