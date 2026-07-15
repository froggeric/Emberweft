import Foundation
import FlameKit

/// Faithful Swift port of flam3's chaos game (flam3.c:`flam3_iterate` +
/// rect.c:`iter_thread`). The per-iteration ISAAC RNG consumption order
/// matches flam3 exactly so that RNG-dependent variations (julia, noise,
/// blur, …) reproduce the oracle's output byte-for-byte at the sample level.
///
/// Consumption order per iteration (flam3.c:246-294):
///   1. `irand(rc) & (GRAIN-1)`  → weighted xform pick (1 word)
///   2. main xform `apply_xform`:
///        - pre_blur (5 words) — SKIPPED when xform has no `pre_blur`
///        - variation loop: julia consumes 1 word (`irand & 1`), others 0
///        - badvalue recovery: 2 words (`isaac_11` × 2) only on NaN
///   3. final xform (if enabled & opacity test passes):
///        - opacity<1 consumes 1 word (`isaac_01 < opacity`)
///        - its variation loop consumes as above (julia in final → 1 word)
///        - its color coordinate IS threaded (apply_xform sets q[2])
///   4. accumulate after `fuse` burn-in iterations
///
/// Seeding chain (rect.c:862-865): a frame-level ("parent") ISAAC seeded from
/// the `isaac_seed` string draws 16 words to seed a thread-local ISAAC which
/// produces every draw the chaos game consumes. This layering is load-bearing
/// for stream parity.
public enum ChaosGame {

    // MARK: - flam3 constants (flam3.c:70, rect.c:36-37, flam3-render.c:134)

    /// `CHOOSE_XFORM_GRAIN` (flam3.c:70) — width of the precomputed weighted
    /// xform-selection table. An ISAAC draw masked to 14 bits indexes it.
    private static let chooseXformGrain = 16384
    private static let chooseXformGrainM1 = UInt32(16383)

    /// `FUSE_27` (rect.c:36) — burn-in iterations discarded before
    /// accumulation when `earlyclip` is off (the frozen goldens' default).
    private static let fuse = 15

    /// `sub_batch_size` default (flam3-render.c:134). Each sub-batch re-seeds
    /// the chain position from the thread ISAAC (rect.c:393-396).
    private static let subBatchSize = 10_000

    /// The `isaac_seed` string pinned by `Tools/regen_goldens.sh`
    /// (`FLAM3_ISAAC_SEED`). Every golden PNG is rendered with this exact
    /// seed, so the parent ISAAC must be seeded identically.
    private static let goldenIsaacSeed = "emberweftgoldens"

    // MARK: - Entry point

