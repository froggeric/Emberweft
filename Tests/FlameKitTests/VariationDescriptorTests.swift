import XCTest
@testable import FlameKit

final class VariationDescriptorTests: XCTestCase {
    func testBlobParams() {
        let d = VariationDescriptor.descriptor(for: "blob")!
        XCTAssertEqual(d.parameters, ["blob_low", "blob_high", "blob_waves"])
        XCTAssertEqual(d.defaults, ["blob_low": 0.0, "blob_high": 1.0, "blob_waves": 1.0])
        XCTAssertEqual(d.rest, ["blob_low": 1.0, "blob_high": 1.0, "blob_waves": 1.0]) // Group B
    }
    func testSuperShapeSlots() {
        let d = VariationDescriptor.descriptor(for: "super_shape")!
        XCTAssertEqual(d.parameters,
            ["super_shape_rnd", "super_shape_m", "super_shape_n1", "super_shape_n2", "super_shape_n3", "super_shape_holes"])
        XCTAssertEqual(VariationDescriptor.slotIndex(variation: "super_shape", param: "super_shape_n3"), 4)
        XCTAssertEqual(d.parameters.count, 6)  // MAX_PARAMS_PER_SLOT driver
        XCTAssertEqual(VariationDescriptor.maxParamsPerSlot,
                       VariationDescriptor.descriptor(for: "super_shape")!.parameters.count,
                       "maxParamsPerSlot is driven by super_shape's param count")
    }
    func testParameterless() {
        for name in ["linear", "spherical", "polar", "rings", "fan"] {
            XCTAssertTrue(VariationDescriptor.descriptor(for: name)!.parameters.isEmpty, name)
        }
    }
    func testGroupCRestUsesSwapAffineNotParams() {
        // fan/rings (Group C): var=1 + swap-affine [0,1;1,0;0,0]; NO param rest.
        XCTAssertTrue(VariationDescriptor.descriptor(for: "fan")!.parameters.isEmpty)
        XCTAssertTrue(VariationDescriptor.descriptor(for: "rings")!.parameters.isEmpty)
    }
    func testAllSixteenPresent() {
        let names = ["spherical","polar","rings","fan","blob","fan2","rings2","perspective",
                     "julian","juliascope","ngon","curl","rectangles","super_shape","wedge_julia","wedge_sph"]
        for n in names { XCTAssertNotNil(VariationDescriptor.descriptor(for: n), n) }
    }
    func testCanonicalOrderIsSingleAuthority() {
        XCTAssertEqual(VariationDescriptor.canonicalOrder.count, 42)
        XCTAssertEqual(Set(VariationDescriptor.canonicalOrder).count, 42, "duplicate canonical name")
        // spherical/polar counted ONCE (spec's "35" double-counted them; faithful = 35).
        XCTAssertEqual(VariationDescriptor.canonicalOrder.filter { $0 == "spherical" }.count, 1)
        XCTAssertEqual(VariationDescriptor.canonicalOrder.filter { $0 == "polar" }.count, 1)
        // Every canonical name resolves to a descriptor + a slot index.
        for n in VariationDescriptor.canonicalOrder {
            XCTAssertNotNil(VariationDescriptor.descriptor(for: n), n)
            XCTAssertNotNil(VariationDescriptor.canonicalSlot(for: n), n)
        }
        // The 14 NEW special-sauce names are all present (the 16 minus spherical/polar).
        let newOnes = ["rings","fan","blob","fan2","rings2","perspective","julian","juliascope",
                       "ngon","curl","rectangles","super_shape","wedge_julia","wedge_sph"]
        for n in newOnes { XCTAssertNotNil(VariationDescriptor.canonicalSlot(for: n), n) }
    }

    /// Lock down the full parametric table (params order + every default + every rest
    /// value). Defaults/rest are load-bearing: they drive the special-sauce padding
    /// (flam3_align) applied later in M3, so a silent change here must fail here.
    func testParametricTableFullyAsserted() {
        // (name, params, defaults, rest)
        let expected: [(String, [String], [String: Double], [String: Double])] = [
            ("blob", ["blob_low","blob_high","blob_waves"],
                ["blob_low":0,"blob_high":1,"blob_waves":1],
                ["blob_low":1,"blob_high":1,"blob_waves":1]),
            ("curl", ["curl_c1","curl_c2"], ["curl_c1":1,"curl_c2":0], ["curl_c1":0,"curl_c2":0]),
            ("rectangles", ["rectangles_x","rectangles_y"], ["rectangles_x":1,"rectangles_y":1], ["rectangles_x":0,"rectangles_y":0]),
            ("fan2", ["fan2_x","fan2_y"], ["fan2_x":0,"fan2_y":0], ["fan2_x":0,"fan2_y":0]),
            ("rings2", ["rings2_val"], ["rings2_val":0], ["rings2_val":0]),
            ("perspective", ["perspective_angle","perspective_dist"],
                ["perspective_angle":0,"perspective_dist":0], ["perspective_angle":0]),   // dist KEPT (absent from rest)
            ("super_shape", ["super_shape_rnd","super_shape_m","super_shape_n1","super_shape_n2","super_shape_n3","super_shape_holes"],
                ["super_shape_rnd":0,"super_shape_m":0,"super_shape_n1":1,"super_shape_n2":1,"super_shape_n3":1,"super_shape_holes":0],
                ["super_shape_rnd":0,"super_shape_n1":2,"super_shape_n2":2,"super_shape_n3":2,"super_shape_holes":0]), // m KEPT
            ("ngon", ["ngon_sides","ngon_power","ngon_circle","ngon_corners"],
                ["ngon_sides":5,"ngon_power":3,"ngon_circle":1,"ngon_corners":2], [:]),
            ("julian", ["julian_power","julian_dist"], ["julian_power":1,"julian_dist":1], [:]),
            ("juliascope", ["juliascope_power","juliascope_dist"], ["juliascope_power":1,"juliascope_dist":1], [:]),
            ("wedge_julia", ["wedge_julia_angle","wedge_julia_count","wedge_julia_power","wedge_julia_dist"],
                ["wedge_julia_angle":0,"wedge_julia_count":1,"wedge_julia_power":1,"wedge_julia_dist":0], [:]),
            ("wedge_sph", ["wedge_sph_angle","wedge_sph_count","wedge_sph_hole","wedge_sph_swirl"],
                ["wedge_sph_angle":0,"wedge_sph_count":1,"wedge_sph_hole":0,"wedge_sph_swirl":0], [:]),
        ]
        for (name, params, defaults, rest) in expected {
            let d = VariationDescriptor.descriptor(for: name)
            XCTAssertNotNil(d, name)
            XCTAssertEqual(d!.parameters, params, "\(name): params order")
            XCTAssertEqual(d!.defaults, defaults, "\(name): defaults")
            XCTAssertEqual(d!.rest, rest, "\(name): rest")
            // rest must only contain keys present in params (no phantom keys)
            for k in d!.rest.keys { XCTAssertTrue(d!.parameters.contains(k), "\(name): rest key \(k) not a param") }
            // params not in `rest` are intentionally kept at default (Group A-ish / "kept")
        }
        XCTAssertEqual(expected.count, 12, "all 12 parametric rows asserted")
    }
}
