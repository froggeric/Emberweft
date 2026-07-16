import Foundation
import Metal
import FlameKit

/// GPU dispatch + decode for the Stage-2 density-estimation kernel.
///
/// Metal twin of `FlameReference.DensityEstimation.apply` (the M1 adaptive-kernel
/// approximation). Packs a `Histogram` into a flat `[Float]` of stride 5
/// (`{count,r,g,b,a}` per bin, decoded units), runs the `densityEstimation`
/// kernel reading `inOut` → `work`, and decodes `work` back to a `Histogram` of
/// Doubles. Passthrough when `radius == 0` (the path the frozen radius=0 goldens
/// hit). Count mass is preserved exactly; color mass matches the CPU
/// approximation to within float precision.
@MainActor
enum DensityEstimationMetal {

    /// Apply the Metal density-estimation kernel. Returns `hist` unchanged when
    /// `radius <= 0` (exact passthrough — the golden path). Deterministic in
    /// `(hist, radius, minimum, curve)` across repeated calls.
    static func apply(_ hist: Histogram,
                      radius: Double,
                      minimum: Double,
                      curve: Double) throws -> Histogram {
        guard radius > 0 else { return hist }
        guard let (device, library) = MetalRenderer.deviceAndLibrary() else {
            throw NSError(domain: "MetalRenderer", code: 13)
        }
        guard let queue = MetalRenderer.commandQueue else {
            throw NSError(domain: "MetalRenderer", code: 14)
        }

        let gw = hist.gridWidth, gh = hist.gridHeight
        let binCount = gw * gh

        // --- Pack bins into a flat Float[5n] of {count,r,g,b,a} ---
        var flat = [Float](repeating: 0, count: binCount * 5)
        for i in 0..<binCount {
            flat[i * 5 + 0] = Float(hist.counts[i])
            flat[i * 5 + 1] = Float(hist.colors[i].x)
            flat[i * 5 + 2] = Float(hist.colors[i].y)
            flat[i * 5 + 3] = Float(hist.colors[i].z)
            flat[i * 5 + 4] = Float(hist.alpha[i])
        }
        let params: [Float] = [Float(radius), Float(minimum), Float(curve)]
        let dims: [UInt32] = [UInt32(gw), UInt32(gh)]

        func buf<T>(_ values: [T]) -> MTLBuffer {
            values.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!,
                                  length: raw.count,
                                  options: .storageModeShared)!
            }
        }
        let inOutBuf = buf(flat)
        let paramsBuf = buf(params)
        let dimsBuf = buf(dims)
        let workBytes = binCount * 5 * MemoryLayout<Float>.stride
        let workBuf = device.makeBuffer(length: workBytes, options: .storageModeShared)!
        memset(workBuf.contents(), 0, workBytes)

        // --- Pipeline + 2D dispatch (fixed Metal API per T2/T5's proven pattern) ---
        guard let function = library.makeFunction(name: "densityEstimation") else {
            throw NSError(domain: "MetalRenderer", code: 15)
        }
        let pso = try device.makeComputePipelineState(function: function)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw NSError(domain: "MetalRenderer", code: 16)
        }
        enc.setComputePipelineState(pso)
        enc.setBuffer(inOutBuf,  offset: 0, index: 0)
        enc.setBuffer(paramsBuf, offset: 0, index: 1)
        enc.setBuffer(dimsBuf,   offset: 0, index: 2)
        enc.setBuffer(workBuf,   offset: 0, index: 3)

        let tpgW = 16, tpgH = 16
        let groupsW = (gw + tpgW - 1) / tpgW
        let groupsH = (gh + tpgH - 1) / tpgH
        enc.dispatchThreadgroups(MTLSize(width: groupsW, height: groupsH, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tpgW, height: tpgH, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        return decode(workBuf: workBuf, binCount: binCount,
                      gridWidth: gw, gridHeight: gh)
    }

    // MARK: - Decode

    /// Read the flat `FloatBin` array from `work` and rebuild a `Histogram` with
    /// Doubles (counts/colors/alpha in the same units the CPU oracle uses).
    private static func decode(workBuf: MTLBuffer, binCount: Int,
                               gridWidth: Int, gridHeight: Int) -> Histogram {
        var hist = Histogram(gridWidth: gridWidth, gridHeight: gridHeight)
        let flats = workBuf.contents().assumingMemoryBound(to: Float.self)
        for i in 0..<binCount {
            let base = i * 5
            hist.counts[i] = Double(flats[base + 0])
            hist.colors[i] = SIMD3(Double(flats[base + 1]),
                                   Double(flats[base + 2]),
                                   Double(flats[base + 3]))
            hist.alpha[i] = Double(flats[base + 4])
        }
        return hist
    }
}
