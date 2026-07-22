import Foundation
import Metal
import FlameKit

// MARK: - Device-side structs (Swift mirrors of the MSL structs in Kernels.metal.
// Field order and types MUST match exactly; both align `float` to 4 bytes.)

/// One IFS transform — the 15 scalar header floats only.
///
/// LAYOUT CONTRACT: the device xform buffer is a FLAT `[Float]` pack produced
/// by `MetalHost.packXforms` (NOT a byte-copy of this struct), because a Swift
/// `Array<Float>` field would be heap-allocated and not inlined into the struct,
/// corrupting the `withUnsafeBytes` copy. This struct therefore carries only
/// the 15 inline header floats (a..f, pa..pf, color/colorSpeed/opacity) used by
/// host-side extraction; the full device layout (348 floats = header + 37
/// varWeights + 296 varParams) is described by `floatsPerXform`/`bytesPerXform`
/// and built by the packer. The MSL `struct GPUXform` mirrors the full 348-float
/// layout field-for-field (15 scalars + `varWeights[37]` + `varParams[296]`).
public struct GPUXform {
    public var a: Float = 0, b: Float = 0, c: Float = 0, d: Float = 0, e: Float = 0, f: Float = 0
    public var pa: Float = 0, pb: Float = 0, pc: Float = 0, pd: Float = 0, pe: Float = 0, pf: Float = 0
    public var color: Float = 0
    public var colorSpeed: Float = 0
    public var opacity: Float = 0
    public init() {}

    // ---- Device layout constants (both sides must agree) ----
    // DERIVED from the authority (VariationDescriptor.canonicalOrder) so numSlots
    // and floatsPerXform can't internally drift. 6 (pre) + 6 (post) + 3
    // (color/cs/opacity) + 37 (varWeights) + 37*8 (varParams) = 348 floats.
    public static let headerFloats = 15
    public static let numSlots = VariationDescriptor.canonicalOrder.count   // authority
    public static let slotWidth = 8                                         // MAX_PARAMS_PER_SLOT=6, device slot width 8
    public static let floatsPerXform = headerFloats + numSlots + numSlots * slotWidth   // 15+37+296 = 348
    public static let bytesPerXform = floatsPerXform * 4                    // 1392
}

/// Per-frame constants passed to the chaos kernel.
public struct GPUFrameParams {
    public var gridWidth: UInt32 = 0
    public var gridHeight: UInt32 = 0
    public var gutter: UInt32 = 0
    public var oversample: Float = 1
    public var cosR: Float = 1
    public var sinR: Float = 0
    public var pixelsPerUnit: Float = 1
    public var centerX: Float = 0
    public var centerY: Float = 0
    public var iterationsPerThread: UInt32 = 0
    public var remainder: UInt32 = 0       // first `remainder` threads do one extra iter
    public var threadCount: UInt32 = 0
    public var fuse: UInt32 = 15
    public var cmapSize: UInt32 = 256
    public var cmapSizeM1: UInt32 = 255
    public var colorScale: Float = 0       // == `scale` (per-frame uint32 fixed-point unit)
    public var hasFinal: UInt32 = 0        // 1 if finalXform buffer is valid
    public init() {}
}

@MainActor
enum MetalHost {
    // Pin thread geometry from params alone (NOT device caps) → machine-independent.
    static let threadsPerGroup: Int = 256

    static func pinnedThreadCount(totalSamples: Int) -> Int {
        let targetThreads = max(1024, Int((Double(totalSamples) / 64).rounded(.up)))
        // Round up to a multiple of threadsPerGroup.
        let groups = (targetThreads + threadsPerGroup - 1) / threadsPerGroup
        return groups * threadsPerGroup
    }

