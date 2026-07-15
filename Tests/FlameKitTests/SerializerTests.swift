import XCTest
@testable import FlameKit

final class SerializerTests: XCTestCase {
    func testRoundTrip() throws {
        let xml = """
        <flames><flame name="R" size="640 480" scale="210" gamma="2.5" quality="40">
          <xform weight="1.5" color="0.25" coefs="0.5 0 0 0.5 0.1 0.2" linear="1" swirl="0.5"/>
        </flame></flames>
        """
        let first = try Flam3Parser.parse(xml.data(using: .utf8)!)
        let out = Flam3Serializer.serialize(first)
        let second = try Flam3Parser.parse(out.data(using: .utf8)!)
        XCTAssertEqual(first, second)
    }

    func testHasXmlDeclarationAndVersion() throws {
        let out = Flam3Serializer.serialize([Flame(name: "V", size: SIMD2(2, 2))])
        XCTAssertTrue(out.hasPrefix("<?xml"))
        XCTAssertTrue(out.contains("version=\"3.0\""))
    }
}
