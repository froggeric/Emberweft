import XCTest
@testable import EmberweftUI
import FlameExport
import FlameKit

@MainActor
final class ExportFramingUITests: XCTestCase {
    private func renderableFlame() -> Flame {
        Flame(
            camera: Camera(center: .zero, scale: 250, zoom: 0, rotation: 0),
            quality: Quality(oversample: 1, samplesPerPixel: 50),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])]
        )
    }

    func testSheetDefaultResolvesNormalized() {
        let em = ExportManager()
        let s = em.resolveSettings(baseFlame: renderableFlame(), backend: .cpu)
        XCTAssertEqual(s.framing, .normalized, "the GUI one-shot export defaults to normalized framing")
    }

    func testFaithfulSelectionThreadsThrough() {
        let em = ExportManager()
        em.framingChoice = .faithful
        let s = em.resolveSettings(baseFlame: renderableFlame(), backend: .cpu)
        XCTAssertEqual(s.framing, .faithful, "the sheet picker's Authored selection reaches the built settings")
    }
}
