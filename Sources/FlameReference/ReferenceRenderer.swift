import Foundation
import FlameKit

/// Façade tying the full CPU reference pipeline together:
/// chaos game → density estimation → tone map → `RGBA8Image`.
///
/// Deterministic: the same `(flame, params)` always yields an identical image.
public enum ReferenceRenderer {
    /// Render `flame` at `params` to an 8-bit RGBA image.
    public static func render(flame: Flame, params: RenderParams) -> RGBA8Image {
        var hist = ChaosGame.iterate(flame: flame, params: params)
        if flame.quality.estimatorRadius > 0 {
            hist = DensityEstimation.apply(hist,
                radius: flame.quality.estimatorRadius,
                minimum: flame.quality.estimatorMinimum,
                curve: flame.quality.estimatorCurveRate)
        }
        return ToneMapping.render(histogram: hist,
            width: params.width, height: params.height, oversample: params.oversample,
            gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
            vibrancy: flame.quality.vibrancy)
    }
}