    public static func iterate(flame: Flame, params: RenderParams) -> Histogram {
        let gw = params.gridWidth, gh = params.gridHeight
        var hist = Histogram(gridWidth: gw, gridHeight: gh)

        // --- xform_distrib: precomputed weighted-selection table ---
        // (flam3.c:165 `flam3_create_chaos_distrib`, non-chaos row).
        // Only standard (non-final) xforms participate in the weighted draw;
        // the goldens do not set `chaos`, so unity-chaos → single row.
        // NOTE: Emberweft keeps `finalXform` SEPARATE from the `xforms` array
        // (unlike flam3, which appends it at the end). So every entry in
        // `flame.xforms` is a standard xform — do NOT subtract one when a
        // final xform is present (that would drop the last real xform).
        let weights = flame.xforms.map { max(0, $0.weight) }
        guard weights.reduce(0, +) > 0 else { return hist }
        let distrib = buildXformDistrib(weights)
        let stdXforms = flame.xforms
        let finalXf = flame.finalXform

        // --- Camera transform: world → supersample-grid pixel ---
        let cosR = cos(flame.camera.rotation * .pi / 180)
        let sinR = sin(flame.camera.rotation * .pi / 180)
        let pixelsPerUnit = flame.camera.scale * pow(2, flame.camera.zoom) * Float(params.oversample)
        let cx = flame.camera.center.x, cy = flame.camera.center.y

        // --- ISAAC seeding chain (rect.c:862-865) ---
        // Parent ISAAC seeded from the golden string; draw RANDSIZ words to
        // seed the thread-local ISAAC that produces every chaos-game draw.
        // nthreads=1 for the goldens (single-threaded render), so exactly one
        // child is created and consumed for the whole frame.
        var parent = ISAAC(isaacSeed: goldenIsaacSeed)
        var childSeed = [UInt64](repeating: 0, count: ISAAC_RANDSIZ_WORDS)
        for i in 0..<ISAAC_RANDSIZ_WORDS { childSeed[i] = UInt64(parent.next()) }
        var rng = ISAAC(randrsl: childSeed)

        // `stdXforms` (all of flame.xforms) and `finalXf` are set above.

        var produced = 0
        let totalNeeded = max(1, params.totalSamples)
        // Hard safety cap: a degenerate (non-contracting) genome could otherwise
        // loop forever trying to reach `totalSamples`. Allow 32× overshoot.
        let hardCap = totalNeeded * 32
        var totalIter = 0

        while produced < totalNeeded && totalIter < hardCap {
            let remaining = totalNeeded - produced
            let batchN = min(subBatchSize, remaining)

            // --- Sub-batch seed (rect.c:393-396): 4 ISAAC draws ---
            // p[0],p[1] = isaac_11 (x,y ∈ [-1,1]); p[2] = isaac_01 (color);
            // p[3] = isaac_01 (vis) — consumed to keep stream alignment; its
            // value is immediately overwritten by the first xform's opacity.
            var p = SIMD2<Float>(rng.isaac11(), rng.isaac11())
            var colorT = rng.isaac01()
            _ = rng.isaac01()   // p[3] vis — value discarded (overwritten below)

            // fuse burn-in + batchN accumulated iterations (flam3_iterate,
            // flam3.c:246: `for i = -4*fuse ..< 4*n`).
            let total = fuse + batchN
            var consec = 0
            var j = 0
            while j < total {
                totalIter += 1

                // (1) xform selection: irand(rc) & (GRAIN-1) → table lookup.
                let draw = rng.next() & chooseXformGrainM1
                let fn = Int(draw)
                let xf = stdXforms[min(distrib[fn], stdXforms.count - 1)]

                // (2) main apply_xform: affine → variations (julia draws here)
                //     → post-affine. Color coordinate blends (apply_xform q[2]).
                var q = applyXformBody(xf, p, rng: &rng)
                let qColor = blendColor(xf, colorT)

                // badvalue recovery (variations.c apply_xform tail): on NaN the
                // main xform draws 2 replacement words and the slot is retried
                // (flam3.c:257-265: consec<5 ⇒ i-=4; continue).
                if !q.x.isFinite || !q.y.isFinite {
                    let rx = rng.isaac11()
                    let ry = rng.isaac11()
                    consec += 1
                    if consec < 5 {
                        p = SIMD2<Float>(rx, ry)
                        continue          // retry slot, do not advance j
                    }
                    // 5 consecutive badvals: accept the replacement and proceed.
                    q = SIMD2<Float>(rx, ry)
                    consec = 0
                } else {
                    consec = 0
                }

                p = q
                colorT = qColor

                // (3) final xform (flam3.c:278-286). Applied every iteration
                // when opacity==1 (no RNG draw); else one isaac_01 draw gates
                // it. The final BLENDS the color coordinate (apply_xform q[2]),
                // while the visibility (q[3]) is kept from the main xform.
                if let fin = finalXf {
                    let apply: Bool
                    if fin.opacity >= 1 {
                        apply = true
                    } else if fin.opacity > 0 {
                        apply = rng.isaac01() < fin.opacity
                    } else {
                        apply = false
                    }
                    if apply {
                        p = applyXformBody(fin, p, rng: &rng)
                        colorT = blendColor(fin, colorT)
                    }
                }

                // (4) accumulate after the fuse burn-in (i >= 0 in flam3).
                if j >= fuse {
                    produced += 1   // flam3 stores every post-fuse sample
                    if p.x.isFinite, p.y.isFinite {
                        // world → grid. floor (not Int truncation): a point at
                        // gx=-0.5 must land in bin -1 (out of frame), not bin 0.
                        let dx = p.x - cx, dy = p.y - cy
                        let rx = dx * cosR - dy * sinR
                        let ry = dx * sinR + dy * cosR
                        let gx = rx * pixelsPerUnit + Float(gw) / 2
                        let gy = ry * pixelsPerUnit + Float(gh) / 2
                        // Guard against Int overflow from diverging genomes.
                        if abs(gx) < Float(Int.max / 2), abs(gy) < Float(Int.max / 2) {
                            let u = Int(gx.rounded(.down)), v = Int(gy.rounded(.down))
                            if u >= 0, u < gw, v >= 0, v < gh {
                                let pal = samplePalette(flame.palette, t: colorT, hue: flame.hueShift)
                                let idx = hist.binIndex(u, v)
                                hist.counts[idx] += 1
                                hist.colors[idx] += pal
                            }
                        }
                    }
                }
                j += 1
            }
        }
        return hist
    }

