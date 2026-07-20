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

    /// `CHOOSE_XFORM_GRAIN` (flam3.c:70) — the canonical grain now lives in
    /// `Flam3XformDistrib.grain` (FlameKit); the draw mask is derived from it
    /// so the chaos game and the distrib table stay in lockstep.
    private static let chooseXformGrainM1 = UInt32(Flam3XformDistrib.grain - 1)

    /// `FUSE_27` (rect.c:36) — burn-in iterations discarded before
    /// accumulation when `earlyclip` is off (the frozen goldens' default).
    private static let fuse = 15

    /// `sub_batch_size` default (flam3-render.c:134). Each sub-batch re-seeds
    /// the chain position from the thread ISAAC (rect.c:393-396).
    private static let subBatchSize = 10_000

    /// The `isaac_seed` string pinned by `Tools/regen_goldens.sh`
    /// (`FLAM3_ISAAC_SEED`). Every golden PNG is rendered with this exact
    /// seed, so the parent ISAAC must be seeded identically. Used as the
    /// default for `iterate(isaacSeed:)` so the temporal motion-blur path can
    /// salt the seed per sub-pass without changing the existing goldens.
    @usableFromInline static let goldenIsaacSeed = "emberweftgoldens"

    // MARK: - Entry point

    public static func iterate(
        flame: Flame, params: RenderParams,
        isaacSeed: String = goldenIsaacSeed,   // per-pass seed salt for temporal motion blur
        colorScalar: Double = 1.0              // flam3 color_scalar (rect.c:757) baked into dmap
    ) -> Histogram {
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
        let distrib = Flam3XformDistrib.build(weights)
        let stdXforms = flame.xforms
        let finalXf = flame.finalXform

        // --- dmap: colormap pre-baked with WHITE_LEVEL (rect.c:776-782) ---
        // flam3 builds a CMAP_SIZE(=256)-entry dmap where each color is
        //   dmap[j].color[k] = (palette[j].color[k] * WHITE_LEVEL) * color_scalar
        // BEFORE iteration. Accumulation then adds these pre-scaled values directly
        // (rect.c:456-466 / 501-511), so the per-hit `*255` happens once at dmap
        // build time, NOT as a final multiply — this operation order is load-bearing
        // for ULP parity. color_scalar = temporal_filter[0] = 1.0 for single-batch
        // renders (nbatches=ntemporal_samples=1; rect.c:642,757). Emberweft's
        // `Palette` stores RGB in [0,1] with no alpha; flam3 embedded palettes are
        // opaque (alpha=1.0), so dmap.alpha = 1.0*255 = 255 uniformly.
        let cmapSize = 256
        let cmapSizeM1 = 255
        let whiteLevel = 255.0
        let dmap = buildDmap(flame.palette, whiteLevel: whiteLevel, colorScalar: colorScalar)
        // dmap alpha channel (rect.c:781, k=3): opaque embedded palettes → 1.0*255 = 255.
        let dmapAlpha = [Double](repeating: whiteLevel * colorScalar, count: cmapSize)

        // --- Camera transform: world → supersample-grid pixel ---
        let cosR = cos(flame.camera.rotation * .pi / 180)
        let sinR = sin(flame.camera.rotation * .pi / 180)
        let pixelsPerUnit = flame.camera.scale * pow(2, flame.camera.zoom) * Double(params.oversample)
        let cx = flame.camera.center.x, cy = flame.camera.center.y

        // --- ISAAC seeding chain (rect.c:862-865) ---
        // Parent ISAAC seeded from the golden string; draw RANDSIZ words to
        // seed the thread-local ISAAC that produces every chaos-game draw.
        // nthreads=1 for the goldens (single-threaded render), so exactly one
        // child is created and consumed for the whole frame. For the temporal
        // motion-blur path the caller salts `isaacSeed` per sub-pass so the N
        // trajectories are not perfectly correlated (rect.c:862-865 layers a
        // sub-batch re-seed on top — Emberweft's single-pass iterate gets the
        // same decorrelation from a distinct parent seed string).
        var parent = ISAAC(isaacSeed: isaacSeed)
        var childSeed = [UInt64](repeating: 0, count: ISAAC.randsizWords)
        for i in 0..<ISAAC.randsizWords { childSeed[i] = UInt64(parent.next()) }
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
            var p = SIMD2<Double>(rng.isaac11(), rng.isaac11())
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

                // badvalue recovery (variations.c:2392): flam3 declares badvalue
                // when the result is NaN OR |q| > 1e10 (NOT just Inf). This range
                // check is load-bearing — on chaotic maps (julia/spherical) large
                // finite excursions occur, and each one triggers a 2-word redraw
                // that keeps the ISAAC stream aligned with the oracle.
                //   #define badvalue(x) (((x)!=(x))||((x)>1e10)||((x)<-1e10))
                func badvalue(_ x: Double) -> Bool { x != x || x > 1e10 || x < -1e10 }
                if badvalue(q.x) || badvalue(q.y) {
                    let rx = rng.isaac11()
                    let ry = rng.isaac11()
                    consec += 1
                    if consec < 5 {
                        p = SIMD2<Double>(rx, ry)
                        continue          // retry slot, do not advance j
                    }
                    // 5 consecutive badvals: accept the replacement and proceed.
                    q = SIMD2<Double>(rx, ry)
                    consec = 0
                } else {
                    consec = 0
                }

                // The iteration point `p` and its color `colorT` carry ONLY the
                // MAIN xform's result into the next iteration. The final xform
                // (if any) transforms a SEPARATE point used solely for
                // binning/display — it does NOT feed back into the trajectory.
                // This matches flam3's `flam3_iterate` (flam3.c:275-296):
                // `p` is the iteration state updated by the main xform; the
                // final writes to the display/binning point `q`, leaving `p`
                // intact. Feeding the final-transformed point back into `p`
                // diverges the chaos-game trajectory from flam3 at T1+.
                p = q
                colorT = qColor

                // (3) final xform (flam3.c:278-296). Applied every iteration
                // when opacity==1 (no RNG draw); else one isaac_01 draw gates
                // it. The final transforms a COPY of the main-xform point for
                // binning; the iteration point `p` is untouched. The final
                // re-blends the color coordinate into the binning point's color
                // (apply_xform sets q[2] on the final's output), used only for
                // this one accumulation — it does not flow to the next iter.
                var binP = p
                var binColor = colorT
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
                        binP = applyXformBody(fin, p, rng: &rng)
                        binColor = blendColor(fin, colorT)
                    }
                }

                // (4) accumulate after the fuse burn-in (i >= 0 in flam3).
                if j >= fuse {
                    produced += 1   // flam3 stores every post-fuse sample
                    if binP.x.isFinite, binP.y.isFinite {
                        // world → grid. floor (not Int truncation): a point at
                        // gx=-0.5 must land in bin -1 (out of frame), not bin 0.
                        // The grid includes the gutter ring (rect.c:685-686), so the
                        // +gw/2 offset = image_half + gutter, matching flam3's
                        // bounds/wb0s0 binning (rect.c:808-825,440-841).
                        let dx = binP.x - cx, dy = binP.y - cy
                        let rx = dx * cosR - dy * sinR
                        let ry = dx * sinR + dy * cosR
                        let gx = rx * pixelsPerUnit + Double(gw) / 2
                        let gy = ry * pixelsPerUnit + Double(gh) / 2
                        // Guard against Int overflow from diverging genomes.
                        if abs(gx) < Double(Int.max / 2), abs(gy) < Double(Int.max / 2) {
                            let u = Int(gx.rounded(.down)), v = Int(gy.rounded(.down))
                            if u >= 0, u < gw, v >= 0, v < gh {
                                // flam3 accumulation (rect.c:440-512, USE_FLOAT_INDICES
                                // undefined → the #else dbl_index path). p[3]=vis=1.0
                                // for the goldens (opacity=1), so the logvis branch is
                                // unused. Palette mode = linear (default).
                                let idx = hist.binIndex(u, v)
                                // dbl_index0 = p[2] * cmap_size  (rect.c:468)
                                let dblIndex0 = binColor * Double(cmapSize)
                                var colorIndex0 = Int(dblIndex0)
                                var dblFrac: Double
                                if colorIndex0 >= cmapSizeM1 {           // rect.c:475-477
                                    colorIndex0 = cmapSizeM1 - 1
                                    dblFrac = 1.0
                                } else {
                                    dblFrac = dblIndex0 - Double(colorIndex0) // rect.c:480
                                }
                                let i0 = dmap[colorIndex0], i1 = dmap[colorIndex0 + 1]
                                let m0 = 1.0 - dblFrac
                                // interpcolor[k] = dmap[i0]*(1-frac) + dmap[i1]*frac (rect.c:484-485)
                                let interpR = i0.x * m0 + i1.x * dblFrac
                                let interpG = i0.y * m0 + i1.y * dblFrac
                                let interpB = i0.z * m0 + i1.z * dblFrac
                                // dmap alpha is uniformly 255 (opaque palette); interpolate
                                // it exactly as flam3 does (rect.c:484, ci=3) so bucket[3]
                                // carries the identical ULP structure.
                                let interpA = dmapAlpha[colorIndex0] * m0 + dmapAlpha[colorIndex0 + 1] * dblFrac
                                // bump_no_overflow (rect.c:501-505): b[0][0..3] += interpcolor
                                hist.colors[idx] += SIMD3<Double>(interpR, interpG, interpB)
                                hist.alpha[idx] += interpA
                                hist.counts[idx] += 1          // b[0][4] += 255.0 (÷255 here)
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
    static func applyXformBody(_ x: Xform, _ p: SIMD2<Double>, rng: inout ISAAC) -> SIMD2<Double> {
        let pre = x.affine.apply(p)
        // ef carries the affine translation (e, f) = (c[2][0], c[2][1]) needed by
        // the coefficient-dependent variations rings/fan (variations.c:521,543).
        let v = Variations.evaluate(x.variations, at: pre,
                                    ef: SIMD2(x.affine.e, x.affine.f), rng: &rng)
        // xform.opacity is reflected in `q[3]` / the final-xform opacity test;
        // it is not part of the geometric output (Emberweft's tone mapping is
        // opaque, and goldens use opacity=1 throughout).
        return x.postAffine.apply(v)
    }

    /// `q[2] = color_speed·color + (1−color_speed)·p[2]` (apply_xform,
    /// variations.c:2139). The final xform re-blends this, so its result must
    /// flow through the iteration.
    @inline(__always)
    static func blendColor(_ x: Xform, _ colorT: Double) -> Double {
        (1 - x.colorSpeed) * colorT + x.colorSpeed * x.color
    }

    // MARK: - xform_distrib table (flam3.c:165 `flam3_create_chaos_distrib`)
    //
    // `buildXformDistrib`/`Flam3XformDistrib.build`, `buildDmap`, and
    // `ISAAC_RANDSIZ_WORDS`/`ISAAC.randsizWords` now live in `FlameKit`
    // (RenderTypes.swift / ISAAC.swift), lifted so `FlameRenderer` can depend on
    // `FlameKit` only. The chaos game calls the `FlameKit` versions directly.
}
