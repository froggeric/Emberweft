import Foundation
import Metal
import FlameKit

/// GPU dispatch + decode for the Stage-1 chaos-game kernel.
///
/// Mirrors `FlameReference.ChaosGame.iterate` on the GPU: builds the device
/// buffers (xforms, final xform, distrib, dmap, dmapAlpha, frame params, and
/// per-thread ISAAC seeds) via the shared `MetalHost`/`FlameKit` builders,
/// dispatches the `chaosGame` kernel, and decodes the fixed-point atomic
/// histogram back into a `FlameKit.Histogram` whose `colors`/`alpha` are in
/// dmap-units (Doubles) matching the CPU oracle's accumulation.
///
/// The Metal histogram stores each channel as a `uint32` fixed-point value:
/// `uint(clamp(v,0,255) * colorScale + 0.5)` per hit, summed atomically. Decoding
/// divides by `colorScale` to recover dmap-units Doubles. The per-hit `+0.5`
/// rounding is a small, bounded quantization error accepted by the statistical
/// parity model (the histogram is a density estimate, not a byte-exact target).
@MainActor
enum ChaosGameMetal {

    /// Run the Stage-1 chaos kernel for `flame`/`params` and return a populated
    /// `Histogram`. Deterministic in `(flame, params)` across repeated calls.
    static func iterate(flame: Flame, params: RenderParams) throws -> Histogram {
        guard let (device, library) = MetalRenderer.deviceAndLibrary() else {
            throw NSError(domain: "MetalRenderer", code: 10)
        }
        guard let queue = MetalRenderer.commandQueue else {
            throw NSError(domain: "MetalRenderer", code: 11)
        }

        // --- Build device payloads via the shared FlameKit/MetalHost builders ---
        let xforms = MetalHost.buildGPUXforms(flame)
        let finalXform = MetalHost.buildGPUFinalXform(flame)
        let weights = flame.xforms.map { max(0, $0.weight) }
        guard weights.reduce(0, +) > 0 else {
            return Histogram(gridWidth: params.gridWidth, gridHeight: params.gridHeight)
        }
        let distribInt = Flam3XformDistrib.build(weights)
        let distrib = distribInt.map { UInt32(min($0, max(0, flame.xforms.count - 1))) }

        // dmap: 256 pre-scaled RGB entries (rect.c:776-782). SIMD3<Float> has
        // stride 16 == Metal `float3` array stride, so it crosses the boundary
        // with no padding reinterpretation.
        let whiteLevel = 255.0
        let colorScalar = 1.0
        let dmapD = buildDmap(flame.palette, whiteLevel: whiteLevel, colorScalar: colorScalar)
        let dmap = dmapD.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        let dmapAlpha = [Float](repeating: Float(whiteLevel * colorScalar), count: 256)

        var fp = MetalHost.buildFrameParams(flame, params)
        fp.hasFinal = finalXform != nil ? 1 : 0
        let threadSeeds = MetalHost.buildThreadSeeds(seed: params.seed,
                                                    threadCount: Int(fp.threadCount))

        // --- Buffers (all .storageModeShared via the `buf` helper) ---
        func buf<T>(_ values: [T]) -> MTLBuffer {
            values.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!,
                                  length: raw.count,
                                  options: .storageModeShared)!
            }
        }
        let xformsBuf    = buf(xforms)
        // finalXf buffer is mandatory in the kernel signature even when unused;
        // emit a zeroed single-element buffer so binding 1 is always valid.
        let finalBuf     = finalXform.map { buf([$0]) }
                                   ?? device.makeBuffer(length: MemoryLayout<GPUXform>.stride,
                                                        options: .storageModeShared)!
        let distribBuf   = buf(distrib)
        let dmapBuf      = buf(dmap)
        let dmapAlphaBuf = buf(dmapAlpha)
        var fpLocal = fp
        let fpBuf        = device.makeBuffer(bytes: &fpLocal,
                                             length: MemoryLayout<GPUFrameParams>.stride,
                                             options: .storageModeShared)!
        let seedsBuf     = buf(threadSeeds)

        let binCount = params.gridWidth * params.gridHeight
        let binBytes = binCount * MemoryLayout<AtomicBinHost>.stride
        let histBuf  = device.makeBuffer(length: binBytes, options: .storageModeShared)!
        memset(histBuf.contents(), 0, binBytes)

        // --- Pipeline + dispatch (fixed Metal API per T2's proven pattern) ---
        guard let function = library.makeFunction(name: "chaosGame") else {
            throw NSError(domain: "MetalRenderer", code: 12)
        }
        let pso = try device.makeComputePipelineState(function: function)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw NSError(domain: "MetalRenderer", code: 13)
        }
        enc.setComputePipelineState(pso)
        enc.setBuffer(xformsBuf,    offset: 0, index: 0)
        enc.setBuffer(finalBuf,     offset: 0, index: 1)
        enc.setBuffer(distribBuf,   offset: 0, index: 2)
        enc.setBuffer(dmapBuf,      offset: 0, index: 3)
        enc.setBuffer(dmapAlphaBuf, offset: 0, index: 4)
        enc.setBuffer(fpBuf,        offset: 0, index: 5)
        enc.setBuffer(seedsBuf,     offset: 0, index: 6)
        enc.setBuffer(histBuf,      offset: 0, index: 7)

        let tc = Int(fp.threadCount)
        let tpg = MetalHost.threadsPerGroup
        let groups = (tc + tpg - 1) / tpg
        enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        return decode(histBuf: histBuf, binCount: binCount,
                      gridWidth: params.gridWidth, gridHeight: params.gridHeight,
                      colorScale: Double(fp.colorScale))
    }

    // MARK: - Decode

    /// Host mirror of MSL `AtomicBin` (5×uint32 per bin). Layout must match the
    /// device struct field-for-field; both are 5 × 4 bytes, 4-byte aligned.
    private struct AtomicBinHost {
        var count: UInt32 = 0
        var r: UInt32 = 0
        var g: UInt32 = 0
        var b: UInt32 = 0
        var a: UInt32 = 0
    }

    /// Read the flat `AtomicBin` array and divide r/g/b/a by `colorScale` to
    /// recover dmap-units Doubles matching CPU `hist.colors`/`alpha`. `counts`
    /// are exact (1 per hit).
    private static func decode(histBuf: MTLBuffer, binCount: Int,
                               gridWidth: Int, gridHeight: Int,
                               colorScale: Double) -> Histogram {
        var hist = Histogram(gridWidth: gridWidth, gridHeight: gridHeight)
        let bins = histBuf.contents().assumingMemoryBound(to: AtomicBinHost.self)
        let invScale = 1.0 / colorScale
        for i in 0..<binCount {
            let bin = bins[i]
            hist.counts[i] = Double(bin.count)
            hist.colors[i] = SIMD3(Double(bin.r) * invScale,
                                   Double(bin.g) * invScale,
                                   Double(bin.b) * invScale)
            hist.alpha[i] = Double(bin.a) * invScale
        }
        return hist
    }
}
