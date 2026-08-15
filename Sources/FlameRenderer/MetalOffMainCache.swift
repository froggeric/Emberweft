import Foundation
import Metal

/// Off-main Metal device/library/queue/PSO cache for the thumbnail render path.
///
/// Every member is accessed ONLY from `MetalRenderer.offMainQueue` (serialized
/// via `offMainQueue.sync`), so the mutable `private(set)` state needs no lock —
/// the queue IS the lock. NOT `Sendable`; do not touch from any other thread.
///
/// This is a deliberate parallel to the `@MainActor` cached state in
/// `MetalRenderer` (`_device`/`_library`/`_queue`/`_chaosPso`/…): the realtime
/// path keeps its MainActor isolation unchanged; the thumbnail path gets its own
/// background-thread cache. Both compile the same `Kernels.metal` source against
/// the system device, so their PSOs (and therefore output) are byte-identical.
final class MetalOffMainCache {
    private(set) var device: MTLDevice?
    private(set) var library: MTLLibrary?
    private(set) var queue: MTLCommandQueue?

    private var chaosPso: MTLComputePipelineState?
    private var decodePso: MTLComputePipelineState?
    private var densityPso: MTLComputePipelineState?
    private var logPso: MTLComputePipelineState?
    private var displayPso: MTLComputePipelineState?

    /// Lazily build + cache the device, library, and command queue.
    func handles() -> (MTLDevice, MTLLibrary, MTLCommandQueue)? {
        if let d = device, let l = library, let q = queue { return (d, l, q) }
        guard let d = MTLCreateSystemDefaultDevice() else { return nil }
        // The `.metal` sources are bundled as SwiftPM resources (.copy("Metal")).
        // ModuleResources resolves Contents/Resources for the bundled .app (see its doc
        // comment); everywhere else it is the same bundle Bundle.module finds.
        guard let url = ModuleResources.bundle.url(
                forResource: "Kernels", withExtension: "metal", subdirectory: "Metal")
                ?? ModuleResources.bundle.url(forResource: "Kernels", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let lib = try? d.makeLibrary(source: source, options: nil),
              let q = d.makeCommandQueue()
        else { return nil }
        device = d
        library = lib
        queue = q
        return (d, lib, q)
    }

    /// Lazily build + cache the 5 fused-path PSOs.
    func pipelines(device: MTLDevice, library: MTLLibrary) ->
        (chaos: MTLComputePipelineState, decode: MTLComputePipelineState,
         density: MTLComputePipelineState, log: MTLComputePipelineState,
         display: MTLComputePipelineState)? {
        if let c = chaosPso, let de = decodePso, let dn = densityPso,
           let lg = logPso, let dp = displayPso {
            return (c, de, dn, lg, dp)
        }
        func pso(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: fn)
        }
        guard let c = pso("chaosGame"),
              let de = pso("atomicBinToFloatBin"),
              let dn = pso("densityEstimation"),
              let lg = pso("logDensity"),
              let dp = pso("displayPipeline")
        else { return nil }
        chaosPso = c; decodePso = de; densityPso = dn; logPso = lg; displayPso = dp
        return (c, de, dn, lg, dp)
    }
}
