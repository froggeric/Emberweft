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

    // MARK: - M6.7 Framing.apply (orientation-aware matrix, spec §3)

    func testPortraitExactFitFor169Genome() {
        let g = esLike(sizeX: 1920, sizeY: 1080, scale: 400)
        let out = Framing.apply(flame: g, renderWidth: 1080, renderHeight: 1920, normalized: true)
        XCTAssertEqual(out.camera.scale, 400, accuracy: 1e-9,
                       "factor = canvasW/authoredH = 1080/1080 = 1.0 (exact fit)")
        XCTAssertEqual(out.camera.rotation, Framing.portraitRotationDegrees, accuracy: 1e-12)
    }

    func testPortraitAnchorMathFor43Genome() {
        let g = esLike(sizeX: 800, sizeY: 592, scale: 260)
        let out = Framing.apply(flame: g, renderWidth: 1080, renderHeight: 1920, normalized: true)
        XCTAssertEqual(out.camera.scale, 260.0 * 1080.0 / 592.0, accuracy: 1e-9)
        XCTAssertEqual(out.camera.rotation, 90, accuracy: 1e-12)
    }

    func testPortrait4x5ExactFitFor169Genome() {
        // Spec §8's 4:5 cell: factor = canvasW/authoredH = 1080/1080 = 1.0
        // (horizontal exact; the top/bottom crop is a render-level consequence,
        // not asserted here).
        let g = esLike(sizeX: 1920, sizeY: 1080, scale: 400)
        let out = Framing.apply(flame: g, renderWidth: 1080, renderHeight: 1350, normalized: true)
        XCTAssertEqual(out.camera.scale, 400, accuracy: 1e-9)
        XCTAssertEqual(out.camera.rotation, Framing.portraitRotationDegrees, accuracy: 1e-12)
    }

    func testPortraitFaithfulRotatesOnly() {
        var g = esLike(sizeX: 1920, sizeY: 1080, scale: 400)
        g.camera.rotation = 12
        let out = Framing.apply(flame: g, renderWidth: 1080, renderHeight: 1920, normalized: false)
        XCTAssertEqual(out.camera.scale, 400, accuracy: 1e-9, "faithful = raw scale, sideways")
        XCTAssertEqual(out.camera.rotation, 102, accuracy: 1e-12, "+90 on the authored value")
    }

    func testPortraitAuthoredGenomeNeverRotated() {
        let g = esLike(sizeX: 1080, sizeY: 1920, scale: 500)
        // Faithful on its native portrait canvas: full identity (the
        // faithful↔animate byte-identity contract for portrait-authored genomes).
        XCTAssertEqual(Framing.apply(flame: g, renderWidth: 1080, renderHeight: 1920,
                                     normalized: false), g)
        // Normalized: the M6.6 width-anchor cell (identity at native width).
        let n = Framing.apply(flame: g, renderWidth: 1080, renderHeight: 1920, normalized: true)
        XCTAssertEqual(n.camera.scale, 500, accuracy: 1e-9)
        XCTAssertEqual(n.camera.rotation, 0, accuracy: 1e-12, "already composed vertically")
    }

    func testSquareAuthoredGenomeOnPortraitCanvasNotRotated() {
        let g = esLike(sizeX: 1000, sizeY: 1000, scale: 300)
        let out = Framing.apply(flame: g, renderWidth: 1080, renderHeight: 1920, normalized: true)
        XCTAssertEqual(out.camera.rotation, 0, accuracy: 1e-12,
                       "spinning a square composition is arbitrary — never do it")
        XCTAssertEqual(out.camera.scale, 300.0 * 1080.0 / 1000.0, accuracy: 1e-9,
                       "width anchor (== height anchor for square-authored)")
    }

    func testSquareCanvasWidthAnchorNoRotation() {
        let g = esLike(sizeX: 1920, sizeY: 1080, scale: 400)
        let out = Framing.apply(flame: g, renderWidth: 1080, renderHeight: 1080, normalized: true)
        XCTAssertEqual(out.camera.rotation, 0, accuracy: 1e-12, "a square canvas never rotates")
        XCTAssertEqual(out.camera.scale, Framing.normalize(flame: g, renderWidth: 1080).camera.scale,
                       accuracy: 1e-9)
    }

    func testDegenerateOnPortraitCanvasEntirelyUnchanged() {
        // size.y <= 0 with valid scale: D10 — the guard wraps rotation TOO.
        let badY = esLike(sizeX: 800, sizeY: 0, scale: 260)
        XCTAssertEqual(Framing.apply(flame: badY, renderWidth: 1080, renderHeight: 1920,
                                     normalized: true), badY)
        let nan = esLike(sizeX: 800, sizeY: 592, scale: .nan)
        let out = Framing.apply(flame: nan, renderWidth: 1080, renderHeight: 1920, normalized: true)
        XCTAssertTrue(out.camera.scale.isNaN)
        XCTAssertEqual(out.camera.rotation, 0, accuracy: 1e-12)
        // Negative scale — the spec-§8-named degenerate variant.
        let neg = esLike(sizeX: 800, sizeY: 592, scale: -259)
        XCTAssertEqual(Framing.apply(flame: neg, renderWidth: 1080, renderHeight: 1920,
                                     normalized: true), neg)
    }

    func testLandscapeCellsDelegateToM66Paths() {
        let g = esLike(sizeX: 800, sizeY: 592, scale: 260)
        // normalized landscape == normalize (byte-identical by construction).
        XCTAssertEqual(Framing.apply(flame: g, renderWidth: 1920, renderHeight: 1080, normalized: true),
                       Framing.normalize(flame: g, renderWidth: 1920))
        // faithful landscape == identity.
        XCTAssertEqual(Framing.apply(flame: g, renderWidth: 1920, renderHeight: 1080,
                                     normalized: false), g)
        // Degenerate on a LANDSCAPE canvas keeps v0.6.1 behavior (normalize's
        // own guard) — the landscape cells are today's code paths.
        let bad = esLike(sizeX: 800, sizeY: 0, scale: 260)
        XCTAssertEqual(Framing.apply(flame: bad, renderWidth: 1920, renderHeight: 1080,
                                     normalized: true).camera.scale,
                       260.0 * 1920.0 / 800.0, accuracy: 1e-9)
    }

    func testApplyIsPureAndRepeatable() {
        let g = esLike(sizeX: 1920, sizeY: 1080, scale: 400)
        XCTAssertEqual(Framing.apply(flame: g, renderWidth: 1080, renderHeight: 1920, normalized: true),
                       Framing.apply(flame: g, renderWidth: 1080, renderHeight: 1920, normalized: true))
    }
}
