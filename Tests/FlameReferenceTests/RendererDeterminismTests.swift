import XCTest
@testable import FlameReference
import FlameKit

final class RendererDeterminismTests: XCTestCase {
    func testPNGRoundTrip() throws {
        let img = RGBA8Image(width: 2, height: 2, pixels: [10,20,30,255, 40,50,60,255, 70,80,90,255, 100,110,120,255])
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("t.png")
        try img.writePNG(to: url)
        let back = try RGBA8Image.readPNG(from: url)
        XCTAssertEqual(img, back)
    }

    func testRenderIsDeterministic() {
        let f = Flame(size: SIMD2(32, 32), camera: Camera(scale: 32),
                      xforms: [Xform(affine: AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, e: 0, f: 0),
                                     color: 0, variations: [Variation(name: "linear", weight: 1)]),
                                Xform(affine: AffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, e: 0.4, f: 0),
                                     color: 1, variations: [Variation(name: "swirl", weight: 0.5),
                                                            Variation(name: "linear", weight: 0.5)])],
                      palette: Palette(colors: (0..<256).map { SIMD3(Float($0)/255, 0, 1 - Float($0)/255) }))
        let p = RenderParams(seed: 99, width: 32, height: 32, oversample: 1, samplesPerPixel: 200)
        let a = ReferenceRenderer.render(flame: f, params: p)
        let b = ReferenceRenderer.render(flame: f, params: p)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.pixels.contains { $0 > 0 })
    }
}
