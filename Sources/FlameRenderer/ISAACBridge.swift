import Foundation
import Metal
import FlameKit

/// Host helper that runs the MSL `isaac_check` kernel and returns the emitted
/// words. Used by the MSL↔Swift ISAAC parity test to prove byte-equality.
@MainActor
enum ISAACBridge {
    /// Run the MSL `isaac_check` kernel for the given 16-word seed and return
    /// the first `count` output words. Throws if Metal is unavailable.
    static func stream(seed16: [UInt64], count: Int) throws -> [UInt32] {
        guard let (device, library) = MetalRenderer.deviceAndLibrary() else {
            throw NSError(domain: "MetalRenderer", code: 10)
        }
        guard let function = library.makeFunction(name: "isaac_check") else {
            throw NSError(domain: "MetalRenderer", code: 11)
        }
        let pso = try device.makeComputePipelineState(function: function)
        let seedBuf = device.makeBuffer(bytes: seed16, length: 16 * MemoryLayout<UInt64>.size)!
        let outBuf  = device.makeBuffer(length: count * MemoryLayout<UInt32>.size)!
        var n = UInt32(count)
        let nBuf   = device.makeBuffer(bytes: &n, length: MemoryLayout<UInt32>.size)!
        let queue = device.makeCommandQueue()!
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setBuffer(seedBuf, offset: 0, index: 0)
        enc.setBuffer(outBuf, offset: 0, index: 1)
        enc.setBuffer(nBuf, offset: 0, index: 2)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: outBuf.contents().assumingMemoryBound(to: UInt32.self), count: count))
    }
}