    // MARK: - xform body & color blend (mirror apply_xform, variations.c:2129+)

    /// Affine pre-transform → sum of weighted variations → post-affine.
    /// Matches flam3 `apply_xform` body (variations.c:2145-2201). The julia
    /// variation (if active) consumes one ISAAC word here, exactly when it is
    /// reached in the variation loop.
    @inline(__always)
    static func applyXformBody(_ x: Xform, _ p: SIMD2<Float>, rng: inout ISAAC) -> SIMD2<Float> {
        let pre = x.affine.apply(p)
        let v = Variations.evaluate(x.variations, at: pre, rng: &rng)
        // xform.opacity is reflected in `q[3]` / the final-xform opacity test;
        // it is not part of the geometric output (Emberweft's tone mapping is
        // opaque, and goldens use opacity=1 throughout).
        return x.postAffine.apply(v)
    }

    /// `q[2] = color_speed·color + (1−color_speed)·p[2]` (apply_xform,
    /// variations.c:2139). The final xform re-blends this, so its result must
    /// flow through the iteration.
    @inline(__always)
    static func blendColor(_ x: Xform, _ colorT: Float) -> Float {
        (1 - x.colorSpeed) * colorT + x.colorSpeed * x.color
    }

    // MARK: - xform_distrib table (flam3.c:165 `flam3_create_chaos_distrib`)

    /// Build the `CHOOSE_XFORM_GRAIN`-entry weighted selection table. A masked
    /// 14-bit ISAAC draw indexes it directly (flam3.c:255), producing a
    /// uniform draw over xforms weighted by `density` (xform weight). This is
    /// mathematically equivalent to a CDF binary search but matches flam3's
    /// exact word→index mapping, which is load-bearing for stream parity.
    static func buildXformDistrib(_ weights: [Float]) -> [Int] {
        let n = weights.count
        precondition(n > 0)
        let total = weights.reduce(0, +)
        precondition(total > 0)
        let dr = total / Float(chooseXformGrain)
        var table = [Int](repeating: 0, count: chooseXformGrain)
        var j = 0
        var t = weights[0]
        var r: Float = 0
        for i in 0..<chooseXformGrain {
            while r >= t {
                j += 1
                if j < n { t += weights[j] } else { break }
            }
            table[i] = min(j, n - 1)
            r += dr
        }
        return table
    }
}

/// Linear-interpolated palette sample at t∈[0,1] with optional hue rotation.
public func samplePalette(_ palette: Palette, t: Float, hue: Float) -> SIMD3<Float> {
    var tt = t + hue
    tt -= tt.rounded(.down)            // wrap to [0,1)
    let f = tt * 255
    let i0 = Int(f) & 255
    let i1 = (i0 + 1) & 255
    let frac = f - Float(i0)
    return palette.colors[i0] * (1 - frac) + palette.colors[i1] * frac
}

/// `RANDSIZ` (isaac.h: `1<<RANDSIZL` = 1<<4 = 16) — the ISAAC results/seed
/// table width. Re-exposed here as a small named constant for the parent→child
/// seeding draw.
@usableFromInline
internal let ISAAC_RANDSIZ_WORDS: Int = 1 << 4
