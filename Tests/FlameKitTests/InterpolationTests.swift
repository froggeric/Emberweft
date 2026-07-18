import XCTest
@testable import FlameKit

final class InterpolationTests: XCTestCase {
    private func flame(_ c: Double, _ scale: Double, xformCount: Int = 1) -> Flame {
        Flame(camera: Camera(scale: scale),
              xforms: (0..<xformCount).map { _ in
                  Xform(affine: AffineTransform(a: c, b: 0, c: 0, d: c, e: 0, f: 0),
                        variations: [Variation(name: "linear", weight: 1)]) })
    }
    func testEndpoints() {
        let a = flame(1, 200), b = flame(2, 400)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 0), a)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 1), b)
    }
    func testMidpointCoeffs() {
        let a = flame(0, 200), b = flame(10, 200)
        let m = Interpolation.interpolate(a, b, at: 0.5)
        XCTAssertEqual(m.xforms[0].affine.a, 5, accuracy: 1e-6)
    }
    func testScaleLogSpace() {
        let a = flame(0, 100), b = flame(0, 400)
        let m = Interpolation.interpolate(a, b, at: 0.5)
        XCTAssertEqual(m.camera.scale, 200, accuracy: 1e-3)   // geometric mean
    }
    func testUnequalXformCounts() {
        let a = flame(1, 200, xformCount: 1), b = flame(2, 200, xformCount: 2)
        let m = Interpolation.interpolate(a, b, at: 0.5)
        XCTAssertEqual(m.xforms.count, 2)
    }
    func testExtraXformTakenUnchanged() {
        // Unequal counts: the extra xform must come through UNCHANGED from the longer side.
        let extra = Xform(affine: AffineTransform(a: 9, b: 0, c: 0, d: 9, e: 0, f: 0),
                          variations: [Variation(name: "spherical", weight: 2)])
        let a = flame(1, 200, xformCount: 1)
        var b = flame(2, 200, xformCount: 2)
        b.xforms[1] = extra
        let m = Interpolation.interpolate(a, b, at: 0.5)
        XCTAssertEqual(m.xforms.count, 2)
        XCTAssertEqual(m.xforms[1], extra)              // unchanged
    }
    func testEndpointsDifferInSizeAndQuality() {
        // Proves the Important fix: at t=1, size & quality come from b, not a.
        var a = flame(1, 200)
        var b = flame(2, 400)
        a.size = SIMD2<Int>(640, 480)
        b.size = SIMD2<Int>(320, 240)
        a.quality.samplesPerPixel = 10
        b.quality.samplesPerPixel = 90
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 0).size, a.size)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 0).quality, a.quality)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 1).size, b.size)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 1).quality, b.quality)
    }
    func testFinalXformAsymmetric() {
        var a = flame(1, 200)
        a.finalXform = Xform(variations: [Variation(name: "linear", weight: 1)])
        let b = flame(2, 400)
        // a has finalXform, b does not -> carried through (a.finalXform ?? b.finalXform).
        XCTAssertNotNil(Interpolation.interpolate(a, b, at: 0.5).finalXform)
        // b has none, a has one -> still carried through (b.finalXform ?? a.finalXform).
        XCTAssertNotNil(Interpolation.interpolate(b, a, at: 0.5).finalXform)
        // neither has one -> nil
        XCTAssertNil(Interpolation.interpolate(flame(1, 200), flame(2, 400), at: 0.5).finalXform)
    }

    // MARK: - GenomeInterpolator

    /// `.linear` must reproduce the legacy `Interpolation.interpolate` output exactly.
    func testLinearParityWithLegacyShim() {
        let a = flame(0, 200, xformCount: 2)
        let b = flame(10, 400, xformCount: 2)
        for t in [0.0, 0.13, 0.25, 0.5, 0.77, 0.91, 1.0] {
            let legacy = Interpolation.interpolate(a, b, at: t)
            let direct = GenomeInterpolator.interpolate(a, b, t: t, type: .linear)
            XCTAssertEqual(direct, legacy, "linear parity drift at t=\(t)")
        }
    }

    /// `.log` midpoint of a 0° -> 90° rotation pair must yield a 45° rotation.
    /// Hand-traced from `convert_linear_to_polar` + `interp_and_convert_back`.
    ///
    /// col0: (1,0)->ang=0,mag=1  ;  (0,1)->ang=π/2,mag=1  => accang=π/4, expmag=1
    /// col1: (0,1)->ang=π/2,mag=1 ; (-1,0)->ang=π,mag=1   => accang=3π/4, expmag=1
    /// result col0=(cos π/4, sin π/4)=(√2/2,√2/2); col1=(cos 3π/4,sin 3π/4)=(-√2/2,√2/2)
    func testLogMidpointRotationPair() {
        let rot0 = AffineTransform(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)   // 0°
        let rot90 = AffineTransform(a: 0, b: 1, c: -1, d: 0, e: 0, f: 0) // 90°
        let a = Flame(xforms: [Xform(affine: rot0, variations: [Variation(name: "linear", weight: 1)])])
        let b = Flame(xforms: [Xform(affine: rot90, variations: [Variation(name: "linear", weight: 1)])])
        let m = GenomeInterpolator.interpolate(a, b, t: 0.5, type: .log)
        let s = sqrt(2) / 2
        let af = m.xforms[0].affine
        XCTAssertEqual(af.a,  s,  accuracy: 1e-12)
        XCTAssertEqual(af.b,  s,  accuracy: 1e-12)
        XCTAssertEqual(af.c, -s,  accuracy: 1e-12)
        XCTAssertEqual(af.d,  s,  accuracy: 1e-12)
        XCTAssertEqual(af.e,  0,  accuracy: 1e-12)
        XCTAssertEqual(af.f,  0,  accuracy: 1e-12)
    }

    /// Near-degenerate affine: col0 magnitudes below the `log(mag) < -10` guard.
    /// Per-column magnitude fallback (interp_and_convert_back:214): col0 magnitude
    /// accumulates LINEARLY (accmag = 0.5·1e-6 + 0.5·2e-6 = 1.5e-6, expmag = accmag,
    /// NOT exp(accmag)); col1 is a normal log column. Result must be finite & match.
    func testLogPerColumnLinearMagnitudeFallback() {
        // col0 = (1e-6, 0), col1 = (1, 0)
        let a = Flame(xforms: [Xform(
            affine: AffineTransform(a: 1e-6, b: 0, c: 1, d: 0, e: 0, f: 0),
            variations: [Variation(name: "linear", weight: 1)])])
        let b = Flame(xforms: [Xform(
            affine: AffineTransform(a: 2e-6, b: 0, c: 1, d: 0, e: 0, f: 0),
            variations: [Variation(name: "linear", weight: 1)])])
        let m = GenomeInterpolator.interpolate(a, b, t: 0.5, type: .log)
        let af = m.xforms[0].affine
        // Finite (no NaN/Inf).
        XCTAssertTrue(af.a.isFinite, "a not finite")
        XCTAssertTrue(af.b.isFinite, "b not finite")
        XCTAssertTrue(af.c.isFinite, "c not finite")
        XCTAssertTrue(af.d.isFinite, "d not finite")
        // col0 linear magnitude fallback -> 1.5e-6 at angle 0.
        XCTAssertEqual(af.a, 1.5e-6, accuracy: 1e-18)
        XCTAssertEqual(af.b, 0.0,     accuracy: 1e-18)
        // col1 normal log path: mag 1 -> expmag 1 at angle 0.
        XCTAssertEqual(af.c, 1.0, accuracy: 1e-15)
        XCTAssertEqual(af.d, 0.0, accuracy: 1e-15)
    }

    /// Post-identity special case (flam3_interpolate_n:668): when both parents' post
    /// is the identity, the result post is forced to identity even under `.log`.
    func testLogPostIdentitySpecialCase() {
        let a = Flame(xforms: [Xform(
            affine: AffineTransform(a: 2, b: 0, c: 0, d: 2, e: 1, f: 1),
            postAffine: .identity,
            variations: [Variation(name: "linear", weight: 1)])])
        let b = Flame(xforms: [Xform(
            affine: AffineTransform(a: 3, b: 0, c: 0, d: 3, e: 2, f: 2),
            postAffine: .identity,
            variations: [Variation(name: "linear", weight: 1)])])
        let m = GenomeInterpolator.interpolate(a, b, t: 0.5, type: .log)
        XCTAssertEqual(m.xforms[0].postAffine, .identity)
    }

    /// When post is NOT identity in `.log` mode, it polar-blends (sanity: not forced).
    func testLogPostNonIdentityPolarBlends() {
        let a = Flame(xforms: [Xform(
            affine: .identity,
            postAffine: AffineTransform(a: 1, b: 0, c: 0, d: 1, e: 5, f: 0),
            variations: [Variation(name: "linear", weight: 1)])])
        let b = Flame(xforms: [Xform(
            affine: .identity,
            postAffine: AffineTransform(a: 1, b: 0, c: 0, d: 1, e: 0, f: 5),
            variations: [Variation(name: "linear", weight: 1)])])
        let m = GenomeInterpolator.interpolate(a, b, t: 0.5, type: .log)
        // Translation interpolates linearly -> (2.5, 2.5).
        XCTAssertEqual(m.xforms[0].postAffine.e, 2.5, accuracy: 1e-12)
        XCTAssertEqual(m.xforms[0].postAffine.f, 2.5, accuracy: 1e-12)
    }

    /// Merge split: `.log` unions variations by name, preserves zero-weight slots,
    /// and carries per-name parameters from whichever side defines them.
    func testLogMergeUnionPreservesZeroAndCarriesParams() {
        let a = Flame(xforms: [Xform(variations: [
            Variation(name: "linear",    weight: 1, parameters: ["x": 5]),
            Variation(name: "spherical", weight: 0, parameters: ["q": 9]),
        ])])
        let b = Flame(xforms: [Xform(variations: [
            Variation(name: "spherical", weight: 0, parameters: ["y": 7]),
        ])])
        let m = GenomeInterpolator.interpolate(a, b, t: 0.5, type: .log)
        let vs = m.xforms[0].variations
        XCTAssertEqual(vs.count, 2)                         // union, both kept
        XCTAssertEqual(vs[0].name, "linear")                // sorted by name
        XCTAssertEqual(vs[0].weight, 0.5, accuracy: 1e-12)
        XCTAssertEqual(vs[0].parameters["x"], 5)            // carried from a
        XCTAssertEqual(vs[1].name, "spherical")
        XCTAssertEqual(vs[1].weight, 0.0, accuracy: 1e-12)  // zero-weight preserved
        XCTAssertEqual(vs[1].parameters["q"], 9)            // carried from a
        XCTAssertEqual(vs[1].parameters["y"], 7)            // carried from b
    }

    /// Merge split: `.linear` uses the legacy merge (drop-zero-weight + sort-by-name)
    /// and does NOT carry parameters.
    func testLinearMergeDropsZeroAndIgnoresParams() {
        let a = Flame(xforms: [Xform(variations: [
            Variation(name: "linear",    weight: 1, parameters: ["x": 5]),
            Variation(name: "spherical", weight: 0, parameters: ["q": 9]),
        ])])
        let b = Flame(xforms: [Xform(variations: [
            Variation(name: "spherical", weight: 0, parameters: ["y": 7]),
        ])])
        let m = GenomeInterpolator.interpolate(a, b, t: 0.5, type: .linear)
        let vs = m.xforms[0].variations
        XCTAssertEqual(vs.count, 1)                         // zero-weight dropped
        XCTAssertEqual(vs[0].name, "linear")
        XCTAssertEqual(vs[0].weight, 0.5, accuracy: 1e-12)
        XCTAssertTrue(vs[0].parameters.isEmpty)             // legacy: no param carry
    }
}
