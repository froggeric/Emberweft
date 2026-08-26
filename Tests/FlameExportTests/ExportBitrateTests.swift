import XCTest
@testable import FlameExport
import AVFoundation

/// M6.7 D13: ONE pixel-band bitrate source (named + `.custom` agree), plus the
/// portrait `Resolution` cases and derived orientation (D2). `@testable`:
/// `ExportCoordinator.autoBitrateMbps` is `internal` (same pattern as
/// `ExportManager.resolveSettings`).
final class ExportBitrateTests: XCTestCase {

    func testNamedCasesCarryPortraitDims() {
        XCTAssertEqual(ExportSettings.Resolution.vertical720.width, 720)
        XCTAssertEqual(ExportSettings.Resolution.vertical720.height, 1280)
        XCTAssertEqual(ExportSettings.Resolution.vertical1080.width, 1080)
        XCTAssertEqual(ExportSettings.Resolution.vertical1080.height, 1920)
        XCTAssertEqual(ExportSettings.Resolution.portrait4x5.width, 1080)
        XCTAssertEqual(ExportSettings.Resolution.portrait4x5.height, 1350)
        XCTAssertEqual(ExportSettings.Resolution.square1080.width, 1080)
        XCTAssertEqual(ExportSettings.Resolution.square1080.height, 1080)
    }

    func testOrientationDerivedFromDims() {
        XCTAssertEqual(ExportSettings.Resolution.p1080.orientation, .landscape)
        XCTAssertEqual(ExportSettings.Resolution.vertical1080.orientation, .portrait)
        XCTAssertEqual(ExportSettings.Resolution.square1080.orientation, .square)
        XCTAssertEqual(ExportSettings.Resolution.custom(width: 100, height: 200).orientation, .portrait)
        XCTAssertEqual(ExportSettings.Resolution.custom(width: 200, height: 200).orientation, .square)
    }

    /// Landscape named values are UNCHANGED (D13) — the pre-M6.7 tiers.
    func testLandscapeNamedTiersUnchanged() {
        let cases: [(ExportSettings.Resolution, Int, Int)] = [
            (.p720, 25, 40), (.p1080, 50, 80), (.p1440, 80, 130), (.p4k, 150, 240)]
        for (res, hevc, h264) in cases {
            XCTAssertEqual(ExportBitrate.mbps(codec: .hevc, width: res.width, height: res.height, fps: 30), hevc)
            XCTAssertEqual(ExportBitrate.mbps(codec: .h264, width: res.width, height: res.height, fps: 30), h264)
        }
    }

    /// The four portrait presets land on their pixel-equivalent tiers (spec §4):
    /// 720×1280 → 720p tier; 1080×1920 / 1080×1350 / 1080×1080 → 1080p tier.
    /// Literal expectations (not a re-implementation of the classifier).
    func testPortraitPresetsOnPixelEquivalentTiers() {
        let portrait: [(w: Int, h: Int, mbps: Int)] = [
            (720, 1280, 25), (1080, 1920, 50), (1080, 1350, 50), (1080, 1080, 50)]
        for p in portrait {
            XCTAssertEqual(ExportBitrate.mbps(codec: .hevc, width: p.w, height: p.h, fps: 30), p.mbps)
        }
    }

    /// Band-boundary pins: drift inside (921,600, 1,166,400] — the gap no named
    /// case spans — must move the boundary visibly (1,050,000 is inclusive-≤).
    func testBitrateBandBoundariesPinned() {
        XCTAssertEqual(ExportBitrate.mbps(codec: .hevc, width: 1000, height: 1050, fps: 30), 25,
                       "1,050,000 px exactly = the 720p tier's inclusive edge")
        XCTAssertEqual(ExportBitrate.mbps(codec: .hevc, width: 1050, height: 1002, fps: 30), 50,
                       "1,052,100 px = the 1080p tier")
        XCTAssertEqual(ExportBitrate.mbps(codec: .hevc, width: 2000, height: 1250, fps: 30), 50,
                       "2,500,000 px exactly = the 1080p tier's inclusive edge")
        XCTAssertEqual(ExportBitrate.mbps(codec: .hevc, width: 3000, height: 2000, fps: 30), 80,
                       "6,000,000 px exactly = the 1440p tier's inclusive edge")
    }

    /// A `.custom` WxH spelling and its named twin agree (the reason D13
    /// exists — the old flat fallback gave `.custom(720,1280)` 50/80).
    func testCustomTwinAgreesWithNamed() {
        for (named, w, h) in [(ExportSettings.Resolution.vertical720, 720, 1280),
                              (ExportSettings.Resolution.vertical1080, 1080, 1920),
                              (ExportSettings.Resolution.p1080, 1920, 1080)] {
            XCTAssertEqual(ExportBitrate.mbps(codec: .hevc, width: w, height: h, fps: 30),
                           ExportBitrate.mbps(codec: .hevc, width: named.width,
                                              height: named.height, fps: 30))
        }
    }

    func testFpsMultiplierAndProRes() {
        XCTAssertEqual(ExportBitrate.mbps(codec: .h264, width: 1920, height: 1080, fps: 60), 120)
        XCTAssertEqual(ExportBitrate.mbps(codec: .proRes422HQ, width: 1080, height: 1920, fps: 30), 0,
                       "ProRes ignores the table (fixed data-rate codec)")
    }

    /// Encoder and disk-precheck agree — the two call sites now delegate to
    /// ONE function, pinned so they cannot drift again.
    func testEncoderAndPrecheckAgree() throws {
        let all: [ExportSettings.Resolution] = [.p720, .p1080, .p1440, .p4k,
                                                .vertical720, .vertical1080,
                                                .portrait4x5, .square1080]
        for res in all {
            let direct = ExportBitrate.mbps(codec: .hevc, width: res.width, height: res.height, fps: 30)
            XCTAssertEqual(ExportCoordinator.autoBitrateMbps(codec: .hevc, res: res, fps: 30), direct,
                           "\(res)")
        }
    }

    func testResolutionCodableRoundTrip() throws {
        for res in [ExportSettings.Resolution.vertical720, .vertical1080,
                    .portrait4x5, .square1080, .custom(width: 1080, height: 1920)] {
            let data = try JSONEncoder().encode(res)
            XCTAssertEqual(try JSONDecoder().decode(ExportSettings.Resolution.self, from: data), res)
        }
    }
}
