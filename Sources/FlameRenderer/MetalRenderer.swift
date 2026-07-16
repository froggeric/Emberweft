import Foundation
import Metal
import FlameKit

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
}
