import XCTest
@testable import FlameKit

final class GenomeHealthTests: XCTestCase {
    // Verified against Sources/FlameKit/Genome.swift: `Camera.center` is
    // `SIMD2<Double>` (there is no `Vec2` type); `Camera.scale` is `Double`;
    // `Flame`, `Xform`, `Variation` all have defaulted inits so the labeled
    // subsets below compile.
    private func flame(center: SIMD2<Double> = .zero, scale: Double = 200) -> Flame {
        var f = Flame(xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])
        f.camera.center = center
        f.camera.scale = scale
        return f
    }

    func testRenderableNormal() throws {
        XCTAssertTrue(flame().isRenderable)
    }
    func testRejectsNaNCenter() throws {
        XCTAssertFalse(flame(center: SIMD2<Double>(x: .nan, y: 0)).isRenderable)
    }
    func testRejectsNonPositiveScale() throws {
        XCTAssertFalse(flame(scale: 0).isRenderable)
        XCTAssertFalse(flame(scale: -5).isRenderable)
    }
    func testRejectsOutOfBandScale() throws {
        XCTAssertFalse(flame(scale: 1e-5).isRenderable)   // below 1e-3
        XCTAssertFalse(flame(scale: 5760).isRenderable)   // above 4000
        XCTAssertTrue(flame(scale: 1e-3).isRenderable)
        XCTAssertTrue(flame(scale: 4000).isRenderable)
    }
    func testRejectsAllZeroWeight() throws {
        var f = flame()
        f.xforms[0].weight = 0
        XCTAssertFalse(f.isRenderable)
    }
}
