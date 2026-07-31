import XCTest
@testable import EmberweftUI
import FlameKit

@MainActor
final class MetadataStoreTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emberweft-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func entry(_ id: String, _ source: LibrarySource) -> LibraryEntry {
        LibraryEntry(id: id, source: source,
                     fileURL: URL(fileURLWithPath: "/tmp/\(id).flam3"),
                     displayName: id, rank: nil)
    }

    // MARK: - Source-qualified key (no collision)

    func testTwoDirectoryRootsSameStemDoNotCollide() {
        let rootA = URL(fileURLWithPath: "/tmp/rootA")
        let rootB = URL(fileURLWithPath: "/tmp/rootB")
        let store = MetadataStore()
        let eA = entry("0242", .directory(rootA))
        let eB = entry("0242", .directory(rootB))

        store.set(GenomeMetadata(favorite: true), for: eA)
        XCTAssertTrue(store.metadata(for: eA).favorite)
        XCTAssertFalse(store.metadata(for: eB).favorite,
                       "dir B (same stem, different root) must NOT inherit dir A's metadata")
    }

    func testBundleStemVsDirectoryStemDistinct() {
        let root = URL(fileURLWithPath: "/tmp/root")
        let store = MetadataStore()
        store.set(GenomeMetadata(favorite: true), for: entry("0242", .bundle))
        XCTAssertFalse(store.metadata(for: entry("0242", .directory(root))).favorite,
                       "bundle stem must not collide with directory-root stem")
    }

    func testImportedDistinctFromDirectory() {
        let root = URL(fileURLWithPath: "/tmp/root")
        let store = MetadataStore()
        store.set(GenomeMetadata(rating: 5), for: entry("foo", .imported))
        XCTAssertEqual(store.metadata(for: entry("foo", .directory(root))).rating, 0)
    }

    // MARK: - Round-trip

    func testRoundTrip() async throws {
        let dir = try tempDir()
        let store = MetadataStore()
        let md = GenomeMetadata(tags: ["x", "y"], rating: 4, favorite: true, notes: "hi")
        store.set(md, for: entry("alpha", .bundle))
        store.scheduleSave(directory: dir)
        await store.flushSaved()

        let (loaded, quarantined) = MetadataStore.loadResilient(directory: dir)
        XCTAssertNil(quarantined)
        XCTAssertEqual(loaded.metadata(for: entry("alpha", .bundle)),
                       GenomeMetadata(tags: ["x", "y"], rating: 4, favorite: true, notes: "hi"))
    }

    // MARK: - Corrupt file ⇒ quarantine + defaults

    func testCorruptFileQuarantinedAndDefaults() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("metadata.json")
        try Data("{ this is not valid json".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let (store, quarantined) = MetadataStore.loadResilient(directory: dir)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(quarantined, "corrupt file should be quarantined")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "original corrupt file should be moved aside")
        if let q = quarantined {
            XCTAssertTrue(q.lastPathComponent.hasPrefix("metadata.json.corrupt-"))
        }
    }

    // MARK: - tags / determinism (rule #2)

    func testAllTagsSortedDedupedCaseInsensitive() {
        let store = MetadataStore()
        store.set(GenomeMetadata(tags: ["Zebra", "apple", "apple", "Berry"]), for: entry("a", .bundle))
        store.set(GenomeMetadata(tags: ["apple", "cherry"]), for: entry("b", .bundle))
        XCTAssertEqual(store.allTags(), ["apple", "Berry", "cherry", "Zebra"])
    }

    func testTagsNormalizedCaseInsensitiveDedup() {
        XCTAssertEqual(GenomeMetadata.normalizeTags(["B", "a", "A", "b"]), ["a", "B"])
    }

    func testRatingClamped() {
        XCTAssertEqual(GenomeMetadata(rating: -3).rating, 0)
        XCTAssertEqual(GenomeMetadata(rating: 99).rating, 5)
    }

    func testByteStableSaveAcrossEqualState() async throws {
        let e1 = entry("alpha", .bundle)
        let e2 = entry("beta", .bundle)

        let dir1 = try tempDir()
        let s1 = MetadataStore()
        s1.set(GenomeMetadata(tags: ["b", "a", "a"], rating: 3, favorite: true), for: e1)
        s1.set(GenomeMetadata(tags: ["c"], rating: 1), for: e2)
        s1.scheduleSave(directory: dir1)
        await s1.flushSaved()
        let bytes1 = try Data(contentsOf: dir1.appendingPathComponent("metadata.json"))

        let dir2 = try tempDir()
        let s2 = MetadataStore()
        // Same logical state, supplied in a different order / with dup tags:
        s2.set(GenomeMetadata(tags: ["a", "b"], rating: 3, favorite: true), for: e1)
        s2.set(GenomeMetadata(tags: ["c", "c"], rating: 1), for: e2)
        s2.scheduleSave(directory: dir2)
        await s2.flushSaved()
        let bytes2 = try Data(contentsOf: dir2.appendingPathComponent("metadata.json"))

        XCTAssertEqual(bytes1, bytes2,
                       "equal metadata state must serialize byte-identically (rule #2)")
    }

    func testDecodeMissingKeysUsesDefaults() throws {
        // Forward-compat: a record with only a `favorite` key decodes with defaults.
        let json = #"{"foo":{"favorite":true}}"#.data(using: .utf8)!
        let entries = try JSONDecoder().decode([String: GenomeMetadata].self, from: json)
        XCTAssertEqual(entries["foo"]?.favorite, true)
        XCTAssertEqual(entries["foo"]?.rating, 0)
        XCTAssertEqual(entries["foo"]?.tags, [])
        XCTAssertEqual(entries["foo"]?.notes, "")
    }
}
