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
        xf.affine = AffineTransform(a: 0.9, b: 0.05, c: -0.05, d: 0.9, e: 0.1, f: 0.2)
        xf.postAffine = AffineTransform(a: 1, b: 0, c: 0, d: 1, e: 0.1, f: 0)
        xf.chaos = [1, 2, 3]
        xf.opacity = 0.9
        f.xforms = [xf]
        var fin = Xform(variations: [Variation(name: "linear", weight: 1)])
        fin.affine = .identity
        f.finalXform = fin
        var pal = Palette.black
        pal.colors[0] = SIMD3<Double>(1, 0, 0)
        pal.colors[10] = SIMD3<Double>(0, 1, 0)
        pal.colors[200] = SIMD3<Double>(0, 0, 1)
        f.palette = pal

        let out = Flam3Serializer.serialize([f])
        // The escaped name must round-trip back to the original "F&<S>".
        let parsed = try Flam3Parser.parse(out.data(using: .utf8)!)[0]
        XCTAssertEqual(parsed, f)
    }

    func testRoundTripsParametricGenome() {
        let xml = """
        <?xml version="1.0"?>
        <flames><flame interpolation_type="log" hue_rotation="0.1">
          <xform weight="1" coefs="1 0 0 1 0 0" animate="1" blob="1" blob_low="0.2" blob_high="0.8" blob_waves="3"/>
          <xform weight="1" coefs="1 0 0 1 0 0" super_shape="1" super_shape_n1="2" super_shape_n2="2" super_shape_n3="2"/>
        </flame></flames>
        """
        let f1 = try! Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        let re = Flam3Serializer.serialize([f1])
        let f2 = try! Flam3Parser.parse(re.data(using: .utf8)!)[0]
        XCTAssertEqual(f1.interpolationType, f2.interpolationType)
        XCTAssertEqual(f1.hueRotation, f2.hueRotation, accuracy: 1e-9)
        let blob1 = f1.xforms[0].variations.first { $0.name == "blob" }!
        let blob2 = f2.xforms[0].variations.first { $0.name == "blob" }!
        XCTAssertEqual(blob1.parameters, blob2.parameters)
    }

    func testRoundTripsParamWithoutWeight() {
        // blob_low present, but NO blob="…" weight attr → must still round-trip as a
        // weight-0 variation carrying the param (synthesized by the parser; params emitted
        // regardless of weight by the serializer).
        let xml = """
        <?xml version="1.0"?>
        <flames><flame><xform weight="1" coefs="1 0 0 1 0 0" linear="1" blob_low="0.2"/></flame></flames>
        """
        let f1 = try! Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        let re = Flam3Serializer.serialize([f1])
        let f2 = try! Flam3Parser.parse(re.data(using: .utf8)!)[0]
        let blob2 = f2.xforms[0].variations.first { $0.name == "blob" }
        XCTAssertNotNil(blob2, "blob variation must survive round-trip even with weight 0")
        XCTAssertEqual(blob2!.weight, 0)
        XCTAssertEqual(blob2!.parameters["blob_low"]!, 0.2, accuracy: 1e-9)
    }

    func testRoundTripsConditionallyEmittedAttrs() {
        // interpolation (temporal) and hsv_rgb_palette_blend are emitted only when
        // non-default — pin that both survive a round trip.
        let xml = """
        <?xml version="1.0"?>
        <flames><flame interpolation="smooth" hsv_rgb_palette_blend="0.3">
          <xform weight="1" coefs="1 0 0 1 0 0" linear="1"/></flame></flames>
        """
        let f1 = try! Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        let re = Flam3Serializer.serialize([f1])
        let f2 = try! Flam3Parser.parse(re.data(using: .utf8)!)[0]
        XCTAssertEqual(f1.interpolation, .smooth)
        XCTAssertEqual(f2.interpolation, .smooth, "temporal interpolation must round-trip")
        XCTAssertEqual(f2.hsvRgbPaletteBlend, 0.3, accuracy: 1e-9, "hsv_rgb_palette_blend must round-trip")
        // and confirm the conditional attrs are actually present in the serialized output
        XCTAssertTrue(re.contains("interpolation=\"smooth\""), re)
        XCTAssertTrue(re.contains("hsv_rgb_palette_blend=\""), re)
    }

    func testRoundTripsTemporalAttrs() {
        // The four motion-blur attrs (temporal_samples, temporal_filter_type,
        // temporal_filter_width, temporal_filter_exp) are emitted only when
        // non-default. Drive ALL four through parse → serialize → parse and
        // pin both survival AND that the serialized XML actually carries each
        // non-default branch (so the conditional-emit paths are test-pinned,
        // not just the parse-side defaults).
        let xml = """
        <?xml version="1.0"?>
        <flames><flame temporal_samples="1000" temporal_filter_type="gaussian" \
        temporal_filter_width="1.2" temporal_filter_exp="2.0">
          <xform weight="1" coefs="1 0 0 1 0 0" linear="1"/></flame></flames>
        """
        let f1 = try! Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        XCTAssertEqual(f1.quality.temporalSamples, 1000)
        XCTAssertEqual(f1.quality.temporalFilterType, .gaussian)
        XCTAssertEqual(f1.quality.temporalFilterWidth, 1.2, accuracy: 1e-9)
        XCTAssertEqual(f1.quality.temporalFilterExp, 2.0, accuracy: 1e-9)

        let re = Flam3Serializer.serialize([f1])
        // Each of the four conditional branches must actually fire.
        XCTAssertTrue(re.contains("temporal_samples=\"1000\""), re)
        XCTAssertTrue(re.contains("temporal_filter_type=\"gaussian\""), re)
        XCTAssertTrue(re.contains("temporal_filter_width=\"1.200000\""), re)
        XCTAssertTrue(re.contains("temporal_filter_exp=\"2.000000\""), re)

        let f2 = try! Flam3Parser.parse(re.data(using: .utf8)!)[0]
        XCTAssertEqual(f2.quality.temporalSamples, 1000, "temporal_samples must round-trip")
        XCTAssertEqual(f2.quality.temporalFilterType, .gaussian, "temporal_filter_type must round-trip")
        XCTAssertEqual(f2.quality.temporalFilterWidth, 1.2, accuracy: 1e-9, "temporal_filter_width must round-trip")
        XCTAssertEqual(f2.quality.temporalFilterExp, 2.0, accuracy: 1e-9, "temporal_filter_exp must round-trip")
        XCTAssertEqual(f1, f2, "whole-genome equality must hold after round-trip")
    }

    func testRoundTripsTemporalFilterTypeExp() {
        // Pin the `.exp` FilterShape case (added after noticing `temporal_filter_type="exp"`
        // would silently coerce to `.box` and then drop the attr on serialize, losing data).
        // Both the type attr and the consumed-by-exp `temporal_filter_exp` must round-trip.
        let xml = """
        <?xml version="1.0"?>
        <flames><flame temporal_filter_type="exp" temporal_filter_exp="2.0">
          <xform weight="1" coefs="1 0 0 1 0 0" linear="1"/></flame></flames>
        """
        let f1 = try! Flam3Parser.parse(xml.data(using: .utf8)!)[0]
        XCTAssertEqual(f1.quality.temporalFilterType, .exp)
        XCTAssertEqual(f1.quality.temporalFilterExp, 2.0, accuracy: 1e-9)

        let re = Flam3Serializer.serialize([f1])
        XCTAssertTrue(re.contains("temporal_filter_type=\"exp\""), re)
        XCTAssertTrue(re.contains("temporal_filter_exp=\"2.000000\""), re)

        let f2 = try! Flam3Parser.parse(re.data(using: .utf8)!)[0]
        XCTAssertEqual(f2.quality.temporalFilterType, .exp, "temporal_filter_type=\"exp\" must round-trip")
        XCTAssertEqual(f2.quality.temporalFilterExp, 2.0, accuracy: 1e-9)
        XCTAssertEqual(f1, f2)
    }
}
