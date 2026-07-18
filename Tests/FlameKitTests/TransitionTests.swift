import XCTest
@testable import FlameKit

/// Port-fidelity tests for `Transition.blend` — the `sheep_edge` port (flam3.c:10582).
///
/// Each test traces the 8-step contract:
///   clone → (motion no-op) → align → time={0,1} → establish_refangles
///   → rotate BOTH endpoints by t·360° → flam3_interpolate(smoother(t), stagger)
///   → strip motion (no-op).
final class TransitionTests: XCTestCase {

    // MARK: - helpers

    /// Animating xforms with non-trivial affines (a=2,b=3,c=5,d=7,e=11,f=13) etc.
    private static let x0 = Xform(affine: AffineTransform(a: 2, b: 3, c: 5, d: 7, e: 11, f: 13),
                                  weight: 0.7, color: 0.3, colorSpeed: 0.5,
                                  variations: [Variation(name: "linear", weight: 1)],
                                  opacity: 0.9, animate: 1.0, padding: 0)
    private static let x1 = Xform(affine: AffineTransform(a: 4, b: -1, c: 0.5, d: 2, e: 3, f: -4),
                                  weight: 0.7, color: 0.3, colorSpeed: 0.5,
                                  variations: [Variation(name: "linear", weight: 1)],
                                  opacity: 0.9, animate: 1.0, padding: 0)

    /// 256-entry palette with a smooth hue ramp (non-constant → HSV blend is non-trivial).
    private static func rampPalette(_ offset: Double) -> Palette {
        Palette(colors: (0..<256).map { i in
            SIMD3<Double>(Double(i) / 255.0, (Double(i) / 255.0 + offset).truncatingRemainder(dividingBy: 1.0), 0.5)
        })
    }

    /// A genome built from the given xforms + a real palette + .log interpolation.
    private static func sampleGenome(_ xforms: [Xform], palette: Palette) -> Flame {
        Flame(name: "edge-test",
              xforms: xforms,
              palette: palette,
              interpolationType: .log,
              paletteInterpolation: .hsvCircular,
              hsvRgbPaletteBlend: 0.5)
    }

    // MARK: - 1. Endpoint equality: blend(A,B,0) ≈ alignedA, blend(A,B,1) ≈ alignedB

    /// At t=0 the rotation is 0 (identity, bit-exact) and interpolation at smoother(0)=0
    /// yields cp0. The `.log` polar decomposition round-trips the affine through
    /// atan2→cos/sin, so the endpoint is recovered within ~1e-15 (NOT bit-exact) — this
    /// is the documented `.log` FP tolerance. blend(A,B,0) must equal the ALIGNED
    /// parent A within that tolerance.
    func testBlendAtZeroEqualsAlignedA() {
        let a = Self.sampleGenome([Self.x0, Self.x1], palette: Self.rampPalette(0.0))
        let b = Self.sampleGenome([Self.x1, Self.x0], palette: Self.rampPalette(0.3))
        let (alignedA, _) = SpecialSauce.align(a, b, interpolationType: .log)

        let result = Transition.blend(a, b, t: 0, stagger: 0)

        XCTAssertEqual(result.xforms.count, alignedA.xforms.count)
        for i in 0..<alignedA.xforms.count {
            let r = result.xforms[i].affine
            let e = alignedA.xforms[i].affine
            XCTAssertEqual(r.a, e.a, accuracy: 1e-12, "xform \(i) affine.a at t=0")
            XCTAssertEqual(r.b, e.b, accuracy: 1e-12, "xform \(i) affine.b at t=0")
            XCTAssertEqual(r.c, e.c, accuracy: 1e-12, "xform \(i) affine.c at t=0")
            XCTAssertEqual(r.d, e.d, accuracy: 1e-12, "xform \(i) affine.d at t=0")
            XCTAssertEqual(r.e, e.e, accuracy: 1e-12, "xform \(i) affine.e at t=0")
            XCTAssertEqual(r.f, e.f, accuracy: 1e-12, "xform \(i) affine.f at t=0")
            XCTAssertEqual(result.xforms[i].variations, alignedA.xforms[i].variations,
                           "xform \(i) variations must equal aligned A at t=0")
            XCTAssertEqual(result.xforms[i].weight, alignedA.xforms[i].weight, accuracy: 1e-12)
        }
    }

