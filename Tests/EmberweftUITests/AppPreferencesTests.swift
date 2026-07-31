import XCTest
@testable import EmberweftUI

final class AppPreferencesTests: XCTestCase {

    /// Unique temp dir per test (rule #2: no shared mutable state between tests).
    private func tempDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("emberweft-prefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testDefaultsRoundTrip() throws {
        let dir = try tempDir()
        let prefs = AppPreferences(qualityPreset: .high, targetFPS: 30, backend: .cpu)
        try prefs.save(directory: dir)

        let loaded = AppPreferences.load(directory: dir)
        XCTAssertEqual(loaded, prefs)
        XCTAssertEqual(loaded.qualityPreset, .high)
        XCTAssertEqual(loaded.targetFPS, 30)
        XCTAssertEqual(loaded.backend, .cpu)
    }

    func testMissingFileReturnsDefaults() throws {
        let dir = try tempDir()
        let loaded = AppPreferences.load(directory: dir)
        XCTAssertEqual(loaded, AppPreferences())
    }

    func testCorruptFileQuarantinedAndReturnsDefaults() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("preferences.json")
        try Data("{ this is not valid json".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let (prefs, quarantined) = AppPreferences.loadResilient(directory: dir)
        XCTAssertEqual(prefs, AppPreferences())
        XCTAssertNotNil(quarantined, "corrupt file should be quarantined")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "original corrupt file should be moved aside")
        if let q = quarantined {
            XCTAssertTrue(FileManager.default.fileExists(atPath: q.path))
            XCTAssertTrue(q.lastPathComponent.hasPrefix("preferences.json.corrupt-"))
        }
    }

    func testRenderParamsMapping() {
        let prefs = AppPreferences(qualityPreset: .high)
        let rp = prefs.renderParams(width: 1920, height: 1080)
        XCTAssertEqual(rp.width, 1920)
        XCTAssertEqual(rp.height, 1080)
        XCTAssertEqual(rp.samplesPerPixel, AppPreferences.QualityPreset.high.samplesPerPixel)
        XCTAssertEqual(rp.oversample, AppPreferences.QualityPreset.high.oversample)
        XCTAssertEqual(rp.seed, prefs.seed)
    }

    func testThumbnailParamsMapping() {
        let prefs = AppPreferences()
        let tp = prefs.thumbnailRenderParams()
        XCTAssertEqual(tp.width, prefs.thumbnailRenderWidth)
        XCTAssertEqual(tp.height, prefs.thumbnailRenderHeight)
        XCTAssertEqual(tp.samplesPerPixel, prefs.thumbnailSPP)
        XCTAssertEqual(tp.oversample, 1)
    }

    func testPreviewParamsMapping() {
        let prefs = AppPreferences()
        let pp = prefs.previewParams()
        XCTAssertEqual(pp.width, prefs.previewWidth)
        XCTAssertEqual(pp.height, prefs.previewHeight)
        XCTAssertEqual(pp.samplesPerPixel, prefs.previewSamplesPerPixel)
        XCTAssertEqual(pp.oversample, 1)
    }

    func testThumbnailBackendDefaultsToMetal() {
        // Thumbnails default to Metal (off-main renderOffMain → fast + no freeze).
        XCTAssertEqual(AppPreferences().thumbnailBackend, .metal)
    }
}
