// Sources/FlameFlock/SQLiteConnection.swift
import Foundation
import SQLite3

/// Minimal system-sqlite3 wrapper (open/prepare/step/bind/column/finalize).
///
/// One serialized writer per `FlockCatalog` actor ⇒ no `SQLITE_BUSY` from the
/// catalog's own writes. When two catalog actors share one `flock.sqlite` (the
/// serialization AC's stress test, and a realistic stale-handle scenario), WAL +
/// `PRAGMA busy_timeout` lets SQLite retry the contended write internally
/// instead of throwing `SQLITE_BUSY` — the second writer blocks until the first
/// commits, then proceeds. The macOS SDK ships `libsqlite3`; linked via
/// `Package.swift` `linkerSettings: [.linkedLibrary("sqlite3")]` (no SwiftPM
/// dependency — rule #4 honored).
final class SQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?

    /// `readOnly: true` opens via `sqlite3_open_v2(..., SQLITE_OPEN_READONLY)`
    /// (used by `EdgePairsOracle` over the ES archive `edges.sqlite` — never
    /// writes). Default `false` opens read-write + creates the DB if missing,
    /// and enables WAL + a 5 s busy timeout (the serialization AC).
    init(_ url: URL, readOnly: Bool = false) throws {
        if readOnly {
            if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                sqlite3_close(db)
                throw FlockCatalogError.openFailed
            }
        } else {
            if sqlite3_open(url.path, &db) != SQLITE_OK {
                // `errmsg` is unsafe to read after close; surface the generic
                // open error (the path is in `url`, owned by the caller).
                sqlite3_close(db)
                throw FlockCatalogError.openFailed
            }
            // WAL allows concurrent readers alongside the writer; `synchronous=
            // NORMAL` is the safe WAL-mode setting (each commit is still
            // crash-safe; only the last tx may roll back on power loss —
            // acceptable for a rebuildable cache). `busy_timeout` makes a
            // contended writer retry for 5 s before surfacing SQLITE_BUSY, so
            // two handles on one file serialize transparently.
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA busy_timeout=5000;", nil, nil, nil)
        }
    }
    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw FlockCatalogError.execFailed(msg)
        }
    }

    /// Run a parameterized statement that returns no rows; returns the number
    /// of rows changed (`sqlite3_changes`).
    @discardableResult
    func run(_ sql: String, _ params: [SQLiteBindable] = []) throws -> Int {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw FlockCatalogError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() { try p.bind(to: stmt, at: Int32(i + 1)) }
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw FlockCatalogError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    /// Prepare + bind a `SELECT`, returning a cursor. The caller owns the
    /// cursor (finalized on deinit) and drives `next()`.
    func query(_ sql: String, _ params: [SQLiteBindable] = []) throws -> SQLiteCursor {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw FlockCatalogError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        for (i, p) in params.enumerated() { try p.bind(to: stmt, at: Int32(i + 1)) }
        return SQLiteCursor(stmt: stmt)
    }
}

/// Bind-protocol conformance for the SQL value types we use. String/Int/Double
/// + their Optionals. `SQLITE_TRANSIENT` (the `-1` reinterpretation) makes
/// SQLite copy the bound text, so the Swift string can be released immediately.
protocol SQLiteBindable { func bind(to stmt: OpaquePointer?, at idx: Int32) throws }
extension String: SQLiteBindable {
    func bind(to s: OpaquePointer?, at i: Int32) throws {
        sqlite3_bind_text(s, i, self, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
extension Int: SQLiteBindable {
    func bind(to s: OpaquePointer?, at i: Int32) throws {
        sqlite3_bind_int64(s, i, sqlite3_int64(self))
    }
}
extension Double: SQLiteBindable {
    func bind(to s: OpaquePointer?, at i: Int32) throws { sqlite3_bind_double(s, i, self) }
}
/// A single conditional conformance covers every `Optional<Wrapped>` where
/// `Wrapped` is itself bindable (Int?, String?, Double?). Swift forbids two
/// separate `Int?`/`String?` conformances — they collapse to one
/// `Optional<Wrapped>` — so this is the one source of truth. `.none` ⇒ NULL.
extension Optional: SQLiteBindable where Wrapped: SQLiteBindable {
    func bind(to s: OpaquePointer?, at i: Int32) throws {
        switch self {
        case .some(let v): try v.bind(to: s, at: i)
        case .none: sqlite3_bind_null(s, i)
        }
    }
}

/// One-shot row cursor over a prepared statement. `next()` advances and reports
/// whether a row is current; `text/int/double/isNull` read columns by 0-based
/// index. Finalizes the statement on deinit.
final class SQLiteCursor {
    let stmt: OpaquePointer?
    var done = false
    init(stmt: OpaquePointer?) { self.stmt = stmt }
    func next() -> Bool { done = (sqlite3_step(stmt) != SQLITE_ROW); return !done }
    func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    deinit { sqlite3_finalize(stmt) }
}
