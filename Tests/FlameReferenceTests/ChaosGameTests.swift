import XCTest
@testable import FlameReference
import FlameKit

final class ChaosGameTests: XCTestCase {
    private func sierpinski() -> Flame {
        Flame(size: SIMD2(64, 64),
              camera: Camera(scale: 64),
              xforms: [
                Xform(affine: AffineTransform(a: 0.5, b: 0, c: 0, d: 0, e: 0.5, f: 0), color: 0,
                      variations: [Variation(name: "linear", weight: 1)]),
                Xform(affine: AffineTransform(a: 0.5, b: 0, c: 0.5, d: 0, e: 0.5, f: 0), color: 0.5,
                      variations: [Variation(name: "linear", weight: 1)]),
                Xform(affine: AffineTransform(a: 0.5, b: 0, c: 0.25, d: 0, e: 0.5, f: 0.43), color: 1,
                      variations: [Variation(name: "linear", weight: 1)]),
              ])
    }

    func testDeterministic() {
        let p = RenderParams(seed: 42, width: 64, height: 64, oversample: 1, samplesPerPixel: 200)
        let a = ChaosGame.iterate(flame: sierpinski(), params: p)
        let b = ChaosGame.iterate(flame: sierpinski(), params: p)
        XCTAssertEqual(a.counts, b.counts)
        XCTAssertEqual(a.colors, b.colors)
    }

    func testSierpinskiBudgetAndShape() {
        let p = RenderParams(seed: 7, width: 64, height: 64, oversample: 1, samplesPerPixel: 500)
        let h = ChaosGame.iterate(flame: sierpinski(), params: p)
        // (a) well-formed contractive flame reaches exactly the budget
        XCTAssertEqual(Int(h.totalSamples), p.totalSamples, "safety cap tripped — flame not contractive?")
        // (b) attractor stays inside the triangle: no hits in the four extreme
        // image corners (which lie outside the Sierpinski hull for this genome).
        let cornerBins = [h[0,0], h[63,0], h[0,63], h[63,63]]
        XCTAssertTrue(cornerBins.allSatisfy { h.counts[$0] == 0 }, "hits outside the triangle")
        // (c) but plenty of hits somewhere in the grid
        XCTAssertGreaterThan(h.counts.reduce(0, +), 0)
    }

    func testFiniteBins() {
        let p = RenderParams(seed: 1, width: 32, height: 32, oversample: 1, samplesPerPixel: 100)
        let h = ChaosGame.iterate(flame: sierpinski(), params: p)
        for c in h.colors {
            XCTAssertTrue(c.x.isFinite && c.y.isFinite && c.z.isFinite)
        }
    }

    func testTerminatesOnDegenerateGenome() {
        // A single xform with scale > 1 diverges to infinity; the engine must
        // still terminate via the safety cap rather than spinning forever.
        let diverging = Flame(size: SIMD2(16, 16), camera: Camera(scale: 16),
            xforms: [Xform(affine: AffineTransform(a: 3, b: 0, c: 0, d: 0, e: 3, f: 0),
                           variations: [Variation(name: "linear", weight: 1)])])
        let p = RenderParams(seed: 1, width: 16, height: 16, oversample: 1, samplesPerPixel: 50)
        let h = ChaosGame.iterate(flame: diverging, params: p)
        XCTAssertEqual(h.counts.count, 16*16)   // it returned at all
    }
}
