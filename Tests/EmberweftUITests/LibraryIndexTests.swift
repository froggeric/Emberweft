import XCTest
@testable import EmberweftUI
import FlameKit

final class LibraryIndexTests: XCTestCase {

    /// Resolve the `Fixtures/` dir. `swift test` runs from the package root, so
    /// the cwd-relative path is primary; `#file`-relative is a fallback (the dir
    /// is `exclude`d from Bundle.module — read from the source tree).
    private var fixtures: URL {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/EmberweftUITests/Fixtures"),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? candidates[0]
    }

    // MARK: - Bundle

    @MainActor
    func testScanBundleSortsByFilenameAndAppliesRanking() async throws {
        let index = LibraryIndex()
        let entries = await index.scanBundle(rootURL: fixtures.appendingPathComponent("bundle"))

        // Sorted by filename: alpha, beta.
        XCTAssertEqual(entries.map(\.id), ["alpha", "beta"])
        XCTAssertEqual(entries.map(\.displayName), ["alpha", "beta"])
        XCTAssertTrue(entries.allSatisfy { $0.source == .bundle })

        // Ranking sidecar applied to alpha, nil for unranked beta.
        XCTAssertEqual(entries[0].rank?.category, "spiral")
        XCTAssertAbsBetween(entries[0].rank?.score ?? -1, low: 0, high: 1)
        XCTAssertNil(entries[1].rank)
    }

    @MainActor
    func testScanBundleMissingRankingIsNotAnError() async throws {
        // Point at the `dir` fixture (no ranking.json) — ranks are all nil.
        let index = LibraryIndex()
        let entries = await index.scanBundle(rootURL: fixtures.appendingPathComponent("dir"))
        XCTAssertTrue(entries.allSatisfy { $0.rank == nil })
    }

    // MARK: - Directory

    @MainActor
    func testScanDirectoryDeterministicOrderAndIDs() async throws {
        let index = LibraryIndex()
        let root = fixtures.appendingPathComponent("dir")
        let entries1 = try await index.scanDirectory(root)
        let entries2 = try await index.scanDirectory(root)

        // Lexicographic by relative path: gamma.flam3, sub/delta.flam3.
        XCTAssertEqual(entries1.map(\.id), ["gamma", "sub__delta"])
        XCTAssertEqual(entries1, entries2, "scan must be deterministic across calls (rule #2)")
        XCTAssertTrue(entries1.allSatisfy { $0.source == .directory(root) })
    }

    @MainActor
    func testScanDirectoryMissingThrows() async {
        let index = LibraryIndex()
        let root = fixtures.appendingPathComponent("does-not-exist")
        do {
            _ = try await index.scanDirectory(root)
            XCTFail("expected libraryNotFound")
        } catch {
            // Expected — any throw satisfies; FeatureCacheError.libraryNotFound.
        }
    }

    // MARK: - Lazy parse + cache

    @MainActor
    func testLoadGenomeParsesAndCaches() async throws {
        let index = LibraryIndex()
        let entries = await index.scanBundle(rootURL: fixtures.appendingPathComponent("bundle"))
        let alpha = entries[0]

        let g1 = try await index.loadGenome(for: alpha)
        let g2 = try await index.loadGenome(for: alpha)
        XCTAssertEqual(g1, g2, "cached reload must equal the first parse")
        // The fixture is a well-formed synthetic genome.
        XCTAssertTrue(g1.isRenderable)
    }
}

/// Assert `value` lies within `[low, high]`.
private func XCTAssertAbsBetween(_ value: Double, low: Double, high: Double,
                                 file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value >= low && value <= high, "\(value) not in [\(low), \(high)]", file: file, line: line)
}