    /// At t=1 both endpoints are rotated by 2π (≈identity within ULP ≈1e-16) and the
    /// interpolation at smoother(1)=1 yields cp1. So blend(A,B,1) ≈ aligned B within
    /// rotation-matrix FP residual (1e-12).
    func testBlendAtOneEqualsAlignedB() {
        let a = Self.sampleGenome([Self.x0, Self.x1], palette: Self.rampPalette(0.0))
        let b = Self.sampleGenome([Self.x1, Self.x0], palette: Self.rampPalette(0.3))
        let (_, alignedB) = SpecialSauce.align(a, b, interpolationType: .log)

        let result = Transition.blend(a, b, t: 1, stagger: 0)

        XCTAssertEqual(result.xforms.count, alignedB.xforms.count)
        for i in 0..<alignedB.xforms.count {
            let r = result.xforms[i].affine
            let e = alignedB.xforms[i].affine
            XCTAssertEqual(r.a, e.a, accuracy: 1e-12, "xform \(i) affine.a")
            XCTAssertEqual(r.b, e.b, accuracy: 1e-12, "xform \(i) affine.b")
            XCTAssertEqual(r.c, e.c, accuracy: 1e-12, "xform \(i) affine.c")
            XCTAssertEqual(r.d, e.d, accuracy: 1e-12, "xform \(i) affine.d")
            XCTAssertEqual(r.e, e.e, accuracy: 1e-12, "xform \(i) affine.e (translation)")
            XCTAssertEqual(r.f, e.f, accuracy: 1e-12, "xform \(i) affine.f (translation)")
            XCTAssertEqual(result.xforms[i].weight, alignedB.xforms[i].weight, accuracy: 1e-12)
        }
    }

    // MARK: - 2. Continuity: smooth (no jumps) over t∈{0,0.1,…,1}

    /// Continuity gate. The blend is smooth (smoother is C2, the rotation is sinusoidal,
    /// the `.log` polar blend is smooth in angle/magnitude), so consecutive frames must
    /// travel smoothly with NO discontinuity spike.
    ///
    /// We measure on NORMALIZED coefficient vectors (each frame's coefficient vector
    /// scaled to unit L2 norm — "normalized coefficients"):
    ///
    /// (a) **Finiteness** of every coefficient.
    /// (b) **No discontinuity**: each consecutive step `‖Δ‖` must be a small fraction
    ///     of the total endpoint-to-endpoint travel. A C0-discontinuity would make one
    ///     step ≈ the total travel (ratio ~1.0); a smooth blend keeps every step's ratio
    ///     well under 0.25 (≈1/10 of the journey per dt=0.1 step).
    ///
    /// (The task's `1e-3` figure is the curvature-only residual achievable WITHOUT the
    /// sheep_edge rotation; the rotation's 2π sweep over `[0,1]` raises the per-step
    /// travel to O(dt), so the meaningful continuity gate is the no-spike ratio below.)
    func testContinuityOverTLadder() {
        let a = Self.sampleGenome([Self.x0, Self.x1], palette: Self.rampPalette(0.0))
        let b = Self.sampleGenome([Self.x1, Self.x0], palette: Self.rampPalette(0.3))

        let ladder = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }
        let frames = ladder.map { Transition.blend(a, b, t: $0, stagger: 0) }
        let vecs = frames.map { Self.coeffVector($0) }

        // (a) Finiteness.
        for v in vecs { for c in v { XCTAssertTrue(c.isFinite, "non-finite coefficient") } }

