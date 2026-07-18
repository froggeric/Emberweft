import XCTest
@testable import FlameKit

final class LoopTests: XCTestCase {

    // Sample non-trivial pre-affine 2×2 (a=2, b=3, c=5, d=7) with translation e=11, f=13.
    private static let pre = AffineTransform(a: 2, b: 3, c: 5, d: 7, e: 11, f: 13)
    private static let post = AffineTransform(a: 1.5, b: -0.5, c: 0.25, d: 0.75, e: 0.5, f: -0.25)

    private static func animatingXform() -> Xform {
        Xform(affine: pre,
              postAffine: post,
              weight: 0.7,
              color: 0.3,
              colorSpeed: 0.5,
              variations: [Variation(name: "linear", weight: 1)],
              chaos: [1.0, 2.0],
              opacity: 0.9,
              animate: 1.0,
              padding: 0)
    }

    private static func sampleFlame() -> Flame {
        Flame(name: "loop-test",
              xforms: [animatingXform()],
              palette: Palette(colors: (0..<256).map { SIMD3<Double>(Double($0)/255, 0.2, 0.8) }))
    }

    // MARK: - t = 0 exact equality (R(0) is bit-exact identity: cos=1, sin=0)

    func testT0ExactEquality() {
        let sheep = Self.sampleFlame()
        let out = Loop.blend(sheep, t: 0)
        XCTAssertEqual(out, sheep, "At t=0 the result must be bit-equal to the input")
    }

    // MARK: - t = 1 seamless within 1e-12 per coefficient (R(2π) has FP residual)

    func testT1SeamlessWithin1e12() {
        let sheep = Self.sampleFlame()
        let out = Loop.blend(sheep, t: 1)
        let inAff = sheep.xforms[0].affine
        let outAff = out.xforms[0].affine
        XCTAssertEqual(outAff.a, inAff.a, accuracy: 1e-12)
        XCTAssertEqual(outAff.b, inAff.b, accuracy: 1e-12)
        XCTAssertEqual(outAff.c, inAff.c, accuracy: 1e-12)
        XCTAssertEqual(outAff.d, inAff.d, accuracy: 1e-12)
    }

    // MARK: - translation e,f, post-affine, palette are byte-equal

    func testTranslationPostPaletteByteEqual() {
        let sheep = Self.sampleFlame()
        let out = Loop.blend(sheep, t: 0.5)   // mid-loop, worst case for "untouched" fields
        let inX = sheep.xforms[0]
        let outX = out.xforms[0]
        XCTAssertEqual(outX.affine.e, inX.affine.e)   // translation untouched
        XCTAssertEqual(outX.affine.f, inX.affine.f)
        XCTAssertEqual(outX.postAffine, inX.postAffine) // post byte-equal
        XCTAssertEqual(out.palette.colors.count, sheep.palette.colors.count)
        XCTAssertEqual(outX.weight, inX.weight)
        XCTAssertEqual(outX.color, inX.color)
        XCTAssertEqual(outX.opacity, inX.opacity)
        XCTAssertEqual(outX.chaos, inX.chaos)
    }

    func testPaletteByteEqualAllEntries() {
        let sheep = Self.sampleFlame()
        let out = Loop.blend(sheep, t: 0.42)
        XCTAssertEqual(out.palette.colors.count, sheep.palette.colors.count)
        for i in 0..<sheep.palette.colors.count {
            XCTAssertEqual(out.palette.colors[i], sheep.palette.colors[i],
                          "palette entry \(i) must be byte-equal")
        }
    }

    // MARK: - animate == 0  ⇒ xform untouched

    func testAnimateZeroUntouched() {
        var sheep = Self.sampleFlame()
        sheep.xforms[0].animate = 0
        let out = Loop.blend(sheep, t: 0.25)  // 90°
        XCTAssertEqual(out.xforms[0].affine, sheep.xforms[0].affine,
                       "animate==0 xform must be byte-equal to input")
    }

    // MARK: - final xform untouched

