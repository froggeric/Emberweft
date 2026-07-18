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

    /// Full Metal pipeline: chaos → decode → density estimation → display.
    ///
    /// PRODUCTION PATH (`renderFused`): all stages are encoded into a SINGLE
    /// `MTLCommandBuffer` with the histogram held GPU-resident throughout — one
    /// commit + one `waitUntilCompleted`. Only the final RGBA8 readback crosses
    /// GPU→CPU. This recovers the ~25 ms 1080p cost of the prior 3-command-buffer
    /// design, where the resolution-sized histogram round-tripped to the CPU four
    /// times per frame (decode to Swift `Histogram`, repack to `[Float]` twice,
    /// with a blocking `waitUntilCompleted` between each stage).
    ///
    /// Determinism is unchanged from the unfused path: chaos still accumulates
    /// `uint32` atomics (associative → byte-deterministic). The only addition is
    /// a pure per-bin `atomicBinToFloatBin` decode kernel (no atomics, no order
    /// dependence) that converts AtomicBin → FloatBin on the GPU between chaos
    /// and density. Fused output is byte-identical to the unfused stage-by-stage
    /// output on a frozen genome (see `FusedUnfusedParityTests`).
    ///
    /// Statistical parity (PSNR ≥ 38 dB) vs `ReferenceRenderer.render`, not
    /// byte-identical to CPU. Failing loudly on a no-GPU box rather than
    /// producing garbage.
    @MainActor
    public static func render(flame: Flame, params: RenderParams) -> RGBA8Image {
        guard isAvailable else {
            fatalError("MetalRenderer.render called when isAvailable is false")
        }
        do {
            return try renderFused(flame: flame, params: params)
        } catch {
            fatalError("Metal render failed: \(error)")
        }
    }

    // MARK: - Fused production path (single command buffer, GPU-resident histogram)

    /// Encode chaos → decode → density (if estimatorRadius>0) → logDensity →
    /// displayPipeline into one command buffer; commit once. The histogram lives
    /// in GPU buffers across all stages (`atomicBuf` → `floatBufA` → optional
    /// `floatBufB`), never crossing to the CPU. Only the final RGBA is read back.
    @MainActor
    static func renderFused(flame: Flame, params: RenderParams) throws -> RGBA8Image {
        guard let (device, library) = deviceAndLibrary() else {
            throw NSError(domain: "MetalRenderer", code: 10)
        }
        guard let queue = commandQueue else {
            throw NSError(domain: "MetalRenderer", code: 11)
        }

        // -------- Shared chaos payload (mirrors ChaosGameMetal.iterate) --------
        let xforms = MetalHost.packXforms(flame)
        let finalXform = MetalHost.packFinalXform(flame)
        let weights = flame.xforms.map { max(0, $0.weight) }
        guard weights.reduce(0, +) > 0 else {
            // Degenerate (zero-weight) flame: emit a black frame.
            return RGBA8Image(width: params.width, height: params.height,
                              pixels: [UInt8](repeating: 0, count: params.width * params.height * 4))
        }
        let distribInt = Flam3XformDistrib.build(weights)
        let distrib = distribInt.map { UInt32(min($0, max(0, flame.xforms.count - 1))) }

        let whiteLevel = 255.0
        let colorScalar = 1.0
        let dmapD = buildDmap(flame.palette, whiteLevel: whiteLevel, colorScalar: colorScalar)
        let dmap = dmapD.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        let dmapAlpha = [Float](repeating: Float(whiteLevel * colorScalar), count: 256)

        var fp = MetalHost.buildFrameParams(flame, params)
        fp.hasFinal = finalXform != nil ? 1 : 0
        let threadSeeds = MetalHost.buildThreadSeeds(seed: params.seed,
                                                    threadCount: Int(fp.threadCount))

        func buf<T>(_ values: [T]) -> MTLBuffer {
            values.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!,
                                  length: raw.count,
                                  options: .storageModeShared)!
            }
        }
        let xformsBuf    = buf(xforms)
        let finalBuf     = finalXform.map { buf($0) }
                                   ?? device.makeBuffer(length: GPUXform.bytesPerXform,
                                                        options: .storageModeShared)!
        let distribBuf   = buf(distrib)
        let dmapBuf      = buf(dmap)
        let dmapAlphaBuf = buf(dmapAlpha)
        var fpLocal = fp
        let fpBuf        = device.makeBuffer(bytes: &fpLocal,
                                             length: MemoryLayout<GPUFrameParams>.stride,
                                             options: .storageModeShared)!
        let seedsBuf     = buf(threadSeeds)

        let gw = params.gridWidth, gh = params.gridHeight
        let binCount = gw * gh

        // AtomicBin host mirror (5×uint32) — layout MUST match MSL AtomicBin.
        struct AtomicBinHost { var count: UInt32 = 0; var r: UInt32 = 0; var g: UInt32 = 0; var b: UInt32 = 0; var a: UInt32 = 0 }
        let atomicBuf = device.makeBuffer(
            length: binCount * MemoryLayout<AtomicBinHost>.stride,
            options: .storageModeShared)!
        memset(atomicBuf.contents(), 0, binCount * MemoryLayout<AtomicBinHost>.stride)

        // FloatBin buffers (5×float). Fully overwritten by their producers
        // (decode writes every cell of floatBufA; density writes every cell of
        // floatBufB), so no zero-fill needed.
        let floatBytes = binCount * 5 * MemoryLayout<Float>.stride
        let floatBufA = device.makeBuffer(length: floatBytes, options: .storageModeShared)!
        let floatBufB = device.makeBuffer(length: floatBytes, options: .storageModeShared)!

        // -------- Display payload (mirrors DisplayPipelineMetal.render) --------
        let oversample = params.oversample
        let contrast: Double = 1.0
        let brightness: Double = 4.0
        let prefilterWhite: Double = 255.0
        let whiteLevelD: Double = 255.0
        let k1 = contrast * brightness * prefilterWhite * 268.0 / 256.0
        let imageW = params.width * oversample
        let imageH = params.height * oversample
        let pixelsPerUnit = flame.camera.scale * pow(2, flame.camera.zoom)
        let area = Double(imageW * imageH) / (pixelsPerUnit * pixelsPerUnit)
        let nbatches = 1
        let sumfilt: Double = 1.0
        let sampleDensity = Double(params.samplesPerPixel)
        let k2 = Double(oversample * oversample * nbatches) /
                 (contrast * area * whiteLevelD * sampleDensity * sumfilt)

        let (fw, kernelFloat) = DisplayPipelineMetal.makeSpatialKernelMetal(
            oversample: oversample, radius: RenderParams.spatialFilterRadius)
        let gutter = (fw - oversample) / 2

        var dp = DisplayPipelineMetal.DisplayParams()
        dp.k1 = Float(k1); dp.k2 = Float(k2)
        dp.gammaInv = Float(1.0 / flame.quality.gamma)
        dp.linrange = Float(flame.quality.gammaThreshold)
        dp.vibrancy = Float(flame.quality.vibrancy)
        dp.bgR = 0; dp.bgG = 0; dp.bgB = 0
        dp.highlightPower = -1.0
        dp.gw = UInt32(gw); dp.gh = UInt32(gh)
        dp.width = UInt32(params.width); dp.height = UInt32(params.height)
        dp.oversample = UInt32(oversample)
        dp.fw = UInt32(fw); dp.gutter = UInt32(gutter)
        var dpExact = dp
        let dpBuf = device.makeBuffer(bytes: &dpExact,
                                      length: MemoryLayout<DisplayPipelineMetal.DisplayParams>.size,
                                      options: .storageModeShared)!
        let spatialBuf = buf(kernelFloat)

        let accumRGBBytes = binCount * 3 * MemoryLayout<Float>.stride
        let accumRGBBuf = device.makeBuffer(length: accumRGBBytes, options: .storageModeShared)!
        let accumABuf = device.makeBuffer(length: binCount * MemoryLayout<Float>.stride,
                                          options: .storageModeShared)!
        let outBytes = params.width * params.height * 4
        let outBuf = device.makeBuffer(length: outBytes, options: .storageModeShared)!

        // Density payload (mirrors DensityEstimationMetal.apply).
        let deRadius = flame.quality.estimatorRadius
        let deParams: [Float] = [Float(deRadius),
                                 Float(flame.quality.estimatorMinimum),
                                 Float(flame.quality.estimatorCurveRate)]
        let deDims: [UInt32] = [UInt32(gw), UInt32(gh)]
        let deParamsBuf = buf(deParams)
        let deDimsBuf = buf(deDims)

        // -------- Pipeline states --------
        func pso(_ name: String) -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else {
                fatalError("Missing MSL kernel: \(name)")
            }
            return try! device.makeComputePipelineState(function: fn)
        }
        let chaosPso   = pso("chaosGame")
        let decodePso  = pso("atomicBinToFloatBin")
        let densityPso = pso("densityEstimation")
        let logPso     = pso("logDensity")
        let dispPso    = pso("displayPipeline")

        guard let cb = queue.makeCommandBuffer() else {
            throw NSError(domain: "MetalRenderer", code: 24)
        }
        let tpg = MetalHost.threadsPerGroup
        let tpg2D = 16

        // -------- Encoder 1: chaosGame (writes atomicBuf, uint32 atomics) --------
        guard let encChaos = cb.makeComputeCommandEncoder() else {
            throw NSError(domain: "MetalRenderer", code: 13)
        }
        encChaos.setComputePipelineState(chaosPso)
        encChaos.setBuffer(xformsBuf,    offset: 0, index: 0)
        encChaos.setBuffer(finalBuf,     offset: 0, index: 1)
        encChaos.setBuffer(distribBuf,   offset: 0, index: 2)
        encChaos.setBuffer(dmapBuf,      offset: 0, index: 3)
        encChaos.setBuffer(dmapAlphaBuf, offset: 0, index: 4)
        encChaos.setBuffer(fpBuf,        offset: 0, index: 5)
        encChaos.setBuffer(seedsBuf,     offset: 0, index: 6)
        encChaos.setBuffer(atomicBuf,    offset: 0, index: 7)
        let tc = Int(fp.threadCount)
        let groups = (tc + tpg - 1) / tpg
        encChaos.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                      threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
        encChaos.endEncoding()

        // -------- Encoder 2: atomicBinToFloatBin (atomicBuf → floatBufA) --------
        guard let encDec = cb.makeComputeCommandEncoder() else {
            throw NSError(domain: "MetalRenderer", code: 17)
        }
        encDec.setComputePipelineState(decodePso)
        encDec.setBuffer(atomicBuf,  offset: 0, index: 0)
        encDec.setBuffer(floatBufA,  offset: 0, index: 1)
        encDec.setBuffer(fpBuf,      offset: 0, index: 2)
        let decGW = (gw + tpg2D - 1) / tpg2D, decGH = (gh + tpg2D - 1) / tpg2D
        encDec.dispatchThreadgroups(MTLSize(width: decGW, height: decGH, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: tpg2D, height: tpg2D, depth: 1))
        encDec.endEncoding()

        // -------- Encoder 3 (optional): densityEstimation (floatBufA → floatBufB) --------
        // Mirror the unfused branch: run ONLY when estimatorRadius > 0. When
        // skipped, logDensity reads floatBufA (the decode output); when run,
        // logDensity reads floatBufB (the density "work" output).
        let runDensity = deRadius > 0
        if runDensity {
            guard let encDe = cb.makeComputeCommandEncoder() else {
                throw NSError(domain: "MetalRenderer", code: 16)
            }
            encDe.setComputePipelineState(densityPso)
            encDe.setBuffer(floatBufA,  offset: 0, index: 0)
            encDe.setBuffer(deParamsBuf, offset: 0, index: 1)
            encDe.setBuffer(deDimsBuf,  offset: 0, index: 2)
            encDe.setBuffer(floatBufB,  offset: 0, index: 3)
            let deGW = (gw + tpg2D - 1) / tpg2D, deGH = (gh + tpg2D - 1) / tpg2D
            encDe.dispatchThreadgroups(MTLSize(width: deGW, height: deGH, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: tpg2D, height: tpg2D, depth: 1))
            encDe.endEncoding()
        }
        let rawBuf = runDensity ? floatBufB : floatBufA

        // -------- Encoder 4: logDensity (rawBuf → accumRGB/accumA) --------
        guard let encLog = cb.makeComputeCommandEncoder() else {
            throw NSError(domain: "MetalRenderer", code: 25)
        }
        encLog.setComputePipelineState(logPso)
        encLog.setBuffer(rawBuf,      offset: 0, index: 0)
        encLog.setBuffer(accumRGBBuf, offset: 0, index: 1)
        encLog.setBuffer(accumABuf,   offset: 0, index: 2)
        encLog.setBuffer(dpBuf,       offset: 0, index: 3)
        let logGW = (gw + tpg2D - 1) / tpg2D, logGH = (gh + tpg2D - 1) / tpg2D
        encLog.dispatchThreadgroups(MTLSize(width: logGW, height: logGH, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: tpg2D, height: tpg2D, depth: 1))
        encLog.endEncoding()

        // -------- Encoder 5: displayPipeline (accumRGB/accumA → outBuf) --------
        guard let encDisp = cb.makeComputeCommandEncoder() else {
            throw NSError(domain: "MetalRenderer", code: 26)
        }
        encDisp.setComputePipelineState(dispPso)
        encDisp.setBuffer(accumRGBBuf, offset: 0, index: 0)
        encDisp.setBuffer(accumABuf,   offset: 0, index: 1)
        encDisp.setBuffer(spatialBuf,  offset: 0, index: 2)
        encDisp.setBuffer(dpBuf,       offset: 0, index: 3)
        encDisp.setBuffer(outBuf,      offset: 0, index: 4)
        let dispGW = (params.width + tpg2D - 1) / tpg2D
        let dispGH = (params.height + tpg2D - 1) / tpg2D
        encDisp.dispatchThreadgroups(MTLSize(width: dispGW, height: dispGH, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tpg2D, height: tpg2D, depth: 1))
        encDisp.endEncoding()

        // -------- Single commit + single wait; only the RGBA crosses to CPU --------
        cb.commit()
        cb.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: outBytes)
        pixels.withUnsafeMutableBytes { dst in
            dst.baseAddress!.copyMemory(from: outBuf.contents(), byteCount: outBytes)
        }
        return RGBA8Image(width: params.width, height: params.height, pixels: pixels)
    }

    // MARK: - Unfused reference path (per-stage, CPU histogram round-trips)
    //
    // Kept as the per-stage stage-by-stage reference for `FusedUnfusedParityTests`
    // and as a documented fallback. It calls the three stage entry points
    // (ChaosGameMetal → DensityEstimationMetal → DisplayPipelineMetal), each of
    // which commits its own command buffer and round-trips the histogram through
    // a Swift `Histogram` of Doubles. The per-stage parity tests
    // (HistogramParityTests, DensityEstimationParityTests, Stage3aParityTests)
    // call those entry points directly, so this path and those tests share one
    // proven code surface.

    @MainActor
    static func renderUnfused(flame: Flame, params: RenderParams) -> RGBA8Image {
        do {
            var hist = try ChaosGameMetal.iterate(flame: flame, params: params)
            if flame.quality.estimatorRadius > 0 {
                hist = try DensityEstimationMetal.apply(hist,
                    radius: flame.quality.estimatorRadius,
                    minimum: flame.quality.estimatorMinimum,
                    curve: flame.quality.estimatorCurveRate)
            }
            return try DisplayPipelineMetal.render(histogram: hist,
                width: params.width, height: params.height, oversample: params.oversample,
                gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
                vibrancy: flame.quality.vibrancy,
                sampleDensity: Double(params.samplesPerPixel),
                pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom))
        } catch {
            fatalError("Metal render (unfused) failed: \(error)")
        }
    }
}
