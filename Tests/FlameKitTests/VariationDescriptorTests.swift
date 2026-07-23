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
        XCTAssertEqual(VariationDescriptor.canonicalOrder.count, 96)
        XCTAssertEqual(Set(VariationDescriptor.canonicalOrder).count, 96, "duplicate canonical name")
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

    /// var24_pdj + var74_split (Task 2 CV2): parametric non-RNG ports. All params
    /// default 0 (flam3 `clear_cp` is preceded by `memset(0)`; pdj_a/b/c/d and
    /// split_xsize/ysize are not explicitly initialized in clear_cp → missing
    /// XML attrs parse as 0). The Emberweft descriptor defaults of 0 mirror this.
    /// Asserted separately so the table-fully-asserted count above stays at the
    /// 12 special-sauce rows (these two have no `rest` overrides).
    func testPdjAndSplitDefaultsAreZero() {
        let pdj = VariationDescriptor.descriptor(for: "pdj")!
        XCTAssertEqual(pdj.parameters, ["pdj_a", "pdj_b", "pdj_c", "pdj_d"])
        XCTAssertEqual(pdj.defaults, ["pdj_a": 0, "pdj_b": 0, "pdj_c": 0, "pdj_d": 0])
        XCTAssertTrue(pdj.rest.isEmpty, "pdj has no special-sauce rest")

        let split = VariationDescriptor.descriptor(for: "split")!
        XCTAssertEqual(split.parameters, ["split_xsize", "split_ysize"])
        XCTAssertEqual(split.defaults, ["split_xsize": 0, "split_ysize": 0])
        XCTAssertTrue(split.rest.isEmpty, "split has no special-sauce rest")

        // Slot indices 42, 43 (after the 5 paramless non-RNG ports at 37..41).
        XCTAssertEqual(VariationDescriptor.canonicalSlot(for: "pdj"), 42)
        XCTAssertEqual(VariationDescriptor.canonicalSlot(for: "split"), 43)
    }

    /// var31_noise / var34_blur / var35_gaussian_blur / var41_arch / var43_square
    /// (Task 3 CV3): 5 RNG-consuming paramless variations. All paramless (no
    /// XML params) and 0..5 isaac_01 draws each. The slot indices 44..48 are
    /// immediately after the parametric non-RNG pair (pdj=42, split=43) and
    /// before the upcoming RNG+Inf/badvalue set (rays/blade/twintrian).
    func testRngSimpleSlotsAreParamlessAt44to48() {
        // noise=2 draws, blur=2 draws, gaussian_blur=5 draws, arch=1 draw, square=2 draws.
        let expected: [(String, Int)] = [
            ("noise", 44), ("blur", 45), ("gaussian_blur", 46),
            ("arch", 47), ("square", 48),
        ]
        for (name, slot) in expected {
            let d = VariationDescriptor.descriptor(for: name)
            XCTAssertNotNil(d, name)
            XCTAssertTrue(d!.parameters.isEmpty, "\(name): must be paramless")
            XCTAssertTrue(d!.defaults.isEmpty, "\(name): no defaults (paramless)")
            XCTAssertTrue(d!.rest.isEmpty, "\(name): no special-sauce rest")
            XCTAssertEqual(VariationDescriptor.canonicalSlot(for: name), slot,
                           "\(name): expected slot \(slot)")
        }
    }

    /// var44_rays / var45_blade / var47_twintrian (Task 4 CV4): 3 RNG-consuming
    /// paramless variations with Inf/badvalue hazards. All paramless (no XML
    /// params), each exactly 1 isaac_01 draw. Slot indices 49..51 immediately
    /// follow the RNG simple set (44..48). rays is un-guarded tan(ang); twintrian
    /// has the badvalue→-30.0 replacement on log10(sinr²)+cosr (both CPU+Metal).
    func testRngInfBadvalueSlotsAreParamlessAt49to51() {
        // rays=1 draw, blade=1 draw, twintrian=1 draw.
        let expected: [(String, Int)] = [
            ("rays", 49), ("blade", 50), ("twintrian", 51),
        ]
        for (name, slot) in expected {
            let d = VariationDescriptor.descriptor(for: name)
            XCTAssertNotNil(d, name)
            XCTAssertTrue(d!.parameters.isEmpty, "\(name): must be paramless")
            XCTAssertTrue(d!.defaults.isEmpty, "\(name): no defaults (paramless)")
            XCTAssertTrue(d!.rest.isEmpty, "\(name): no special-sauce rest")
            XCTAssertEqual(VariationDescriptor.canonicalSlot(for: name), slot,
                           "\(name): expected slot \(slot)")
        }
    }

    /// var51_flower / var52_conic / var53_parabola (Task 5 CV5): 3 parametric
    /// RNG-consuming variations. Each has 2 params (all default 0), and 1..2
    /// isaac_01 draws (flower=1, conic=1, parabola=2). Slot indices 52..54
    /// immediately follow the RNG + Inf/badvalue set (49..51). flam3's `clear_cp`
    /// does NOT initialize any of these params — memset(0) in parser.c:229 wins,
    /// so missing XML attrs parse as 0 (same reasoning as pdj/split in CV2).
    /// NOTE: `conic_eccentricity` is set to 1.0 in `initialize_xforms` only (used
    /// when adding NEW xforms for interpolation padding, NOT during parsing), so
    /// for parsed genomes the effective default is 0 — Emberweft mirrors that.
    func testFlowerConicParabolaDefaultsAreZero() {
        let flower = VariationDescriptor.descriptor(for: "flower")!
        XCTAssertEqual(flower.parameters, ["flower_holes", "flower_petals"])
        XCTAssertEqual(flower.defaults, ["flower_holes": 0, "flower_petals": 0])
        XCTAssertTrue(flower.rest.isEmpty, "flower has no special-sauce rest")

        let conic = VariationDescriptor.descriptor(for: "conic")!
        XCTAssertEqual(conic.parameters, ["conic_eccentricity", "conic_holes"])
        XCTAssertEqual(conic.defaults, ["conic_eccentricity": 0, "conic_holes": 0])
        XCTAssertTrue(conic.rest.isEmpty, "conic has no special-sauce rest")

        let parabola = VariationDescriptor.descriptor(for: "parabola")!
        XCTAssertEqual(parabola.parameters, ["parabola_height", "parabola_width"])
        XCTAssertEqual(parabola.defaults, ["parabola_height": 0, "parabola_width": 0])
        XCTAssertTrue(parabola.rest.isEmpty, "parabola has no special-sauce rest")

        // Slot indices 52, 53, 54 (after the RNG + Inf/badvalue trio at 49..51).
        XCTAssertEqual(VariationDescriptor.canonicalSlot(for: "flower"), 52)
        XCTAssertEqual(VariationDescriptor.canonicalSlot(for: "conic"), 53)
        XCTAssertEqual(VariationDescriptor.canonicalSlot(for: "parabola"), 54)
    }

    /// var46_secant2 + var49_disc2 (Task 7 CV7): the final 2 corpus-used flam3
    /// variations (the last 2 of the 44 missing-from-Emberweft variations that
    /// appear in the 23k-genome corpus survey — all other 42 unused). Completes
    /// 100% corpus-used variation coverage (Emberweft 57/99). secant2 is
    /// paramless + non-RNG (slot 55); disc2 is parametric (`disc2_rot`,
    /// `disc2_twist`, default 0) + non-RNG (slot 56). flam3's `clear_cp` does
    /// NOT initialize disc2_rot/disc2_twist (memset(0) in parser.c:229 wins) →
    /// missing XML attrs parse as 0 (same reasoning as pdj/split/flower/conic/
    /// parabola). disc2 additionally derives `disc2_timespi`/`disc2_sinadd`/
    /// `disc2_cosadd` via `disc2_precalc` (variations.c:1977-1997), inlined
    /// into the CPU closure + MSL function — NOT exposed as XML params.
    func testSecant2AndDisc2Descriptors() {
        let secant2 = VariationDescriptor.descriptor(for: "secant2")!
        XCTAssertTrue(secant2.parameters.isEmpty, "secant2: must be paramless")
        XCTAssertTrue(secant2.defaults.isEmpty, "secant2: no defaults (paramless)")
        XCTAssertTrue(secant2.rest.isEmpty, "secant2: no special-sauce rest")

        let disc2 = VariationDescriptor.descriptor(for: "disc2")!
        XCTAssertEqual(disc2.parameters, ["disc2_rot", "disc2_twist"])
        XCTAssertEqual(disc2.defaults, ["disc2_rot": 0, "disc2_twist": 0])
        XCTAssertTrue(disc2.rest.isEmpty, "disc2 has no special-sauce rest")

        // Slot indices 55, 56 (immediately after the parametric+RNG trio at 52..54).
        XCTAssertEqual(VariationDescriptor.canonicalSlot(for: "secant2"), 55)
        XCTAssertEqual(VariationDescriptor.canonicalSlot(for: "disc2"), 56)
        // Canonical-order authority for the full 96.
        XCTAssertEqual(VariationDescriptor.canonicalOrder.count, 96)
    }
}
