// Tests/FlameFlockTests/FlockCatalogTests.swift
import XCTest
import AVFoundation
@testable import FlameFlock
import FlameExport
import FlameKit

/// Task 7 — `FlockCatalog`: flock.sqlite schema + CRUD + batch lookup + rebuild
/// + corrupt recovery + serialization. The catalog is an `actor` (the single
/// serialization point that — with WAL + `busy_timeout` — prevents SQLITE_BUSY).
final class FlockCatalogTests: XCTestCase {

    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flock-\(UUID().uuidString)")
    }

    /// Canonical shard used across tests (loopFrames=round(15*30)=450,
    /// transFrames=round(12*30)=360 ⇒ no `_Lf-Tf` suffix).
    private let shardName = "1920x1080_30fps"
    private let renderedISO = "2026-08-12T12:00:00Z"

    private func shardSpec(name: String = "1920x1080_30fps") -> ShardSpec {
        ShardSpec(name: name, width: 1920, height: 1080, fps: 30,
                  loopSeconds: 15, transSeconds: 12,
                  loopFrames: 450, transFrames: 360,
                  isCanonical: true, codec: .hevc)
    }

    private func sampleRow(seed: Int = 42) -> ArtifactRow {
        ArtifactRow(
            aGen: "248", aId: "00628", bGen: "248", bId: "03194",
            shard: shardName, kind: .edge,
            file: "1920x1080_30fps/mpeg/248=00628=248=03194.mov", thumb: nil,
            width: 1920, height: 1080, fps: 30,
            loopFrames: 450, transFrames: 360,
            spp: 30, temporal: 1, smoothing: "off", smoothingHw: 0,
            qualityRank: 30.0, bytes: 12345, renderedAt: 0,
            sourceSha: "abc", seed: seed, codec: .hevc)
    }

    // MARK: - Schema

    func testSchemaCreatedOnInitAndSchemaVersionTwo() async throws {
        let root = makeRoot()
        let cat = try FlockCatalog(root: root)
        // flock_meta.schema_version == "2" (v2 = seam-aware geometry columns;
        // read via the same connection).
        let v = try await cat.schemaVersion()
        XCTAssertEqual(v, "2")
        // The 4 tables exist (counts don't throw).
        let snap = await cat.snapshot()
        XCTAssertEqual(snap.shardCount, 0)
        XCTAssertEqual(snap.artifactCount, 0)
        // The sqlite file + WAL sidecar were created on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("flock.sqlite").path))
    }

    /// v1 → v2 in-place migration: a pre-seam-geometry catalog (schema_version
    /// "1", no `wrap_file`/`geom` columns) opens cleanly, bumps to "2", and its
    /// legacy rows decode with `geom == 1` (the exact hit-gate value that makes
    /// a seam-aware stitch re-render them instead of splicing mixed geometries).
    func testSchemaV1MigratesInPlaceWithLegacyGeometry() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Hand-build a v1 catalog (the pre-M6.5-seam schema).
        let v1 = try SQLiteConnection(root.appendingPathComponent("flock.sqlite"))
        try v1.exec("""
            CREATE TABLE flock_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE shards (name TEXT PRIMARY KEY, width INTEGER NOT NULL, height INTEGER NOT NULL,
              fps INTEGER NOT NULL, loop_seconds REAL NOT NULL, trans_seconds REAL NOT NULL,
              loop_frames INTEGER NOT NULL, trans_frames INTEGER NOT NULL, is_canonical INTEGER NOT NULL,
              codec TEXT NOT NULL);
            CREATE TABLE sheep (gen TEXT NOT NULL, id TEXT NOT NULL, origin TEXT NOT NULL,
              source_ref TEXT, source_sha TEXT, display_name TEXT, added_at INTEGER NOT NULL,
              PRIMARY KEY (gen, id));
            CREATE TABLE artifacts (
              a_gen TEXT NOT NULL, a_id TEXT NOT NULL, b_gen TEXT NOT NULL, b_id TEXT NOT NULL,
              shard TEXT NOT NULL, kind TEXT NOT NULL, file TEXT NOT NULL, thumb TEXT,
              width INTEGER NOT NULL, height INTEGER NOT NULL, fps INTEGER NOT NULL,
              loop_frames INTEGER NOT NULL, trans_frames INTEGER NOT NULL, spp INTEGER NOT NULL,
              temporal INTEGER NOT NULL, smoothing TEXT NOT NULL, smoothing_hw INTEGER NOT NULL DEFAULT 0,
              quality_rank REAL NOT NULL, bytes INTEGER NOT NULL, rendered_at INTEGER NOT NULL,
              source_sha TEXT, seed INTEGER NOT NULL, codec TEXT NOT NULL,
              PRIMARY KEY (a_gen, a_id, b_gen, b_id, shard),
              FOREIGN KEY (shard) REFERENCES shards(name));
            INSERT INTO flock_meta(key,value) VALUES('schema_version','1');
            INSERT INTO shards VALUES('\(shardName)',1920,1080,30,15.0,12.0,450,360,1,'hevc');
            INSERT INTO artifacts(a_gen,a_id,b_gen,b_id,shard,kind,file,thumb,width,height,fps,
              loop_frames,trans_frames,spp,temporal,smoothing,smoothing_hw,quality_rank,bytes,
              rendered_at,source_sha,seed,codec)
              VALUES('248','00628','248','03194','\(shardName)','edge',
                     'x/mpeg/a.mov',NULL,1920,1080,30,450,360,30,1,'off',0,30.0,1,0,NULL,7,'hevc');
            """)

        // Opening with the current binary migrates in place.
        let cat = try FlockCatalog(root: root)
        let v = try await cat.schemaVersion()
        XCTAssertEqual(v, "2", "a v1 catalog must migrate to v2 on open")
        // The legacy row survived and decodes as geometry 1 (legacy monolithic).
        let row = try await cat.lookup(aGen: "248", aId: "00628", bGen: "248", bId: "03194",
                                       shard: shardName)
        let r = try XCTUnwrap(row, "the v1 row must survive the migration")
        XCTAssertEqual(r.geom, 1, "legacy rows decode as geometry v1")
        XCTAssertNil(r.wrapFile)
        XCTAssertEqual(r.file, "x/mpeg/a.mov")
        XCTAssertEqual(r.seed, 7)
        // A NEW upsert writes geometry-v2 fields side by side.
        var upgraded = sampleRow(seed: 8)
        upgraded.geom = ArchiveRenderer.SeamGeometry.version
        try await cat.upsertArtifact(upgraded)
        let r2 = try await cat.lookup(aGen: "248", aId: "00628", bGen: "248", bId: "03194",
                                      shard: shardName)
        XCTAssertEqual(r2?.geom, ArchiveRenderer.SeamGeometry.version)
    }

    // MARK: - Upsert / lookup (PK = (a_gen,a_id,b_gen,b_id,shard))

    func testUpsertArtifactThenLookupReturnsRow() async throws {
        let cat = try FlockCatalog(root: makeRoot())
        try await cat.upsertShard(shardSpec())
        try await cat.upsertArtifact(sampleRow())
        let one = try await cat.lookup(aGen: "248", aId: "00628",
                                       bGen: "248", bId: "03194",
                                       shard: shardName)
        XCTAssertEqual(one?.seed, 42)
        XCTAssertEqual(one?.kind, .edge)
        XCTAssertEqual(one?.codec, .hevc)
        XCTAssertEqual(one?.qualityRank, 30.0)

        // Missing key ⇒ nil.
        let miss = try await cat.lookup(aGen: "248", aId: "00628",
                                        bGen: "248", bId: "99999",
                                        shard: shardName)
        XCTAssertNil(miss)
    }

    func testUpsertArtifactOverwritesOnPKConflict() async throws {
        let cat = try FlockCatalog(root: makeRoot())
        try await cat.upsertShard(shardSpec())
        try await cat.upsertArtifact(sampleRow(seed: 1))
        var updated = sampleRow(seed: 2)
        updated.spp = 100; updated.qualityRank = 100.0
        try await cat.upsertArtifact(updated)
        let one = try await cat.lookup(aGen: "248", aId: "00628",
                                       bGen: "248", bId: "03194",
                                       shard: shardName)
        XCTAssertEqual(one?.seed, 2)
        XCTAssertEqual(one?.spp, 100)
        let snapAfter = await cat.snapshot()
        XCTAssertEqual(snapAfter.artifactCount, 1)   // overwrite, not insert
    }

    // MARK: - batchLookup (single round trip)

    func testBatchLookupReturnsOnlyPresentRows() async throws {
        let cat = try FlockCatalog(root: makeRoot())
        try await cat.upsertShard(shardSpec())
        try await cat.upsertArtifact(sampleRow())    // (248,00628,248,03194)
        let keys: [(String, String, String, String, String)] = [
            ("248", "00628", "248", "03194", shardName),   // present
            ("248", "00628", "248", "99999", shardName),   // absent
        ]
        let rows = try await cat.batchLookup(keys)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.bId, "03194")
    }

    func testBatchLookupEmptyKeysIsNoOp() async throws {
        let cat = try FlockCatalog(root: makeRoot())
        let rows = try await cat.batchLookup([])
        XCTAssertTrue(rows.isEmpty)
    }

    /// Structural pin: the IN-clause placeholder count scales 1:1 with
    /// `keys.count` (each key ⇒ one `(?,?,?,?,?)` group). If the builder were
    /// hardcoded or off-by-one, this would fail for any count other than the
    /// constant. Combined with `testBatchLookupReturnsOnlyPresentRows`
    /// (behavioral), this pins "one round trip, N placeholders for N keys".
    func testBatchInPlaceholdersEqualKeysCount() {
        XCTAssertEqual(FlockCatalog.batchInPlaceholders(1), "(?,?,?,?,?)")
        XCTAssertEqual(FlockCatalog.batchInPlaceholders(2), "(?,?,?,?,?),(?,?,?,?,?)")
        XCTAssertEqual(FlockCatalog.batchInPlaceholders(3),
                       "(?,?,?,?,?),(?,?,?,?,?),(?,?,?,?,?)")
    }

    /// Behavioral scaling pin: 5 distinct present keys ⇒ exactly 5 rows back in
    /// one observable call (the placeholder group count must track keys.count).
    func testBatchLookupScalesWithKeyCount() async throws {
        let cat = try FlockCatalog(root: makeRoot())
        try await cat.upsertShard(shardSpec())
        for i in 0..<5 {
            let id = String(format: "%05d", 100 + i)
            try await cat.upsertArtifact(ArtifactRow(
                aGen: "248", aId: id, bGen: "248", bId: id,
                shard: shardName, kind: .loop,
                file: "mpeg/\(id).mov", thumb: nil,
                width: 1920, height: 1080, fps: 30, loopFrames: 450, transFrames: 360,
                spp: 8, temporal: 1, smoothing: "off", smoothingHw: 0,
                qualityRank: 8, bytes: 1, renderedAt: 0, sourceSha: nil, seed: i,
                codec: .hevc))
        }
        let keys: [(String, String, String, String, String)] = (0..<5).map { i in
            let id = String(format: "%05d", 100 + i)
            return ("248", id, "248", id, shardName)
        }
        let rows = try await cat.batchLookup(keys)
        XCTAssertEqual(rows.count, 5)
    }

    // MARK: - nextMintedId (persisted across close/reopen)

    func testNextMintedIdZeroPaddedAndPersistent() async throws {
        let root = makeRoot()
        let cat1 = try FlockCatalog(root: root)
        let id1 = try await cat1.nextMintedId()
        XCTAssertEqual(id1, "000001")
        let id2 = try await cat1.nextMintedId()
        XCTAssertEqual(id2, "000002")
        // Close + reopen (fresh actor over the same flock.sqlite).
        let cat2 = try FlockCatalog(root: root)
        let id3 = try await cat2.nextMintedId()
        XCTAssertEqual(id3, "000003")
    }

    // MARK: - upsertSheep round-trip

    func testUpsertSheepRoundTrips() async throws {
        let cat = try FlockCatalog(root: makeRoot())
        try await cat.upsertSheep(gen: "248", id: "00628", origin: .es,
                                  sourceRef: URL(fileURLWithPath: "/g/248_00628.flam3"),
                                  sourceSha: "deadbeef", displayName: "Loop 00628")
        let s = try await cat.sheep(gen: "248", id: "00628")
        XCTAssertEqual(s?.origin, .es)
        XCTAssertEqual(s?.sourceSha, "deadbeef")
        XCTAssertEqual(s?.displayName, "Loop 00628")
        let miss = try await cat.sheep(gen: "248", id: "99999")
        XCTAssertNil(miss)
    }

    // MARK: - Rebuild (delete + recreate)

    /// Builds a fake `<root>/1920x1080_30fps/mpeg/` containing:
    ///   - one loop `.mov`  (`248=00628=248=00628`, a==b)
    ///   - one edge `.mov`  (`248=00628=248=03194`, a!=b)
    ///   - one unparseable-name `.mov` (`garbage.mov`) — must be SKIPPED, not fatal.
    /// Each good `.mov` carries the `emberweft.*` mdta tags rebuild reads.
    /// Returns the root + the two ArtifactRows rebuild is expected to produce.
    private func makeRebuildRoot() async throws -> (root: URL, loop: ArtifactRow, edge: ArtifactRow) {
        let root = makeRoot()
        let mpeg = root.appendingPathComponent("1920x1080_30fps/mpeg")
        try FileManager.default.createDirectory(at: mpeg, withIntermediateDirectories: true)

        let loopRow = try await writeTaggedMOV(
            at: mpeg.appendingPathComponent("248=00628=248=00628.mov"),
            aId: "00628", bId: "00628", sourceSha: "sha-loop", seed: 111)
        let edgeRow = try await writeTaggedMOV(
            at: mpeg.appendingPathComponent("248=00628=248=03194.mov"),
            aId: "00628", bId: "03194", sourceSha: "sha-edge", seed: 222)
        // Unparseable name — rebuild must skip it, not throw.
        _ = try await writeTaggedMOV(
            at: mpeg.appendingPathComponent("garbage.mov"),
            aId: "00628", bId: "03194", sourceSha: "sha-junk", seed: 999)
        return (root, loopRow, edgeRow)
    }

    /// Writes a real HEVC `.mov` (one black frame) carrying the `emberweft.*`
    /// mdta tags, then returns the `ArtifactRow` rebuild should derive from it.
    @discardableResult
    private func writeTaggedMOV(at url: URL, aId: String, bId: String,
                                sourceSha: String, seed: Int) async throws -> ArtifactRow {
        var settings = ExportSettings()
        settings.codec = .hevc; settings.container = .mov
        settings.resolution = .p1080; settings.fps = 30
        let tags = Self.emberweftTags(spp: "30", ts: "1", smoothing: "off",
                                      smoothingHw: "0", qualityRank: "30.0",
                                      sourceSha: sourceSha, seed: String(seed),
                                      rendered: renderedISO)
        let enc = try VideoEncoder(settings: settings, outputURL: url, metadata: tags)
        try enc.start()
        let w = settings.resolution.width, h = settings.resolution.height
        try await enc.append(RGBA8Image(width: w, height: h,
                                        pixels: [UInt8](repeating: 0, count: w * h * 4)),
                             atFrame: 0)
        try await enc.finish()

        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let renderedAt = Int(ISO8601DateFormatter().date(from: renderedISO)!.timeIntervalSince1970)
        let kind: ArtifactRow.Kind = (aId == bId) ? .loop : .edge
        let stem = url.deletingPathExtension().lastPathComponent
        return ArtifactRow(
            aGen: "248", aId: aId, bGen: "248", bId: bId,
            shard: "1920x1080_30fps", kind: kind,
            file: "1920x1080_30fps/mpeg/\(stem).mov", thumb: nil,
            width: 1920, height: 1080, fps: 30, loopFrames: 450, transFrames: 360,
            spp: 30, temporal: 1, smoothing: "off", smoothingHw: 0,
            qualityRank: 30.0, bytes: bytes, renderedAt: renderedAt,
            sourceSha: sourceSha, seed: seed, codec: .hevc)
    }

    /// Builds the `[AVMetadataItem]` mdta tag set symmetric to the keys rebuild
    /// reads (`emberweft.spp`/`.ts`/`.smoothing`/`.smoothing_hw`/`.quality_rank`/
    /// `.source_sha`/`.seed`/`.rendered`). KeySpace MUST be `mdta` (a literal
    /// "emberweft" keyspace is silently dropped by AVAssetWriter on `.mov`).
    static func emberweftTags(spp: String, ts: String, smoothing: String,
                              smoothingHw: String, qualityRank: String,
                              sourceSha: String, seed: String,
                              rendered: String) -> [AVMetadataItem] {
        func tag(_ key: String, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            item.key = key as NSString
            item.value = value as NSString
            return item
        }
        return [
            tag("emberweft.spp", spp),
            tag("emberweft.ts", ts),
            tag("emberweft.smoothing", smoothing),
            tag("emberweft.smoothing_hw", smoothingHw),
            tag("emberweft.quality_rank", qualityRank),
            tag("emberweft.source_sha", sourceSha),
            tag("emberweft.seed", seed),
            tag("emberweft.rendered", rendered),
        ]
    }

    func testRebuildFromFilesRecreatesSnapshot() async throws {
        let (root, loopExpected, edgeExpected) = try await makeRebuildRoot()
        // No pre-existing flock.sqlite ⇒ rebuild creates it fresh from mpeg/.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("flock.sqlite").path))
        try await FlockCatalog.rebuild(from: root)

        let cat = try FlockCatalog(root: root)
        let snap = await cat.snapshot()
        XCTAssertEqual(snap.shardCount, 1)
        XCTAssertEqual(snap.artifactCount, 2)        // garbage.mov skipped
        // No prior sqlite ⇒ no .bak produced.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("flock.sqlite.bak").path))

        let loop = try await cat.lookup(aGen: "248", aId: "00628",
                                        bGen: "248", bId: "00628", shard: "1920x1080_30fps")
        let edge = try await cat.lookup(aGen: "248", aId: "00628",
                                        bGen: "248", bId: "03194", shard: "1920x1080_30fps")
        XCTAssertEqual(loop, loopExpected)
        XCTAssertEqual(edge, edgeExpected)
        // The shard row was reconstructed too (canonical pace + HEVC codec).
        let sh = try await cat.shard(named: "1920x1080_30fps")
        XCTAssertEqual(sh?.width, 1920)
        XCTAssertEqual(sh?.height, 1080)
        XCTAssertEqual(sh?.fps, 30)
        XCTAssertEqual(sh?.loopFrames, 450)
        XCTAssertEqual(sh?.transFrames, 360)
        XCTAssertEqual(sh?.isCanonical, true)
        XCTAssertEqual(sh?.codec, .hevc)
    }

    func testRebuildIteratesAllShardSubdirectories() async throws {
        // Two distinct shard dirs under the same root; rebuild must walk BOTH
        // (not a hardcoded shard name).
        let root = makeRoot()
        let mpegA = root.appendingPathComponent("1920x1080_30fps/mpeg")
        let mpegB = root.appendingPathComponent("1280x720_24fps/mpeg")
        try FileManager.default.createDirectory(at: mpegA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mpegB, withIntermediateDirectories: true)
        _ = try await writeTaggedMOV(at: mpegA.appendingPathComponent("248=00628=248=00628.mov"),
                                     aId: "00628", bId: "00628", sourceSha: "sha-a", seed: 1)
        _ = try await writeTaggedMOV(at: mpegB.appendingPathComponent("248=00628=248=00628.mov"),
                                     aId: "00628", bId: "00628", sourceSha: "sha-b", seed: 2)
        try await FlockCatalog.rebuild(from: root)
        let cat = try FlockCatalog(root: root)
        let snap = await cat.snapshot()
        XCTAssertEqual(snap.shardCount, 2)
        XCTAssertEqual(snap.artifactCount, 2)
    }

    // MARK: - Rebuild (corrupt catalog recovery)

    func testRebuildRecoversFromCorruptCatalog() async throws {
        let (root, loopExpected, edgeExpected) = try await makeRebuildRoot()
        // Write GARBAGE into flock.sqlite (simulates corruption/loss). Rebuild
        // must back it up to flock.sqlite.bak, then rebuild from mpeg/ + tags.
        let sqliteURL = root.appendingPathComponent("flock.sqlite")
        let garbage = Data([0x00, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00])
        try garbage.write(to: sqliteURL)
        try await FlockCatalog.rebuild(from: root)

        let bak = root.appendingPathComponent("flock.sqlite.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bak.path))
        let backedUp = try Data(contentsOf: bak)
        XCTAssertEqual(backedUp, garbage, "corrupt catalog must be backed up verbatim before rebuild")

        // Rebuilt snapshot matches the delete-then-rebuild case (same mpeg/
        // layout ⇒ same rows).
        let cat = try FlockCatalog(root: root)
        let snap = await cat.snapshot()
        XCTAssertEqual(snap.shardCount, 1)
        XCTAssertEqual(snap.artifactCount, 2)
        let loop = try await cat.lookup(aGen: "248", aId: "00628",
                                        bGen: "248", bId: "00628",
                                        shard: "1920x1080_30fps")
        XCTAssertEqual(loop, loopExpected)
        let edge = try await cat.lookup(aGen: "248", aId: "00628",
                                        bGen: "248", bId: "03194",
                                        shard: "1920x1080_30fps")
        XCTAssertEqual(edge, edgeExpected)
    }

    // MARK: - Serialization (two actors ⇒ no SQLITE_BUSY)

    func testTwoActorsConcurrentWritesNoBusy() async throws {
        let root = makeRoot()
        // Seed the shard row via a setup catalog (both writers reuse it).
        let setup = try FlockCatalog(root: root)
        try await setup.upsertShard(shardSpec())
        let n = 1000

        // Two independent catalog actors over the SAME flock.sqlite, writing
        // concurrently. WAL + busy_timeout must absorb the contention (no
        // SQLITE_BUSY), and actor isolation serializes each writer's own writes.
        // (Hoist `shardName` to a local so the async-let child tasks don't
        // capture non-Sendable `self`.)
        let shard = shardName
        async let a = Self.writeBatch(root: root, shard: shard, idOffset: 0, count: n)
        async let b = Self.writeBatch(root: root, shard: shard, idOffset: n, count: n)
        _ = try await a
        _ = try await b

        let snap = await setup.snapshot()
        XCTAssertEqual(snap.artifactCount, 2 * n)   // 2000 distinct PKs
    }

    private static func writeBatch(root: URL, shard: String, idOffset: Int, count: Int) async throws {
        let cat = try FlockCatalog(root: root)
        for i in 0..<count {
            let id = String(format: "%05d", idOffset + i + 1)
            try await cat.upsertArtifact(ArtifactRow(
                aGen: "248", aId: id, bGen: "248", bId: id,
                shard: shard, kind: .loop,
                file: "\(shard)/mpeg/\(id).mov", thumb: nil,
                width: 1920, height: 1080, fps: 30, loopFrames: 450, transFrames: 360,
                spp: 8, temporal: 1, smoothing: "off", smoothingHw: 0,
                qualityRank: 8, bytes: 1, renderedAt: 0, sourceSha: nil,
                seed: idOffset + i, codec: .hevc))
        }
    }

    // MARK: - Shard-name parsing (rebuild best-effort derivation)

    func testParseShardNameCanonicalAndNonCanonical() {
        let canon = FlockCatalog.parseShardName("1920x1080_30fps")
        XCTAssertEqual(canon?.width, 1920)
        XCTAssertEqual(canon?.height, 1080)
        XCTAssertEqual(canon?.fps, 30)
        XCTAssertEqual(canon?.loopFrames, 450)      // round(15*30)
        XCTAssertEqual(canon?.transFrames, 360)     // round(12*30)
        XCTAssertEqual(canon?.isCanonical, true)

        let nonCanon = FlockCatalog.parseShardName("1920x1080_30fps_Lf495-Tf300")
        XCTAssertEqual(nonCanon?.loopFrames, 495)
        XCTAssertEqual(nonCanon?.transFrames, 300)
        XCTAssertEqual(nonCanon?.isCanonical, false)
        XCTAssertEqual(nonCanon?.width, 1920)

        // Unparseable shard name ⇒ nil (rebuild skips the dir, not fatal).
        XCTAssertNil(FlockCatalog.parseShardName("not-a-shard"))
    }

    // MARK: - helpers
}
