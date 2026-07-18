import XCTest
@testable import FlameKit

/// Port-fidelity tests for `SpecialSauce.align` (flam3_align, interpolation.c:768-1032).
///
/// Each test traces the C, not the implementation: the padding xform's final
/// state is derived from flam3_align's pad → parametric-copy → rest-position
/// (Group A/B/C + linear fallback) → renormalize sequence. Expectations are
/// recomputed here independently.
final class SpecialSauceTests: XCTestCase {

    // MARK: - helpers

    private func linear(_ w: Double = 1) -> Xform {
        Xform(affine: .identity, variations: [Variation(name: "linear", weight: w)])
    }

    private func make(_ regular: [Xform], final: Xform? = nil,
                      type: MatrixInterpolationType = .log) -> Flame {
        var f = Flame()
        f.xforms = regular
        f.finalXform = final
        f.interpolationType = type
        return f
    }

    private func weight(_ x: Xform, _ name: String) -> Double {
        x.variations.first { $0.name == name }?.weight ?? 0
    }

    private func params(_ x: Xform, _ name: String) -> [String: Double] {
        x.variations.first { $0.name == name }?.parameters ?? [:]
    }

    /// Non-optional param accessor (returns .nan if absent so the assert fails).
    private func param(_ x: Xform, _ variation: String, _ key: String) -> Double {
        params(x, variation)[key] ?? .nan
    }

    // MARK: - count padding

    func testPadsToEqualRegularXformCount() {
        // A: 2 regular, B: 3 regular → both 3 after align.
        let a = make([linear(), linear()])
        let b = make([linear(), linear(), linear()])
        let (ra, rb) = SpecialSauce.align(a, b, interpolationType: .log)
        XCTAssertEqual(ra.xforms.count, 3)
        XCTAssertEqual(rb.xforms.count, 3)
        XCTAssertEqual(ra.xforms[2].padding, 1)   // newly padded slot
        XCTAssertEqual(rb.xforms[2].padding, 0)   // original
    }

    func testPadsFinalXformPresence() {
        let a = make([linear(), linear()])                         // no final
        let b = make([linear(), linear()], final: linear())        // has final
        let (ra, rb) = SpecialSauce.align(a, b, interpolationType: .log)
        XCTAssertNotNil(ra.finalXform)   // padded in
        XCTAssertNotNil(rb.finalXform)
        XCTAssertEqual(ra.finalXform!.padding, 1)
    }

    // MARK: - default (linear fallback)

    func testDefaultRestPositionIsLinearOne() {
        // Neighbor B[2] has only julia (not in any group) → default → linear=1.
        let a = make([linear(), linear()])
        let b = make([linear(), linear(),
                      Xform(affine: .identity, variations: [Variation(name: "julia", weight: 1)])])
        let (ra, _) = SpecialSauce.align(a, b, interpolationType: .log)
        let pad = ra.xforms[2]
        XCTAssertEqual(weight(pad, "linear"), 1.0, accuracy: 1e-12)
        XCTAssertEqual(pad.affine, .identity)
    }

    // MARK: - Group B (blob): var=1 + rest params, renormalized

    func testGroupBBlobRestPosition() {
        // Neighbor B[2] has blob → padded A[2] gets blob (param-copy) then Group-B
        // rest (weight=1, low=high=waves=1), renormalized.
        let a = make([linear(), linear()])
        let b = make([linear(), linear(), Xform(affine: .identity, variations: [
            Variation(name: "blob", weight: 1.0,
                      parameters: ["blob_low": 0.2, "blob_high": 0.8, "blob_waves": 3.0])
        ])])
        let (ra, _) = SpecialSauce.align(a, b, interpolationType: .log)
        let pad = ra.xforms[2]
        XCTAssertEqual(weight(pad, "blob"), 1.0, accuracy: 1e-12)      // single match → renorm keeps 1
        // REST values overwrite the copied neighbor params (flam3_align:935-941).
        XCTAssertEqual(param(pad, "blob", "blob_low"), 1.0, accuracy: 1e-12)
        XCTAssertEqual(param(pad, "blob", "blob_high"), 1.0, accuracy: 1e-12)
        XCTAssertEqual(param(pad, "blob", "blob_waves"), 1.0, accuracy: 1e-12)
        XCTAssertEqual(weight(pad, "linear"), 0.0, accuracy: 1e-12)    // removed, not re-added
        // Not Group C → identity coefs.
        XCTAssertEqual(pad.affine, .identity)
    }

