import Foundation
import Metal
import FlameKit

/// GPU dispatch for the Stage-3a display pipeline.
///
/// Faithful Metal twin of `FlameReference.ToneMapping.render` (flam3 rect.c +
/// palettes.c). Dispatches two kernels in order on a single command buffer:
/// `logDensity` (per grid cell log-density scale) then `displayPipeline` (per
/// output pixel spatial-filter gather + gamma + vibrancy/background blend). The
/// two encoders are enqueued in order within one command buffer, which gives
/// full write-visibility between them — the portable, API-stable sync.
///
/// `DisplayParams` (9 floats + 7 uints = 64 bytes) is laid out identically to
/// the MSL `DisplayParams` struct; the host copies `MemoryLayout<DisplayParams>
/// .size` bytes into a shared buffer.
@MainActor
enum DisplayPipelineMetal {

    /// Host mirror of MSL `DisplayParams` (Kernels.metal). Field order, types,
    /// and sizes MUST match the device struct. 9 floats + 7 uints = 64 bytes,
    /// all 4-byte aligned → no padding (size == stride == 64).
    struct DisplayParams {
        var k1: Float = 0
        var k2: Float = 0
        var gammaInv: Float = 0
        var linrange: Float = 0
        var vibrancy: Float = 0
        var bgR: Float = 0
        var bgG: Float = 0
        var bgB: Float = 0
        var highlightPower: Float = 0
        var gw: UInt32 = 0
        var gh: UInt32 = 0
        var width: UInt32 = 0
        var height: UInt32 = 0
        var oversample: UInt32 = 0
        var fw: UInt32 = 0
        var gutter: UInt32 = 0
    }

    /// flam3 display defaults (genomes here don't override these).
    private static let contrast: Double = 1.0
    private static let prefilterWhite: Double = 255.0
    private static let whiteLevel: Double = 255.0

