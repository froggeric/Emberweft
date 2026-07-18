import XCTest
@testable import FlameKit

// Task 17: Feature-vector disk cache (F5). One sorted-array record per sheep id
// under `<libraryDir>/.feature_cache/`. Incremental rebuild by mtime, explicit
// full rebuild, and a clear error when similarity is requested with a fully
// absent cache.
//
// F1: cache records serialize as SORTED ARRAYS (deterministic decode), never a
// String-keyed Dict whose iteration could reorder across encoders.
final class FeatureCacheTests: XCTestCase {

    // MARK: - Incremental rebuild: new file by mtime

    func testIncrementalRebuildPicksUpNewFile() throws {
        let lib = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: lib) }

        let cache = FeatureCache(libraryDir: lib)

        // First scan: one sheep.
        _ = try cache.scan()
        let filesBefore = try cache.flam3Files()
        XCTAssertEqual(filesBefore.count, 1, "expected the seed sheep")

        // Add a second, distinct sheep and re-scan → new record built.
        try writeFlam3(in: lib, relative: "sheep_B.flam3",
                       name: "sheep_B", variations: [("sinusoidal", 0.8)])
        let vectors = try cache.scan()

        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(try cache.flam3Files().count, 2)
        // The new record exists and decodes to the expected vector.
        let recB = try cache.record(forID: "sheep_B")
        let directB = FeatureVector(for: try parseFlam3(in: lib, relative: "sheep_B.flam3"))
        XCTAssertEqual(recB.featureVector.variations.map { $0.name },
                       directB.variations.map { $0.name })
    }

    // MARK: - Incremental rebuild: changed file (newer mtime) → rebuilt

    func testChangedFileNewerMtimeIsRebuilt() throws {
        let lib = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: lib) }

        // Seed source with an old mtime.
        let src = lib.appendingPathComponent("sheep_A.flam3")
        try setMtime(src, Date(timeIntervalSince1970: 1_000_000))

        let cache = FeatureCache(libraryDir: lib)
        _ = try cache.scan()
        let recordBefore = try cache.record(forID: "sheep_A")
        XCTAssertEqual(recordBefore.sourceMtime, 1_000_000, accuracy: 1.0)

        // Rewrite the source content AND bump mtime → record must be rebuilt.
        try writeFlam3(in: lib, relative: "sheep_A.flam3",
                       name: "sheep_A", variations: [("linear", 0.3), ("swirl", 0.9)])
        try setMtime(src, Date(timeIntervalSince1970: 2_000_000))

        _ = try cache.scan()
        let recordAfter = try cache.record(forID: "sheep_A")
        XCTAssertEqual(recordAfter.sourceMtime, 2_000_000, accuracy: 1.0)
        // Content changed: rebuilt record now reflects the swirl variation.
        XCTAssertTrue(recordAfter.featureVector.variations.contains { $0.name == "swirl" },
                      "rebuilt record must reflect the new source content")
    }

    // MARK: - Unchanged files → NOT rebuilt

    func testUnchangedFileIsNotRebuilt() throws {
        let lib = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: lib) }

        let cache = FeatureCache(libraryDir: lib)
        _ = try cache.scan()

        let cacheFile = cache.cacheFile(forID: "sheep_A")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
        // Capture the record file's own mtime.
        let recMtimeBefore = try FileManager.default
            .attributesOfItem(atPath: cacheFile.path)[.modificationDate] as? Date

        // Re-scan with no source change → record file must NOT be rewritten.
        _ = try cache.scan()
        let recMtimeAfter = try FileManager.default
            .attributesOfItem(atPath: cacheFile.path)[.modificationDate] as? Date
        XCTAssertEqual(recMtimeBefore, recMtimeAfter,
                       "unchanged record must not be rewritten")
    }

    // MARK: - Absent cache + similarity → clear error

    func testAbsentCacheSimilarityThrowsClearError() throws {
        let lib = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: lib) }

        let cache = FeatureCache(libraryDir: lib)
        // No scan / rebuild performed → cache fully absent.
        XCTAssertThrowsError(try cache.loadForSimilararity()) { error in
            switch error as? FeatureCacheError {
            case .cacheAbsent:
                break   // the clear, user-actionable error
            default:
                XCTFail("expected .cacheAbsent, got \(error)")
            }
        }
    }

    // MARK: - Sequential needs no cache

    func testSequentialSelectorNeedsNoCache() throws {
        // A sequential walk proceeds with zero cache I/O. Constructing and
        // driving Sequential must not require any feature cache at all.
        var seq = Sequential(seed: 1)
        let next = seq.next(from: 0, librarySize: 4)
        XCTAssertEqual(next, 1)
        // The cache directory is never created for a sequential-only run.
        let lib = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: lib) }
        let cache = FeatureCache(libraryDir: lib)
        _ = seq.next(from: 1, librarySize: 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.cacheDir.path),
                       "sequential selector must not create a cache directory")
    }

    // MARK: - loadForSimilararity succeeds after scan

    func testLoadForSimilararityAfterScan() throws {
        let lib = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: lib) }
        try writeFlam3(in: lib, relative: "second.flam3",
                       name: "second", variations: [("horseshoe", 0.5)])

        let cache = FeatureCache(libraryDir: lib)
        let scanned = try cache.scan()
        let loaded = try cache.loadForSimilararity()
        XCTAssertEqual(scanned.count, loaded.count)
        XCTAssertEqual(loaded.count, 2)
    }

    // MARK: - Full rebuild

    func testRebuildAllClearsAndRebuilds() throws {
        let lib = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: lib) }

        let cache = FeatureCache(libraryDir: lib)
        _ = try cache.scan()

        // Remove the source so a stale orphan record would linger after an
        // incremental scan; rebuildAll must still yield a consistent cache.
        try FileManager.default.removeItem(at: lib.appendingPathComponent("sheep_A.flam3"))
        try writeFlam3(in: lib, relative: "fresh.flam3",
                       name: "fresh", variations: [("linear", 1.0)])

        let rebuilt = try cache.rebuildAll()
        XCTAssertEqual(rebuilt.count, 1)
        XCTAssertEqual(try cache.flam3Files().count, 1)
        // Old orphan record gone.
        XCTAssertThrowsError(try cache.record(forID: "sheep_A")) { _ in }
        // New record present.
        _ = try cache.record(forID: "fresh")
    }

    // MARK: - F1: records are sorted-array (deterministic)

    func testRecordsSerializeAsSortedArray_F1() throws {
        let lib = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: lib) }

        let cache = FeatureCache(libraryDir: lib)
        _ = try cache.scan()

        let cacheFile = cache.cacheFile(forID: "sheep_A")
        let data = try Data(contentsOf: cacheFile)

        // Decode generically: `variations` must be an ARRAY, never a String-keyed
        // object (an object's key order is not guaranteed across encoders).
        let json = try JSONSerialization.jsonObject(with: data)
        guard let obj = json as? [String: Any] else {
            return XCTFail("record is not a JSON object")
        }
        guard let vars = obj["variations"] as? [Any] else {
            return XCTFail("variations must serialize as an array (F1), got: \(String(describing: obj["variations"]))")
        }
        XCTAssertFalse(vars.isEmpty, "fixture sheep should have ≥1 variation")
        // Names within the array must be sorted ascending (lexicographic).
        let names = vars.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, names.sorted(),
                       "variation array must be sorted by name (F1)")

        // Deterministic re-encode: same record → byte-identical JSON.
        let rec = try cache.record(forID: "sheep_A")
        let enc1 = try FeatureCacheRecord.encoded(rec)
        let enc2 = try FeatureCacheRecord.encoded(rec)
        XCTAssertEqual(enc1, enc2, "record encoding must be byte-stable (F1)")

        // Round-trips back to an equivalent FeatureVector.
        let direct = FeatureVector(for: try parseFlam3(in: lib, relative: "sheep_A.flam3"))
        XCTAssertEqual(rec.featureVector.variations.map { $0.name },
                       direct.variations.map { $0.name })
        XCTAssertEqual(rec.featureVector.xformCount, direct.xformCount)
    }

    func testCacheFilesSortedByIDAcrossFiles() throws {
        // Multiple records → their ids sort lexicographically matches the
        // sorted-by-relative-path flam3 listing (the index alignment contract).
        let lib = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: lib) }
        try writeFlam3(in: lib, relative: "zzz.flam3", name: "zzz", variations: [("linear", 1.0)])
        try writeFlam3(in: lib, relative: "aaa.flam3", name: "aaa", variations: [("linear", 1.0)])

        let cache = FeatureCache(libraryDir: lib)
        let vectors = try cache.scan()
        XCTAssertEqual(vectors.count, 3)
        // flam3Files() sorted by relative path → ["aaa.flam3", "sheep_A.flam3", "zzz.flam3"].
        let files = try cache.flam3Files().map { $0.lastPathComponent }
        XCTAssertEqual(files, files.sorted())
    }

    // MARK: - Helpers

    private func makeTempLibrary() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("emberweft-featurecache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Seed with one sheep so the library is non-empty.
        try writeFlam3(in: tmp, relative: "sheep_A.flam3",
                       name: "sheep_A", variations: [("linear", 1.0)])
        return tmp
    }

    /// Write a minimal valid `.flam3` with the given per-xform variation weights.
    private func writeFlam3(in libraryDir: URL, relative: String,
                            name: String, variations: [(String, Double)]) throws {
        var attrs = ""
        for (n, w) in variations { attrs += " \(n)=\"\(w)\"" }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <flames>
        <flame name="\(name)" size="320 200" quality="100" center="0 0" scale="100">
        <xform weight="1.0" color="0.0" coefs="0.7 0.0 0.0 0.7 0.0 0.0"\(attrs)/>
        </flame>
        </flames>
        """
        let url = libraryDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try xml.data(using: .utf8)!.write(to: url)
    }

    private func parseFlam3(in libraryDir: URL, relative: String) throws -> Flame {
        let url = libraryDir.appendingPathComponent(relative)
        let data = try Data(contentsOf: url)
        return try Flam3Parser.parse(data).first!
    }

    private func setMtime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path)
    }
}