    func testGroupBRenormalizesWhenMultipleMatches() {
        // Neighbor B[2] has blob AND curl → both set to 1 → renorm → 0.5 each.
        let a = make([linear(), linear()])
        let b = make([linear(), linear(), Xform(affine: .identity, variations: [
            Variation(name: "blob", weight: 0.7,
                      parameters: VariationDescriptor.descriptor(for: "blob")!.defaults),
            Variation(name: "curl", weight: 0.4,
                      parameters: VariationDescriptor.descriptor(for: "curl")!.defaults)
        ])])
        let (ra, _) = SpecialSauce.align(a, b, interpolationType: .log)
        let pad = ra.xforms[2]
        XCTAssertEqual(weight(pad, "blob"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(weight(pad, "curl"), 0.5, accuracy: 1e-12)
        // curl rest: c1=c2=0
        XCTAssertEqual(param(pad, "curl", "curl_c1"), 0.0, accuracy: 1e-12)
        XCTAssertEqual(param(pad, "curl", "curl_c2"), 0.0, accuracy: 1e-12)
    }

    // MARK: - Group A (spherical): linear=-1, rotated identity, NOT renormalized (log only)

    func testGroupARotatedIdentityNotRenormalized() {
        let a = make([linear(), linear()])
        let b = make([linear(), linear(),
                      Xform(affine: .identity, variations: [Variation(name: "spherical", weight: 1)])])
        let (ra, _) = SpecialSauce.align(a, b, interpolationType: .log)
        let pad = ra.xforms[2]
        XCTAssertEqual(weight(pad, "linear"), -1.0, accuracy: 1e-12)   // 180° rotated identity
        XCTAssertEqual(pad.affine, AffineTransform(a: -1, b: 0, c: 0, d: -1, e: 0, f: 0))
        // fnd=-1 → NOT renormalized: linear stays exactly -1 (not divided by sum).
        XCTAssertEqual(weight(pad, "linear"), -1.0, accuracy: 1e-12)
    }

    func testGroupAOnlyAppliesUnderLog() {
        // Under .linear, Group A is gated off → default linear=1.
        let a = make([linear(), linear()])
        let b = make([linear(), linear(),
                      Xform(affine: .identity, variations: [Variation(name: "spherical", weight: 1)])])
        let (ra, _) = SpecialSauce.align(a, b, interpolationType: .linear)
        let pad = ra.xforms[2]
        XCTAssertEqual(weight(pad, "linear"), 1.0, accuracy: 1e-12)
        XCTAssertEqual(weight(pad, "spherical"), 0.0, accuracy: 1e-12)
    }

    // MARK: - Group C (fan/rings): var=1 + swap-affine, renormalized

    func testGroupCFanSwapAffineRenormalized() {
        let a = make([linear(), linear()])
        let b = make([linear(), linear(),
                      Xform(affine: .identity, variations: [Variation(name: "fan", weight: 1)])])
        let (ra, _) = SpecialSauce.align(a, b, interpolationType: .log)
        let pad = ra.xforms[2]
        XCTAssertEqual(weight(pad, "fan"), 1.0, accuracy: 1e-12)
        // swap-affine [0,1;1,0;0,0] (flam3_align:1003-1008)
        XCTAssertEqual(pad.affine, AffineTransform(a: 0, b: 1, c: 1, d: 0, e: 0, f: 0))
    }

    // MARK: - compat/older early return

    func testCompatSkipsRestPositionEntirely() {
        // compat → early return (flam3_align:801-803): padding xform keeps linear=1.
        let a = make([linear(), linear()])
        let b = make([linear(), linear(),
                      Xform(affine: .identity, variations: [Variation(name: "blob", weight: 1,
                      parameters: VariationDescriptor.descriptor(for: "blob")!.defaults)])])
        let (ra, _) = SpecialSauce.align(a, b, interpolationType: .compat)
        let pad = ra.xforms[2]
        XCTAssertEqual(weight(pad, "linear"), 1.0, accuracy: 1e-12)
        XCTAssertEqual(weight(pad, "blob"), 0.0, accuracy: 1e-12)
    }

    // MARK: - parametric-param copy (visible via Group A julian: params copied, weight 0)

    func testParametricParamCopyFromNeighbor() {
        // Neighbor B[2] has julian (parametric + Group A). Padding A[2]:
        //   step 1 copies julian_power/dist from B (weight stays 0),
        //   step 2 Group A sets linear=-1 (julian weight untouched).
        let a = make([linear(), linear()])
        let b = make([linear(), linear(), Xform(affine: .identity, variations: [
            Variation(name: "julian", weight: 2.0,
                      parameters: ["julian_power": 5.0, "julian_dist": 0.7])
        ])])
        let (ra, _) = SpecialSauce.align(a, b, interpolationType: .log)
        let pad = ra.xforms[2]
        XCTAssertEqual(weight(pad, "linear"), -1.0, accuracy: 1e-12)
        XCTAssertEqual(weight(pad, "julian"), 0.0, accuracy: 1e-12)   // weight NOT set by Group A
        // params copied from neighbor (flam3_copy_params via align:829)
        XCTAssertEqual(param(pad, "julian", "julian_power"), 5.0, accuracy: 1e-12)
        XCTAssertEqual(param(pad, "julian", "julian_dist"), 0.7, accuracy: 1e-12)
    }

    // MARK: - KEPT params (perspective dist, super_shape m) preserved from copy

    func testSuperShapeKeepsMFromNeighborCopy() {
        // Neighbor B[2] super_shape with m=4. Padding A[2]:
        //   step 1 copies ALL params (m=4, n1=0.3, ...),
        //   step 2 Group B sets weight=1 + rest (n1=n2=n3=2, rnd=holes=0); m KEPT.
        let a = make([linear(), linear()])
        let b = make([linear(), linear(), Xform(affine: .identity, variations: [
            Variation(name: "super_shape", weight: 1.0, parameters: [
                "super_shape_rnd": 0.6, "super_shape_m": 4.0,
                "super_shape_n1": 0.3, "super_shape_n2": 0.4, "super_shape_n3": 0.5,
                "super_shape_holes": 0.7
            ])
        ])])
        let (ra, _) = SpecialSauce.align(a, b, interpolationType: .log)
        let pad = ra.xforms[2]
        XCTAssertEqual(weight(pad, "super_shape"), 1.0, accuracy: 1e-12)
        XCTAssertEqual(param(pad, "super_shape", "super_shape_n1"), 2.0, accuracy: 1e-12)
        XCTAssertEqual(param(pad, "super_shape", "super_shape_n2"), 2.0, accuracy: 1e-12)
        XCTAssertEqual(param(pad, "super_shape", "super_shape_n3"), 2.0, accuracy: 1e-12)
        XCTAssertEqual(param(pad, "super_shape", "super_shape_rnd"), 0.0, accuracy: 1e-12)
        XCTAssertEqual(param(pad, "super_shape", "super_shape_holes"), 0.0, accuracy: 1e-12)
        // m KEPT (flam3_align:962 "Keep supershape_m the same") — stays at copied 4.0
        XCTAssertEqual(param(pad, "super_shape", "super_shape_m"), 4.0, accuracy: 1e-12)
    }

    func testPerspectiveKeepsDistFromNeighborCopy() {
        let a = make([linear(), linear()])
        let b = make([linear(), linear(), Xform(affine: .identity, variations: [
            Variation(name: "perspective", weight: 1.0, parameters: [
                "perspective_angle": 1.1, "perspective_dist": 2.5
            ])
        ])])
        let (ra, _) = SpecialSauce.align(a, b, interpolationType: .log)
        let pad = ra.xforms[2]
        XCTAssertEqual(weight(pad, "perspective"), 1.0, accuracy: 1e-12)
        XCTAssertEqual(param(pad, "perspective", "perspective_angle"), 0.0, accuracy: 1e-12)  // rest override
        XCTAssertEqual(param(pad, "perspective", "perspective_dist"), 2.5, accuracy: 1e-12)   // KEPT (flam3_align:947)
    }
}
