import XCTest
@testable import EmberweftUI
import FlameKit

@MainActor
final class CollectionsStoreTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emberweft-collections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func entry(_ id: String, _ source: LibrarySource) -> LibraryEntry {
        LibraryEntry(id: id, source: source,
                     fileURL: URL(fileURLWithPath: "/tmp/\(id).flam3"),
                     displayName: id, rank: nil)
    }

    private func ce(_ id: String, _ source: LibrarySource) -> CollectionEntry {
        CollectionEntry(entry(id, source))
    }

    // MARK: - CollectionEntry (mirrors PlaybackRoute shape)

    func testCollectionEntryFromLibraryEntryRoundTripsSourceFields() {
        let root = URL(fileURLWithPath: "/tmp/root")
        XCTAssertEqual(ce("0242", .bundle).source, "bundle")
        XCTAssertEqual(ce("0242", .bundle).rootPath, nil)
        XCTAssertEqual(ce("0242", .directory(root)).source, "directory")
        XCTAssertEqual(ce("0242", .directory(root)).rootPath, "/tmp/root")
        XCTAssertEqual(ce("0242", .imported).source, "imported")
    }

    func testIdentityIsStableAndSourceQualified() {
        let rootA = URL(fileURLWithPath: "/tmp/rootA")
        let rootB = URL(fileURLWithPath: "/tmp/rootB")
        // Same stem, different roots → different identity (no collision).
        XCTAssertNotEqual(ce("0242", .directory(rootA)).identity,
                          ce("0242", .directory(rootB)).identity)
        // Bundle vs directory same stem → different identity.
        XCTAssertNotEqual(ce("0242", .bundle).identity,
                          ce("0242", .directory(rootA)).identity)
        // Equal entries → equal identity (deterministic).
        XCTAssertEqual(ce("0242", .bundle).identity, ce("0242", .bundle).identity)
    }

    // MARK: - Create

    func testCreateAppendsAndReturnsCollection() {
        let store = CollectionsStore()
        let c = store.create(name: "Favorites", from: [ce("a", .bundle), ce("b", .bundle)])
        XCTAssertEqual(store.collections.count, 1)
        XCTAssertEqual(store.collections.first?.id, c.id)
        XCTAssertEqual(c.name, "Favorites")
        XCTAssertEqual(c.entries.map(\.id), ["a", "b"], "entries preserved in given order")
    }

    func testCreateEmptyNameBecomesUntitled() {
        let store = CollectionsStore()
        let c = store.create(name: "   ", from: [])
        XCTAssertEqual(c.name, "Untitled")
    }

    // MARK: - Rename / Delete

    func testRenameUpdatesName() {
        let store = CollectionsStore()
        let c = store.create(name: "Old", from: [])
        store.rename(c.id, to: "New")
        XCTAssertEqual(store.collection(id: c.id)?.name, "New")
    }

    func testRenameEmptyFallsBackToUntitled() {
        let store = CollectionsStore()
        let c = store.create(name: "Old", from: [])
        store.rename(c.id, to: "")
        XCTAssertEqual(store.collection(id: c.id)?.name, "Untitled")
    }

    func testRenameUnknownIdIsNoOp() {
        let store = CollectionsStore()
        store.create(name: "A", from: [])
        store.rename(UUID(), to: "X")
        XCTAssertEqual(store.collections.count, 1)
        XCTAssertEqual(store.collections.first?.name, "A")
    }

    func testDeleteRemovesCollection() {
        let store = CollectionsStore()
        let a = store.create(name: "A", from: [])
        let b = store.create(name: "B", from: [])
        store.delete(a.id)
        XCTAssertEqual(store.collections.map(\.id), [b.id])
        XCTAssertNil(store.collection(id: a.id))
    }

    // MARK: - addEntries (dedupe by identity)

    func testAddEntriesDedupesByIdentity() {
        let store = CollectionsStore()
        let c = store.create(name: "C", from: [ce("a", .bundle)])
        let added = store.addEntries([ce("a", .bundle), ce("b", .bundle)], to: c.id)
        XCTAssertEqual(added, 1, "the duplicate 'a' is skipped, 'b' is added")
        XCTAssertEqual(store.collection(id: c.id)?.entries.map(\.id), ["a", "b"])
    }

    func testAddEntriesToUnknownIdAddsNothing() {
        let store = CollectionsStore()
        XCTAssertEqual(store.addEntries([ce("a", .bundle)], to: UUID()), 0)
    }

    // MARK: - removeEntry (stored-index)

    func testRemoveEntryByStoredIndex() {
        let store = CollectionsStore()
        let c = store.create(name: "C", from: [ce("a", .bundle), ce("b", .bundle), ce("c", .bundle)])
        store.removeEntry(at: 1, from: c.id)   // remove "b"
        XCTAssertEqual(store.collection(id: c.id)?.entries.map(\.id), ["a", "c"])
    }

    func testRemoveEntryOutOfRangeIsNoOp() {
        let store = CollectionsStore()
        let c = store.create(name: "C", from: [ce("a", .bundle)])
        store.removeEntry(at: 5, from: c.id)
        XCTAssertEqual(store.collection(id: c.id)?.entries.count, 1)
    }

    // MARK: - moveEntry (reorder)

    func testMoveEntryDownSwapsOrder() {
        let store = CollectionsStore()
        let c = store.create(name: "C", from: [ce("a", .bundle), ce("b", .bundle), ce("c", .bundle)])
        store.moveEntry(in: c.id, from: 0, to: 1)   // a → position 1
        XCTAssertEqual(store.collection(id: c.id)?.entries.map(\.id), ["b", "a", "c"])
    }

    func testMoveEntryUpSwapsOrder() {
        let store = CollectionsStore()
        let c = store.create(name: "C", from: [ce("a", .bundle), ce("b", .bundle), ce("c", .bundle)])
        store.moveEntry(in: c.id, from: 2, to: 0)   // c → position 0
        XCTAssertEqual(store.collection(id: c.id)?.entries.map(\.id), ["c", "a", "b"])
    }

    func testMoveEntryOutOfRangeFromIsNoOp() {
        let store = CollectionsStore()
        let c = store.create(name: "C", from: [ce("a", .bundle), ce("b", .bundle)])
        store.moveEntry(in: c.id, from: 9, to: 0)
        XCTAssertEqual(store.collection(id: c.id)?.entries.map(\.id), ["a", "b"])
    }

    // MARK: - Ordered playlist semantics (rule #2)

    func testEntriesOrderIsStableAcrossOperations() {
        // The entries array is the playlist order; it must not be reordered by
        // hashed-collection iteration anywhere in the store.
        let store = CollectionsStore()
        let ids = (0..<8).map { "g\($0)" }
        let c = store.create(name: "C", from: ids.map { ce($0, .bundle) })
        XCTAssertEqual(store.collection(id: c.id)?.entries.map(\.id), ids)
    }

    // MARK: - Round-trip persistence

    func testRoundTrip() async throws {
        let dir = try tempDir()
        let store = CollectionsStore()
        let root = URL(fileURLWithPath: "/tmp/root")
        _ = store.create(name: "Favs",
                         from: [ce("alpha", .bundle), ce("beta", .directory(root))])
        store.scheduleSave(directory: dir)
        await store.flushSaved()
        let (loaded, quarantined) = CollectionsStore.loadResilient(directory: dir)
        XCTAssertNil(quarantined)
        XCTAssertEqual(loaded.collections.count, 1)
        XCTAssertEqual(loaded.collections.first?.name, "Favs")
        XCTAssertEqual(loaded.collections.first?.entries.map(\.id), ["alpha", "beta"])
        // Source + rootPath survive (resolution consistency with PlaybackRoute).
        XCTAssertEqual(loaded.collections.first?.entries[1].source, "directory")
        XCTAssertEqual(loaded.collections.first?.entries[1].rootPath, "/tmp/root")
    }

    // MARK: - Corrupt file ⇒ quarantine + defaults

    func testCorruptFileQuarantinedAndDefaults() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("collections.json")
        try Data("{ this is not valid json".utf8).write(to: url)
        let (store, quarantined) = CollectionsStore.loadResilient(directory: dir)
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertNotNil(quarantined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Determinism (rule #2): byte-stable save across equal state

    func testByteStableSaveAcrossEqualState() async throws {
        // A collection's `id` is a random UUID generated at creation (necessary
        // for Identifiable + WindowGroup routing), so two independently-created
        // stores legitimately differ. This test pins the id + entries to check
        // the SERIALIZATION is deterministic: sorted keys, stable entry order,
        // no hash-collection iteration in the encode path.
        let root = URL(fileURLWithPath: "/tmp/root")
        let fixedID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let entries = [ce("alpha", .bundle), ce("beta", .directory(root))]

        let dir1 = try tempDir()
        let s1 = CollectionsStore(collections: [GenomeCollection(id: fixedID, name: "C", entries: entries)])
        s1.scheduleSave(directory: dir1); await s1.flushSaved()
        let bytes1 = try Data(contentsOf: dir1.appendingPathComponent("collections.json"))

        let dir2 = try tempDir()
        let s2 = CollectionsStore(collections: [GenomeCollection(id: fixedID, name: "C", entries: entries)])
        s2.scheduleSave(directory: dir2); await s2.flushSaved()
        let bytes2 = try Data(contentsOf: dir2.appendingPathComponent("collections.json"))
        XCTAssertEqual(bytes1, bytes2,
                       "equal collections state (pinned id) must serialize byte-identically (rule #2)")
    }
}
