import XCTest
@testable import FlameKit

final class ParserTests: XCTestCase {
    func testParsesCompleteDocument() throws {
        // flam3/Apophysis form: variation weights are xform ATTRIBUTES.
        let xml = """
        <?xml version="1.0"?>
        <flames>
          <flame name="T" size="800 600" center="0 0" scale="200" quality="50" gamma="3.0">
            <xform weight="1" color="0" coefs="1 0 0 1 0 0" linear="1" sinusoidal="0.5"/>
            <palette>
              <color index="0" rgb="FF0000"/>
              <color index="255" rgb="0000FF"/>
            </palette>
          </flame>
        </flames>
        """
        let flames = try Flam3Parser.parse(xml.data(using: .utf8)!)
        XCTAssertEqual(flames.count, 1)
        let f = flames[0]
        XCTAssertEqual(f.name, "T")
        XCTAssertEqual(f.size, SIMD2<Int>(800, 600))
        XCTAssertEqual(f.camera.scale, 200)
        XCTAssertEqual(f.quality.gamma, 3.0)
        XCTAssertEqual(f.xforms.count, 1)
        // Attribute-form variations parse through (sorted by name).
        XCTAssertEqual(f.xforms[0].variations,
                       [Variation(name: "linear", weight: 1),
                        Variation(name: "sinusoidal", weight: 0.5)])
        XCTAssertEqual(f.palette.colors[0], SIMD3<Double>(1, 0, 0))
        XCTAssertEqual(f.palette.colors[255], SIMD3<Double>(0, 0, 1))
    }
    func testParsesVarChildForm() throws {
        // The <var> child-element form (genome-format.md) is also accepted,
        // merged after any attribute variations. flam3-render does NOT read this
        // form, so the serializer never emits it; it is supported for import only.
        let xml = """
        <flames><flame><xform coefs="1 0 0 1 0 0"><var name="linear" weight="1"/></xform></flame></flames>
        """
        let f = try Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        XCTAssertEqual(f.xforms[0].variations, [Variation(name: "linear", weight: 1)])
    }
    func testDefaultsApplied() throws {
        let xml = "<flames><flame><xform coefs=\"1 0 0 1 0 0\"><var name=\"linear\" weight=\"1\"/></xform></flame></flames>"
        let f = try Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        XCTAssertEqual(f.camera.scale, 250)
        XCTAssertEqual(f.quality.gamma, 2.2)
    }
    func testRejectsBadCoefsCount() {
        let xml = "<flames><flame><xform coefs=\"1 0 0\"/></flame></flames>"
        XCTAssertThrowsError(try Flam3Parser.parse(xml.data(using: .utf8)!)) { err in
            XCTAssertEqual(err as? FlameKitError, .invalidAttribute("coefs", value: "1 0 0"))
        }
    }
    func testRejectsMalformedXML() {
        let xml = "<flames><flame>"
        XCTAssertThrowsError(try Flam3Parser.parse(xml.data(using: .utf8)!))
    }
    func testPaletteDoesNotLeakBetweenFlames() throws {
        // Regression: palette state must reset per <flame> so entries written by
        // flame N do not persist into flame N+1 in a multi-flame document.
        let xml = """
        <flames>
          <flame name="a"><xform coefs="1 0 0 1 0 0" linear="1"/>
            <palette><color index="0" rgb="FF0000"/></palette></flame>
          <flame name="b"><xform coefs="1 0 0 1 0 0" linear="1"/>
            <palette><color index="255" rgb="0000FF"/></palette></flame>
        </flames>
        """
        let flames = try Flam3Parser.parse(xml.data(using: .utf8)!)
        XCTAssertEqual(flames.count, 2)
        // Flame b only set index 255; index 0 must NOT carry over red from flame a.
        XCTAssertEqual(flames[1].palette.colors[0], SIMD3<Double>(0, 0, 0))
        XCTAssertEqual(flames[1].palette.colors[255], SIMD3<Double>(0, 0, 1))
        XCTAssertEqual(flames[0].palette.colors[0], SIMD3<Double>(1, 0, 0))
    }
    func testParsesHexBlockPalette() throws {
        // flam3 native <palette> hex-text form: 6 hex digits per color (RRGGBB).
        let xml = """
        <flames><flame><xform coefs="1 0 0 1 0 0" linear="1"/>
          <palette>FF000000FF00</palette></flame></flames>
        """
        let f = try Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        XCTAssertEqual(f.palette.colors[0], SIMD3<Double>(1, 0, 0))
        XCTAssertEqual(f.palette.colors[1], SIMD3<Double>(0, 1, 0))
    }
    func testParsesFinalXform() throws {
        let xml = """
        <flames><flame>
          <xform coefs="1 0 0 1 0 0" linear="1"/>
          <finalxform coefs="1 0 0 1 0 0" spherical="1"/>
        </flame></flames>
        """
        let f = try Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        XCTAssertEqual(f.xforms.count, 1)
        XCTAssertNotNil(f.finalXform)
        XCTAssertEqual(f.finalXform?.variations, [Variation(name: "spherical", weight: 1)])
    }
    func testParsesVariationParameters() {
        let xml = """
        <?xml version="1.0"?>
        <flames><flame><xform weight="1" coefs="1 0 0 1 0 0" curl="1" curl_c1="0.5" curl_c2="-0.2"/></flame></flames>
        """
        let f = try! Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        let curl = f.xforms[0].variations.first { $0.name == "curl" }!
        XCTAssertEqual(curl.weight, 1)
        XCTAssertEqual(curl.parameters["curl_c1"]!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(curl.parameters["curl_c2"]!, -0.2, accuracy: 1e-9)
    }
    func testParsesAnimationAttributes() {
        let xml = """
        <?xml version="1.0"?>
        <flames><flame interpolation_type="log" palette_interpolation="hsv_circular" hue_rotation="0.25">
          <xform weight="1" coefs="1 0 0 1 0 0" animate="0" linear="1"/></flame></flames>
        """
        let f = try! Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        XCTAssertEqual(f.interpolationType, .log)
        XCTAssertEqual(f.paletteInterpolation, .hsvCircular)
        XCTAssertEqual(f.hueRotation, 0.25, accuracy: 1e-9)
        XCTAssertEqual(f.xforms[0].animate, 0)
    }
    /// Legacy `symmetry=` attr (deprecated; flam3 parser.c:856-861) sets BOTH
    /// `color_speed = (1 - sym) / 2` AND `animate = sym > 0 ? 0 : 1`. Real
    /// Electric Sheep genomes gen-169..243 use `symmetry` exclusively (no
    /// `color_speed`/`animate`); the wrong factor (1-sym vs (1-sym)/2) or
    /// missing animate derivation costs ~40 dB on the CV6 real-genome parity
    /// gate (242.00099 etc.). Pinned here so a regression can't silently
    /// re-introduce the bug.
    func testParsesLegacySymmetryAsColorSpeedAndAnimate() throws {
        let xml = """
        <flames><flame>
          <xform weight="1" coefs="1 0 0 1 0 0" linear="1"/>
          <xform weight="1" coefs="1 0 0 1 0 0" linear="1" symmetry="0"/>
          <xform weight="1" coefs="1 0 0 1 0 0" linear="1" symmetry="1"/>
          <xform weight="1" coefs="1 0 0 1 0 0" linear="1" symmetry="-1"/>
          <xform weight="1" coefs="1 0 0 1 0 0" linear="1" symmetry="0.5"/>
          <xform weight="1" coefs="1 0 0 1 0 0" linear="1" color_speed="0.25" animate="0"/>
        </flame></flames>
        """
        let f = try Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        // xform 0: no symmetry / no color_speed / no animate → defaults
        XCTAssertEqual(f.xforms[0].colorSpeed, 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.xforms[0].animate, 1.0, accuracy: 1e-9)
        // xform 1: symmetry="0" → color_speed=(1-0)/2=0.5; animate = 0>0 ? 0 : 1 = 1
        XCTAssertEqual(f.xforms[1].colorSpeed, 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.xforms[1].animate, 1.0, accuracy: 1e-9)
        // xform 2: symmetry="1" → color_speed=(1-1)/2=0.0; animate = 1>0 ? 0 : 1 = 0
        XCTAssertEqual(f.xforms[2].colorSpeed, 0.0, accuracy: 1e-9)
        XCTAssertEqual(f.xforms[2].animate, 0.0, accuracy: 1e-9)
        // xform 3: symmetry="-1" → color_speed=(1-(-1))/2=1.0; animate = -1>0 ? 0 : 1 = 1
        XCTAssertEqual(f.xforms[3].colorSpeed, 1.0, accuracy: 1e-9)
        XCTAssertEqual(f.xforms[3].animate, 1.0, accuracy: 1e-9)
        // xform 4: symmetry="0.5" → color_speed=(1-0.5)/2=0.25; animate = 0.5>0 ? 0 : 1 = 0
        XCTAssertEqual(f.xforms[4].colorSpeed, 0.25, accuracy: 1e-9)
        XCTAssertEqual(f.xforms[4].animate, 0.0, accuracy: 1e-9)
        // xform 5: explicit color_speed wins; explicit animate wins (symmetry
        // is NOT set so the legacy fallback doesn't fire).
        XCTAssertEqual(f.xforms[5].colorSpeed, 0.25, accuracy: 1e-9)
        XCTAssertEqual(f.xforms[5].animate, 0.0, accuracy: 1e-9)
    }
    func testMatchParamAttributeResolvesExactlyOneVariation() {
        // Every parametric attr resolves to exactly one variation; no prefix collisions
        // (fan2_ does NOT match fan_, rings2_ does NOT match rings_).
        let cases: [(attr: String, variation: String)] = [
            ("blob_low", "blob"), ("curl_c2", "curl"), ("rectangles_x", "rectangles"),
            ("fan2_x", "fan2"), ("rings2_val", "rings2"), ("perspective_angle", "perspective"),
            ("super_shape_n3", "super_shape"), ("ngon_sides", "ngon"),
            ("julian_power", "julian"), ("juliascope_power", "juliascope"),
            ("wedge_julia_angle", "wedge_julia"), ("wedge_sph_hole", "wedge_sph"),
        ]
        for (attr, variation) in cases {
            let hit = VariationDescriptor.matchParamAttribute(attr)
            XCTAssertNotNil(hit, attr)
            XCTAssertEqual(hit!.variation, variation, attr)
        }
        // fan2_ must NOT resolve as fan; rings2_ must NOT resolve as rings
        XCTAssertNotEqual(VariationDescriptor.matchParamAttribute("fan2_x")?.variation, "fan")
        XCTAssertNotEqual(VariationDescriptor.matchParamAttribute("rings2_val")?.variation, "rings")
        // A plain variation-weight attr (no suffix) returns nil
        XCTAssertNil(VariationDescriptor.matchParamAttribute("linear"))
        XCTAssertNil(VariationDescriptor.matchParamAttribute("curl"))
    }
}
