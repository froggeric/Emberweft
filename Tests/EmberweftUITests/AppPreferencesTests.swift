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
        let prefs = AppPreferences(exportQuality: ExportQualityChoice.high.rawValue,
                                   targetFPS: 30, backend: .cpu)
        try prefs.save(directory: dir)

        let loaded = AppPreferences.load(directory: dir)
        XCTAssertEqual(loaded, prefs)
        XCTAssertEqual(loaded.exportQualityChoice, .high)
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

    /// v0.6.x: `exportQuality` (String raw of `ExportQualityChoice`) is the
    /// Settings default that seeds the export sheet. Defaults to genome-default
    /// (mastering) — the pre-existing sheet default — and decodes additively
    /// (an older prefs file without the key loads at the default; the legacy
    /// `qualityPreset` key it carries is ignored). An unknown stored value
    /// resolves back to genome-default via `exportQualityChoice`.
    func testExportQualityDefaultRoundTripAndLegacyDecode() throws {
        XCTAssertEqual(AppPreferences().exportQualityChoice, .genomeDefault,
                       "out-of-box default is the genome-default mastering tier")
        var prefs = AppPreferences()
        prefs.exportQuality = ExportQualityChoice.medium.rawValue
        let dir = try tempDir()
        try prefs.save(directory: dir)
        XCTAssertEqual(AppPreferences.load(directory: dir).exportQualityChoice, .medium)

        // Legacy file (pre-exportQuality, carries the removed qualityPreset key):
        // decodes at the default, ignores the unknown key.
        let legacy = dir.appendingPathComponent("preferences.json")
        try """
        {"backend":"metal","targetFPS":60,"defaultSamplesPerPixel":8,
         "qualityPreset":"high","seed":1,"thumbnailBackend":"metal",
         "thumbnailHeight":144,"thumbnailSPP":8,"thumbnailWidth":256,
         "thumbnailRenderWidth":1280,"thumbnailRenderHeight":720,
         "previewSamplesPerPixel":2,"previewWidth":854,"previewHeight":480,
         "previewOversample":1,"previewPreset":"draft","density":"medium"}
        """.write(to: legacy, atomically: true, encoding: .utf8)
        XCTAssertEqual(AppPreferences.load(directory: dir).exportQualityChoice, .genomeDefault)

        // Unknown stored value falls back, never crashes.
        prefs.exportQuality = "bogus"
        XCTAssertEqual(prefs.exportQualityChoice, .genomeDefault)
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

    // MARK: - PreviewPreset / PreviewResolution (M4 final)

    func testPreviewPresetDefaultsToDraft() {
        XCTAssertEqual(AppPreferences().previewPreset, .draft)
        XCTAssertEqual(AppPreferences().previewOversample, 1)
    }

    /// Default `.draft` is byte-identical to the pre-preset preview (the
    /// raw-field defaults), so existing users see no behavior change on upgrade.
    func testDraftPresetMatchesLegacyRawDefaults() {
        let prefs = AppPreferences()
        let pp = prefs.previewParams()
        XCTAssertEqual(pp.width, prefs.previewWidth)
        XCTAssertEqual(pp.height, prefs.previewHeight)
        XCTAssertEqual(pp.samplesPerPixel, prefs.previewSamplesPerPixel)
        XCTAssertEqual(pp.oversample, 1)
    }

    func testPreviewParamsMatchesEachNamedPreset() {
        for preset in [AppPreferences.PreviewPreset.draft, .balanced, .quality] {
            var prefs = AppPreferences()
            prefs.previewPreset = preset
            // Set raw fields to sentinel values to PROVE the named preset ignores them.
            prefs.previewWidth = 1; prefs.previewHeight = 1
            prefs.previewSamplesPerPixel = 1; prefs.previewOversample = 9
            let pp = prefs.previewParams()
            XCTAssertEqual(pp.width, preset.resolution.width)
            XCTAssertEqual(pp.height, preset.resolution.height)
            XCTAssertEqual(pp.samplesPerPixel, preset.samplesPerPixel)
            XCTAssertEqual(pp.oversample, preset.oversample)
            XCTAssertEqual(pp.seed, prefs.seed)
        }
    }

    func testPreviewParamsCustomUsesRawFields() {
        var prefs = AppPreferences()
        prefs.previewPreset = .custom
        prefs.previewWidth = 100; prefs.previewHeight = 50
        prefs.previewSamplesPerPixel = 7; prefs.previewOversample = 3
        let pp = prefs.previewParams()
        XCTAssertEqual(pp.width, 100)
        XCTAssertEqual(pp.height, 50)
        XCTAssertEqual(pp.samplesPerPixel, 7)
        XCTAssertEqual(pp.oversample, 3)
    }

    func testPreviewPresetRoundTrip() throws {
        let dir = try tempDir()
        var prefs = AppPreferences()
        prefs.previewPreset = .quality
        prefs.previewOversample = 2
        try prefs.save(directory: dir)
        let loaded = AppPreferences.load(directory: dir)
        XCTAssertEqual(loaded.previewPreset, .quality)
        XCTAssertEqual(loaded.previewOversample, 2)
    }

    /// A pre-M4-final `preferences.json` (no `previewPreset`/`previewOversample`)
    /// must load as `.draft` / `1` (additive decode), never quarantine.
    func testLegacyPrefsMissingPreviewPresetLoadsDraft() throws {
        let dir = try tempDir()
        let json = """
        {"backend":"metal","defaultSamplesPerPixel":8,"density":"medium",
         "directorySources":[],"previewHeight":480,"previewSamplesPerPixel":2,
         "previewWidth":854,"qualityPreset":"medium","seed":1,"targetFPS":60,
         "thumbnailBackend":"metal","thumbnailHeight":144,"thumbnailRenderHeight":720,
         "thumbnailRenderWidth":1280,"thumbnailSPP":8,"thumbnailWidth":256}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("preferences.json"))
        let loaded = AppPreferences.load(directory: dir)
        XCTAssertEqual(loaded.previewPreset, .draft, "legacy file must default to .draft (additive)")
        XCTAssertEqual(loaded.previewOversample, 1)
    }

    func testPreviewResolutionNearestAndLabels() {
        XCTAssertEqual(AppPreferences.PreviewResolution.nearest(width: 1280, height: 720), .p720)
        XCTAssertEqual(AppPreferences.PreviewResolution.nearest(width: 854, height: 480), .p480)
        XCTAssertEqual(AppPreferences.PreviewResolution.nearest(width: 1920, height: 1080), .p1080)
        XCTAssertEqual(AppPreferences.PreviewResolution.nearest(width: 3840, height: 2160), .p4k)
        XCTAssertEqual(AppPreferences.PreviewResolution.p4k.label, "4K")
        // Closer to 720p than 1080p by pixel count.
        XCTAssertEqual(AppPreferences.PreviewResolution.nearest(width: 1300, height: 730), .p720)
    }

    func testPresetDerivedValuesAreInternallyConsistent() {
        // The preset's computed props are the single source of truth previewParams reads.
        for preset in [AppPreferences.PreviewPreset.draft, .balanced, .quality] {
            XCTAssertEqual(preset.detail.contains("\(preset.samplesPerPixel) spp"), true,
                           "detail should mention the preset's spp")
        }
    }

    // MARK: - rememberedCheckpointURL (M6.1 D4)

    /// Default is nil (no remembered paused export).
    func testRememberedCheckpointURLDefaultsToNil() {
        XCTAssertNil(AppPreferences().rememberedCheckpointURL)
    }

    /// The URL round-trips through save/load (encode is synthesized from the
    /// CodingKey; decode is additive via decodeIfPresent).
    func testRememberedCheckpointURLRoundTrips() throws {
        let dir = try tempDir()
        var prefs = AppPreferences()
        let url = URL(fileURLWithPath: "/tmp/test.emberweft-export.json")
        prefs.rememberedCheckpointURL = url
        try prefs.save(directory: dir)

        let loaded = AppPreferences.load(directory: dir)
        XCTAssertEqual(loaded.rememberedCheckpointURL?.path, url.path)
        XCTAssertEqual(loaded, prefs, "full struct must round-trip including the new field")
    }

    /// A pre-M6.1 `preferences.json` (no `rememberedCheckpointURL` key) must load
    /// with nil rather than failing/quarantining — the field is purely additive
    /// (custom decoder uses decodeIfPresent). Guards against a schema break on upgrade.
    func testLegacyPrefsMissingRememberedCheckpointURLLoadsNil() throws {
        let dir = try tempDir()
        let json = """
        {"backend":"metal","defaultSamplesPerPixel":8,"density":"medium",
         "directorySources":[],"previewHeight":480,"previewSamplesPerPixel":2,
         "previewWidth":854,"previewPreset":"draft","previewOversample":1,
         "qualityPreset":"medium","seed":1,"targetFPS":60,
         "thumbnailBackend":"metal","thumbnailHeight":144,"thumbnailRenderHeight":720,
         "thumbnailRenderWidth":1280,"thumbnailSPP":8,"thumbnailWidth":256}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("preferences.json"))
        let loaded = AppPreferences.load(directory: dir)
        XCTAssertNil(loaded.rememberedCheckpointURL,
                     "legacy file without the field must decode to nil (additive — P11)")
        XCTAssertEqual(loaded.backend, .metal)
    }

    /// `nil` (explicit) also round-trips — encoded as JSON null and decoded back
    /// to nil by decodeIfPresent.
    func testRememberedCheckpointURLNilRoundTrips() throws {
        let dir = try tempDir()
        let prefs = AppPreferences()
        XCTAssertNil(prefs.rememberedCheckpointURL)
        try prefs.save(directory: dir)
        let loaded = AppPreferences.load(directory: dir)
        XCTAssertNil(loaded.rememberedCheckpointURL)
    }

    // MARK: - flockDir (M6.5 T18)

    /// Default is nil (⇒ the default `<app-support>/Emberweft/Flock` root is
    /// resolved at use). Round-trips a configured folder through encode/decode.
    func testFlockDirDefaultsNilAndRoundTrips() throws {
        var p = AppPreferences()
        XCTAssertNil(p.flockDir)
        p.flockDir = URL(fileURLWithPath: "/tmp/Flock")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertEqual(decoded.flockDir?.path, "/tmp/Flock")
    }

    /// A v0.5.7 `preferences.json` written before `flockDir` existed must load
    /// with nil rather than failing/quarantining — the field is purely additive
    /// (custom decoder uses decodeIfPresent). The fixture is built by encoding
    /// current prefs and stripping the `flockDir` key via JSONSerialization, so
    /// it mirrors a real legacy blob (the M6.1 S6 lesson).
    func testFlockDirAbsentOnOldPrefsDecodesNil() throws {
        var blob = try JSONEncoder().encode(AppPreferences())
        var dict = try JSONSerialization.jsonObject(with: blob) as! [String: Any]
        dict.removeValue(forKey: "flockDir")
        blob = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: blob)
        XCTAssertNil(decoded.flockDir,
                     "legacy file without flockDir must decode to nil (additive — T18)")
    }

    // MARK: - flockDefaultShard (M6.5 — the Flock tabs' initial shard)

    /// Default is nil (⇒ the canonical 1080p30 default is resolved by the Flock
    /// tabs). Round-trips a configured shard name through encode/decode.
    func testFlockDefaultShardDefaultsNilAndRoundTrips() throws {
        var p = AppPreferences()
        XCTAssertNil(p.flockDefaultShard)
        p.flockDefaultShard = "2560x1440_30fps"
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertEqual(decoded.flockDefaultShard, "2560x1440_30fps")
    }

    /// A `preferences.json` written before `flockDefaultShard` existed must load
    /// with nil rather than failing/quarantining — purely additive
    /// (`decodeIfPresent`). Built by stripping the key from a current blob, so
    /// it mirrors a real legacy file (same approach as `flockDir` above).
    func testFlockDefaultShardAbsentOnOldPrefsDecodesNil() throws {
        var blob = try JSONEncoder().encode(AppPreferences())
        var dict = try JSONSerialization.jsonObject(with: blob) as! [String: Any]
        dict.removeValue(forKey: "flockDefaultShard")
        blob = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: blob)
        XCTAssertNil(decoded.flockDefaultShard,
                     "legacy file without flockDefaultShard must decode to nil (additive)")
        // The rest of the prefs still decode.
        XCTAssertEqual(decoded.previewPreset, AppPreferences().previewPreset)
    }
}
