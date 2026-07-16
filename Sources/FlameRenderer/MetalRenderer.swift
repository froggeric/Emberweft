import Foundation
import Metal
import FlameKit
import FlameReference  // Stage-3b on-ramp only; Task 9 removes this dep.

/// Metal-compute fractal-flame renderer — faithful statistical twin of
/// `FlameReference`. Deterministic within the Metal backend (same seed →
/// identical frame, machine-independent). Not byte-identical to CPU.
public enum MetalRenderer {
    /// Best-effort cached default device. `MTLCreateSystemDefaultDevice` is
    /// documented safe to call once and reuse; we memoize in an Optional.
    @MainActor private static var _device: MTLDevice?
    @MainActor private static var _library: MTLLibrary?

    /// True iff a Metal device exists AND the MSL library compiles.
    /// Gate `--backend metal` on this; the CLI falls back to CPU otherwise.
    public static var isAvailable: Bool {
        MainActor.assumeIsolated { deviceAndLibrary() != nil }
    }

    @MainActor
    static func deviceAndLibrary() -> (MTLDevice, MTLLibrary)? {
        if let d = _device, let l = _library { return (d, l) }
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        // The .metal sources are bundled as SwiftPM resources (.copy("Metal")).
        guard let url = Bundle.module.url(
            forResource: "Kernels", withExtension: "metal", subdirectory: "Metal"
        ) ?? Bundle.module.url(forResource: "Kernels", withExtension: "metal"),
            let source = try? String(contentsOf: url, encoding: .utf8),
            let library = try? device.makeLibrary(source: source, options: nil)
        else { return nil }
        _device = device
        _library = library
        return (device, library)
    }

    /// Render `flame` at `params` to an 8-bit RGBA image.
    ///
    /// Stage-3b on-ramp (M2): chaos on Metal, density-estimation + tone-map on
    /// CPU. Deterministic within the Metal backend. Statistical twin of
    /// `ReferenceRenderer.render` (PSNR ≥ 38 dB), not byte-identical.
    ///
    /// The Metal chaos kernel fetches its own device/queue via
    /// `ChaosGameMetal.iterate`, so the only host-side gate needed here is
    /// `isAvailable` — failing loudly on a no-GPU box rather than producing
    /// garbage.
    @MainActor
    public static func render(flame: Flame, params: RenderParams) -> RGBA8Image {
        guard isAvailable else {
            fatalError("MetalRenderer.render called when isAvailable is false")
        }
        do {
            var hist = try ChaosGameMetal.iterate(flame: flame, params: params)
            if flame.quality.estimatorRadius > 0 {
                // CPU approximation twin (frozen goldens are radius=0 — unexercised in M2).
                hist = FlameReference.DensityEstimation.apply(hist,
                    radius: flame.quality.estimatorRadius,
                    minimum: flame.quality.estimatorMinimum,
                    curve: flame.quality.estimatorCurveRate)
            }
            return FlameReference.ToneMapping.render(histogram: hist,
                width: params.width, height: params.height, oversample: params.oversample,
                gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
                vibrancy: flame.quality.vibrancy,
                sampleDensity: Double(params.samplesPerPixel),
                pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom))
        } catch {
            fatalError("Metal render failed: \(error)")
        }
    }
}
