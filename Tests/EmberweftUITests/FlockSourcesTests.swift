import XCTest
@testable import EmberweftUI
import FlameKit

/// `flockSortedSources` is the rule-#2-critical ordering for Flock source lists
/// built from unordered inputs (Favorites / the multi-selection). These tests
/// pin the sort key `(sourceRank, sourcePath, id)` and determinism — the same
/// inputs always yield the same order regardless of how they were gathered.
final class FlockSourcesTests: XCTestCase {

    private func entry(_ id: String, _ source: LibrarySource) -> LibraryEntry {
        LibraryEntry(id: id, source: source,
                     fileURL: URL(fileURLWithPath: "/tmp/\(id).flam3"),
                     displayName: id, rank: nil)
    }

    /// bundle < directory < imported, regardless of input order.
    func testFlockSortedSourcesOrdersBySourceRank() {
        let bundle = entry("a", .bundle)
        let imported = entry("z", .imported)
        let directory = entry("m", .directory(URL(fileURLWithPath: "/lib")))

        XCTAssertEqual(
            flockSortedSources([imported, directory, bundle]).map(\.id),
            ["a", "m", "z"])
        // Shuffled again → same result (deterministic).
        XCTAssertEqual(
            flockSortedSources([directory, bundle, imported]).map(\.id),
            ["a", "m", "z"])
    }

    /// Two opened folders disambiguate by root path, then by id within a folder.
    func testFlockSortedSourcesDirectoriesByPathThenId() {
        let folderA = URL(fileURLWithPath: "/aaa")
        let folderZ = URL(fileURLWithPath: "/zzz")
        let a_b = entry("b", .directory(folderA))
        let a_a = entry("a", .directory(folderA))
        let z_a = entry("a", .directory(folderZ))

        let ordered = flockSortedSources([z_a, a_b, a_a])
        // "/aaa" entries first (id a < b), then "/zzz". Joined strings (tuples
        // are not Equatable, so flatten for the comparison).
        let key = { (e: LibraryEntry) in
            "\(LibrarySourceOrder.path(e.source))|\(e.id)"
        }
        XCTAssertEqual(ordered.map(key), ["/aaa|a", "/aaa|b", "/zzz|a"])
    }

    /// An entry's position never depends on Set/Dict hash order — feeding the
    /// same entries in many permutations yields byte-identical sequences.
    func testFlockSortedSourcesIsStableAcrossPermutations() {
        let es = (0..<6).map { entry(String($0), .bundle) }
        var rng = SystemRandomNumberGenerator()
        var first: [LibraryEntry] = []
        for _ in 0..<8 {
            let shuffled = es.shuffled(using: &rng)
            let ordered = flockSortedSources(shuffled).map(\.id)
            if first.isEmpty { first = ordered.map { entry($0, .bundle) } }
            // Always the ascending id order.
            XCTAssertEqual(ordered, ["0", "1", "2", "3", "4", "5"])
        }
    }

    /// `LibrarySourceOrder` rank/path agree with the documented order
    /// (bundle < directory < imported; directory carries its root path).
    func testLibrarySourceOrderRankAndPath() {
        XCTAssertEqual(LibrarySourceOrder.rank(.bundle), 0)
        XCTAssertEqual(LibrarySourceOrder.rank(.directory(URL(fileURLWithPath: "/x"))), 1)
        XCTAssertEqual(LibrarySourceOrder.rank(.imported), 2)
        XCTAssertEqual(LibrarySourceOrder.path(.bundle), "")
        XCTAssertEqual(LibrarySourceOrder.path(.imported), "")
        let url = URL(fileURLWithPath: "/var/lib")
        XCTAssertEqual(LibrarySourceOrder.path(.directory(url)), "/var/lib")
    }
}
