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
    /// The 5 fused-path compute pipeline states, built ONCE and reused across
    /// every frame. `device.makeComputePipelineState(function:)` compiles+links
    /// the kernel; redoing it per frame (the old behaviour) dominated `animate`
    /// and thrashed the driver pipeline cache on long sequences. A PSO is a pure
    /// function of (kernel source, device), so caching is byte-identical.
    @MainActor private static var _chaosPso: MTLComputePipelineState?
    @MainActor private static var _decodePso: MTLComputePipelineState?
    @MainActor private static var _densityPso: MTLComputePipelineState?
    @MainActor private static var _logPso: MTLComputePipelineState?
    @MainActor private static var _dispPso: MTLComputePipelineState?

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

    /// The 5 fused-path PSOs, built lazily on first use then cached. Tied to the
    /// cached device from `deviceAndLibrary()` (the only device this renderer
    /// ever uses). Returns nil iff no device/library.
    @MainActor
    static func fusedPipelines() -> (chaos: MTLComputePipelineState,
                                      decode: MTLComputePipelineState,
                                      density: MTLComputePipelineState,
                                      log: MTLComputePipelineState,
                                      display: MTLComputePipelineState)? {
        if let c = _chaosPso, let de = _decodePso, let dn = _densityPso,
           let lg = _logPso, let dp = _dispPso {
            return (c, de, dn, lg, dp)
        }
        guard let (device, library) = deviceAndLibrary() else { return nil }
        func pso(_ name: String) -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else {
                fatalError("Missing MSL kernel: \(name)")
            }
            return try! device.makeComputePipelineState(function: fn)
        }
        _chaosPso   = pso("chaosGame")
        _decodePso  = pso("atomicBinToFloatBin")
        _densityPso = pso("densityEstimation")
        _logPso     = pso("logDensity")
        _dispPso    = pso("displayPipeline")
        return (_chaosPso!, _decodePso!, _densityPso!, _logPso!, _dispPso!)
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

    // MARK: - Temporal motion-blur path (N fused chaos passes into one atomicBuf)

    /// Temporal motion-blur render: Metal twin of `ReferenceRenderer.render`
    /// `(blendAt:centerTime:temporal:sumfilt:params:)`. Faithful port of flam3's
    /// `temporal_samples` loop (rect.c:754-905).
    ///
    /// Encodes N chaos passes into ONE `atomicBuf` (cleared ONCE, accumulated
    /// across passes), then a single decode → (optional) DE → log → display —
    /// all in one `MTLCommandBuffer` with one commit + one `waitUntilCompleted`.
    /// Per pass: rebuild the dmap with `colorScalar = sub.weight` baked in
    /// (rect.c:757, 778-782), regenerate `threadSeeds` with a distinct salt
    /// (`params.seed &+ UInt64(i)`) so passes don't correlate, dispatch
    /// `≈threadCount/N` threads. Cost-neutral (rect.c:833): total samples across
    /// the N passes equals the full `width·height·samplesPerPixel` budget.
    ///
    /// N=1 identity: for box (the only type real ES genomes use),
    /// `colorScalar=1.0`, `sumfilt=1.0`, and `params.seed &+ UInt64(0) ==
    /// params.seed`, so `perPassThreads` collapses to `tc_full` and the path is
    /// byte-identical to `render(flame: blendAt(centerTime), params:)`.
    ///
    /// Gaussian/exp guard: real ES genomes use box exclusively; the CPU honors
    /// gaussian/exp (Task 2). Metal fails loudly (`fatalError`) on any sub-pass
    /// with `weight != 1.0` rather than render an untest-validated weighted-dmap
    /// path. The host-side per-pass dmap rebuild with `colorScalar: sub.weight`
    /// is structurally general, but runtime is guarded to box.
    @MainActor
    public static func render(
        blendAt: (Double) -> Flame,
        centerTime: Double,
        temporal: [(delta: Double, weight: Double)],
        sumfilt: Double,
        params: RenderParams
    ) -> RGBA8Image {
        guard isAvailable else {
            fatalError("MetalRenderer.render(blendAt:…) called when isAvailable is false")
        }
        // Gaussian/exp guard (see doc comment). A `fatalError` is the project
        // convention for an unsupported-but-structurally-typed path — the same
        // boundary `MetalRenderer.render(flame:params:)` uses for "no GPU".
        for sub in temporal where sub.weight != 1.0 {
            fatalError("""
                MetalRenderer.render(blendAt:…): non-box temporal filters \
                (sub-sample weight != 1.0) are not yet supported on Metal — only \
                box is (all real ES genomes use box). Got a sub-sample with \
                weight=\(sub.weight). Use ReferenceRenderer for gaussian/exp.
                """)
        }
        do {
            return try renderTemporalFused(
                blendAt: blendAt, centerTime: centerTime,
                temporal: temporal, sumfilt: sumfilt, params: params)
        } catch {
            fatalError("Metal temporal render failed: \(error)")
        }
    }

    // MARK: - Fused production path (single command buffer, GPU-resident histogram)

    /// Encode chaos → decode → density (if estimatorRadius>0) → logDensity →
    /// displayPipeline into one command buffer; commit once. The histogram lives
    /// in GPU buffers across all stages (`atomicBuf` → `floatBufA` → optional
    /// `floatBufB`), never crossing to the CPU. Only the final RGBA is read back.
    @MainActor
    static func renderFused(flame: Flame, params: RenderParams) throws -> RGBA8Image {
        guard let (device, _) = deviceAndLibrary() else {
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
        let brightness: Double = flame.quality.brightness
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

        // -------- Pipeline states (cached; built once on first frame) --------
        guard let psos = fusedPipelines() else {
            throw NSError(domain: "MetalRenderer", code: 27)
        }
        let chaosPso   = psos.chaos
        let decodePso  = psos.decode
        let densityPso = psos.density
        let logPso     = psos.log
        let dispPso    = psos.display

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

    // MARK: - Temporal motion-blur fused path (N chaos passes into one atomicBuf)

    /// Encode N chaos passes into one `atomicBuf` (cleared ONCE, accumulated
    /// across passes), then decode → (optional) DE → logDensity → display —
    /// all in one `MTLCommandBuffer`. See `render(blendAt:…)` for the contract.
    ///
    /// The chaos stage becomes a loop over `temporal`; the decode/DE/log/display
    /// stages are byte-for-byte copies of `renderFused` (they read the
    /// `atomicBuf` AFTER all passes have accumulated into it).
    @MainActor
    static func renderTemporalFused(
        blendAt: (Double) -> Flame,
        centerTime: Double,
        temporal: [(delta: Double, weight: Double)],
        sumfilt: Double,
        params: RenderParams
    ) throws -> RGBA8Image {
        precondition(!temporal.isEmpty,
            "renderTemporalFused: temporal must contain at least one sub-sample")
        let center = blendAt(centerTime)
        let N = temporal.count

        guard let (device, _) = deviceAndLibrary() else {
            throw NSError(domain: "MetalRenderer", code: 10)
        }
        guard let queue = commandQueue else {
            throw NSError(domain: "MetalRenderer", code: 11)
        }

        let gw = params.gridWidth, gh = params.gridHeight
        let binCount = gw * gh

        // Local MTLBuffer builder (same form as renderFused's nested `buf`).
        func buf<T>(_ values: [T]) -> MTLBuffer {
            values.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!,
                                   length: raw.count,
                                   options: .storageModeShared)!
            }
        }

        // -------- AtomicBin: cleared ONCE; N chaos encoders accumulate --------
        // into it (NOT cleared between passes). Layout MUST match MSL AtomicBin.
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

        // -------- Display payload (mirrors renderFused; sumfilt in k2) --------
        // MetalRenderer does NOT call ToneMapping; k2 is computed INLINE here
        // and `sumfilt` is threaded into its denominator exactly as ToneMapping
        // now does (rect.c:937). For box `sumfilt=1.0` → k2 unchanged.
        let oversample = params.oversample
        let contrast: Double = 1.0
        let brightness: Double = center.quality.brightness
        let prefilterWhite: Double = 255.0
        let whiteLevelD: Double = 255.0
        let k1 = contrast * brightness * prefilterWhite * 268.0 / 256.0
        let imageW = params.width * oversample
        let imageH = params.height * oversample
        let pixelsPerUnit = center.camera.scale * pow(2, center.camera.zoom)
        let area = Double(imageW * imageH) / (pixelsPerUnit * pixelsPerUnit)
        let nbatches = 1
        let sampleDensity = Double(params.samplesPerPixel)
        let k2 = Double(oversample * oversample * nbatches) /
                 (contrast * area * whiteLevelD * sampleDensity * sumfilt)

        let (fw, kernelFloat) = DisplayPipelineMetal.makeSpatialKernelMetal(
            oversample: oversample, radius: RenderParams.spatialFilterRadius)
        let gutter = (fw - oversample) / 2

        var dp = DisplayPipelineMetal.DisplayParams()
        dp.k1 = Float(k1); dp.k2 = Float(k2)
        dp.gammaInv = Float(1.0 / center.quality.gamma)
        dp.linrange = Float(center.quality.gammaThreshold)
        dp.vibrancy = Float(center.quality.vibrancy)
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

        // DE payload (from center flame — quality is frame-level).
        let deRadius = center.quality.estimatorRadius
        let deParams: [Float] = [Float(deRadius),
                                 Float(center.quality.estimatorMinimum),
                                 Float(center.quality.estimatorCurveRate)]
        let deDims: [UInt32] = [UInt32(gw), UInt32(gh)]
        let deParamsBuf = buf(deParams)
        let deDimsBuf = buf(deDims)

        // -------- Full-budget GPUFrameParams (colorScale uses the FULL T) --------
        // `colorScale` (`GPUFrameParams.colorScale`, the uint32 fixed-point atomic
        // normalizer) MUST use the FULL budget T = width*height*samplesPerPixel.
        // Computing it per pass from T/N would under-scale: the atomic
        // accumulation across N passes would overflow the uint32 bins. (Metal
        // analog of the CPU "count unweighted / sampleDensity = original" rule.)
        var fp = MetalHost.buildFrameParams(center, params)
        let centerFinal = MetalHost.packFinalXform(center)
        fp.hasFinal = centerFinal != nil ? 1 : 0
        // fpBuf for decode/log/display (frame-level; reads colorScale + grid
        // dims only — threadCount/ipt/remainder are unused by those kernels).
        var fpDecode = fp
        let fpBufDecode = device.makeBuffer(bytes: &fpDecode,
                                            length: MemoryLayout<GPUFrameParams>.stride,
                                            options: .storageModeShared)!

        let tpg = MetalHost.threadsPerGroup
        let tpg2D = 16
        let tcFull = Int(fp.threadCount)   // pinnedThreadCount(totalSamples: T)

        // Per-pass thread count: ≈ tcFull / N, rounded UP to a multiple of tpg.
        // For N=1 this collapses to tcFull → byte-identical to renderFused.
        // For N>1 the per-pass budget (T/N) is split into ipt/rem below so total
        // work across passes sums to exactly T (cost-neutral, rect.c:833).
        let target = tcFull / N
        let rounded = ((target + tpg - 1) / tpg) * tpg
        let perPassThreads = max(tpg, rounded)

        // Distribute the integer budget T across N passes (rect.c:833).
        let T = params.totalSamples
        let baseBudget = T / N
        let remBudget = T % N

        // -------- Pipeline states (cached; built once on first frame) --------
        guard let psos = fusedPipelines() else {
            throw NSError(domain: "MetalRenderer", code: 27)
        }
        let chaosPso   = psos.chaos
        let decodePso  = psos.decode
        let densityPso = psos.density
        let logPso     = psos.log
        let dispPso    = psos.display

        guard let cb = queue.makeCommandBuffer() else {
            throw NSError(domain: "MetalRenderer", code: 24)
        }

        // -------- Encoder 1 (LOOP): N chaos passes into the SAME atomicBuf ----
        // Each pass: re-pack xforms/final/distrib/dmap from blendAt(center+δ),
        // regenerate threadSeeds with a distinct salt (params.seed &+ UInt64(i)),
        // set per-pass threadCount/ipt/remainder, dispatch perPassThreads.
        // atomicBuf is NOT cleared between passes — chaos accumulates.
        for (i, sub) in temporal.enumerated() {
            let perPassBudget = baseBudget + (i < remBudget ? 1 : 0)
            // flam3 truncates per-pass budget of 0 (samplesPerPixel < N) —
            // skipping the encoder matches the CPU iterate safety-strap.
            guard perPassBudget > 0 else { continue }
            let passFlame = blendAt(centerTime + sub.delta)

            // Re-pack xforms/finalXform/distrib from the sub-pass flame.
            let passXforms = MetalHost.packXforms(passFlame)
            let passFinalXform = MetalHost.packFinalXform(passFlame)
            let passWeights = passFlame.xforms.map { max(0, $0.weight) }
            guard passWeights.reduce(0, +) > 0 else { continue }   // degenerate
            let passDistribInt = Flam3XformDistrib.build(passWeights)
            let passDistrib = passDistribInt.map {
                UInt32(min($0, max(0, passFlame.xforms.count - 1)))
            }

            // Rebuild dmap/dmapAlpha with this sub-pass's colorScalar baked in
            // (rect.c:757, 778-782). For box, sub.weight == 1.0 → byte-identical
            // to the single-pass dmap. Colors AND alpha carry the weight
            // automatically via the dmap lookup.
            let whiteLevel = 255.0
            let passDmapD = buildDmap(passFlame.palette,
                                      whiteLevel: whiteLevel, colorScalar: sub.weight)
            let passDmap = passDmapD.map {
                SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
            }
            let passDmapAlpha = [Float](repeating: Float(whiteLevel * sub.weight), count: 256)

            // Per-pass threadSeeds (rect.c:862-865 layered with a per-pass salt
            // so passes don't correlate). For N=1: params.seed &+ 0 == params.seed
            // → byte-identity with renderFused's seedsBuf. Metal DOES consume
            // params.seed (unlike the CPU path), so no special N>1 gate is
            // needed — the salt naturally falls out of the loop index.
            let passSeed = params.seed &+ UInt64(i)
            let passThreadSeeds = MetalHost.buildThreadSeeds(
                seed: passSeed, threadCount: perPassThreads)

            // Per-pass fpLocal: threadCount/ipt/remainder from per-pass budget.
            // camera (cosR/sinR/pixelsPerUnit/center) comes from the PASS flame
            // (buildFrameParams reads flame.camera). colorScale stays at the
            // FULL-budget value (buildFrameParams reads params.totalSamples).
            var fpLocal = MetalHost.buildFrameParams(passFlame, params)
            fpLocal.threadCount = UInt32(perPassThreads)
            fpLocal.iterationsPerThread = UInt32(perPassBudget / perPassThreads)
            fpLocal.remainder = UInt32(perPassBudget % perPassThreads)
            fpLocal.hasFinal = passFinalXform != nil ? 1 : 0

            let xformsBuf    = buf(passXforms)
            let finalBuf     = passFinalXform.map { buf($0) }
                                       ?? device.makeBuffer(length: GPUXform.bytesPerXform,
                                                            options: .storageModeShared)!
            let distribBuf   = buf(passDistrib)
            let dmapBuf      = buf(passDmap)
            let dmapAlphaBuf = buf(passDmapAlpha)
            var fpPassLocal = fpLocal
            let fpBuf        = device.makeBuffer(bytes: &fpPassLocal,
                                                 length: MemoryLayout<GPUFrameParams>.stride,
                                                 options: .storageModeShared)!
            let seedsBuf     = buf(passThreadSeeds)

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
            encChaos.setBuffer(atomicBuf,    offset: 0, index: 7)   // SAME uncleared
            let groups = (perPassThreads + tpg - 1) / tpg
            encChaos.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                          threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
            encChaos.endEncoding()
        }

        // -------- Encoder 2: atomicBinToFloatBin (atomicBuf → floatBufA) --------
        // Uses the FULL-budget fp (colorScale + grid dims are frame-level).
        guard let encDec = cb.makeComputeCommandEncoder() else {
            throw NSError(domain: "MetalRenderer", code: 17)
        }
        encDec.setComputePipelineState(decodePso)
        encDec.setBuffer(atomicBuf,   offset: 0, index: 0)
        encDec.setBuffer(floatBufA,   offset: 0, index: 1)
        encDec.setBuffer(fpBufDecode, offset: 0, index: 2)
        let decGW = (gw + tpg2D - 1) / tpg2D, decGH = (gh + tpg2D - 1) / tpg2D
        encDec.dispatchThreadgroups(MTLSize(width: decGW, height: decGH, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: tpg2D, height: tpg2D, depth: 1))
        encDec.endEncoding()

        // -------- Encoder 3 (optional): densityEstimation (floatBufA → floatBufB) --------
        let runDensity = deRadius > 0
        if runDensity {
            guard let encDe = cb.makeComputeCommandEncoder() else {
                throw NSError(domain: "MetalRenderer", code: 16)
            }
            encDe.setComputePipelineState(densityPso)
            encDe.setBuffer(floatBufA,   offset: 0, index: 0)
            encDe.setBuffer(deParamsBuf, offset: 0, index: 1)
            encDe.setBuffer(deDimsBuf,   offset: 0, index: 2)
            encDe.setBuffer(floatBufB,   offset: 0, index: 3)
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
                brightness: flame.quality.brightness,
                sampleDensity: Double(params.samplesPerPixel),
                pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom))
        } catch {
            fatalError("Metal render (unfused) failed: \(error)")
        }
    }
}