    func testFinalXformUntouched() {
        var sheep = Self.sampleFlame()
        let final = Xform(affine: AffineTransform(a: 4, b: -1, c: 2, d: 6, e: 1, f: 2),
                          variations: [Variation(name: "linear", weight: 1)],
                          animate: 1.0)
        sheep.finalXform = final
        let out = Loop.blend(sheep, t: 0.25)
        XCTAssertEqual(out.finalXform, final, "final xform must never be rotated")
    }

    // MARK: - padding xform: untouched under .linear, rotated under .log

    func testPaddingUntouchedUnderLinear() {
        var sheep = Self.sampleFlame()
        sheep.xforms[0].padding = 1
        sheep.interpolationType = .linear
        let out = Loop.blend(sheep, t: 0.25)
        XCTAssertEqual(out.xforms[0].affine, sheep.xforms[0].affine,
                       "padding xform under .linear must be byte-equal")
    }

    func testPaddingRotatedUnderLog() {
        var sheep = Self.sampleFlame()
        sheep.xforms[0].padding = 1
        sheep.interpolationType = .log
        let out = Loop.blend(sheep, t: 0.25)
        // Should rotate (same 90° result as the hand-check below).
        XCTAssertNotEqual(out.xforms[0].affine.a, sheep.xforms[0].affine.a,
                          "padding xform under .log must be rotated")
        // And match the same 90° formulas computed in testHandCheck90Degrees.
        let θ = 0.25 * 2 * Double.pi
        let cs = cos(θ), sn = sin(θ)
        let m = sheep.xforms[0].affine
        XCTAssertEqual(out.xforms[0].affine.a, cs * m.a - sn * m.b, accuracy: 1e-12)
        XCTAssertEqual(out.xforms[0].affine.d, sn * m.c + cs * m.d, accuracy: 1e-12)
    }

    // MARK: - 90° (t = 0.25) hand-check of R(π/2)·M
    // The math matrix M = [[a,c],[b,d]] (per AffineTransform.apply) has its COLUMNS
    // (a,b) and (c,d) each rotated by R(θ)=[[cos,-sin],[sin,cos]] — equivalently
    // flam3's mult_matrix (interpolation.c:110) computes U = T·R with storage
    // c[0][0]=a, c[0][1]=b, c[1][0]=c, c[1][1]=d.  Pinned:
    //   a' =  cos·a − sin·b
    //   b' =  sin·a + cos·b
    //   c' =  cos·c − sin·d
    //   d' =  sin·c + cos·d

    func testHandCheck90Degrees() {
        let sheep = Self.sampleFlame()
        let out = Loop.blend(sheep, t: 0.25)
        // θ = t * 2 * π  (NOT reduced mod 2π — pinned)
        let θ = 0.25 * 2 * Double.pi
        let cs = cos(θ), sn = sin(θ)
        let m = sheep.xforms[0].affine
        let r = out.xforms[0].affine
        XCTAssertEqual(r.a, cs * m.a - sn * m.b, accuracy: 1e-12)
        XCTAssertEqual(r.b, sn * m.a + cs * m.b, accuracy: 1e-12)
        XCTAssertEqual(r.c, cs * m.c - sn * m.d, accuracy: 1e-12)
        XCTAssertEqual(r.d, sn * m.c + cs * m.d, accuracy: 1e-12)
        // Sanity: at θ=π/2, cos≈0, sin≈1 ⇒ a'≈−b, b'≈a, c'≈−d, d'≈c.
        // (a=2, b=3, c=5, d=7 ⇒ a'=−3, b'=2, c'=−7, d'=5; accuracy 1e-12
        // absorbs the cos(π/2)≈6.1e-17 FP residual.)
        XCTAssertEqual(r.a, -m.b, accuracy: 1e-12)
        XCTAssertEqual(r.b,  m.a, accuracy: 1e-12)
        XCTAssertEqual(r.c, -m.d, accuracy: 1e-12)
        XCTAssertEqual(r.d,  m.c, accuracy: 1e-12)
    }

    // MARK: - does not mutate the input

    func testInputNotMutated() {
        let sheep = Self.sampleFlame()
        let snapshot = sheep
        _ = Loop.blend(sheep, t: 0.25)
        XCTAssertEqual(sheep, snapshot, "blend must not mutate its input (value semantics)")
    }
}
