import XCTest
@testable import EmberweftUI

final class ImportKitTests: XCTestCase {

    // MARK: - sanitizeImportStem

    func testSanitizeAcceptsCleanStem() {
        XCTAssertEqual(sanitizeImportStem("My_Genome-24.flam3"), "My_Genome-24")
        XCTAssertEqual(sanitizeImportStem("0242.flam3"), "0242")
    }

    func testSanitizeRejectsPathTraversal() {
        XCTAssertNil(sanitizeImportStem("../etc/x.flam3"))
        XCTAssertNil(sanitizeImportStem("/etc/passwd.flam3"))
        XCTAssertNil(sanitizeImportStem("~/x.flam3"))
        XCTAssertNil(sanitizeImportStem("a/b.flam3"))
        XCTAssertNil(sanitizeImportStem("a\\b.flam3"))
    }

    func testSanitizeRejectsHiddenAndEmpty() {
        XCTAssertNil(sanitizeImportStem(".hidden.flam3"))
        XCTAssertNil(sanitizeImportStem(""))
        XCTAssertNil(sanitizeImportStem(".flam3"))
    }

    func testSanitizeRejectsBadChars() {
        XCTAssertNil(sanitizeImportStem("bad name.flam3"))     // space
        XCTAssertNil(sanitizeImportStem("café.flam3"))          // non-ASCII
        XCTAssertNil(sanitizeImportStem("a:b.flam3"))           // colon
    }

    // MARK: - dedupedStem

    func testDedupReturnsStemWhenFree() {
        XCTAssertEqual(dedupedStem("foo", existing: ["bar"]), "foo")
    }

    func testDedupSuffixesLowestFreeN() {
        XCTAssertEqual(dedupedStem("foo", existing: ["foo"]), "foo-2")
        XCTAssertEqual(dedupedStem("foo", existing: ["foo", "foo-2"]), "foo-3")
        XCTAssertEqual(dedupedStem("foo", existing: ["foo", "foo-2", "foo-3"]), "foo-4")
        // Lowest free n: foo-2 taken, foo-3 free ⇒ foo-3 (even if foo-4 taken).
        XCTAssertEqual(dedupedStem("foo", existing: ["foo", "foo-2", "foo-4"]), "foo-3")
    }

    // MARK: - planImports

    func testPlanKeepsOnlyFlam3AndSanitizes() {
        // URL.lastPathComponent is a clean filename for real drops (no path); the
        // traversal defense is exercised directly in testSanitizeRejectsPathTraversal.
        let urls = [
            URL(fileURLWithPath: "/src/alpha.flam3"),
            URL(fileURLWithPath: "/src/readme.txt"),          // ignored (not flam3)
            URL(fileURLWithPath: "/src/UPPER.FLAM3"),          // kept (case-insensitive ext)
            URL(fileURLWithPath: "/src/beta.flam3")
        ]
        let plan = planImports(urls: urls, existingStems: [])
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan.map(\.destStem).sorted(), ["UPPER", "alpha", "beta"])
    }

    func testPlanDedupsWithinBatchAndAgainstExisting() {
        let urls = [
            URL(fileURLWithPath: "/a/foo.flam3"),
            URL(fileURLWithPath: "/b/foo.flam3"),              // same name twice
            URL(fileURLWithPath: "/c/foo.flam3")               // thrice
        ]
        let plan = planImports(urls: urls, existingStems: ["foo-2"])  // foo-2 already used
        XCTAssertEqual(plan.map(\.destStem), ["foo", "foo-3", "foo-4"])
    }
}

@MainActor
final class ImportScanTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emberweft-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testScanImportedSortsByIdStem() async throws {
        let dir = try tempDir()
        for name in ["zeta.flam3", "alpha.flam3", "mid.flam3"] {
            try Data("<flame/>".utf8).write(to: dir.appendingPathComponent(name))
        }
        let index = LibraryIndex()
        let entries = await index.scanImported(rootURL: dir)
        XCTAssertEqual(entries.map(\.id), ["alpha", "mid", "zeta"])
        XCTAssertTrue(entries.allSatisfy { $0.source == .imported })
        XCTAssertTrue(entries.allSatisfy { $0.rank == nil })
    }

    func testScanImportedMissingDirIsEmpty() async {
        let index = LibraryIndex()
        let entries = await index.scanImported(
            rootURL: URL(fileURLWithPath: "/nonexistent/emberweft-import-\(UUID().uuidString)"))
        XCTAssertTrue(entries.isEmpty)
    }
}
