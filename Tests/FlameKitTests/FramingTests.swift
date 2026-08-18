// Tests/FlameKitTests/FramingTests.swift
import XCTest
@testable import FlameKit

/// M6.6 framing normalization (spec §2.3/§3): `scale` is absolute pixels-per-unit
/// authored for `size.x`, so rendering at another width must multiply it by
/// renderW/authoredW. Width (not height) is the ES authoring anchor: gen-248's
/// three populations agree on scale/width to 2% while scale/height differs 34%.
final class FramingTests: XCTestCase {
    private func esLike(sizeX: Int, sizeY: Int, scale: Double) -> Flame {
        var f = Flame()
        f.size = SIMD2<Int>(sizeX, sizeY)
        f.camera.scale = scale
        return f
    }

    func testIdentityAtAuthoredWidth() {
        let g = esLike(sizeX: 800, sizeY: 592, scale: 260)
        let n = Framing.normalize(flame: g, renderWidth: 800)
        XCTAssertEqual(n.camera.scale, 260, accuracy: 1e-9)
        XCTAssertEqual(n, g, "factor 1 must be a full identity")
    }

    func testFactorMathPerPopulation() {
        // The three real gen-248 authoring sizes (spec §2.2), rendered at 4K/720p.
        let cases: [(authored: Int, scale: Double, render: Int, expected: Double)] = [
            (800, 260, 3840, 260.0 * 3840.0 / 800.0),
            (1280, 426, 1280, 426.0),                       // identity
            (1920, 633, 1280, 633.0 * 1280.0 / 1920.0),
        ]
        for c in cases {
            let n = Framing.normalize(flame: esLike(sizeX: c.authored, sizeY: c.authored / 16 * 9,
                                                    scale: c.scale),
                                      renderWidth: c.render)
            XCTAssertEqual(n.camera.scale, c.expected, accuracy: 1e-9)
        }
    }

    func testOnlyCameraScaleMutatedAndInputUntouched() {
        var g = esLike(sizeX: 800, sizeY: 592, scale: 260)
        g.camera.center = SIMD2<Double>(0.25, -0.5)
        g.camera.rotation = 42
        let before = g
        let n = Framing.normalize(flame: g, renderWidth: 1920)
        XCTAssertEqual(g, before, "input must not be mutated")
        XCTAssertEqual(n.camera.center, g.camera.center)
        XCTAssertEqual(n.camera.rotation, g.camera.rotation)
        XCTAssertEqual(n.camera.zoom, g.camera.zoom)
        XCTAssertEqual(n.size, g.size)
        XCTAssertEqual(n.camera.scale, 260.0 * 1920.0 / 800.0, accuracy: 1e-9)
    }

    func testGuardsLeaveDegenerateGenomesUnchanged() {
        // size.x <= 0 (malformed) — unchanged.
        let bad = esLike(sizeX: 0, sizeY: 0, scale: 100)
        XCTAssertEqual(Framing.normalize(flame: bad, renderWidth: 1920).camera.scale, 100)
        // NaN / non-positive scale (gen-248 data-integrity class) — unchanged.
        let nan = esLike(sizeX: 800, sizeY: 592, scale: .nan)
        XCTAssert(Framing.normalize(flame: nan, renderWidth: 1920).camera.scale.isNaN)
        let neg = esLike(sizeX: 800, sizeY: 592, scale: -259)
        XCTAssertEqual(Framing.normalize(flame: neg, renderWidth: 1920).camera.scale, -259)
    }

    func testDeterministicPureRepeat() {
        let g = esLike(sizeX: 800, sizeY: 592, scale: 260)
        XCTAssertEqual(Framing.normalize(flame: g, renderWidth: 1440),
                       Framing.normalize(flame: g, renderWidth: 1440))
    }
}
