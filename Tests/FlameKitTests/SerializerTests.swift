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

    func testRoundTripFullFeatures() throws {
        var f = Flame(name: "F&<S>", size: SIMD2<Int>(320, 200))
        f.camera.center = SIMD2(0.5, -0.25)
        f.camera.zoom = 0.3
        f.camera.rotation = 15
        f.quality.oversample = 2
        f.quality.samplesPerPixel = 60
        f.quality.gamma = 4.0
        f.quality.vibrancy = 1.5
        f.quality.estimatorRadius = 5
        f.quality.estimatorMinimum = 2
        f.quality.estimatorCurveRate = 0.7
        f.hueShift = 0.1
        f.time = 3.5
        var xf = Xform(weight: 1.2, color: 0.4, colorSpeed: 0.8,
                       variations: [Variation(name: "spherical", weight: 1),
                                    Variation(name: "swirl", weight: 0.5)])
        xf.affine = AffineTransform(a: 0.9, b: 0.0, c: 0.1, d: 0.0, e: 0.9, f: 0.2)
        xf.postAffine = AffineTransform(a: 1, b: 0, c: 0.1, d: 0, e: 1, f: 0)
        xf.chaos = [1, 2, 3]
        xf.opacity = 0.9
        f.xforms = [xf]
        var fin = Xform(variations: [Variation(name: "linear", weight: 1)])
        fin.affine = AffineTransform(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0)
        f.finalXform = fin
        var pal = Palette.black
        pal.colors[0] = SIMD3<Float>(1, 0, 0)
        pal.colors[10] = SIMD3<Float>(0, 1, 0)
        pal.colors[200] = SIMD3<Float>(0, 0, 1)
        f.palette = pal

        let out = Flam3Serializer.serialize([f])
        // The escaped name must round-trip back to the original "F&<S>".
        let parsed = try Flam3Parser.parse(out.data(using: .utf8)!)[0]
        XCTAssertEqual(parsed, f)
    }
}