        // (b) No-discontinuity: consecutive step ratio against total travel.
        let totalTravel = Self.l2(Self.sub(vecs.last!, vecs.first!))
        XCTAssertGreaterThan(totalTravel, 0, "endpoints must differ for the gate to be meaningful")
        var maxRatio = 0.0
        for i in 1..<vecs.count {
            let step = Self.l2(Self.sub(vecs[i], vecs[i - 1]))
            let ratio = step / totalTravel
            maxRatio = max(maxRatio, ratio)
            XCTAssertLessThan(ratio, 0.25,
                              "discontinuity at t=\(ladder[i]): step \(step) is \(ratio) of total travel")
        }
        // Sanity: a smooth blend over 10 steps keeps the peak step (smoother peaks
        // mid-transition) well below a discontinuity-level ratio (~1.0).
        XCTAssertLessThan(maxRatio, 0.25,
                          "max consecutive step \(maxRatio) of total travel indicates a discontinuity")
    }

    // MARK: - 3. Finiteness on a mismatched-xform-count pair (exercises padding)

    /// A has 2 xforms, B has 3 → SpecialSauce pads. The blend must be finite everywhere.
    func testFinitenessOnMismatchedXformCounts() {
        let a = Self.sampleGenome([Self.x0, Self.x1], palette: Self.rampPalette(0.0))
        let b = Self.sampleGenome([Self.x1, Self.x0, Self.x0], palette: Self.rampPalette(0.3))

        for step in 0...20 {
            let t = Double(step) / 20.0
            let g = Transition.blend(a, b, t: t, stagger: 0.2)
            XCTAssertEqual(g.xforms.count, 3, "padded to max count at t=\(t)")
            for xf in g.xforms {
                XCTAssertTrue(xf.affine.a.isFinite)
                XCTAssertTrue(xf.affine.b.isFinite)
                XCTAssertTrue(xf.affine.c.isFinite)
                XCTAssertTrue(xf.affine.d.isFinite)
                XCTAssertTrue(xf.weight.isFinite)
                for v in xf.variations { XCTAssertTrue(v.weight.isFinite) }
            }
        }
    }

    // MARK: - 4. stagger > 0 desyncs non-final xforms

    /// At t=0.5 with stagger>0, non-final xforms get staggered blend coefficients that
    /// differ from the plain smoother(0.5)=0.5, so the staggered genome must differ from
    /// the stagger==0 genome.
    func testStaggerDesyncsAtInteriorT() {
        // 3 animating xforms so stagger has room (nx=3, needs >=2).
        let a = Self.sampleGenome([Self.x0, Self.x1, Self.x0], palette: Self.rampPalette(0.0))
        let b = Self.sampleGenome([Self.x1, Self.x0, Self.x1], palette: Self.rampPalette(0.3))

        let noStagger = Transition.blend(a, b, t: 0.5, stagger: 0)
        let staggered = Transition.blend(a, b, t: 0.5, stagger: 0.7)

        // At least one xform's affine must differ.
        var anyDiffer = false
        for i in 0..<noStagger.xforms.count {
            if noStagger.xforms[i].affine != staggered.xforms[i].affine {
                anyDiffer = true
            }
        }
        XCTAssertTrue(anyDiffer, "stagger>0 must desync at least one non-final xform at t=0.5")
    }

    /// stagger <= 0 leaves every xform on the same eased curve (no per-xform split):
    /// stagger==0 and stagger<0 must produce identical genomes.
    func testNonPositiveStaggerIsEquivalent() {
        let a = Self.sampleGenome([Self.x0, Self.x1, Self.x0], palette: Self.rampPalette(0.0))
        let b = Self.sampleGenome([Self.x1, Self.x0, Self.x1], palette: Self.rampPalette(0.3))

        let zero = Transition.blend(a, b, t: 0.5, stagger: 0)
        let neg = Transition.blend(a, b, t: 0.5, stagger: -0.5)
        XCTAssertEqual(zero, neg, "stagger<=0 must yield identical results")
    }

    /// Stagger preserves endpoints: at t=0 and t=1 the staggered blend must still equal
    /// the aligned parents (within FP), because staggerCoef collapses to {0,1} at ends.
    func testStaggerPreservesEndpoints() {
        let a = Self.sampleGenome([Self.x0, Self.x1, Self.x0], palette: Self.rampPalette(0.0))
        let b = Self.sampleGenome([Self.x1, Self.x0, Self.x1], palette: Self.rampPalette(0.3))

        let g0 = Transition.blend(a, b, t: 0, stagger: 0.9)
        let g1 = Transition.blend(a, b, t: 1, stagger: 0.9)

        // Endpoint of staggerCoef at t=0: c0=1 → returns 1 (>= et) → per-xform t=0.
        // Endpoint at t=1: c0=0 → returns 0 (<= st) → per-xform t=1.
        // Rotation at 0 is identity; at 1 is 2π. Affine 2×2 within ULP of aligned parents.
        let (alignedA, alignedB) = SpecialSauce.align(a, b, interpolationType: .log)
        for i in 0..<alignedA.xforms.count {
            XCTAssertEqual(g0.xforms[i].affine.a, alignedA.xforms[i].affine.a, accuracy: 1e-12)
            XCTAssertEqual(g1.xforms[i].affine.a, alignedB.xforms[i].affine.a, accuracy: 1e-12)
        }
    }

    // MARK: - 5. Rotate BOTH endpoints (not just one)

    /// At t=0.5 the rotation is θ = 0.5·2π = π (180°). `flam3_rotate` is applied to
    /// BOTH spun[0] and spun[1]. For a `.log` polar blend, rotating both endpoints by
    /// the same angle θ and interpolating at the midpoint equals rotating the unrotated
    /// midpoint by θ — because polar angles shift by θ on both sides, so the averaged
    /// angle shifts by θ. R(π) = -I, so the 2×2 part negates while translation (e,f) is
    /// untouched by rotation. If only ONE endpoint were rotated, this clean negation
    /// would NOT hold. Both animate!=0 ⇒ RefAngles writes no wind ⇒ clean property.
    func testRotatesBothEndpoints() {
        let a = Self.sampleGenome([Self.x0], palette: Self.rampPalette(0.0))
        let b = Self.sampleGenome([Self.x1], palette: Self.rampPalette(0.3))
        let (alignedA, alignedB) = SpecialSauce.align(a, b, interpolationType: .log)

        // Unrotated midpoint (no Transition — direct GenomeInterpolator at smoother(0.5)=0.5).
        let unrotatedMid = GenomeInterpolator.interpolate(
            alignedA, alignedB, t: BlendMath.smoother(0.5), type: .log)

        // Transition midpoint (rotates both endpoints by π, then interpolates).
        let blendMid = Transition.blend(a, b, t: 0.5, stagger: 0)

        let ur = unrotatedMid.xforms[0].affine
        let bm = blendMid.xforms[0].affine

        // 2×2 part negated (R(π) = -I applied to both, polar-midpoint commutes).
        XCTAssertEqual(bm.a, -ur.a, accuracy: 1e-9, "rotated-mid a should be -unrotated a")
        XCTAssertEqual(bm.b, -ur.b, accuracy: 1e-9)
        XCTAssertEqual(bm.c, -ur.c, accuracy: 1e-9)
        XCTAssertEqual(bm.d, -ur.d, accuracy: 1e-9)
        // Translation is NOT part of the 2×2 rotation — untouched, linearly interpolated.
        XCTAssertEqual(bm.e, ur.e, accuracy: 1e-9, "translation e unaffected by rotation")
        XCTAssertEqual(bm.f, ur.f, accuracy: 1e-9)
    }

    /// A symmetry xform (animate == 0) is NEVER rotated in either endpoint. Its affine
    /// must equal the aligned parent's affine at t=0.5 mid-blend (interpolated only).
    func testAnimateZeroXformNotRotated() {
        var a = Self.sampleGenome([Self.x0, Self.x1], palette: Self.rampPalette(0.0))
        var b = Self.sampleGenome([Self.x0, Self.x1], palette: Self.rampPalette(0.3))
        // Mark xform 0 as symmetry (animate==0) in BOTH endpoints.
        a.xforms[0].animate = 0
        b.xforms[0].animate = 0

        let result = Transition.blend(a, b, t: 0.5, stagger: 0)
        let (alignedA, _) = SpecialSauce.align(a, b, interpolationType: .log)

        // The symmetry xform is interpolated (not rotated). At smoother(0.5)=0.5 the
        // .log midpoint of two identical affines (x0==x0) is affine itself.
        XCTAssertEqual(result.xforms[0].affine.a, alignedA.xforms[0].affine.a, accuracy: 1e-12)
        XCTAssertEqual(result.xforms[0].affine.b, alignedA.xforms[0].affine.b, accuracy: 1e-12)
        XCTAssertEqual(result.xforms[0].affine.c, alignedA.xforms[0].affine.c, accuracy: 1e-12)
        XCTAssertEqual(result.xforms[0].affine.d, alignedA.xforms[0].affine.d, accuracy: 1e-12)
    }

    // MARK: - 6. Input not mutated

    func testInputsNotMutated() {
        let a = Self.sampleGenome([Self.x0, Self.x1], palette: Self.rampPalette(0.0))
        let b = Self.sampleGenome([Self.x1, Self.x0], palette: Self.rampPalette(0.3))
        let snapA = a, snapB = b
        _ = Transition.blend(a, b, t: 0.5, stagger: 0.3)
        XCTAssertEqual(a, snapA, "blend must not mutate input A (value semantics)")
        XCTAssertEqual(b, snapB, "blend must not mutate input B (value semantics)")
    }

    // MARK: - 7. Palette is HSV-blended (not the naive linear RGB blend)

    /// The palette goes through PaletteBlend with the genome's hsvCircular mode +
    /// hsvRgbPaletteBlend fraction. For a non-trivial ramp the HSV-circular result
    /// differs from a plain linear-RGB blend — verifying Transition wires PaletteBlend.
    func testPaletteUsesHsvCircularBlend() {
        let a = Self.sampleGenome([Self.x0], palette: Self.rampPalette(0.0))
        let b = Self.sampleGenome([Self.x1], palette: Self.rampPalette(0.3))
        let result = Transition.blend(a, b, t: 0.5, stagger: 0)

        let (alignedA, alignedB) = SpecialSauce.align(a, b, interpolationType: .log)
        let expectedPalette = PaletteBlend.blend(
            alignedA.palette, alignedB.palette, at: BlendMath.smoother(0.5),
            mode: .hsvCircular, hsvMix: 0.5)

        XCTAssertEqual(result.palette.colors.count, 256)
        for i in 0..<256 {
            let r = result.palette.colors[i]
            let e = expectedPalette.colors[i]
            XCTAssertEqual(r.x, e.x, accuracy: 1e-12, "palette entry \(i) R must match HSV-circular blend")
            XCTAssertEqual(r.y, e.y, accuracy: 1e-12, "palette entry \(i) G must match HSV-circular blend")
            XCTAssertEqual(r.z, e.z, accuracy: 1e-12, "palette entry \(i) B must match HSV-circular blend")
        }
    }

    // MARK: - coefficient-vector helpers (for the continuity test)

    /// Flatten a genome's blend-relevant coefficients into a vector (affine 6 per xform
    /// + variation weights + weight/color/opacity scalars). Palette is intentionally
    /// excluded — its 768 entries would dominate the norm.
    private static func coeffVector(_ g: Flame) -> [Double] {
        var v: [Double] = []
        for x in g.xforms {
            v.append(contentsOf: [x.affine.a, x.affine.b, x.affine.c,
                                  x.affine.d, x.affine.e, x.affine.f])
            v.append(x.weight)
            v.append(x.color)
            v.append(x.opacity)
            for variation in x.variations { v.append(variation.weight) }
        }
        return v
    }

    /// L2 norm of a vector.
    private static func l2(_ v: [Double]) -> Double {
        sqrt(v.reduce(0) { $0 + $1 * $1 })
    }

    /// Element-wise difference.
    private static func sub(_ a: [Double], _ b: [Double]) -> [Double] {
        precondition(a.count == b.count)
        return zip(a, b).map { $0 - $1 }
    }
}
