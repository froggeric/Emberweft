// Sources/FlameFlock/EdgePairsOracle.swift
import Foundation

/// Read-only pair oracle over `genomes/electric-sheep/edges.sqlite` (spec §5.1,
/// I5). Schema (verified against the archive):
/// `edge_pairs(edge_gen TEXT, edge_id TEXT, a_gen TEXT, a_id TEXT, b_gen TEXT,
///  b_id TEXT, frames INTEGER, resolved INTEGER, sim_score REAL, curated INTEGER)`.
///
/// Used (a) as a selection oracle (does this ordered pair exist?) and
/// (b) by `ListXmlExporter` to recover the real ES `edge_id` on a pair — the
/// **lowest** on the 364 duplicate pairs (spec §9, I6: the most-duplicated pair
/// `(244,01458)→(244,01474)` has 32 rows; lowest `edge_id = "01535"`).
///
/// Opens with `SQLITE_OPEN_READONLY` (via `SQLiteConnection(..., readOnly: true)`)
/// and issues SELECTs only — defense-in-depth over the ES archive: it must never
/// risk writing `edges.sqlite`.
public final class EdgePairsOracle: @unchecked Sendable {
    private let conn: SQLiteConnection

    /// Read-only open. Throws on an open failure (missing/corrupt sqlite).
    public init(url: URL) throws {
        self.conn = try SQLiteConnection(url, readOnly: true)
    }

    /// Lowest `edge_id` (5-digit zero-padded string) for an exact **ordered**
    /// pair, or nil.
    ///
    /// - Same-gen ES pairs: queries the table, returns the MIN edge_id
    ///   (`CAST(edge_id AS INTEGER)` makes the TEXT column numeric for MIN; the
    ///   result is re-zero-padded to 5 digits — deterministic lowest, rule #2).
    /// - Cross-gen pairs (`aGen != bGen`): nil — spec §9 mandates a SYNTHESIZED
    ///   id for cross-gen pairs (no single ES original), even though
    ///   `edges.sqlite` carries some cross-gen rows; short-circuit before the
    ///   query. This also covers minted-gen pairs (`900000` vs anything).
    /// - Absent pairs: nil (MIN over zero rows is NULL).
    public func edgeId(aGen: String, aId: String,
                       bGen: String, bId: String) throws -> String? {
        // Cross-gen ⇒ no single ES edge_id (spec §9). Short-circuit (also
        // covers minted-gen pairs, which have no ES original).
        guard aGen == bGen else { return nil }
        let cur = try conn.query("""
            SELECT MIN(CAST(edge_id AS INTEGER)) FROM edge_pairs
            WHERE a_gen=? AND a_id=? AND b_gen=? AND b_id=?
            """, [aGen, aId, bGen, bId])
        guard cur.next(), !cur.isNull(0) else { return nil }
        return String(format: "%05d", cur.int(0))
    }
}
