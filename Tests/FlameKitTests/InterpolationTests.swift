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

    /// Quality display-pipeline fields (brightness/gamma/vibrancy/etc.) must
    /// be linearly interpolated across the blend, matching flam3's
    /// `INTERP(brightness)`, `INTERP(gamma)`, … block (interpolation.c:473-501).
    /// Previously the whole `Quality` struct was hard-cut at `t < 0.5`, which
    /// made brightness jump discontinuously at the midpoint whenever two
    /// keyframes carried different values (real ES genomes do: e.g. seg3
    /// 02632 brightness=19.13 → 15729 brightness=4) — a uniform colour pop
    /// with no shape change (Class A "mid-transition colour/intensity jump").
    /// This test pins the faithful interpolation.
    func testQualityFieldsInterpolatedNotHardCut() {
        var a = flame(1, 200)
        var b = flame(2, 400)
        a.quality.brightness = 19.0
        b.quality.brightness = 4.0
        a.quality.gamma = 3.0
        b.quality.gamma = 4.0
        a.quality.vibrancy = 0.5
        b.quality.vibrancy = 1.0
        a.quality.highlightPower = -1.0
        b.quality.highlightPower = 1.0
        a.quality.gammaThreshold = 0.0
        b.quality.gammaThreshold = 0.05
        a.quality.filterRadius = 0.5
        b.quality.filterRadius = 1.5
        a.quality.estimatorRadius = 9.0
        b.quality.estimatorRadius = 11.0
        a.quality.samplesPerPixel = 100
        b.quality.samplesPerPixel = 200

        // Endpoints reproduce the parents exactly (interpolation reduces to a/b).
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 0).quality, a.quality)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 1).quality, b.quality)

        // Midpoint is the linear average — NOT a's, NOT b's (the old hard-cut
        // returned a.quality for all t < 0.5, so midpoint brightness was 19.0).
        let mid = Interpolation.interpolate(a, b, at: 0.5).quality
        XCTAssertEqual(mid.brightness, 11.5, accuracy: 1e-12)
        XCTAssertEqual(mid.gamma, 3.5, accuracy: 1e-12)
        XCTAssertEqual(mid.vibrancy, 0.75, accuracy: 1e-12)
        XCTAssertEqual(mid.highlightPower, 0.0, accuracy: 1e-12)
        XCTAssertEqual(mid.gammaThreshold, 0.025, accuracy: 1e-12)
        XCTAssertEqual(mid.filterRadius, 1.0, accuracy: 1e-12)
        XCTAssertEqual(mid.estimatorRadius, 10.0, accuracy: 1e-12)
        XCTAssertEqual(mid.samplesPerPixel, 150)   // (100+200)/2, rounded

        // Quarter-point skews toward a (faithful linear interp).
        let q = Interpolation.interpolate(a, b, at: 0.25).quality
        XCTAssertEqual(q.brightness, 15.25, accuracy: 1e-12)   // 19*0.75 + 4*0.25
        XCTAssertEqual(q.gamma, 3.25, accuracy: 1e-12)

        // Enum / structural fields stay copied from a (flam3 cpi[0] rule).
        a.quality.temporalSamples = 7
        b.quality.temporalSamples = 13
        a.quality.oversample = 2
        b.quality.oversample = 4
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 0.5).quality.temporalSamples, 7)
        XCTAssertEqual(Interpolation.interpolate(a, b, at: 0.5).quality.oversample, 2)
    }

    /// A2 seamless divergence: when A and B affines have opposite handedness
    /// (`det(A)·det(B) < 0`), the `.log` polar interp would cross det=0 at
    /// the midpoint (collapsing 2D→1D for that xform). The fix falls back to
    /// `.linear` (`lerpAffine`) for opposite-handedness pairs. This test
    /// pins the divergence using the exact seg9 xform[5] matrices (a
    /// det=−1 reflection and a det=+1 rotation that previously produced
    /// det=2.2e−16 at t=0.5).
    ///
    /// Note: `Interpolation.interpolate` is a `.linear`-only shim, so to
    /// exercise the `.log` path we must call `GenomeInterpolator.interpolate`
    /// with `type: .log` directly.
    func testLogAffineOppositeHandednessFallsBackToLinear() {
        // A xform[5] of 08031: coefs="-1 0 0 1 0 0" — det = -1.
        let a = AffineTransform(a: -1, b: 0, c: 0, d: 1, e: 0, f: 0)
        // B xform[5] of 21790: coefs="0.935016 0.354605 -0.354605 0.935016 0 0" — det ≈ +1.
        let b = AffineTransform(a: 0.935016, b: 0.354605, c: -0.354605, d: 0.935016, e: 0, f: 0)
        let xa = Xform(affine: a, variations: [Variation(name: "linear", weight: 1)])
        let xb = Xform(affine: b, variations: [Variation(name: "linear", weight: 1)])
        let fa = Flame(xforms: [xa], interpolationType: .log)
        let fb = Flame(xforms: [xb], interpolationType: .log)
        // Use the .log path directly (Interpolation.interpolate uses .linear).
        let mid = GenomeInterpolator.interpolate(fa, fb, t: 0.5, type: .log)
        let m = mid.xforms[0].affine
        // The fallback returns lerpAffine(a, b, 0.5) exactly — pin every coef.
        let expectedA = (1 - 0.5) * a.a + 0.5 * b.a
        let expectedB = (1 - 0.5) * a.b + 0.5 * b.b
        let expectedC = (1 - 0.5) * a.c + 0.5 * b.c
        let expectedD = (1 - 0.5) * a.d + 0.5 * b.d
        XCTAssertEqual(m.a, expectedA, accuracy: 1e-12, "fallback should use lerpAffine (a)")
        XCTAssertEqual(m.b, expectedB, accuracy: 1e-12, "fallback should use lerpAffine (b)")
        XCTAssertEqual(m.c, expectedC, accuracy: 1e-12, "fallback should use lerpAffine (c)")
        XCTAssertEqual(m.d, expectedD, accuracy: 1e-12, "fallback should use lerpAffine (d)")
        // Sanity: the result is NOT the polar midpoint (which had identical
        // columns at t=0.5 for this pair). m.a should NOT equal m.c.
        XCTAssertNotEqual(m.a, m.c, accuracy: 1e-9,
            "fallback must avoid the polar path's coincident-column singularity")
    }

    /// A2 same-handedness pairs are unaffected by the determinant guard —
    /// they still use the polar `.log` path byte-identically to flam3.
    func testLogAffineSameHandednessUnaffectedByDetGuard() {
        // Both det = +1 (rotations) — polar interp should be used.
        let a = AffineTransform(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)              // det = +1
        let b = AffineTransform(a: 0, b: 1, c: -1, d: 0, e: 0, f: 0)             // det = +1
        let xa = Xform(affine: a, variations: [Variation(name: "linear", weight: 1)])
        let xb = Xform(affine: b, variations: [Variation(name: "linear", weight: 1)])
        let fa = Flame(xforms: [xa], interpolationType: .log)
        let fb = Flame(xforms: [xb], interpolationType: .log)
        let mid = GenomeInterpolator.interpolate(fa, fb, t: 0.5, type: .log)
        let m = mid.xforms[0].affine
        // The result should NOT equal lerpAffine(a, b, 0.5) (which would give
        // a = 0.5, b = 0.5, c = -0.5, d = 0.5). Instead it's the polar interp,
        // which for two rotations produces a rotation by the midpoint angle.
        // Polar interp of identity (col angles 0, π/2) and 90° rotation
        // (col angles π/2, π): midpoint angles π/4 and 3π/4.
        //   col0 = (cos(π/4), sin(π/4)) ≈ (0.7071, 0.7071)
        //   col1 = (cos(3π/4), sin(3π/4)) ≈ (-0.7071, 0.7071)
        // After the per-frame rotation (Transition's step 6 rotates by t·360°;
        // GenomeInterpolator doesn't), this is the .log-path midpoint.
        XCTAssertNotEqual(m.a, 0.5, accuracy: 1e-9,
            "same-handedness should NOT use lerpAffine fallback")
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

    /// `.linear` must reproduce the legacy `Interpolation.interpolate` output
    /// exactly. NOTE: `Interpolation.interpolate` is a shim that delegates to
    /// `GenomeInterpolator.interpolate(..., type: .linear)`, so this is a smoke
    /// test that the shim + the no-param `flame()` factory stay stable — it is
    /// NOT a flam3 faithfulness proof (the `.linear` merge is exercised directly
    /// by `testLinearMergeInterpolatesParams` / `testLinearMergeAtOneReturnsBParams`).
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
    /// and **linearly interpolates** per-name parameters (faithful to flam3's
    /// `INTERP(x)` macro applied per parametric field in `flam3_interpolate_n`).
    /// When one side lacks a parameter, the descriptor default is used; for
    /// unknown/synthetic parameters the default is 0.
    func testLogMergeUnionPreservesZeroAndInterpolatesParams() {
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
        // x: a has 5, b lacks it → default 0 → linear interp 0.5*5 + 0.5*0 = 2.5
        XCTAssertEqual(vs[0].parameters["x"] ?? .nan, 2.5, accuracy: 1e-12)
        XCTAssertEqual(vs[1].name, "spherical")
        XCTAssertEqual(vs[1].weight, 0.0, accuracy: 1e-12)  // zero-weight preserved
        // q: a has 9, b lacks it → 0.5*9 + 0.5*0 = 4.5
        XCTAssertEqual(vs[1].parameters["q"] ?? .nan, 4.5, accuracy: 1e-12)
        // y: a lacks it (0), b has 7 → 0.5*0 + 0.5*7 = 3.5
        XCTAssertEqual(vs[1].parameters["y"] ?? .nan, 3.5, accuracy: 1e-12)
    }

    /// `.log` per-param interpolation: at t=1 the result carries B's parametric
    /// values, not A's (regression test for the transition-endpoint bug where
    /// A's `curl_c1` bled into the result and produced an active curl final
    /// endpoint when raw B had no final xform).
    func testLogMergeAtOneReturnsBParams() {
        let a = Flame(xforms: [Xform(variations: [
            Variation(name: "curl", weight: 1, parameters: ["curl_c1": 0.5, "curl_c2": 0.0]),
        ])])
        let b = Flame(xforms: [Xform(variations: [
            Variation(name: "curl", weight: 1, parameters: ["curl_c1": 0.0, "curl_c2": 0.0]),
        ])])
        let m = GenomeInterpolator.interpolate(a, b, t: 1.0, type: .log)
        let vs = m.xforms[0].variations
        XCTAssertEqual(vs.count, 1)
        XCTAssertEqual(vs[0].name, "curl")
        XCTAssertEqual(vs[0].weight, 1.0, accuracy: 1e-12)
        XCTAssertEqual(vs[0].parameters["curl_c1"] ?? .nan, 0.0, accuracy: 1e-12)   // B's value, not A's 0.5
        XCTAssertEqual(vs[0].parameters["curl_c2"] ?? .nan, 0.0, accuracy: 1e-12)
    }

    /// Merge: `.linear` now uses the SAME variation merge as `.log` (union by
    /// name, zero-weight slots preserved, per-param linear interpolation).
    /// Faithful to flam3 — in `flam3_interpolate_n` (interpolation.c:543-655)
    /// the parametric INTERPs and the `INTERP(xform[i].var[j])` loop execute
    /// BEFORE the `.log`/`.linear` matrix branch (line 657), so variation
    /// handling is identical for both types. Regression coverage for the
    /// pre-fix `mergeLinear`, which dropped ALL parameters and filtered
    /// zero-weight entries (no flam3 basis).
    func testLinearMergeInterpolatesParams() {
        let a = Flame(xforms: [Xform(variations: [
            Variation(name: "linear",    weight: 1, parameters: ["x": 5]),
            Variation(name: "spherical", weight: 0, parameters: ["q": 9]),
        ])])
        let b = Flame(xforms: [Xform(variations: [
            Variation(name: "spherical", weight: 0, parameters: ["y": 7]),
        ])])
        let m = GenomeInterpolator.interpolate(a, b, t: 0.5, type: .linear)
        let vs = m.xforms[0].variations
        XCTAssertEqual(vs.count, 2)                         // union, both kept
        XCTAssertEqual(vs[0].name, "linear")                // sorted by name
        XCTAssertEqual(vs[0].weight, 0.5, accuracy: 1e-12)
        // x: a has 5, b lacks it → default 0 → 0.5*5 + 0.5*0 = 2.5
        XCTAssertEqual(vs[0].parameters["x"] ?? .nan, 2.5, accuracy: 1e-12)
        XCTAssertEqual(vs[1].name, "spherical")
        XCTAssertEqual(vs[1].weight, 0.0, accuracy: 1e-12)  // zero-weight preserved
        // q: a has 9, b lacks it → 0.5*9 + 0.5*0 = 4.5
        XCTAssertEqual(vs[1].parameters["q"] ?? .nan, 4.5, accuracy: 1e-12)
        // y: a lacks it (0), b has 7 → 0.5*0 + 0.5*7 = 3.5
        XCTAssertEqual(vs[1].parameters["y"] ?? .nan, 3.5, accuracy: 1e-12)
    }

    /// `.linear` per-param interpolation: at t=1 the result carries B's
    /// parametric values, not A's. Mirrors `testLogMergeAtOneReturnsBParams`
    /// — regression for the pre-fix `mergeLinear`, which dropped params
    /// entirely so a `.linear` transition into a parametric-variation
    /// endpoint lost the endpoint's params at the renderer.
    func testLinearMergeAtOneReturnsBParams() {
        let a = Flame(xforms: [Xform(variations: [
            Variation(name: "curl", weight: 1, parameters: ["curl_c1": 0.5, "curl_c2": 0.0]),
        ])])
        let b = Flame(xforms: [Xform(variations: [
            Variation(name: "curl", weight: 1, parameters: ["curl_c1": 0.25, "curl_c2": 0.1]),
        ])])
        let m = GenomeInterpolator.interpolate(a, b, t: 1.0, type: .linear)
        let vs = m.xforms[0].variations
        XCTAssertEqual(vs.count, 1)
        XCTAssertEqual(vs[0].name, "curl")
        XCTAssertEqual(vs[0].weight, 1.0, accuracy: 1e-12)
        XCTAssertEqual(vs[0].parameters["curl_c1"] ?? .nan, 0.25, accuracy: 1e-12)  // B's value
        XCTAssertEqual(vs[0].parameters["curl_c2"] ?? .nan, 0.1,  accuracy: 1e-12)  // B's value
    }

    /// `.linear` and `.log` produce IDENTICAL variation merges on the same
    /// inputs — direct evidence the consolidation is faithful (flam3's param
    /// INTERPs at interpolation.c:543-655 precede the type branch at 657).
    /// Only the affine/post matrices may differ between the two modes.
    func testLinearAndLogMergeIdentically() {
        let a = Flame(xforms: [Xform(variations: [
            Variation(name: "curl",    weight: 0.7, parameters: ["curl_c1": 0.3, "curl_c2": 0.4]),
            Variation(name: "julian",  weight: 0.3, parameters: ["julian_power": 4, "julian_dist": 1.0]),
        ])])
        let b = Flame(xforms: [Xform(variations: [
            Variation(name: "curl",    weight: 0.4, parameters: ["curl_c1": 0.9, "curl_c2": 0.1]),
            Variation(name: "spherical", weight: 0.6),
        ])])
        let lin = GenomeInterpolator.interpolate(a, b, t: 0.35, type: .linear).xforms[0].variations
        let log = GenomeInterpolator.interpolate(a, b, t: 0.35, type: .log).xforms[0].variations
        XCTAssertEqual(lin.count, log.count, "linear and log must union the same names")
        for (l, g) in zip(lin, log) {
            XCTAssertEqual(l.name, g.name)
            XCTAssertEqual(l.weight, g.weight, accuracy: 1e-12)
            XCTAssertEqual(l.parameters.count, g.parameters.count)
            for (k, v) in l.parameters {
                XCTAssertEqual(g.parameters[k] ?? .nan, v, accuracy: 1e-12,
                               "param \(k) drift between .linear and .log")
            }
        }
    }
}
