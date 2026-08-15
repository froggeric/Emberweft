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
        // ModuleResources resolves Contents/Resources for the bundled .app (see its doc
        // comment); everywhere else it is the same bundle Bundle.module finds.
        guard let url = ModuleResources.bundle.url(
            forResource: "Kernels", withExtension: "metal", subdirectory: "Metal"
        ) ?? ModuleResources.bundle.url(forResource: "Kernels", withExtension: "metal"),
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
    public static func render(flame: Flame, params: RenderParams,
                              seedBudget: MetalRenderer.ThreadSeedBudget? = nil) -> RGBA8Image {
        guard isAvailable else {
            fatalError("MetalRenderer.render called when isAvailable is false")
        }
        do {
            return try renderFused(flame: flame, params: params, seedBudget: seedBudget)
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
        params: RenderParams,
        seedBudget: MetalRenderer.ThreadSeedBudget? = nil
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
                temporal: temporal, sumfilt: sumfilt, params: params,
                seedBudget: seedBudget)
        } catch {
            fatalError("Metal temporal render failed: \(error)")
        }
    }

    // MARK: - Fused production path (single command buffer, GPU-resident histogram)

    /// Encode chaos → decode → density (if estimatorRadius>0) → logDensity →
    /// displayPipeline into one command buffer; commit once. The histogram lives
    /// in GPU buffers across all stages (`atomicBuf` → `floatBufA` → optional
    /// `floatBufB`), never crossing to the CPU. Only the final RGBA is read back.
    /// Core fused-path encode/commit/readback, actor-agnostic. The Metal handles
    /// are passed in so this runs identically on the MainActor (realtime path,
    /// via `renderFused`) OR on a dedicated background queue (thumbnail path, via
    /// `renderOffMain`). Output is byte-identical either way — the GPU
    /// computation is independent of the encoding thread; only the thread that
    /// blocks on `waitUntilCompleted` differs (main vs background).
    static func renderFusedCore(
        flame: Flame,
        params: RenderParams,
        device: MTLDevice,
        queue: MTLCommandQueue,
        psos: (chaos: MTLComputePipelineState, decode: MTLComputePipelineState,
               density: MTLComputePipelineState, log: MTLComputePipelineState,
               display: MTLComputePipelineState),
        seedBudget: MetalRenderer.ThreadSeedBudget? = nil
    ) throws -> RGBA8Image {
        // Thread `flame.quality.filterRadius` into `params.spatialFilterRadius`
        // before the chaos game iterates — the grid's gutter width depends on
        // the filter radius (rect.c:656), so the radius must be set in `params`
        // at grid-allocation time. Same rationale as ReferenceRenderer.render.
        let params = params.settingSpatialFilterRadius(flame.quality.filterRadius)

        // -------- Shared chaos payload (mirrors ChaosGameMetal.iterate) --------
        // Degenerate (zero-weight) flame guard: emit a black frame (mirrors
        // ChaosGameMetal.iterate). encodeChaos assumes non-degenerate — it would
        // build a zero-weight distrib table whose weighted pick is undefined.
        let weights = flame.xforms.map { max(0, $0.weight) }
        guard weights.reduce(0, +) > 0 else {
            return RGBA8Image(width: params.width, height: params.height,
                              pixels: [UInt8](repeating: 0, count: params.width * params.height * 4))
        }

        // -------- Chaos stage (shared extraction, T6) -------------------------
        // encodeChaos builds the chaos payload + atomicBuf + command buffer +
        // encChaos dispatch — everything up to encChaos.endEncoding(). The
        // decode/DE/log/display stages continue below using the returned cb +
        // atomicBuf. BEHAVIOR UNCHANGED (D5): same payload, same buffer layout,
        // same dispatch — only factored into a shared helper (also used by
        // renderFusedCoreToHistogram). The floatBuf/display allocs move after
        // encChaos (pure device.makeBuffer calls, no side effects on the chaos
        // encoding → no behavioral change).
        let (atomicBuf, fp, binCount, cb) = try encodeChaos(
            flame: flame, params: params, device: device, queue: queue,
            chaosPso: psos.chaos, seedBudget: seedBudget)

        let gw = params.gridWidth, gh = params.gridHeight

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
            oversample: oversample, radius: params.spatialFilterRadius)
        let gutter = (fw - oversample) / 2

        var dp = DisplayPipelineMetal.DisplayParams()
        dp.k1 = Float(k1); dp.k2 = Float(k2)
        dp.gammaInv = Float(1.0 / flame.quality.gamma)
        dp.linrange = Float(flame.quality.gammaThreshold)
        dp.vibrancy = Float(flame.quality.vibrancy)
        dp.bgR = 0; dp.bgG = 0; dp.bgB = 0
        dp.highlightPower = Float(flame.quality.highlightPower)
        dp.gw = UInt32(gw); dp.gh = UInt32(gh)
        dp.width = UInt32(params.width); dp.height = UInt32(params.height)
        dp.oversample = UInt32(oversample)
        dp.fw = UInt32(fw); dp.gutter = UInt32(gutter)
        var dpExact = dp
        let dpBuf = device.makeBuffer(bytes: &dpExact,
                                      length: MemoryLayout<DisplayPipelineMetal.DisplayParams>.size,
                                      options: .storageModeShared)!

        // Shared MTLBuffer builder (same nested form as encodeChaos /
        // renderTemporalFusedCore). Stays here for the display + DE payload allocs.
        func buf<T>(_ values: [T]) -> MTLBuffer {
            values.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!,
                                  length: raw.count,
                                  options: .storageModeShared)!
            }
        }
        // fpBuf for decode/log/display — rebuilt from the fp encodeChaos returned
        // (byte-identical to the fpBuf encChaos used internally: same
        // GPUFrameParams value, same device.makeBuffer(bytes:) copy).
        var fpDecode = fp
        let fpBuf = device.makeBuffer(bytes: &fpDecode,
                                      length: MemoryLayout<GPUFrameParams>.stride,
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

        // -------- Pipeline states (passed in by the caller) --------
        let decodePso  = psos.decode
        let densityPso = psos.density
        let logPso     = psos.log
        let dispPso    = psos.display

        let tpg2D = 16

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

    // MARK: - Shared chaos encoding (T6 extraction)

    /// Shared chaos-encoding extraction (T6): build the chaos payload, allocate +
    /// zero the `atomicBuf`, create the command buffer, dispatch `encChaos`, and
    /// return what the caller needs — `(atomicBuf, fp, binCount, cb)`. This is the
    /// chaos-ONLY portion of the former `renderFusedCore` (everything up to
    /// `encChaos.endEncoding()`), factored so the new readback variant
    /// (`renderFusedCoreToHistogram`) can encode chaos identically then commit +
    /// readback + decode instead of continuing to decode/DE/log/display.
    ///
    /// `params` MUST already be spatial-filter-threaded by the caller (same as
    /// `renderFusedCore` does before calling this). The caller is also responsible
    /// for the zero-weight guard (different return type per caller).
    ///
    /// BEHAVIOR UNCHANGED (D5): the chaos payload, buffer layout, and dispatch
    /// are byte-identical to the former inline code in `renderFusedCore` —
    /// verified by `FusedUnfusedParityTests` (fused == unfused, byte-exact). The
    /// `atomicBuf` sizing uses `MetalHistogramDecode.AtomicBinHost` (the
    /// parity-proven host mirror, T4) — same layout as the former local struct
    /// (5×UInt32, 20 B, no padding), so the buffer size + memset are identical.
    static func encodeChaos(
        flame: Flame,
        params: RenderParams,
        device: MTLDevice,
        queue: MTLCommandQueue,
        chaosPso: MTLComputePipelineState,
        seedBudget: MetalRenderer.ThreadSeedBudget?
    ) throws -> (atomicBuf: MTLBuffer, fp: GPUFrameParams,
                 binCount: Int, commandBuffer: MTLCommandBuffer) {
        // -------- Shared chaos payload (mirrors ChaosGameMetal.iterate) --------
        let xforms = MetalHost.packXforms(flame)
        let finalXform = MetalHost.packFinalXform(flame)
        let weights = flame.xforms.map { max(0, $0.weight) }
        let distribInt = Flam3XformDistrib.build(weights)
        let distrib = distribInt.map { UInt32(min($0, max(0, flame.xforms.count - 1))) }

        let whiteLevel = 255.0
        let colorScalar = 1.0
        let dmapD = buildDmap(flame.palette, whiteLevel: whiteLevel, colorScalar: colorScalar)
        let dmap = dmapD.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        let dmapAlpha = [Float](repeating: Float(whiteLevel * colorScalar), count: 256)

        var fp = MetalHost.buildFrameParams(flame, params)
        fp.hasFinal = finalXform != nil ? 1 : 0
        let threadSeeds = seedBudget?.seeds(forPass: 0, threadCount: Int(fp.threadCount))
            ?? MetalHost.buildThreadSeeds(seed: params.seed, threadCount: Int(fp.threadCount))

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

        // AtomicBin: 5×uint32 per bin. Uses the T4 host mirror (S8 — no new local
        // struct). Layout MUST match MSL AtomicBin; identical to the former local.
        let atomicBuf = device.makeBuffer(
            length: binCount * MemoryLayout<MetalHistogramDecode.AtomicBinHost>.stride,
            options: .storageModeShared)!
        memset(atomicBuf.contents(), 0,
               binCount * MemoryLayout<MetalHistogramDecode.AtomicBinHost>.stride)

        guard let cb = queue.makeCommandBuffer() else {
            throw NSError(domain: "MetalRenderer", code: 24)
        }
        let tpg = MetalHost.threadsPerGroup

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

        return (atomicBuf, fp, binCount, cb)
    }

    // MARK: - Fused readback histogram (T6, smoothing-ON Metal path)

    /// Encode chaos ONLY (via the shared `encodeChaos`), commit, read `atomicBuf`
    /// back, decode via `MetalHistogramDecode.decode` (T4) → pre-DE Double
    /// `Histogram`. This is the single-pass readback variant — the Metal half of
    /// the smoothing-ON per-frame histogram for non-temporal (N=1) renders. T8
    /// EMAs the returned histogram, then calls T5's `renderSmoothedDisplay(OffMain)`
    /// for DE + display.
    ///
    /// No decode PSO / DE / log / display — those run separately via T5's
    /// `applyCore`+`renderCore` (the smoothing split). `colorScale` comes from the
    /// FULL-budget `GPUFrameParams` (built inside `encodeChaos` via
    /// `MetalHost.buildFrameParams`, which reads `params.totalSamples`).
    ///
    /// Actor-agnostic — the Metal handles are passed in so this runs identically on
    /// the MainActor (via `renderHistogram`) OR off-main (via
    /// `renderHistogramOffMain`). Output is byte-identical either way.
    static func renderFusedCoreToHistogram(
        flame: Flame,
        params: RenderParams,
        device: MTLDevice,
        queue: MTLCommandQueue,
        psos: (chaos: MTLComputePipelineState, decode: MTLComputePipelineState,
               density: MTLComputePipelineState, log: MTLComputePipelineState,
               display: MTLComputePipelineState),
        seedBudget: MetalRenderer.ThreadSeedBudget? = nil
    ) throws -> Histogram {
        // Thread spatialFilterRadius (same rationale as renderFusedCore).
        let params = params.settingSpatialFilterRadius(flame.quality.filterRadius)

        // Zero-weight guard: empty Histogram, no trap (mirrors
        // ChaosGameMetal.iterate).
        let weights = flame.xforms.map { max(0, $0.weight) }
        guard weights.reduce(0, +) > 0 else {
            return Histogram(gridWidth: params.gridWidth, gridHeight: params.gridHeight)
        }

        // Chaos → commit → readback → decode. No decode PSO / DE / log / display.
        let (atomicBuf, fp, binCount, cb) = try encodeChaos(
            flame: flame, params: params, device: device, queue: queue,
            chaosPso: psos.chaos, seedBudget: seedBudget)
        cb.commit()
        cb.waitUntilCompleted()
        return MetalHistogramDecode.decode(
            histBuf: atomicBuf, binCount: binCount,
            gridWidth: params.gridWidth, gridHeight: params.gridHeight,
            colorScale: Double(fp.colorScale))
    }

    // MARK: - Realtime (MainActor) fused entry

    /// MainActor fused render — the realtime/playback path. Builds the cached
    /// device/queue/PSOs (MainActor-isolated) and delegates to `renderFusedCore`.
    @MainActor
    static func renderFused(flame: Flame, params: RenderParams,
                            seedBudget: MetalRenderer.ThreadSeedBudget? = nil) throws -> RGBA8Image {
        guard let (device, _) = deviceAndLibrary() else {
            throw NSError(domain: "MetalRenderer", code: 10)
        }
        guard let queue = commandQueue else {
            throw NSError(domain: "MetalRenderer", code: 11)
        }
        guard let psos = fusedPipelines() else {
            throw NSError(domain: "MetalRenderer", code: 27)
        }
        return try renderFusedCore(flame: flame, params: params,
                                   device: device, queue: queue, psos: psos,
                                   seedBudget: seedBudget)
    }

    // MARK: - Off-main (thumbnail) entry

    /// Dedicated serial queue for off-main Metal rendering. All access to
    /// `offMainCache` is serialized through this queue → no separate lock needed.
    nonisolated private static let offMainQueue =
        DispatchQueue(label: "emberweft.metal.offmain")

    /// Off-main Metal cache. `nonisolated(unsafe)` is the honest escape: the
    /// compiler can't see that all access is serialized via `offMainQueue.sync`.
    nonisolated(unsafe) private static let offMainCache = MetalOffMainCache()

    /// Render on a **background thread** — never touches the MainActor, so it
    /// cannot freeze the UI. Blocks the calling (background) thread for the
    /// encode + GPU wait. Returns `nil` if Metal is unavailable or the render
    /// fails (callers fall back; never traps). Used by the thumbnail path.
    nonisolated
    public static func renderOffMain(flame: Flame, params: RenderParams,
                                     seedBudget: MetalRenderer.ThreadSeedBudget? = nil) -> RGBA8Image? {
        offMainQueue.sync {
            guard let (device, library, queue) = offMainCache.handles() else { return nil }
            guard let psos = offMainCache.pipelines(device: device, library: library) else { return nil }
            do {
                return try renderFusedCore(flame: flame, params: params,
                                           device: device, queue: queue, psos: psos,
                                           seedBudget: seedBudget)
            } catch {
                return nil
            }
        }
    }

    // MARK: - Temporal motion-blur fused path (N chaos passes into one atomicBuf)

    /// Encode N chaos passes into one `atomicBuf` (cleared ONCE, accumulated
    /// across passes), then decode → (optional) DE → logDensity → display —
    /// all in one `MTLCommandBuffer`. See `render(blendAt:…)` for the contract.
    ///
    /// The chaos stage becomes a loop over `temporal`; the decode/DE/log/display
    /// stages are byte-for-byte copies of `renderFused` (they read the
    /// `atomicBuf` AFTER all passes have accumulated into it).
    ///
    /// Actor-agnostic temporal motion-blur core — the temporal twin of
    /// `renderFusedCore`. Identical body to the former `renderTemporalFused`; the
    /// three MainActor handles (device/queue/psos) are passed in so it runs
    /// identically on the MainActor (via `renderTemporalFused`) OR off-main (via
    /// `renderTemporalOffMain`). Output is byte-identical either way — the GPU
    /// computation is independent of the encoding thread; only the thread that
    /// blocks on `waitUntilCompleted` differs (main vs `offMainQueue`).
    static func renderTemporalFusedCore(
        blendAt: (Double) -> Flame,
        centerTime: Double,
        temporal: [(delta: Double, weight: Double)],
        sumfilt: Double,
        params: RenderParams,
        device: MTLDevice,
        queue: MTLCommandQueue,
        psos: (chaos: MTLComputePipelineState, decode: MTLComputePipelineState,
               density: MTLComputePipelineState, log: MTLComputePipelineState,
               display: MTLComputePipelineState),
        seedBudget: MetalRenderer.ThreadSeedBudget? = nil
    ) throws -> RGBA8Image {
        precondition(!temporal.isEmpty,
            "renderTemporalFusedCore: temporal must contain at least one sub-sample")
        let center = blendAt(centerTime)
        // Thread the center flame's `filterRadius` into `params.spatialFilterRadius`
        // — quality / display params are frame-level (rect.c:911-937), driven by
        // the center CP. Same as renderFused.
        let params = params.settingSpatialFilterRadius(center.quality.filterRadius)
        let N = temporal.count

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
            oversample: oversample, radius: params.spatialFilterRadius)
        let gutter = (fw - oversample) / 2

        var dp = DisplayPipelineMetal.DisplayParams()
        dp.k1 = Float(k1); dp.k2 = Float(k2)
        dp.gammaInv = Float(1.0 / center.quality.gamma)
        dp.linrange = Float(center.quality.gammaThreshold)
        dp.vibrancy = Float(center.quality.vibrancy)
        dp.bgR = 0; dp.bgG = 0; dp.bgB = 0
        dp.highlightPower = Float(center.quality.highlightPower)
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

        // -------- Pipeline states (passed in by the caller) --------
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
            let passThreadSeeds = seedBudget?.seeds(forPass: i, threadCount: perPassThreads)
                ?? MetalHost.buildThreadSeeds(seed: params.seed &+ UInt64(i),
                                              threadCount: perPassThreads)

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

    // MARK: - Temporal readback histogram (T6, smoothing-ON Metal path)

    /// Temporal twin of `renderFusedCoreToHistogram`: encode N chaos passes into
    /// ONE `atomicBuf` (cleared ONCE, accumulated across passes), commit, read
    /// `atomicBuf` back, decode via `MetalHistogramDecode.decode` (T4) → pre-DE
    /// Double `Histogram`. This is the Metal half of the smoothing-ON per-frame
    /// histogram for motion-blurred (temporal) renders. T8 EMAs the returned
    /// histogram, then calls T5's `renderSmoothedDisplay(OffMain)` for DE + display.
    ///
    /// The per-pass loop is REPLICATED BYTE-IDENTICALLY from
    /// `renderTemporalFusedCore` (R8): same dmap rebuild with
    /// `colorScalar=sub.weight`, same `params.seed &+ UInt64(i)` salt, same
    /// thread-budget split (`baseBudget`/`remBudget`), same `perPassThreads`
    /// rounding, same dispatch into the SAME uncleared `atomicBuf`, same full-
    /// budget `fp.colorScale`. Only the post-chaos stage differs (commit + readback
    /// + decode vs decode-PSO + DE + log + display).
    ///
    /// Gaussian/exp guard: `fatalError`s on any sub-pass with `weight != 1.0`
    /// (same as `render(blendAt:…)`). Real ES genomes use box exclusively.
    ///
    /// Actor-agnostic — runs identically on the MainActor (via
    /// `renderTemporalHistogram`) OR off-main (via `renderTemporalHistogramOffMain`).
    static func renderTemporalFusedCoreToHistogram(
        blendAt: (Double) -> Flame,
        centerTime: Double,
        temporal: [(delta: Double, weight: Double)],
        sumfilt: Double,
        params: RenderParams,
        device: MTLDevice,
        queue: MTLCommandQueue,
        psos: (chaos: MTLComputePipelineState, decode: MTLComputePipelineState,
               density: MTLComputePipelineState, log: MTLComputePipelineState,
               display: MTLComputePipelineState),
        seedBudget: MetalRenderer.ThreadSeedBudget? = nil
    ) throws -> Histogram {
        precondition(!temporal.isEmpty,
            "renderTemporalFusedCoreToHistogram: temporal must contain at least one sub-sample")
        // Gaussian/exp guard — same boundary as render(blendAt:…).
        for sub in temporal where sub.weight != 1.0 {
            fatalError("""
                MetalRenderer.renderTemporalFusedCoreToHistogram: non-box temporal \
                filters (sub-sample weight != 1.0) are not supported on Metal — only \
                box is (all real ES genomes use box). Got a sub-sample with \
                weight=\(sub.weight). Use ReferenceRenderer for gaussian/exp.
                """)
        }
        let center = blendAt(centerTime)
        // Thread spatialFilterRadius (same rationale as renderTemporalFusedCore).
        let params = params.settingSpatialFilterRadius(center.quality.filterRadius)
        let N = temporal.count

        let gw = params.gridWidth, gh = params.gridHeight
        let binCount = gw * gh

        // Local MTLBuffer builder (same form as renderTemporalFusedCore's `buf`).
        func buf<T>(_ values: [T]) -> MTLBuffer {
            values.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!,
                                   length: raw.count,
                                   options: .storageModeShared)!
            }
        }

        // -------- AtomicBin: cleared ONCE; N chaos encoders accumulate --------
        // into it (NOT cleared between passes). Uses MetalHistogramDecode's host
        // mirror (S8 — no new local struct); layout MUST match MSL AtomicBin.
        let atomicBuf = device.makeBuffer(
            length: binCount * MemoryLayout<MetalHistogramDecode.AtomicBinHost>.stride,
            options: .storageModeShared)!
        memset(atomicBuf.contents(), 0,
               binCount * MemoryLayout<MetalHistogramDecode.AtomicBinHost>.stride)

        // -------- Full-budget GPUFrameParams (colorScale uses the FULL T) --------
        // `colorScale` MUST use the FULL budget T = width*height*samplesPerPixel
        // (see renderTemporalFusedCore's comment). The decode step reads this
        // value to un-scale the uint32 atomics back to dmap-units Doubles.
        var fp = MetalHost.buildFrameParams(center, params)
        let centerFinal = MetalHost.packFinalXform(center)
        fp.hasFinal = centerFinal != nil ? 1 : 0

        let tpg = MetalHost.threadsPerGroup
        let tcFull = Int(fp.threadCount)   // pinnedThreadCount(totalSamples: T)

        // Per-pass thread count: ≈ tcFull / N, rounded UP to a multiple of tpg.
        // For N=1 this collapses to tcFull. Same math as renderTemporalFusedCore.
        let target = tcFull / N
        let rounded = ((target + tpg - 1) / tpg) * tpg
        let perPassThreads = max(tpg, rounded)

        // Distribute the integer budget T across N passes (rect.c:833).
        let T = params.totalSamples
        let baseBudget = T / N
        let remBudget = T % N

        let chaosPso = psos.chaos

        guard let cb = queue.makeCommandBuffer() else {
            throw NSError(domain: "MetalRenderer", code: 24)
        }

        // -------- Encoder 1 (LOOP): N chaos passes into the SAME atomicBuf ----
        // VERBATIM replication of renderTemporalFusedCore's per-pass loop (R8):
        // same dmap rebuild (colorScalar=sub.weight), same seed salt
        // (params.seed &+ UInt64(i)), same budget split, same dispatch into the
        // same uncleared atomicBuf, same full-budget fp.colorScale.
        for (i, sub) in temporal.enumerated() {
            let perPassBudget = baseBudget + (i < remBudget ? 1 : 0)
            guard perPassBudget > 0 else { continue }
            let passFlame = blendAt(centerTime + sub.delta)

            let passXforms = MetalHost.packXforms(passFlame)
            let passFinalXform = MetalHost.packFinalXform(passFlame)
            let passWeights = passFlame.xforms.map { max(0, $0.weight) }
            guard passWeights.reduce(0, +) > 0 else { continue }   // degenerate
            let passDistribInt = Flam3XformDistrib.build(passWeights)
            let passDistrib = passDistribInt.map {
                UInt32(min($0, max(0, passFlame.xforms.count - 1)))
            }

            let whiteLevel = 255.0
            let passDmapD = buildDmap(passFlame.palette,
                                      whiteLevel: whiteLevel, colorScalar: sub.weight)
            let passDmap = passDmapD.map {
                SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
            }
            let passDmapAlpha = [Float](repeating: Float(whiteLevel * sub.weight), count: 256)

            let passThreadSeeds = seedBudget?.seeds(forPass: i, threadCount: perPassThreads)
                ?? MetalHost.buildThreadSeeds(seed: params.seed &+ UInt64(i),
                                              threadCount: perPassThreads)

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

        // -------- Commit + readback + decode (no decode PSO / DE / log / display) --------
        cb.commit()
        cb.waitUntilCompleted()
        return MetalHistogramDecode.decode(
            histBuf: atomicBuf, binCount: binCount,
            gridWidth: gw, gridHeight: gh,
            colorScale: Double(fp.colorScale))
    }

    // MARK: - Realtime (MainActor) temporal entry

    /// MainActor temporal motion-blur render — the realtime/playback path. Builds
    /// the cached device/queue/PSOs (MainActor-isolated) and delegates to
    /// `renderTemporalFusedCore`. The thin twin of `renderFused`.
    @MainActor
    static func renderTemporalFused(
        blendAt: (Double) -> Flame,
        centerTime: Double,
        temporal: [(delta: Double, weight: Double)],
        sumfilt: Double,
        params: RenderParams,
        seedBudget: MetalRenderer.ThreadSeedBudget? = nil
    ) throws -> RGBA8Image {
        guard let (device, _) = deviceAndLibrary() else {
            throw NSError(domain: "MetalRenderer", code: 10)
        }
        guard let queue = commandQueue else {
            throw NSError(domain: "MetalRenderer", code: 11)
        }
        guard let psos = fusedPipelines() else {
            throw NSError(domain: "MetalRenderer", code: 27)
        }
        return try renderTemporalFusedCore(blendAt: blendAt, centerTime: centerTime,
                                           temporal: temporal, sumfilt: sumfilt,
                                           params: params, device: device, queue: queue,
                                           psos: psos, seedBudget: seedBudget)
    }

    // MARK: - Realtime (MainActor) histogram entries (T6, CLI MainActor R2)

    /// MainActor fused readback histogram — the CLI's MainActor branch (R2). Builds
    /// the cached device/queue/PSOs (MainActor-isolated) and delegates to
    /// `renderFusedCoreToHistogram`. `fatalError`s on failure (same boundary as
    /// `renderFused`). Returns the pre-DE Double `Histogram` for T8 to EMA.
    @MainActor
    public static func renderHistogram(
        flame: Flame, params: RenderParams,
        seedBudget: MetalRenderer.ThreadSeedBudget? = nil
    ) -> Histogram {
        guard isAvailable else {
            fatalError("MetalRenderer.renderHistogram called when isAvailable is false")
        }
        guard let (device, _) = deviceAndLibrary() else {
            fatalError("MetalRenderer.renderHistogram: no Metal device")
        }
        guard let queue = commandQueue else {
            fatalError("MetalRenderer.renderHistogram: no command queue")
        }
        guard let psos = fusedPipelines() else {
            fatalError("MetalRenderer.renderHistogram: no fused pipelines")
        }
        do {
            return try renderFusedCoreToHistogram(flame: flame, params: params,
                                                  device: device, queue: queue, psos: psos,
                                                  seedBudget: seedBudget)
        } catch {
            fatalError("Metal histogram readback failed: \(error)")
        }
    }

    /// MainActor temporal readback histogram — the CLI's MainActor branch (R2).
    /// Builds the cached device/queue/PSOs and delegates to
    /// `renderTemporalFusedCoreToHistogram`. `fatalError`s on failure OR non-box
    /// temporal (same boundaries as `render(blendAt:…)`).
    @MainActor
    public static func renderTemporalHistogram(
        blendAt: (Double) -> Flame,
        centerTime: Double,
        temporal: [(delta: Double, weight: Double)],
        sumfilt: Double,
        params: RenderParams,
        seedBudget: MetalRenderer.ThreadSeedBudget? = nil
    ) -> Histogram {
        guard isAvailable else {
            fatalError("MetalRenderer.renderTemporalHistogram called when isAvailable is false")
        }
        // Box guard — same boundary as render(blendAt:…).
        for sub in temporal where sub.weight != 1.0 {
            fatalError("""
                MetalRenderer.renderTemporalHistogram: non-box temporal filters \
                (sub-sample weight != 1.0) are not supported on Metal — only box is. \
                Got weight=\(sub.weight). Use ReferenceRenderer for gaussian/exp.
                """)
        }
        guard let (device, _) = deviceAndLibrary() else {
            fatalError("MetalRenderer.renderTemporalHistogram: no Metal device")
        }
        guard let queue = commandQueue else {
            fatalError("MetalRenderer.renderTemporalHistogram: no command queue")
        }
        guard let psos = fusedPipelines() else {
            fatalError("MetalRenderer.renderTemporalHistogram: no fused pipelines")
        }
        do {
            return try renderTemporalFusedCoreToHistogram(
                blendAt: blendAt, centerTime: centerTime, temporal: temporal,
                sumfilt: sumfilt, params: params, device: device, queue: queue,
                psos: psos, seedBudget: seedBudget)
        } catch {
            fatalError("Metal temporal histogram readback failed: \(error)")
        }
    }

    // MARK: - Off-main temporal entry (the temporal twin of `renderOffMain`)

    /// Off-main temporal motion-blur render — the temporal twin of `renderOffMain`.
    /// Runs on `offMainQueue`, never touches the MainActor, so it cannot freeze
    /// the UI. Used by the GUI export path (motion-blurred exports, zero UI
    /// freeze). Returns nil iff Metal is unavailable, the render fails, OR
    /// `temporal` carries a non-box weight (defensive — callers throw on nil; real
    /// ES genomes are box). Byte-identical to the MainActor `render(blendAt:…)`
    /// path: the GPU computation is thread-independent (already pinned for the
    /// single-pass path by `testRenderOffMainMatchesMainActorPath` /
    /// `…OnRealGenome`; the temporal core is the same code, so the same proof
    /// applies).
    nonisolated
    public static func renderTemporalOffMain(
        blendAt: (Double) -> Flame,
        centerTime: Double,
        temporal: [(delta: Double, weight: Double)],
        sumfilt: Double,
        params: RenderParams,
        seedBudget: MetalRenderer.ThreadSeedBudget? = nil
    ) -> RGBA8Image? {
        // Defensive: empty temporal is a never-hit caller invariant (the
        // coordinator only takes the temporal branch when temporalSamples > 1 ⇒
        // TemporalFilter.samples ⇒ non-empty), but `try?` below cannot catch the
        // `precondition(!temporal.isEmpty)` trap in the core. Return nil instead
        // of letting a background thread trap.
        guard !temporal.isEmpty else { return nil }
        // Box guard (defensive). The @MainActor public entry `render(blendAt:)`
        // fatalErrors on non-box; the off-main path returns nil instead (a
        // background thread fatalError is undesirable; nil ⇒ coordinator throws
        // .metalUnavailable).
        for sub in temporal where sub.weight != 1.0 { return nil }
        return offMainQueue.sync {
            guard let (device, library, queue) = offMainCache.handles() else { return nil }
            guard let psos = offMainCache.pipelines(device: device, library: library) else { return nil }
            return try? renderTemporalFusedCore(blendAt: blendAt, centerTime: centerTime,
                                                temporal: temporal, sumfilt: sumfilt,
                                                params: params, device: device, queue: queue,
                                                psos: psos, seedBudget: seedBudget)
        }
    }

    // MARK: - Off-main histogram entries (T6, GUI off-main)

    /// Off-main fused readback histogram — the GUI export's off-main branch (T6).
    /// Runs on `offMainQueue`, never touches the MainActor → cannot freeze the UI.
    /// Returns the pre-DE Double `Histogram` for T8 to EMA. Returns nil iff Metal
    /// is unavailable or the readback fails (callers fall back; never traps —
    /// matches `renderOffMain`). Byte-identical to the MainActor
    /// `renderHistogram`: the GPU computation is thread-independent.
    nonisolated
    public static func renderHistogramOffMain(
        flame: Flame, params: RenderParams,
        seedBudget: MetalRenderer.ThreadSeedBudget? = nil
    ) -> Histogram? {
        offMainQueue.sync {
            guard let (device, library, queue) = offMainCache.handles() else { return nil }
            guard let psos = offMainCache.pipelines(device: device, library: library) else { return nil }
            return try? renderFusedCoreToHistogram(flame: flame, params: params,
                                                   device: device, queue: queue, psos: psos,
                                                   seedBudget: seedBudget)
        }
    }

    /// Off-main temporal readback histogram — the temporal twin of
    /// `renderHistogramOffMain`. Runs on `offMainQueue`, never touches the
    /// MainActor. Returns nil iff Metal is unavailable, the readback fails, OR
    /// `temporal` carries a non-box weight (defensive — matches
    /// `renderTemporalOffMain`'s box guard). Byte-identical to the MainActor
    /// `renderTemporalHistogram`.
    nonisolated
    public static func renderTemporalHistogramOffMain(
        blendAt: (Double) -> Flame,
        centerTime: Double,
        temporal: [(delta: Double, weight: Double)],
        sumfilt: Double,
        params: RenderParams,
        seedBudget: MetalRenderer.ThreadSeedBudget? = nil
    ) -> Histogram? {
        // Defensive guards (same as renderTemporalOffMain): empty temporal → nil
        // (the core's precondition would trap); non-box → nil (the core fatalErrors).
        guard !temporal.isEmpty else { return nil }
        for sub in temporal where sub.weight != 1.0 { return nil }
        return offMainQueue.sync {
            guard let (device, library, queue) = offMainCache.handles() else { return nil }
            guard let psos = offMainCache.pipelines(device: device, library: library) else { return nil }
            return try? renderTemporalFusedCoreToHistogram(
                blendAt: blendAt, centerTime: centerTime, temporal: temporal,
                sumfilt: sumfilt, params: params, device: device, queue: queue,
                psos: psos, seedBudget: seedBudget)
        }
    }

    // MARK: - Off-main DE+display (smoothed display)

    /// Compose density-estimation (if `deRadius > 0`) then display on the passed
    /// pre-DE histogram, on the MainActor — sourcing device/queue/PSOs from
    /// `MetalRenderer`'s cached MainActor state. The CLI's MainActor branch (R2)
    /// and the realtime path drive this. Thin orchestrator over the
    /// `nonisolated` `DensityEstimationMetal.applyCore` +
    /// `DisplayPipelineMetal.renderCore` (both byte-identical to the
    /// `@MainActor apply`/`render` they were extracted from — a PSO is a pure
    /// function of kernel+device). Mirrors the `renderFused`/`renderFusedCore`
    /// split: this is the MainActor entry; `renderSmoothedDisplayOffMain` is the
    /// background-queue twin.
    @MainActor
    public static func renderSmoothedDisplay(
        histogram: Histogram,
        deRadius: Double, deMinimum: Double, deCurve: Double,
        width: Int, height: Int, oversample: Int,
        gamma: Double, gammaThreshold: Double, vibrancy: Double,
        brightness: Double, sampleDensity: Double, pixelsPerUnit: Double,
        highlightPower: Double, spatialFilterRadius: Double
    ) throws -> RGBA8Image {
        guard let (device, _) = deviceAndLibrary() else {
            throw NSError(domain: "MetalRenderer", code: 20)
        }
        guard let queue = commandQueue else {
            throw NSError(domain: "MetalRenderer", code: 21)
        }
        guard let psos = fusedPipelines() else {
            throw NSError(domain: "MetalRenderer", code: 27)
        }
        let deHist = deRadius > 0
            ? try DensityEstimationMetal.applyCore(histogram, radius: deRadius,
                                                   minimum: deMinimum, curve: deCurve,
                                                   device: device, queue: queue,
                                                   densityPso: psos.density)
            : histogram
        return try DisplayPipelineMetal.renderCore(
            histogram: deHist, width: width, height: height, oversample: oversample,
            gamma: gamma, gammaThreshold: gammaThreshold, vibrancy: vibrancy,
            brightness: brightness, sampleDensity: sampleDensity,
            pixelsPerUnit: pixelsPerUnit, highlightPower: highlightPower,
            spatialFilterRadius: spatialFilterRadius,
            device: device, queue: queue, logPso: psos.log, displayPso: psos.display)
    }

    /// Off-main twin of `renderSmoothedDisplay`: composes DE (if `deRadius > 0`)
    /// then display on `offMainQueue`, sourcing PSOs from `offMainCache`. Never
    /// touches the MainActor → cannot freeze the UI. Used by the GUI export
    /// smoothing display step (T8). Returns nil iff Metal is unavailable or the
    /// render fails (callers fall back; never traps — matches `renderOffMain`).
    /// Byte-identical to the MainActor `renderSmoothedDisplay` / the
    /// `@MainActor apply`+`render` path: the GPU computation is
    /// thread-independent (pinned by `OffMainDisplayParityTests`).
    nonisolated
    public static func renderSmoothedDisplayOffMain(
        histogram: Histogram,
        deRadius: Double, deMinimum: Double, deCurve: Double,
        width: Int, height: Int, oversample: Int,
        gamma: Double, gammaThreshold: Double, vibrancy: Double,
        brightness: Double, sampleDensity: Double, pixelsPerUnit: Double,
        highlightPower: Double, spatialFilterRadius: Double
    ) -> RGBA8Image? {
        offMainQueue.sync {
            guard let (device, library, queue) = offMainCache.handles() else { return nil }
            guard let psos = offMainCache.pipelines(device: device, library: library) else { return nil }
            do {
                let deHist = deRadius > 0
                    ? try DensityEstimationMetal.applyCore(histogram, radius: deRadius,
                                                           minimum: deMinimum, curve: deCurve,
                                                           device: device, queue: queue,
                                                           densityPso: psos.density)
                    : histogram
                return try DisplayPipelineMetal.renderCore(
                    histogram: deHist, width: width, height: height, oversample: oversample,
                    gamma: gamma, gammaThreshold: gammaThreshold, vibrancy: vibrancy,
                    brightness: brightness, sampleDensity: sampleDensity,
                    pixelsPerUnit: pixelsPerUnit, highlightPower: highlightPower,
                    spatialFilterRadius: spatialFilterRadius,
                    device: device, queue: queue, logPso: psos.log, displayPso: psos.display)
            } catch {
                return nil
            }
        }
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
            let p = params.settingSpatialFilterRadius(flame.quality.filterRadius)
            var hist = try ChaosGameMetal.iterate(flame: flame, params: p)
            if flame.quality.estimatorRadius > 0 {
                hist = try DensityEstimationMetal.apply(hist,
                    radius: flame.quality.estimatorRadius,
                    minimum: flame.quality.estimatorMinimum,
                    curve: flame.quality.estimatorCurveRate)
            }
            return try DisplayPipelineMetal.render(histogram: hist,
                width: p.width, height: p.height, oversample: p.oversample,
                gamma: flame.quality.gamma, gammaThreshold: flame.quality.gammaThreshold,
                vibrancy: flame.quality.vibrancy,
                brightness: flame.quality.brightness,
                sampleDensity: Double(p.samplesPerPixel),
                pixelsPerUnit: flame.camera.scale * pow(2, flame.camera.zoom),
                highlightPower: flame.quality.highlightPower,
                spatialFilterRadius: p.spatialFilterRadius)
        } catch {
            fatalError("Metal render (unfused) failed: \(error)")
        }
    }
}
