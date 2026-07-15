import XCTest
@testable import FlameReference
import FlameKit

final class PropertyTests: XCTestCase {
    func testFiniteDeterministicRenders() {
        var rng = PCG32(seed: 12345, stream: 1)
        for _ in 0..<50 {
            let f = GenomeGen.make(rng: &rng)
            let p = RenderParams(seed: 7, width: 16, height: 16, oversample: 1, samplesPerPixel: 50)
            let a = ReferenceRenderer.render(flame: f, params: p)
            XCTAssertTrue(a.pixels.allSatisfy { $0 <= 255 })
            let b = ReferenceRenderer.render(flame: f, params: p)
            XCTAssertEqual(a, b)
        }
    }
    func testParserRoundTrip() throws {
        // Serialization formats floats to 6 decimals and emits variations as
        // xform attributes (order not preserved by XMLParser), so exact equality
        // is neither required nor expected. Compare structurally with a 1e-4
        // tolerance and order-insensitive variation matching.
        var rng = PCG32(seed: 999, stream: 2)
        for _ in 0..<50 {
            let f = GenomeGen.make(rng: &rng)
            let xml = Flam3Serializer.serialize([f])
            let parsed = try Flam3Parser.parse(xml.data(using: .utf8)!)
            XCTAssertTrue(flameApproxEqual(f, parsed[0], accuracy: 1e-4),
                          "round-trip diverged:\n\(xml)")
        }
    }
    private func flameApproxEqual(_ a: Flame, _ b: Flame, accuracy: Float) -> Bool {
        guard a.size == b.size, a.xforms.count == b.xforms.count else { return false }
        guard abs(a.camera.scale - b.camera.scale) <= accuracy,
              abs(a.camera.zoom - b.camera.zoom) <= accuracy,
              abs(a.camera.center.x - b.camera.center.x) <= accuracy,
              abs(a.camera.center.y - b.camera.center.y) <= accuracy,
              abs(a.quality.gamma - b.quality.gamma) <= accuracy,
              abs(Float(a.quality.samplesPerPixel) - Float(b.quality.samplesPerPixel)) <= 0.01,
              abs(a.hueShift - b.hueShift) <= accuracy
        else { return false }
        for (xa, xb) in zip(a.xforms, b.xforms) {
            let ca = xa.affine, cb = xb.affine
            let pa = xa.postAffine, pb = xb.postAffine
            guard abs(xa.weight - xb.weight) <= accuracy,
                  abs(xa.color - xb.color) <= accuracy,
                  abs(xa.colorSpeed - xb.colorSpeed) <= accuracy,
                  abs(xa.opacity - xb.opacity) <= accuracy,
                  abs(ca.a-cb.a) <= accuracy, abs(ca.b-cb.b) <= accuracy, abs(ca.c-cb.c) <= accuracy,
                  abs(ca.d-cb.d) <= accuracy, abs(ca.e-cb.e) <= accuracy, abs(ca.f-cb.f) <= accuracy,
                  abs(pa.a-pb.a) <= accuracy, abs(pa.b-pb.b) <= accuracy, abs(pa.c-pb.c) <= accuracy,
                  abs(pa.d-pb.d) <= accuracy, abs(pa.e-pb.e) <= accuracy, abs(pa.f-pb.f) <= accuracy
            else { return false }
            // variations: order-insensitive, matched by name
            let da = Dictionary(uniqueKeysWithValues: xa.variations.map { ($0.name, $0.weight) })
            let db = Dictionary(uniqueKeysWithValues: xb.variations.map { ($0.name, $0.weight) })
            guard da.count == db.count else { return false }
            for (k, va) in da where abs(va - (db[k] ?? .nan)) > accuracy { return false }
        }
        return true
    }
}
