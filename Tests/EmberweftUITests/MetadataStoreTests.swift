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
        store.set(GenomeMetadata(sentiment: 1), for: eA)
        XCTAssertEqual(store.metadata(for: eA).sentiment, 1)
        XCTAssertEqual(store.metadata(for: eB).sentiment, 0,
                       "dir B (same stem, different root) must NOT inherit dir A's metadata")
    }

    func testBundleStemVsDirectoryStemDistinct() {
        let root = URL(fileURLWithPath: "/tmp/root")
        let store = MetadataStore()
        store.set(GenomeMetadata(sentiment: 1), for: entry("0242", .bundle))
        XCTAssertEqual(store.metadata(for: entry("0242", .directory(root))).sentiment, 0)
    }

    // MARK: - Sentiment

    func testSentimentIsClamped() {
        XCTAssertEqual(GenomeMetadata(sentiment: 5).sentiment, 1)
        XCTAssertEqual(GenomeMetadata(sentiment: -9).sentiment, -1)
        XCTAssertEqual(GenomeMetadata.clamp(2), 1)
        XCTAssertEqual(GenomeMetadata.clamp(-2), -1)
    }

    func testAdjustSentimentClampsAtBounds() {
        let store = MetadataStore()
        let e = entry("a", .bundle)
        store.set(GenomeMetadata(sentiment: 1), for: e)
        store.adjustSentiment(for: e, by: 1)            // already +1 ⇒ stays +1
        XCTAssertEqual(store.metadata(for: e).sentiment, 1)
        store.adjustSentiment(for: e, by: -3)           // ⇒ -1 (clamped)
        XCTAssertEqual(store.metadata(for: e).sentiment, -1)
    }

    // MARK: - Round-trip

    func testRoundTrip() async throws {
        let dir = try tempDir()
        let store = MetadataStore()
        store.set(GenomeMetadata(sentiment: 1, importedAt: Date(timeIntervalSince1970: 1234)),
                  for: entry("alpha", .bundle))
        store.scheduleSave(directory: dir)
        await store.flushSaved()
        let (loaded, quarantined) = MetadataStore.loadResilient(directory: dir)
        XCTAssertNil(quarantined)
        XCTAssertEqual(loaded.metadata(for: entry("alpha", .bundle)).sentiment, 1)
    }

    // MARK: - Corrupt file ⇒ quarantine + defaults

    func testCorruptFileQuarantinedAndDefaults() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("metadata.json")
        try Data("{ this is not valid json".utf8).write(to: url)
        let (store, quarantined) = MetadataStore.loadResilient(directory: dir)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(quarantined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Determinism (rule #2)

    func testByteStableSaveAcrossEqualState() async throws {
        let e1 = entry("alpha", .bundle), e2 = entry("beta", .bundle)
        let dir1 = try tempDir()
        let s1 = MetadataStore()
        s1.set(GenomeMetadata(sentiment: 1), for: e1)
        s1.set(GenomeMetadata(sentiment: -1), for: e2)
        s1.scheduleSave(directory: dir1); await s1.flushSaved()
        let bytes1 = try Data(contentsOf: dir1.appendingPathComponent("metadata.json"))

        let dir2 = try tempDir()
        let s2 = MetadataStore()
        s2.set(GenomeMetadata(sentiment: 1), for: e1)
        s2.set(GenomeMetadata(sentiment: -1), for: e2)
        s2.scheduleSave(directory: dir2); await s2.flushSaved()
        let bytes2 = try Data(contentsOf: dir2.appendingPathComponent("metadata.json"))
        XCTAssertEqual(bytes1, bytes2, "equal metadata state must serialize byte-identically (rule #2)")
    }

    // MARK: - v1 migration (favorite → like) + missing-key defaults

    func testDecodeMissingKeysUsesDefaults() throws {
        let json = #"{"foo":{"sentiment":1}}"#.data(using: .utf8)!
        let entries = try JSONDecoder().decode([String: GenomeMetadata].self, from: json)
        XCTAssertEqual(entries["foo"]?.sentiment, 1)
        XCTAssertEqual(entries["foo"]?.schemaVersion, 2)
        XCTAssertNil(entries["foo"]?.importedAt)
    }

    func testV1FavoriteMigratesToLike() throws {
        // A v1 record with favorite:true (no sentiment) migrates to sentiment=+1.
        let json = #"{"foo":{"favorite":true}}"#.data(using: .utf8)!
        let entries = try JSONDecoder().decode([String: GenomeMetadata].self, from: json)
        XCTAssertEqual(entries["foo"]?.sentiment, 1)
        // favorite:false (or absent) stays neutral.
        let json2 = #"{"bar":{"favorite":false}}"#.data(using: .utf8)!
        let entries2 = try JSONDecoder().decode([String: GenomeMetadata].self, from: json2)
        XCTAssertEqual(entries2["bar"]?.sentiment, 0)
    }
}
