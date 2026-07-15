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
        XCTAssertEqual(f.palette.colors[0], SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(f.palette.colors[255], SIMD3<Float>(0, 0, 1))
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
        XCTAssertEqual(flames[1].palette.colors[0], SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(flames[1].palette.colors[255], SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(flames[0].palette.colors[0], SIMD3<Float>(1, 0, 0))
    }
    func testParsesHexBlockPalette() throws {
        // flam3 native <palette> hex-text form: 6 hex digits per color (RRGGBB).
        let xml = """
        <flames><flame><xform coefs="1 0 0 1 0 0" linear="1"/>
          <palette>FF000000FF00</palette></flame></flames>
        """
        let f = try Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        XCTAssertEqual(f.palette.colors[0], SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(f.palette.colors[1], SIMD3<Float>(0, 1, 0))
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
}
