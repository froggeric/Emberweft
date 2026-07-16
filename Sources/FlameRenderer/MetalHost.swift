import Foundation
import Metal
import FlameKit

// MARK: - Device-side structs (Swift mirrors of the MSL structs in Kernels.metal.
// Field order and types MUST match exactly; both align `float` to 4 bytes.)

/// One IFS transform, device layout. 19-slot variation table.
///
/// LAYOUT CONTRACT: this struct crosses the Swift→MSL boundary as raw bytes,
/// so its in-memory layout MUST match `struct GPUXform` in Kernels.metal
/// field-for-field. Both sides are all-`float` (4-byte align), 6+6+3+19 = 34
/// floats = 136 bytes, stride 136. Swift does not formally guarantee struct
/// field order or homogeneous-tuple contiguity in the language spec, but the
/// ABI lays out trivial structs of `Float` fields sequentially with no
/// padding. `buildGPUXforms` asserts the stride at runtime so any future ABI
/// drift fails loudly instead of silently corrupting the device buffer. If
/// the assertion ever fires on a new toolchain, switch `varWeights` to a
/// `withUnsafeMutablePointer`-filled `[Float]` of count 19 copied into the
/// device buffer (or 4×`SIMD4<Float>`), which is fully layout-defined.
public struct GPUXform {
    public var a: Float = 0, b: Float = 0, c: Float = 0, d: Float = 0, e: Float = 0, f: Float = 0
    public var pa: Float = 0, pb: Float = 0, pc: Float = 0, pd: Float = 0, pe: Float = 0, pf: Float = 0
    public var color: Float = 0
    public var colorSpeed: Float = 0
    public var opacity: Float = 0
    public var varWeights: (Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float) =
          (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    public init() {}
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

    /// Build the device xform array from a Flame: affine (tx=a·x+c·y+e),
    /// post-affine, color/colorSpeed/opacity, and the 19-slot canonical
    /// variation table (summing weights of repeated names, which is algebraically
    /// identical to CPU's array-order sum because variation terms commute).
    static func buildGPUXforms(_ flame: Flame) -> [GPUXform] {
        // Layout-contract guard: see GPUXform doc comment. 34 Floats == 136 B.
        precondition(MemoryLayout<GPUXform>.stride == 136,
                     "GPUXform stride drifted from MSL mirror (136 bytes); Metal buffer would be misread")
        let slots = Variations.canonicalOrder
        var idxMap = [String: Int]()
        for (i, n) in slots.enumerated() { idxMap[n] = i }
        return flame.xforms.map { xf in
            var g = GPUXform()
            g.a = Float(xf.affine.a); g.b = Float(xf.affine.b); g.c = Float(xf.affine.c)
            g.d = Float(xf.affine.d); g.e = Float(xf.affine.e); g.f = Float(xf.affine.f)
            g.pa = Float(xf.postAffine.a); g.pb = Float(xf.postAffine.b); g.pc = Float(xf.postAffine.c)
            g.pd = Float(xf.postAffine.d); g.pe = Float(xf.postAffine.e); g.pf = Float(xf.postAffine.f)
            g.color = Float(xf.color); g.colorSpeed = Float(xf.colorSpeed); g.opacity = Float(xf.opacity)
            withUnsafeMutableBytes(of: &g.varWeights) { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: Float.self)
                for v in xf.variations where v.weight != 0 {
                    if let s = idxMap[v.name] { base[s] += Float(v.weight) }
                }
            }
            return g
        }
    }

    /// Build the optional final-xform buffer (nil if the flame has none).
    static func buildGPUFinalXform(_ flame: Flame) -> GPUXform? {
        guard flame.finalXform != nil else { return nil }
        // Reuse buildGPUXforms on a synthetic single-xform flame to keep one code path.
        let single = Flame(xforms: [flame.finalXform!])
        return buildGPUXforms(single)[0]
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
