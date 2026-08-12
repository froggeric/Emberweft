// Tests/FlameFlockTests/EdgePairsOracleTests.swift
import XCTest
@testable import FlameFlock

/// Task 13 — `EdgePairsOracle`: read-only pair oracle over the ES archive
/// `edges.sqlite`. Recovers the LOWEST real ES `edge_id` on duplicate pairs
/// (spec §9, I6: 364 duplicate pairs / 879 surplus rows; the most-duplicated
/// pair `(244,01458)→(244,01474)` has 32 rows, lowest "01535"). Opens
/// `SQLITE_OPEN_READONLY` and never writes (defense-in-depth over the archive).
final class EdgePairsOracleTests: XCTestCase {

    /// Build a tiny synthetic `edge_pairs` sqlite at a temp URL with the REAL
    /// archive schema (verified: 10 columns), seed it with the given rows, and
    /// return the URL. The writer connection closes (data persisted) when it
    /// falls out of scope; the read-only oracle then opens the file.
    private func makeFixtureEdgePairs(rows: [(edgeGen: String, edgeId: String,
                                              aGen: String, aId: String,
                                              bGen: String, bId: String)]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edgepairs-\(UUID().uuidString).sqlite")
        let conn = try SQLiteConnection(url)   // read-write (creates the file)
        try conn.exec("""
            CREATE TABLE edge_pairs (
              edge_gen TEXT, edge_id TEXT, a_gen TEXT, a_id TEXT,
              b_gen TEXT, b_id TEXT, frames INTEGER, resolved INTEGER,
              sim_score REAL, curated INTEGER)
            """)
        for r in rows {
            try conn.run("""
                INSERT INTO edge_pairs(edge_gen,edge_id,a_gen,a_id,b_gen,b_id,
                                       frames,resolved,sim_score,curated)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """, [r.edgeGen, r.edgeId, r.aGen, r.aId, r.bGen, r.bId, 80, 1, 0.0, 0])
        }
        return url
    }

    /// The duplicate-pair pin: `(244,01458)→(244,01474)` with three edge_ids
    /// ("01535","09999","10001") ⇒ lowest "01535". Absent pair ⇒ nil.
    /// Cross-gen / minted pair ⇒ nil (no single ES original; spec §9).
    func testLowestEdgeIdOnDuplicatePair() throws {
        let url = try makeFixtureEdgePairs(rows: [
            ("244", "01535", "244", "01458", "244", "01474"),
            ("244", "09999", "244", "01458", "244", "01474"),
            ("244", "10001", "244", "01458", "244", "01474"),
        ])
        let oracle = try EdgePairsOracle(url: url)
        XCTAssertEqual(
            try oracle.edgeId(aGen: "244", aId: "01458", bGen: "244", bId: "01474"),
            "01535")
        // Absent pair ⇒ nil.
        XCTAssertNil(try oracle.edgeId(aGen: "244", aId: "99999",
                                       bGen: "244", bId: "99999"))
        // Cross-gen / minted (b_gen="900000") ⇒ nil (no ES original).
        XCTAssertNil(try oracle.edgeId(aGen: "248", aId: "00628",
                                       bGen: "900000", bId: "000042"))
    }

    /// Single-row (non-duplicate) pair returns its one edge_id, zero-padded.
    func testSingleRowPairReturnsItsEdgeId() throws {
        let url = try makeFixtureEdgePairs(rows: [
            ("244", "02000", "244", "00001", "244", "00002"),
        ])
        let oracle = try EdgePairsOracle(url: url)
        XCTAssertEqual(
            try oracle.edgeId(aGen: "244", aId: "00001", bGen: "244", bId: "00002"),
            "02000")
    }

    /// Empty table ⇒ nil for any pair (MIN over zero rows is NULL).
    func testEmptyTableReturnsNil() throws {
        let url = try makeFixtureEdgePairs(rows: [])
        let oracle = try EdgePairsOracle(url: url)
        XCTAssertNil(try oracle.edgeId(aGen: "244", aId: "01458",
                                       bGen: "244", bId: "01474"))
    }

    /// Ordered-pair semantics: `(A→B)` ≠ `(B→A)` — only the stored direction
    /// matches; the reverse direction returns nil.
    func testOrderedPairNotSymmetric() throws {
        let url = try makeFixtureEdgePairs(rows: [
            ("244", "04200", "244", "01458", "244", "01474"),  // forward only
        ])
        let oracle = try EdgePairsOracle(url: url)
        XCTAssertEqual(
            try oracle.edgeId(aGen: "244", aId: "01458", bGen: "244", bId: "01474"),
            "04200")
        XCTAssertNil(try oracle.edgeId(aGen: "244", aId: "01474",
                                       bGen: "244", bId: "01458"))
    }
}
