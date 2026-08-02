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

    // MARK: - Density (B11)

    func testDensityDefaultsToMedium() {
        XCTAssertEqual(AppPreferences().density, .medium)
        XCTAssertEqual(AppPreferences.Density.medium.gridMinimum, 180)
    }

    func testDensityGridMinimumMapping() {
        XCTAssertEqual(AppPreferences.Density.small.gridMinimum, 140)
        XCTAssertEqual(AppPreferences.Density.medium.gridMinimum, 180)
        XCTAssertEqual(AppPreferences.Density.large.gridMinimum, 240)
    }

    func testDensityRoundTrip() throws {
        let dir = try tempDir()
        var prefs = AppPreferences()
        prefs.density = .large
        try prefs.save(directory: dir)

        let loaded = AppPreferences.load(directory: dir)
        XCTAssertEqual(loaded, prefs)
        XCTAssertEqual(loaded.density, .large)
    }

    /// A pre-B11 `preferences.json` (no `density` key) must load with `.medium`
    /// rather than failing/quarantining — density is purely additive (custom
    /// decoder uses decodeIfPresent). Guards against a schema break for existing
    /// users on upgrade.
    func testLegacyPrefsMissingDensityLoadsMedium() throws {
        let dir = try tempDir()
        let json = """
        {"backend":"metal","defaultLibraryDir":null,"defaultSamplesPerPixel":8,
         "previewHeight":480,"previewSamplesPerPixel":2,"previewWidth":854,
         "qualityPreset":"medium","seed":1,"targetFPS":60,
         "thumbnailBackend":"metal","thumbnailHeight":144,"thumbnailRenderHeight":720,
         "thumbnailRenderWidth":1280,"thumbnailSPP":8,"thumbnailWidth":256}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("preferences.json"))

        let loaded = AppPreferences.load(directory: dir)
        XCTAssertEqual(loaded.density, .medium,
                       "legacy file without density must default to .medium (additive)")
        XCTAssertEqual(loaded.backend, .metal)
        XCTAssertEqual(loaded.qualityPreset, .medium)
    }

    // MARK: - directorySources (multi-folder)

    func testDirectorySourcesRoundTrip() throws {
        let dir = try tempDir()
        var prefs = AppPreferences()
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("ew-a-\(UUID().uuidString)")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("ew-b-\(UUID().uuidString)")
        prefs.directorySources = [a, b]
        try prefs.save(directory: dir)

        let loaded = AppPreferences.load(directory: dir)
        // Compare by path: Foundation's URL Codable form is an implementation
        // detail; the on-disk meaning is the folder path.
        XCTAssertEqual(loaded.directorySources.map(\.path), prefs.directorySources.map(\.path))
    }

    /// A pre-multi-folder `preferences.json` with a single `defaultLibraryDir`
    /// must migrate that folder into `directorySources` on load (not lose it /
    /// not quarantine). Migration fires only when `directorySources` is absent or
    /// empty, so an already-migrated file is left alone.
    func testLegacyDefaultLibraryDirMigratesIntoDirectorySources() throws {
        let dir = try tempDir()
        let json = """
        {"backend":"metal","defaultLibraryDir":"/Volumes/old/sheep","defaultSamplesPerPixel":8,
         "previewHeight":480,"previewSamplesPerPixel":2,"previewWidth":854,
         "qualityPreset":"medium","seed":1,"targetFPS":60,
         "thumbnailBackend":"metal","thumbnailHeight":144,"thumbnailRenderHeight":720,
         "thumbnailRenderWidth":1280,"thumbnailSPP":8,"thumbnailWidth":256}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("preferences.json"))

        let loaded = AppPreferences.load(directory: dir)
        XCTAssertEqual(loaded.directorySources.map(\.path), ["/Volumes/old/sheep"],
                       "legacy single folder must migrate into directorySources")
        XCTAssertEqual(loaded.density, .medium, "density stays additive")
    }

    /// An already-migrated file (has `directorySources`) ignores the legacy
    /// `defaultLibraryDir` key, so a stale legacy value can't double the folder.
    func testDirectorySourcesPreferredOverLegacyDefaultLibraryDir() throws {
        let dir = try tempDir()
        let json = """
        {"backend":"metal","defaultLibraryDir":"/Volumes/old/sheep","defaultSamplesPerPixel":8,
         "directorySources":["/Volumes/new/a","/Volumes/new/b"],
         "previewHeight":480,"previewSamplesPerPixel":2,"previewWidth":854,
         "qualityPreset":"medium","seed":1,"targetFPS":60,
         "thumbnailBackend":"metal","thumbnailHeight":144,"thumbnailRenderHeight":720,
         "thumbnailRenderWidth":1280,"thumbnailSPP":8,"thumbnailWidth":256}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("preferences.json"))

        let loaded = AppPreferences.load(directory: dir)
        XCTAssertEqual(loaded.directorySources.map(\.path),
                       ["/Volumes/new/a", "/Volumes/new/b"])
    }

    /// `dedupe` is order-preserving and collapses paths that standardize to the
    /// same string (rule #2: Set is membership-only; the array order is stable).
    func testDedupeDirectorySourcesCollapsesEquivalentPaths() {
        let a = URL(fileURLWithPath: "/Volumes/lib/sheep")
        let sameA = URL(fileURLWithPath: "/Volumes/lib/sheep/")
        let b = URL(fileURLWithPath: "/Volumes/lib/other")
        let deduped = AppPreferences.dedupe([a, b, sameA])
        XCTAssertEqual(deduped.count, 2)
        XCTAssertEqual(deduped.first?.path, a.path)
    }

    /// `addDirectorySource` is idempotent; `removeDirectorySource` is purely
    /// in-memory (AppPreferences never touches the filesystem). Files-on-disk
    /// safety for "remove from library" is enforced at this layer.
    func testAddRemoveDirectorySourceIsIdempotentAndInMemory() {
        var prefs = AppPreferences()
        let a = URL(fileURLWithPath: "/Volumes/lib/a")

        prefs.addDirectorySource(a)
        prefs.addDirectorySource(a)              // duplicate → no-op
        XCTAssertEqual(prefs.directorySources.map(\.path), ["/Volumes/lib/a"])

        prefs.removeDirectorySource(a)
        XCTAssertTrue(prefs.directorySources.isEmpty,
                      "removeDirectorySource must drop the folder from the list")
        // No FileManager API exists on AppPreferences — removal is structural,
        // so nothing on disk is ever touched. (No assertion needed; structural.)
    }
}
