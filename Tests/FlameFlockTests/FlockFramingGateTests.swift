import XCTest
import FlameKit
@testable import FlameFlock

/// M6.7 D7: the framing hit-gate — ONE derivation shared by ArchiveRenderer
/// (row + mdta) and the Stitch/Generate compares.
final class FlockFramingGateTests: XCTestCase {

    func testFaithfulIsZero() {
        XCTAssertEqual(FlockFramingGate.value(normalized: false, canvasW: 1080, canvasH: 1920,
                                              authoredW: 1920, authoredH: 1080), 0)
    }

    func testLandscapeShardNormalizedIsOne() {
        XCTAssertEqual(FlockFramingGate.value(normalized: true, canvasW: 1920, canvasH: 1080,
                                              authoredW: 1920, authoredH: 1080), 1)
    }

    func testSquareShardNormalizedIsOne() {
        // Square is UNROTATED width-anchor (spec §3) — gate 1, not "not-landscape ⇒ 2".
        XCTAssertEqual(FlockFramingGate.value(normalized: true, canvasW: 1080, canvasH: 1080,
                                              authoredW: 1920, authoredH: 1080), 1)
    }

    func testPortraitShardLandscapeAuthoredIsTwo() {
        XCTAssertEqual(FlockFramingGate.value(normalized: true, canvasW: 1080, canvasH: 1920,
                                              authoredW: 1920, authoredH: 1080), 2)
        XCTAssertEqual(FlockFramingGate.value(normalized: true, canvasW: 1080, canvasH: 1350,
                                              authoredW: 800, authoredH: 592), 2)
    }

    func testPortraitShardPortraitAuthoredIsOne() {
        // A portrait-authored genome on a portrait shard is NOT rotated (D3).
        XCTAssertEqual(FlockFramingGate.value(normalized: true, canvasW: 1080, canvasH: 1920,
                                              authoredW: 1080, authoredH: 1920), 1)
    }

    /// `unitFlames` + the row write must derive the SAME gate the compares
    /// derive (write/compare divergence = permanent re-render loop). Asserts
    /// `Framing.portraitRotationDegrees` (not a literal) so a Task 8 A/B
    /// direction flip never breaks this file.
    func testUnitFlamesAgreesWithGate() {
        var landscapeAuthored = Flame(); landscapeAuthored.size = SIMD2<Int>(1920, 1080)
        let shardW = 1080, shardH = 1920
        let (nA, _) = ArchiveRenderer.unitFlames(A: landscapeAuthored, B: nil,
                                                 renderWidth: shardW, renderHeight: shardH,
                                                 framing: .normalized)
        XCTAssertEqual(nA.camera.rotation, Framing.portraitRotationDegrees, accuracy: 1e-12,
                       "rotated ⇒ gate must be 2")
        XCTAssertEqual(FlockFramingGate.value(normalized: true, canvasW: shardW, canvasH: shardH,
                                              authoredW: landscapeAuthored.size.x,
                                              authoredH: landscapeAuthored.size.y), 2)
        // Faithful mode still rotates (D3) but records 0.
        let (fA, _) = ArchiveRenderer.unitFlames(A: landscapeAuthored, B: nil,
                                                 renderWidth: shardW, renderHeight: shardH,
                                                 framing: .faithful)
        XCTAssertEqual(fA.camera.rotation, Framing.portraitRotationDegrees, accuracy: 1e-12)
        XCTAssertEqual(FlockFramingGate.value(normalized: false, canvasW: shardW, canvasH: shardH,
                                              authoredW: landscapeAuthored.size.x,
                                              authoredH: landscapeAuthored.size.y), 0)
    }
}
