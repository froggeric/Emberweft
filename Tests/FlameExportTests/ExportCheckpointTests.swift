import XCTest
@testable import FlameExport

final class ExportCheckpointTests: XCTestCase {
    private func mk(completed: Set<Int> = [], total: Int = 3690, interval: Int = 30) -> ExportCheckpoint {
        ExportCheckpoint(settings: .init(), framesPerSegment: 450,
            transitionFramesPerSegment: 360, segmentCount: 9, selector: .sequential,
            seed: 1, loopCycles: 1, stagger: 0, out: URL(fileURLWithPath: "/tmp/x.mov"),
            loopRepeatCount: 2, checkpointIntervalFrames: interval, totalGlobalFrames: total,
            completedChunkIndexes: completed, sources: [])
    }

    func testChunkCountCeil() {
        XCTAssertEqual(mk().chunkCount, 123)          // ceil(3690/30) = 123
        XCTAssertEqual(mk(total: 1, interval: 30).chunkCount, 1)   // interval > total ⇒ 1
        XCTAssertEqual(mk(total: 60, interval: 30).chunkCount, 2)  // exact division
    }

    func testCompletedSetEncodesSortedAndStable() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let a = try encoder.encode(mk(completed: [5, 1, 3, 0, 2]))
        let b = try encoder.encode(mk(completed: [0, 1, 2, 3, 5]))   // same members, diff insertion order
        XCTAssertEqual(a, b)                                          // byte-identical (rule #2)
        let decoded = try JSONDecoder().decode(ExportCheckpoint.self, from: a)
        XCTAssertEqual(decoded.completedChunkIndexes, [0, 1, 2, 3, 5])
    }

    func testURLHelpersBesideOutNotNested() {
        let out = URL(fileURLWithPath: "/tmp/dir/my export.mov")
        XCTAssertEqual(ExportCheckpoint.chunkURL(out: out, index: 7, container: .mov).path,
                       "/tmp/dir/my export.emberweft-chunk-0007.mov")
        XCTAssertEqual(ExportCheckpoint.checkpointURL(out: out).path,
                       "/tmp/dir/my export.emberweft-export.json")
    }

    /// P6: the guard fires ONLY when the LEAF stem is ".."/"."/empty. Foundation does
    /// NOT resolve ".." in `URL(fileURLWithPath:)` (verified under both system swift and
    /// the macOS 26 SDK), so a mid-path ".." is NOT this guard's job — chunks always
    /// land beside `out` in the user-declared dir. NOTE: Foundation strips a TRAILING
    /// slash, so `/tmp/` yields leaf "tmp" (a safe stem), NOT empty — verified by
    /// probing `lastPathComponent` directly. The plan originally asserted "output" for
    /// `/tmp/`; that contradicts Foundation's real normalization, so the actual (safe)
    /// value "tmp" is asserted here.
    func testSanitizedStemRejectsTraversalLeaf() {
        XCTAssertEqual(ExportCheckpoint.sanitizedStem(URL(fileURLWithPath: "/tmp/..")), "output")
        XCTAssertEqual(ExportCheckpoint.sanitizedStem(URL(fileURLWithPath: "/tmp/.")), "output")
        XCTAssertEqual(ExportCheckpoint.sanitizedStem(URL(fileURLWithPath: "/tmp/")), "tmp")
        // A mid-path ".." is left literal (Foundation keeps it); the stem is the leaf:
        XCTAssertEqual(ExportCheckpoint.sanitizedStem(URL(fileURLWithPath: "/tmp/../etc/passwd")), "passwd")
        // Separator in a stem is flattened:
        XCTAssertEqual(ExportCheckpoint.sanitizedStem(URL(fileURLWithPath: "/tmp/a/b")), "b")
    }
}
