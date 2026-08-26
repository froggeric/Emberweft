import XCTest
import FlameKit
import FlameExport
@testable import EmberweftUI

/// M6.7: portrait resolutions thread through the sheet's settings resolution
/// unchanged (the matrix transform itself is pinned in FlameKitTests — this
/// layer only moves enums/dims).
@MainActor
final class ExportOrientationUITests: XCTestCase {

    func testResolveSettingsKeepsPortraitResolutionDims() {
        let em = ExportManager()
        em.resolution = .vertical1080
        let s = em.resolveSettings(baseFlame: Flame(), backend: .cpu)
        XCTAssertEqual(s.resolution, .vertical1080)
        XCTAssertEqual(s.resolution.width, 1080)
        XCTAssertEqual(s.resolution.height, 1920)
        XCTAssertEqual(s.resolution.orientation, .portrait)
    }

    func testResolveSettingsKeepsFramingEnumWithPortrait() {
        let em = ExportManager()   // framingChoice defaults .normalized
        em.resolution = .square1080
        let s = em.resolveSettings(baseFlame: Flame(), backend: .cpu)
        XCTAssertEqual(s.framing, em.framingChoice)
        em.framingChoice = .faithful
        XCTAssertEqual(em.resolveSettings(baseFlame: Flame(), backend: .cpu).framing, .faithful)
    }

    func testCustomPortraitDimsDeriveOrientation() {
        let em = ExportManager()
        em.resolution = .custom(width: 1080, height: 1920)
        XCTAssertEqual(em.resolveSettings(baseFlame: Flame(), backend: .cpu)
                         .resolution.orientation, .portrait)
    }
}
