// Sources/FlameFlock/FlockCatalog.swift
import Foundation
import AVFoundation
import FlameExport   // ExportSettings.Codec

/// Errors thrown by the catalog / SQLite wrapper. `openFailed` is the generic
/// open error (sqlite keeps its per-call message internal to the throw site).
public enum FlockCatalogError: Error, Equatable {
    case openFailed
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case schemaVersionUnsupported(Int)
}

/// `flock.sqlite` source-of-truth catalog (spec §6).
///
/// An `actor` — the single serialization point for catalog writes. With WAL +
/// `PRAGMA busy_timeout` (set on every open) two handles on one DB serialize
/// transparently instead of throwing `SQLITE_BUSY`; the actor itself guarantees
/// a single in-process writer for the production path (GenerateCoordinator +
/// StitchCoordinator share ONE catalog). GUI reads go through `snapshot()` (a
/// value-type `FlockSnapshot`) — the GUI never touches SQLite directly.
public actor FlockCatalog {
    private let conn: SQLiteConnection
    public let root: URL

    /// Open (or create) the catalog at `root/flock.sqlite` and run migrations.
    /// `root` is created if missing. The DB is opened read-write + WAL +
    /// busy_timeout; a schema-version mismatch throws (call `rebuild(from:)`
    /// for recovery).
    public init(root: URL) throws {
        self.root = root.resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        // `migrate` reads only the immutable `conn` let → safe to call from
        // this nonisolated init (actor `let` properties are nonisolated).
        self.conn = try SQLiteConnection(self.root.appendingPathComponent("flock.sqlite"))
        try migrate()
    }

    // MARK: - Schema (nonisolated: reads only the `conn` let)

    /// Create the 4-table schema if missing + enforce the schema-version gate.
    /// Idempotent (`CREATE TABLE IF NOT EXISTS`). `nonisolated` so the
    /// nonisolated `init` can call it without an `await`.
    private nonisolated func migrate() throws {
        try conn.exec("""
            CREATE TABLE IF NOT EXISTS flock_meta (
              key   TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS shards (
              name          TEXT PRIMARY KEY,
              width         INTEGER NOT NULL,
              height        INTEGER NOT NULL,
              fps           INTEGER NOT NULL,
              loop_seconds  REAL NOT NULL,
              trans_seconds REAL NOT NULL,
              loop_frames   INTEGER NOT NULL,
              trans_frames  INTEGER NOT NULL,
              is_canonical  INTEGER NOT NULL,
              codec         TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sheep (
              gen          TEXT NOT NULL,
              id           TEXT NOT NULL,
              origin       TEXT NOT NULL,
              source_ref   TEXT,
              source_sha   TEXT,
              display_name TEXT,
              added_at     INTEGER NOT NULL,
              PRIMARY KEY (gen, id)
            );
            CREATE TABLE IF NOT EXISTS artifacts (
              a_gen        TEXT NOT NULL,
              a_id         TEXT NOT NULL,
              b_gen        TEXT NOT NULL,
              b_id         TEXT NOT NULL,
              shard        TEXT NOT NULL,
              kind         TEXT NOT NULL,
              file         TEXT NOT NULL,
              wrap_file    TEXT,
              geom         INTEGER NOT NULL DEFAULT 1,
              framing      INTEGER NOT NULL DEFAULT 0,
              thumb        TEXT,
              width        INTEGER NOT NULL,
              height       INTEGER NOT NULL,
              fps          INTEGER NOT NULL,
              loop_frames  INTEGER NOT NULL,
              trans_frames INTEGER NOT NULL,
              spp          INTEGER NOT NULL,
              temporal     INTEGER NOT NULL,
              smoothing    TEXT NOT NULL,
              smoothing_hw INTEGER NOT NULL DEFAULT 0,
              quality_rank REAL NOT NULL,
              bytes        INTEGER NOT NULL,
              rendered_at  INTEGER NOT NULL,
              source_sha   TEXT,
              seed         INTEGER NOT NULL,
              codec        TEXT NOT NULL,
              PRIMARY KEY (a_gen, a_id, b_gen, b_id, shard),
              FOREIGN KEY (shard) REFERENCES shards(name)
            );
            CREATE INDEX IF NOT EXISTS idx_artifacts_shard ON artifacts(shard);
            CREATE INDEX IF NOT EXISTS idx_artifacts_a ON artifacts(a_gen, a_id);
            CREATE INDEX IF NOT EXISTS idx_artifacts_b ON artifacts(b_gen, b_id);
            """)
        // Schema-version gate (§6 migrations). Missing ⇒ seed at the current
        // version; an OLDER version is migrated forward in place; a NEWER one
        // (a future schema this binary doesn't know) throws.
        //   v1 → v2 (M6.5 seam-aware geometry): `artifacts` gains `wrap_file`
        //   (a loop unit's second file) + `geom` (the seam-geometry version an
        //   EXACT hit-gate compares, like `codec`). ALTER TABLE ADD COLUMN is
        //   enough — v1 rows keep their identity and decode as geometry 1
        //   (legacy), so a seam-aware stitch simply re-renders them.
        //   v2 → v3 (M6.6 framing normalization): `artifacts` gains `framing`
        //   (0 = faithful/legacy, 1 = normalized — an EXACT hit-gate alongside
        //   `geom`). v1 rows cascade 1→2→3 in one open (the loop re-reads the
        //   version after each step) and decode as framing 0.
        let cur = try conn.query("SELECT value FROM flock_meta WHERE key='schema_version'")
        var v = ""
        if cur.next() && !cur.isNull(0) { v = cur.text(0) }
        if v.isEmpty {
            try conn.run("INSERT INTO flock_meta(key,value) VALUES('schema_version','3')")
        } else {
            while v != "3" {
                if v == "1" {
                    try conn.exec("ALTER TABLE artifacts ADD COLUMN wrap_file TEXT")
                    try conn.exec("ALTER TABLE artifacts ADD COLUMN geom INTEGER NOT NULL DEFAULT 1")
                    try conn.run("UPDATE flock_meta SET value='2' WHERE key='schema_version'")
                } else if v == "2" {
                    try conn.exec("ALTER TABLE artifacts ADD COLUMN framing INTEGER NOT NULL DEFAULT 0")
                    try conn.run("UPDATE flock_meta SET value='3' WHERE key='schema_version'")
                } else {
                    throw FlockCatalogError.schemaVersionUnsupported(Int(v) ?? 0)
                }
                // Re-read: a v1 catalog must cascade 1→2→3 in this same open.
                let step = try conn.query("SELECT value FROM flock_meta WHERE key='schema_version'")
                v = (step.next() && !step.isNull(0)) ? step.text(0) : ""
            }
        }
    }

    public func schemaVersion() throws -> String {
        let cur = try conn.query("SELECT value FROM flock_meta WHERE key='schema_version'")
        if cur.next() && !cur.isNull(0) { return cur.text(0) }
        return ""
    }

    // MARK: - Shards

    public func upsertShard(_ s: ShardSpec) throws {
        try conn.run("""
            INSERT INTO shards(name,width,height,fps,loop_seconds,trans_seconds,
                               loop_frames,trans_frames,is_canonical,codec)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(name) DO UPDATE SET
              width=excluded.width, height=excluded.height, fps=excluded.fps,
              loop_seconds=excluded.loop_seconds, trans_seconds=excluded.trans_seconds,
              loop_frames=excluded.loop_frames, trans_frames=excluded.trans_frames,
              is_canonical=excluded.is_canonical, codec=excluded.codec
            """, [s.name, s.width, s.height, s.fps, s.loopSeconds, s.transSeconds,
                  s.loopFrames, s.transFrames, s.isCanonical ? 1 : 0, s.codec.rawValue])
    }

    public func shard(named name: String) throws -> ShardSpec? {
        let cur = try conn.query("""
            SELECT name,width,height,fps,loop_seconds,trans_seconds,
                   loop_frames,trans_frames,is_canonical,codec
            FROM shards WHERE name=?
            """, [name])
        guard cur.next() else { return nil }
        return ShardSpec(
            name: cur.text(0), width: cur.int(1), height: cur.int(2), fps: cur.int(3),
            loopSeconds: cur.double(4), transSeconds: cur.double(5),
            loopFrames: cur.int(6), transFrames: cur.int(7),
            isCanonical: cur.int(8) != 0,
            codec: ExportSettings.Codec(rawValue: cur.text(9)) ?? .hevc)
    }

    // MARK: - Sheep

    public func upsertSheep(gen: String, id: String, origin: Sheep.Origin,
                            sourceRef: URL?, sourceSha: String?,
                            displayName: String?) throws {
        try conn.run("""
            INSERT INTO sheep(gen,id,origin,source_ref,source_sha,display_name,added_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(gen,id) DO UPDATE SET
              origin=excluded.origin, source_ref=excluded.source_ref,
              source_sha=excluded.source_sha, display_name=excluded.display_name
            """, [gen, id, origin.rawValue, sourceRef?.path, sourceSha, displayName,
                  Int(Date().timeIntervalSince1970)])
    }

    public func sheep(gen: String, id: String) throws -> Sheep? {
        let cur = try conn.query("""
            SELECT gen,id,origin,source_ref,source_sha,display_name,added_at
            FROM sheep WHERE gen=? AND id=?
            """, [gen, id])
        guard cur.next() else { return nil }
        return Sheep(
            gen: cur.text(0), id: cur.text(1),
            origin: Sheep.Origin(rawValue: cur.text(2)) ?? .user,
            sourceRef: cur.isNull(3) ? nil : cur.text(3),
            sourceSha: cur.isNull(4) ? nil : cur.text(4),
            displayName: cur.isNull(5) ? nil : cur.text(5),
            addedAt: cur.int(6))
    }

    /// Read-only lookup by `source_sha` (used by `IdMinter` to dedupe minted
    /// ids, §7). If multiple rows share a sha, the lexicographically smallest
    /// `(gen,id)` wins — `ORDER BY gen,id LIMIT 1` is a deterministic tiebreak
    /// (rule #2: never a hash-ordered read). Returns nil if no row matches
    /// (including an empty `sha`, which no ES row carries).
    public func sheepBySourceSha(_ sha: String) async throws -> Sheep? {
        let cur = try conn.query("""
            SELECT gen,id,origin,source_ref,source_sha,display_name,added_at
            FROM sheep WHERE source_sha=?
            ORDER BY gen, id LIMIT 1
            """, [sha])
        guard cur.next() else { return nil }
        return Sheep(
            gen: cur.text(0), id: cur.text(1),
            origin: Sheep.Origin(rawValue: cur.text(2)) ?? .user,
            sourceRef: cur.isNull(3) ? nil : cur.text(3),
            sourceSha: cur.isNull(4) ? nil : cur.text(4),
            displayName: cur.isNull(5) ? nil : cur.text(5),
            addedAt: cur.int(6))
    }

    // MARK: - Minted-id counter (reserved flock 900000, §7)

    /// Mint the next id; persists the counter across close/reopen. Zero-padded
    /// to 6 digits (the final id form owned by `IdMinter`, T8).
    public func nextMintedId() throws -> String {
        var current = 0
        let cur = try conn.query("SELECT value FROM flock_meta WHERE key='next_minted_id'")
        if cur.next() && !cur.isNull(0) { current = Int(cur.text(0)) ?? 0 }
        current += 1
        try conn.run("""
            INSERT INTO flock_meta(key,value) VALUES('next_minted_id',?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """, [String(current)])
        return String(format: "%06d", current)
    }

    // MARK: - Artifacts (PK = (a_gen,a_id,b_gen,b_id,shard) == cache key, D2)

    /// After the file + thumb are on disk (atomic write done). Upsert by PK.
    /// The on-disk-before-row ordering is the CALLER's invariant
    /// (ArchiveRenderer, T9) — the catalog stores the row, it does not verify
    /// the file.
    public func upsertArtifact(_ r: ArtifactRow) throws {
        let params: [SQLiteBindable] = [
            r.aGen, r.aId, r.bGen, r.bId, r.shard, r.kind.rawValue, r.file, r.wrapFile,
            r.geom, r.framing, r.thumb,
            r.width, r.height, r.fps, r.loopFrames, r.transFrames, r.spp, r.temporal,
            r.smoothing, r.smoothingHw, r.qualityRank, r.bytes, r.renderedAt,
            r.sourceSha, r.seed, r.codec.rawValue,
        ]
        try conn.run("""
            INSERT INTO artifacts(a_gen,a_id,b_gen,b_id,shard,kind,file,wrap_file,geom,framing,thumb,width,
                height,fps,loop_frames,trans_frames,spp,temporal,smoothing,smoothing_hw,
                quality_rank,bytes,rendered_at,source_sha,seed,codec)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(a_gen,a_id,b_gen,b_id,shard) DO UPDATE SET
              kind=excluded.kind, file=excluded.file, wrap_file=excluded.wrap_file,
              geom=excluded.geom, framing=excluded.framing, thumb=excluded.thumb,
              width=excluded.width, height=excluded.height, fps=excluded.fps,
              loop_frames=excluded.loop_frames, trans_frames=excluded.trans_frames,
              spp=excluded.spp, temporal=excluded.temporal, smoothing=excluded.smoothing,
              smoothing_hw=excluded.smoothing_hw, quality_rank=excluded.quality_rank,
              bytes=excluded.bytes, rendered_at=excluded.rendered_at,
              source_sha=excluded.source_sha, seed=excluded.seed, codec=excluded.codec
            """, params)
    }

    public func removeArtifact(aGen: String, aId: String, bGen: String, bId: String,
                               shard: String) throws {
        try conn.run("""
            DELETE FROM artifacts WHERE a_gen=? AND a_id=? AND b_gen=? AND b_id=? AND shard=?
            """, [aGen, aId, bGen, bId, shard])
    }

    /// Single-key lookup (delegates to `batchLookup`).
    public func lookup(aGen: String, aId: String, bGen: String, bId: String,
                       shard: String) throws -> ArtifactRow? {
        try batchLookup([(aGen: aGen, aId: aId, bGen: bGen, bId: bId, shard: shard)]).first
    }

    /// ONE parameterized round trip (no N+1). The `IN (...)` list is built with
    /// exactly `keys.count` `(?,?,?,?,?)` placeholder groups (see
    /// `batchInPlaceholders`), values bound in `(aGen,aId,bGen,bId,shard)` order
    /// — pure key-positioned binding (rule #2; no Dict/Set, no float sums).
    public func batchLookup(_ keys: [(aGen: String, aId: String, bGen: String,
                                      bId: String, shard: String)]) throws -> [ArtifactRow] {
        guard !keys.isEmpty else { return [] }
        let placeholders = Self.batchInPlaceholders(keys.count)
        var params: [SQLiteBindable] = []
        params.reserveCapacity(keys.count * 5)
        for k in keys {
            params.append(k.aGen); params.append(k.aId)
            params.append(k.bGen); params.append(k.bId)
            params.append(k.shard)
        }
        let cur = try conn.query("""
            SELECT a_gen,a_id,b_gen,b_id,shard,kind,file,wrap_file,geom,framing,thumb,width,height,fps,
                   loop_frames,trans_frames,spp,temporal,smoothing,smoothing_hw,
                   quality_rank,bytes,rendered_at,source_sha,seed,codec
            FROM artifacts
            WHERE (a_gen,a_id,b_gen,b_id,shard) IN (\(placeholders))
            """, params)
        var rows: [ArtifactRow] = []
        while cur.next() { rows.append(Self.rowFrom(cur)) }
        return rows
    }

    /// Structural pin: the `IN (...)` clause has exactly `count` placeholder
    /// groups — one per key. Pure string function (deterministic; rule-#2-safe).
    internal static func batchInPlaceholders(_ count: Int) -> String {
        (0..<count).map { _ in "(?,?,?,?,?)" }.joined(separator: ",")
    }

    private static func rowFrom(_ c: SQLiteCursor) -> ArtifactRow {
        ArtifactRow(
            aGen: c.text(0), aId: c.text(1), bGen: c.text(2), bId: c.text(3),
            shard: c.text(4),
            kind: ArtifactRow.Kind(rawValue: c.text(5)) ?? .edge,
            file: c.text(6),
            wrapFile: c.isNull(7) ? nil : c.text(7),
            geom: c.int(8),
            framing: c.int(9),
            thumb: c.isNull(10) ? nil : c.text(10),
            width: c.int(11), height: c.int(12), fps: c.int(13),
            loopFrames: c.int(14), transFrames: c.int(15),
            spp: c.int(16), temporal: c.int(17),
            smoothing: c.text(18), smoothingHw: c.int(19),
            qualityRank: c.double(20), bytes: c.int(21), renderedAt: c.int(22),
            sourceSha: c.isNull(23) ? nil : c.text(23),
            seed: c.int(24),
            codec: ExportSettings.Codec(rawValue: c.text(25)) ?? .hevc)
    }

    /// All artifacts in one shard, in deterministic `(a_gen,a_id,b_gen,b_id)`
    /// order (rule #2 — a parameterized `WHERE shard=?` over a key, never a
    /// hash-ordered scan). Used by `ListXmlExporter` to emit one `<sheep>` per
    /// artifact in the shard (spec §9).
    public func artifactsIn(shard: String) async throws -> [ArtifactRow] {
        let cur = try conn.query("""
            SELECT a_gen,a_id,b_gen,b_id,shard,kind,file,wrap_file,geom,framing,thumb,width,height,fps,
                   loop_frames,trans_frames,spp,temporal,smoothing,smoothing_hw,
                   quality_rank,bytes,rendered_at,source_sha,seed,codec
            FROM artifacts WHERE shard=?
            ORDER BY a_gen, a_id, b_gen, b_id
            """, [shard])
        var rows: [ArtifactRow] = []
        while cur.next() { rows.append(Self.rowFrom(cur)) }
        return rows
    }

    // MARK: - Snapshot (value-type, for GUI reads)

    public func snapshot() -> FlockSnapshot {
        var shards = 0
        if let c1 = try? conn.query("SELECT COUNT(*) FROM shards"), c1.next() { shards = c1.int(0) }
        var artifacts = 0
        if let c2 = try? conn.query("SELECT COUNT(*) FROM artifacts"), c2.next() { artifacts = c2.int(0) }
        return FlockSnapshot(shardCount: shards, artifactCount: artifacts)
    }

    /// All shard rows, ordered by name (deterministic — rule #2: a key-ordered
    /// `ORDER BY` scan, never a hash-ordered read). Drives the FlockView shard
    /// picker (T17). Additive read; no parity impact.
    public func listShards() throws -> [ShardSpec] {
        let cur = try conn.query("""
            SELECT name,width,height,fps,loop_seconds,trans_seconds,
                   loop_frames,trans_frames,is_canonical,codec
            FROM shards ORDER BY name
            """)
        var out: [ShardSpec] = []
        while cur.next() {
            out.append(ShardSpec(
                name: cur.text(0), width: cur.int(1), height: cur.int(2), fps: cur.int(3),
                loopSeconds: cur.double(4), transSeconds: cur.double(5),
                loopFrames: cur.int(6), transFrames: cur.int(7),
                isCanonical: cur.int(8) != 0,
                codec: ExportSettings.Codec(rawValue: cur.text(9)) ?? .hevc))
        }
        return out
    }

    /// Per-shard (count, total bytes) for the Browse size readout. One
    /// parameterized round trip over a key (`WHERE shard=?`). Integer arithmetic
    /// only (rule-#2-safe). Additive read; no parity impact.
    public func shardStats(_ shard: String) throws -> (count: Int, bytes: Int) {
        let cur = try conn.query(
            "SELECT COUNT(*), COALESCE(SUM(bytes),0) FROM artifacts WHERE shard=?",
            [shard])
        if cur.next() { return (cur.int(0), cur.int(1)) }
        return (0, 0)
    }

    /// A page of artifact rows for the Browse grid (T17). Indexed `LIMIT/OFFSET`
    /// over a key-ordered `WHERE shard=? ORDER BY a_gen,a_id,b_gen,b_id` scan —
    /// never mass-parses the archive (rule #2). Thumbnails are loaded lazily by
    /// the GUI from each row's `thumb` path. Additive read; no parity impact.
    public func artifactPage(shard: String, offset: Int, limit: Int) throws -> [ArtifactRow] {
        let cur = try conn.query("""
            SELECT a_gen,a_id,b_gen,b_id,shard,kind,file,wrap_file,geom,framing,thumb,width,height,fps,
                   loop_frames,trans_frames,spp,temporal,smoothing,smoothing_hw,
                   quality_rank,bytes,rendered_at,source_sha,seed,codec
            FROM artifacts WHERE shard=?
            ORDER BY a_gen, a_id, b_gen, b_id
            LIMIT ? OFFSET ?
            """, [shard, limit, offset])
        var rows: [ArtifactRow] = []
        while cur.next() { rows.append(Self.rowFrom(cur)) }
        return rows
    }

    // MARK: - Rebuild (resilience: delete + recreate from mpeg/ + tags)

    /// Rebuild `flock.sqlite` from `mpeg/` filenames + embedded video tags
    /// (spec §6 resilience; "flock rebuild" + Browse's "Rebuild catalog").
    ///
    /// The existing `flock.sqlite` (valid OR corrupt OR missing) is moved to
    /// `flock.sqlite.bak` (any prior `.bak` is removed first), then a fresh
    /// catalog is constructed and repopulated. Files whose stem doesn't parse
    /// to 4 numeric `=`-fields are SKIPPED (logged elsewhere, not fatal). ALL
    /// shard subdirectories under `root` are enumerated (each
    /// `<shard>/mpeg/*.mov`), not a hardcoded shard name. Missing tag values
    /// are best-effort'd from the filename + shard dir (resolution/fps/pace
    /// from the shard name; kind = self-edge iff a==b; codec = HEVC, D12).
    public static func rebuild(from root: URL) async throws {
        let root = root.resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sqliteURL = root.appendingPathComponent("flock.sqlite")
        let bak = root.appendingPathComponent("flock.sqlite.bak")
        try? FileManager.default.removeItem(at: bak)
        // Back up the existing (possibly corrupt) catalog, then start fresh.
        // `try?`: if there's no prior sqlite (the delete+recreate case), the
        // move is a no-op and rebuild proceeds.
        try? FileManager.default.moveItem(at: sqliteURL, to: bak)

        let cat = try FlockCatalog(root: root)

        guard let shardDirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for shardDir in shardDirs {
            let isDir = (try? shardDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard isDir else { continue }
            let shardName = shardDir.lastPathComponent
            guard FlockNaming.isValidShardName(shardName),
                  let parsed = parseShardName(shardName) else { continue }
            let mpeg = shardDir.appendingPathComponent("mpeg")
            guard FileManager.default.fileExists(atPath: mpeg.path) else { continue }

            // Reconstruct + upsert the shard row.
            try await cat.upsertShard(ShardSpec(
                name: shardName, width: parsed.width, height: parsed.height, fps: parsed.fps,
                loopSeconds: Double(parsed.loopFrames) / Double(parsed.fps),
                transSeconds: Double(parsed.transFrames) / Double(parsed.fps),
                loopFrames: parsed.loopFrames, transFrames: parsed.transFrames,
                isCanonical: parsed.isCanonical, codec: .hevc))

            guard let en = FileManager.default.enumerator(
                at: mpeg, includingPropertiesForKeys: nil) else { continue }
            // `for-in` over a DirectoryEnumerator is unavailable from async
            // contexts (its `makeIterator()` is gated); drive `nextObject()`
            // directly. The enumerator IS its own iterator, so this is correct.
            while let url = en.nextObject() as? URL {
                guard ["mov", "mp4"].contains(url.pathExtension.lowercased()) else { continue }
                let stem = url.deletingPathExtension().lastPathComponent
                // Loop WRAP variant files are part of their loop unit's row (the
                // `wrap_file` column), not standalone rows — skip here; the core
                // file's row picks them up via `wrapRelFile` below.
                if FlockNaming.isWrapStem(stem) { continue }
                guard let (aGen, aId, bGen, bId) = FlockNaming.decode(stem: stem) else {
                    continue   // unparseable stem — skip (not an error)
                }
                let tags = await readMdtaTags(at: url)
                let spp = Int(tags["emberweft.spp"] ?? "") ?? 0
                let temporal = Int(tags["emberweft.ts"] ?? "") ?? 1
                let smoothing = tags["emberweft.smoothing"] ?? "off"
                let smoothingHw = Int(tags["emberweft.smoothing_hw"] ?? "") ?? 0
                let qualityRank = Double(tags["emberweft.quality_rank"] ?? "") ?? Double(spp)
                let sourceSha = tags["emberweft.source_sha"]   // nil if absent
                let seed = Int(tags["emberweft.seed"] ?? "") ?? 0
                let renderedAt = parseRendered(tags["emberweft.rendered"])
                let geom = Int(tags["emberweft.geom"] ?? "") ?? 1
                // M6.6 framing gate: 0 = faithful/legacy, 1 = normalized. The
                // `emberweft.framing` tag lands in T7 — a legacy file (no tag)
                // defaults 0, so a normalized request re-renders it.
                let framing = Int(tags["emberweft.framing"] ?? "") ?? 0
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                let kind: ArtifactRow.Kind = (aGen == bGen && aId == bId) ? .loop : .edge
                let relFile = "\(shardName)/mpeg/\(url.lastPathComponent)"
                // A seam-aware loop core carries a sibling wrap file (same stem +
                // `=wrap`); the row records it so a stitch can interleave it
                // between loop repetitions.
                var wrapRel: String? = nil
                if kind == .loop, geom >= 2 {
                    let wrapName = FlockNaming.fileName(aGen: aGen, aId: aId, bGen: bGen,
                                                        bId: bId, ext: url.pathExtension,
                                                        variant: FlockNaming.wrapVariant)
                    let wrapPath = mpeg.appendingPathComponent(wrapName).path
                    if FileManager.default.fileExists(atPath: wrapPath) {
                        wrapRel = "\(shardName)/mpeg/\(wrapName)"
                    }
                }
                let thumbRel = "\(shardName)/jpeg/\(stem).jpg"
                let thumb = FileManager.default.fileExists(atPath: root.appendingPathComponent(thumbRel).path)
                    ? thumbRel : nil
                try await cat.upsertArtifact(ArtifactRow(
                    aGen: aGen, aId: aId, bGen: bGen, bId: bId,
                    shard: shardName, kind: kind, file: relFile, wrapFile: wrapRel, geom: geom,
                    framing: framing,
                    thumb: thumb,
                    width: parsed.width, height: parsed.height, fps: parsed.fps,
                    loopFrames: parsed.loopFrames, transFrames: parsed.transFrames,
                    spp: spp, temporal: temporal, smoothing: smoothing, smoothingHw: smoothingHw,
                    qualityRank: qualityRank, bytes: bytes, renderedAt: renderedAt,
                    sourceSha: sourceSha, seed: seed, codec: .hevc))
            }
        }
    }

    // MARK: - Rebuild helpers

    /// Read embedded `emberweft.*` tags via `AVURLAsset.load(.metadata)`
    /// filtered to keyspace `mdta` + key prefix `emberweft.` (NOT
    /// `.commonMetadata`, which carries only common-key equivalents). Symmetric
    /// to ArchiveRenderer.makeMetadata (T9). Keyed on unique string tags — no
    /// ordering concern (rule #2 is about FP accumulation; this is a lookup map).
    private static func readMdtaTags(at url: URL) async -> [String: String] {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return [:] }
        var tags: [String: String] = [:]
        for item in items {
            guard item.keySpace == AVMetadataKeySpace(rawValue: "mdta"),
                  let key = item.key as? String,
                  key.hasPrefix("emberweft.") else { continue }
            // `.value` is deprecated on macOS 13+; load it asynchronously (the
            // items from `load(.metadata)` are often already-populated, so this
            // is usually a cached return — cheap for an offline rebuild).
            if let value = try? await item.load(.value) as? String {
                tags[key] = value
            }
        }
        return tags
    }

    private static func parseRendered(_ iso: String?) -> Int {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return 0 }
        return Int(d.timeIntervalSince1970)
    }

    /// Parsed shard-directory components (rebuild best-effort derivation of
    /// resolution/fps/pace from the dir name). `internal` so the parser is
    /// unit-pinned (`testParseShardNameCanonicalAndNonCanonical`).
    internal struct ParsedShard: Equatable {
        let width, height, fps, loopFrames, transFrames: Int
        let isCanonical: Bool
    }

    /// Parse `WxH_fps` (canonical: 15 s loops / 12 s transitions) or
    /// `WxH_fps_Lf<loop>-Tf<trans>` (non-canonical). Returns nil for an
    /// unparseable name (caller skips the dir).
    internal static func parseShardName(_ name: String) -> ParsedShard? {
        let parts = name.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let res = parts[0].split(separator: "x", omittingEmptySubsequences: true).map(String.init)
        guard res.count == 2,
              let w = Int(res[0]), let h = Int(res[1]), w > 0, h > 0 else { return nil }
        let fpsStr = parts[1]
        guard fpsStr.hasSuffix("fps"),
              let fps = Int(fpsStr.dropLast(3)), fps > 0 else { return nil }
        let canonicalLoop = Int((15.0 * Double(fps)).rounded())
        let canonicalTrans = Int((12.0 * Double(fps)).rounded())
        if parts.count == 2 {
            return ParsedShard(width: w, height: h, fps: fps,
                               loopFrames: canonicalLoop, transFrames: canonicalTrans,
                               isCanonical: true)
        }
        guard parts.count == 3 else { return nil }
        let suffix = parts[2]
        guard suffix.hasPrefix("Lf") else { return nil }
        let body = String(suffix.dropFirst(2))   // "<loop>-Tf<trans>"
        let chunks = body.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard chunks.count == 2, chunks[1].hasPrefix("Tf"),
              let lf = Int(chunks[0]), let tf = Int(chunks[1].dropFirst(2)),
              lf > 0, tf > 0 else { return nil }
        return ParsedShard(width: w, height: h, fps: fps,
                           loopFrames: lf, transFrames: tf, isCanonical: false)
    }
}