    /// Build the flat-packed device xform buffer for a Flame. Each xform emits
    /// `GPUXform.floatsPerXform` (348) floats: 15 header (a..f, pa..pf,
    /// color/colorSpeed/opacity), then 37 `varWeights` (canonical slot order,
    /// summing weights of repeated names — algebraically identical to CPU's
    /// array-order sum because variation terms commute), then 296 `varParams`
    /// (`varParams[slot*8 + intraIdx]`; `super_shape_rnd` clamped to [0,1];
    /// parameterless variations + unused tail slots zeroed).
    ///
    /// FLAT PACK (not a `[Float]` struct field): a Swift `Array<Float>` field
    /// on `GPUXform` would be heap-allocated and not inlined into the struct,
    /// so the `withUnsafeBytes` device-buffer copy would send garbage. This
    /// returns a contiguous `[Float]` that crosses the boundary intact.
    static func packXforms(_ flame: Flame) -> [Float] {
        let order = Variations.canonicalOrder          // 37-name authority
        var idxMap = [String: Int]()
        for (i, n) in order.enumerated() { idxMap[n] = i }
        let nXforms = flame.xforms.count
        var flat = [Float](repeating: 0, count: nXforms * GPUXform.floatsPerXform)

        for (xi, xf) in flame.xforms.enumerated() {
            let base = xi * GPUXform.floatsPerXform
            // 15 header floats.
            flat[base + 0]  = Float(xf.affine.a)
            flat[base + 1]  = Float(xf.affine.b)
            flat[base + 2]  = Float(xf.affine.c)
            flat[base + 3]  = Float(xf.affine.d)
            flat[base + 4]  = Float(xf.affine.e)
            flat[base + 5]  = Float(xf.affine.f)
            flat[base + 6]  = Float(xf.postAffine.a)
            flat[base + 7]  = Float(xf.postAffine.b)
            flat[base + 8]  = Float(xf.postAffine.c)
            flat[base + 9]  = Float(xf.postAffine.d)
            flat[base + 10] = Float(xf.postAffine.e)
            flat[base + 11] = Float(xf.postAffine.f)
            flat[base + 12] = Float(xf.color)
            flat[base + 13] = Float(xf.colorSpeed)
            flat[base + 14] = Float(xf.opacity)

            let wBase = base + GPUXform.headerFloats                  // 37 weights
            let pBase = wBase + GPUXform.numSlots                     // 296 params

            for v in xf.variations where v.weight != 0 {
                guard let slot = idxMap[v.name] else { continue }
                flat[wBase + slot] += Float(v.weight)
                // Per-slot params: write each into varParams[slot*8 + intraIdx].
                if let desc = VariationDescriptor.descriptor(for: v.name),
                   !desc.parameters.isEmpty {
                    // intraIdx == VariationDescriptor.slotIndex(variation:param:) but O(1)
                    // (we're already iterating desc.parameters in declared order).
                    for (intraIdx, key) in desc.parameters.enumerated() {
                        guard intraIdx < GPUXform.slotWidth else { break }
                        var val = v.parameters[key] ?? desc.defaults[key] ?? 0
                        if key == "super_shape_rnd" { val = min(1, max(0, val)) }
                        flat[pBase + slot * GPUXform.slotWidth + intraIdx] = Float(val)
                    }
                }
            }
        }
        return flat
    }

    /// Build the flat-packed final-xform buffer (single xform, length
    /// `GPUXform.floatsPerXform`), or nil if the flame has no final xform.
    static func packFinalXform(_ flame: Flame) -> [Float]? {
        guard flame.finalXform != nil else { return nil }
        return packXforms(Flame(xforms: [flame.finalXform!]))
    }

    /// Precompute every thread's 16-word ISAAC `randrsl` by serial draws from a
    /// parent ISAAC. Collision-free, deterministic, machine-independent — the
    /// exact flam3 parent→child mechanism, replicated per thread.
    static func buildThreadSeeds(seed: UInt64, threadCount: Int) -> [UInt64] {
        var parent = ISAAC(isaacSeed: "emberweft-metal-\(seed)")
        var out = [UInt64](repeating: 0, count: threadCount * ISAAC.randsizWords)
        for t in 0..<threadCount {
            for w in 0..<ISAAC.randsizWords { out[t * ISAAC.randsizWords + w] = UInt64(parent.next()) }
        }
        return out
    }

    /// Per-frame uint32 fixed-point scale: `scale = 2^31 / (T·255)`.
    static func colorScale(totalSamples: Int) -> Float {
        Float((Double(1 << 31)) / (Double(totalSamples) * 255.0))
    }

    /// Build GPUFrameParams from flame + params + pinned thread geometry.
    static func buildFrameParams(_ flame: Flame, _ params: RenderParams) -> GPUFrameParams {
        let tc = pinnedThreadCount(totalSamples: params.totalSamples)
        let ipt = params.totalSamples / tc
        let rem = params.totalSamples % tc
        var fp = GPUFrameParams()
        fp.gridWidth = UInt32(params.gridWidth)
        fp.gridHeight = UInt32(params.gridHeight)
        fp.gutter = UInt32(params.gutterWidth)
        fp.oversample = Float(params.oversample)
        let r = flame.camera.rotation * .pi / 180
        fp.cosR = Float(cos(r)); fp.sinR = Float(sin(r))
        fp.pixelsPerUnit = Float(flame.camera.scale * pow(2, flame.camera.zoom) * Double(params.oversample))
        fp.centerX = Float(flame.camera.center.x); fp.centerY = Float(flame.camera.center.y)
        fp.iterationsPerThread = UInt32(ipt)
        fp.remainder = UInt32(rem)
        fp.threadCount = UInt32(tc)
        fp.colorScale = colorScale(totalSamples: params.totalSamples)
        return fp
    }
}