    /// Render `histogram` to an 8-bit RGBA image via the full Metal display
    /// pipeline. Deterministic in `(histogram, width, height, oversample, gamma,
    /// gammaThreshold, vibrancy, brightness, sampleDensity, pixelsPerUnit)`.
    static func render(histogram: Histogram, width: Int, height: Int, oversample: Int,
                       gamma: Double, gammaThreshold: Double, vibrancy: Double,
                       brightness: Double = 4.0,
                       sampleDensity: Double, pixelsPerUnit: Double) throws -> RGBA8Image {
        precondition(MemoryLayout<DisplayParams>.size == 64,
                     "DisplayParams size drifted from MSL mirror (64 bytes)")
        guard let (device, library) = MetalRenderer.deviceAndLibrary() else {
            throw NSError(domain: "MetalRenderer", code: 20)
        }
        guard let queue = MetalRenderer.commandQueue else {
            throw NSError(domain: "MetalRenderer", code: 21)
        }

        let gw = histogram.gridWidth, gh = histogram.gridHeight
        let binCount = gw * gh

        // --- k1 / k2 (rect.c:933-937) ---
        let k1 = contrast * brightness * prefilterWhite * 268.0 / 256.0
        let imageW = width * oversample
        let imageH = height * oversample
        let area = Double(imageW * imageH) / (pixelsPerUnit * pixelsPerUnit)
        let nbatches = 1
        let sumfilt: Double = 1.0
        let k2 = Double(oversample * oversample * nbatches) /
                 (contrast * area * whiteLevel * sampleDensity * sumfilt)

        // --- Spatial filter kernel (filters.c:217-269, faithful twin of CPU) ---
        let (fw, kernelFloat) = makeSpatialKernelMetal(oversample: oversample,
                                                       radius: RenderParams.spatialFilterRadius)
        let gutter = (fw - oversample) / 2

        var dp = DisplayParams()
        dp.k1 = Float(k1)
        dp.k2 = Float(k2)
        dp.gammaInv = Float(1.0 / gamma)
        dp.linrange = Float(gammaThreshold)
        dp.vibrancy = Float(vibrancy)
        dp.bgR = 0; dp.bgG = 0; dp.bgB = 0
        dp.highlightPower = -1.0
        dp.gw = UInt32(gw)
        dp.gh = UInt32(gh)
        dp.width = UInt32(width)
        dp.height = UInt32(height)
        dp.oversample = UInt32(oversample)
        dp.fw = UInt32(fw)
        dp.gutter = UInt32(gutter)

        // --- Pack histogram into FloatBin {count,r,g,b,a} (dmap units) ---
        var flat = [Float](repeating: 0, count: binCount * 5)
        for i in 0..<binCount {
            flat[i * 5 + 0] = Float(histogram.counts[i])
            flat[i * 5 + 1] = Float(histogram.colors[i].x)
            flat[i * 5 + 2] = Float(histogram.colors[i].y)
            flat[i * 5 + 3] = Float(histogram.colors[i].z)
            flat[i * 5 + 4] = Float(histogram.alpha[i])
        }

        func buf<T>(_ values: [T]) -> MTLBuffer {
            values.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!,
                                  length: raw.count,
                                  options: .storageModeShared)!
            }
        }
        let rawBuf = buf(flat)
        let accumRGBBytes = binCount * 3 * MemoryLayout<Float>.stride
        let accumRGBBuf = device.makeBuffer(length: accumRGBBytes, options: .storageModeShared)!
        memset(accumRGBBuf.contents(), 0, accumRGBBytes)
        let accumABuf = device.makeBuffer(length: binCount * MemoryLayout<Float>.stride,
                                          options: .storageModeShared)!
        memset(accumABuf.contents(), 0, binCount * MemoryLayout<Float>.stride)
        let spatialBuf = buf(kernelFloat)
        let dpExact = device.makeBuffer(bytes: &dp,
                                        length: MemoryLayout<DisplayParams>.size,
                                        options: .storageModeShared)!
        let outBytes = width * height * 4
        let outBuf = device.makeBuffer(length: outBytes, options: .storageModeShared)!
        memset(outBuf.contents(), 0, outBytes)

        // --- Pipeline states (fixed Metal API per T2/T5/T8 proven pattern) ---
        guard let f1 = library.makeFunction(name: "logDensity") else {
            throw NSError(domain: "MetalRenderer", code: 22)
        }
        let pso1 = try device.makeComputePipelineState(function: f1)
        guard let f2 = library.makeFunction(name: "displayPipeline") else {
            throw NSError(domain: "MetalRenderer", code: 23)
        }
        let pso2 = try device.makeComputePipelineState(function: f2)

        guard let cb = queue.makeCommandBuffer() else {
            throw NSError(domain: "MetalRenderer", code: 24)
        }

        let tpgW = 16, tpgH = 16

        // --- Encoder 1: logDensity (gw × gh threads) ---
        guard let enc1 = cb.makeComputeCommandEncoder() else {
            throw NSError(domain: "MetalRenderer", code: 25)
        }
        enc1.setComputePipelineState(pso1)
        enc1.setBuffer(rawBuf,      offset: 0, index: 0)
        enc1.setBuffer(accumRGBBuf, offset: 0, index: 1)
        enc1.setBuffer(accumABuf,   offset: 0, index: 2)
        enc1.setBuffer(dpExact,     offset: 0, index: 3)
        let groupsG_W = (gw + tpgW - 1) / tpgW
        let groupsG_H = (gh + tpgH - 1) / tpgH
        enc1.dispatchThreadgroups(MTLSize(width: groupsG_W, height: groupsG_H, depth: 1),
                                  threadsPerThreadgroup: MTLSize(width: tpgW, height: tpgH, depth: 1))
        enc1.endEncoding()

        // --- Encoder 2: displayPipeline (width × height threads) ---
        // Encoders within one command buffer execute in enqueue order with full
        // write visibility — accumRGB/accumA from enc1 are visible to enc2.
        guard let enc2 = cb.makeComputeCommandEncoder() else {
            throw NSError(domain: "MetalRenderer", code: 26)
        }
        enc2.setComputePipelineState(pso2)
        enc2.setBuffer(accumRGBBuf, offset: 0, index: 0)
        enc2.setBuffer(accumABuf,   offset: 0, index: 1)
        enc2.setBuffer(spatialBuf,  offset: 0, index: 2)
        enc2.setBuffer(dpExact,     offset: 0, index: 3)
        enc2.setBuffer(outBuf,      offset: 0, index: 4)
        let groupsW = (width + tpgW - 1) / tpgW
        let groupsH = (height + tpgH - 1) / tpgH
        enc2.dispatchThreadgroups(MTLSize(width: groupsW, height: groupsH, depth: 1),
                                  threadsPerThreadgroup: MTLSize(width: tpgW, height: tpgH, depth: 1))
        enc2.endEncoding()

        cb.commit()
        cb.waitUntilCompleted()

        // --- Read back RGBA8 ---
        var pixels = [UInt8](repeating: 0, count: outBytes)
        pixels.withUnsafeMutableBytes { dst in
            dst.baseAddress!.copyMemory(from: outBuf.contents(), byteCount: outBytes)
        }
        return RGBA8Image(width: width, height: height, pixels: pixels)
    }

    // MARK: - Spatial filter kernel (filters.c:217-269)
    //
    // Byte-identical twin of CPU `makeSpatialKernel` in ToneMapping.swift (computed
    // in Double, cast to Float at the end so the MSL receives the same coefficients
    // the CPU oracle convolves with, to float precision).

    /// Build the normalized Gaussian spatial-filter kernel as `[Float]`. Matches
    /// CPU `makeSpatialKernel` exactly (same `support`, `adjust`, `exp(-2·ii·ii)·
    /// sqrt(2/π)` product, same normalization), returning float-precision coeffs.
    static func makeSpatialKernelMetal(oversample: Int, radius: Double)
            -> (width: Int, coeffs: [Float]) {
        let support: Double = 1.5       // flam3_spatial_support[gaussian] (filters.c:31)
        let fwRaw = 2.0 * support * Double(oversample) * radius
        let fwidth = flam3SpatialFilterWidth(oversample: oversample, radius: radius)
        let adjust = fwRaw > 0 ? support * Double(fwidth) / fwRaw : 1.0

        var c = [Double](repeating: 0, count: fwidth * fwidth)
        var sum: Double = 0
        for i in 0..<fwidth {
            for j in 0..<fwidth {
                let ii = ((2.0 * Double(i) + 1.0) / Double(fwidth) - 1.0) * adjust
                let jj = ((2.0 * Double(j) + 1.0) / Double(fwidth) - 1.0) * adjust
                let v = gaussianMS(ii) * gaussianMS(jj)    // filters.c:259-260
                c[i + j * fwidth] = v
                sum += v
            }
        }
        if sum > 0 { for k in c.indices { c[k] /= sum } }   // normalize_vector
        return (fwidth, c.map { Float($0) })
    }
}

/// `flam3_gaussian_filter` (filters.c:156-158). Same as CPU `gaussian`.
private func gaussianMS(_ x: Double) -> Double {
    exp(-2.0 * x * x) * (2.0 / .pi).squareRoot()
}
