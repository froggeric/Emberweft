// Tests/FlameFlockTests/ListXmlExporterTests.swift
import XCTest
@testable import FlameFlock
import FlameExport

/// Task 13 — `ListXmlExporter`: ES `<list>` XML interchange emission (spec §9).
/// One `<sheep>` per cataloged artifact in the shard; ES-sourced edges carry
/// the recovered real ES `edge_id` (lowest on duplicates); non-ES / cross-gen /
/// minted edges carry a synthesized stable id. Writes `<shard>.xml` beside the
/// shard dir.
final class ListXmlExporterTests: XCTestCase {

    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flock-list-\(UUID().uuidString)")
    }

    private let shardName = "1920x1080_30fps"

    private func shardSpec() -> ShardSpec {
        ShardSpec(name: shardName, width: 1920, height: 1080, fps: 30,
                  loopSeconds: 15, transSeconds: 12,
                  loopFrames: 450, transFrames: 360,
                  isCanonical: true, codec: .hevc)
    }

    /// Build a tiny `edge_pairs` fixture (real schema) with the given rows.
    private func makeFixtureEdgePairs(rows: [(edgeGen: String, edgeId: String,
                                              aGen: String, aId: String,
                                              bGen: String, bId: String)]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edgepairs-\(UUID().uuidString).sqlite")
        let conn = try SQLiteConnection(url)
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

    /// End-to-end: ES edge recovers the real edge_id (lowest); minted edge
    /// synthesizes; `size` matches the shard; the emitted file is well-formed
    /// XML written beside the shard.
    func testExportEmitsOneSheepPerArtifactWithRecoveredAndSynthesizedIds() async throws {
        let root = makeRoot()
        let cat = try FlockCatalog(root: root)
        try await cat.upsertShard(shardSpec())

        // ES-sourced edge: (244,01458)→(244,01474) — duplicate pair in the
        // fixture, lowest edge_id "01535".
        let esRow = ArtifactRow(
            aGen: "244", aId: "01458", bGen: "244", bId: "01474",
            shard: shardName, kind: .edge,
            file: "\(shardName)/mpeg/244=01458=244=01474.mov", thumb: nil,
            width: 1920, height: 1080, fps: 30, loopFrames: 450, transFrames: 360,
            spp: 30, temporal: 1, smoothing: "off", smoothingHw: 0,
            qualityRank: 30.0, bytes: 1234, renderedAt: 0,
            sourceSha: "es", seed: 1, codec: .hevc)
        // Non-ES (minted flock 900000) edge — no ES original ⇒ synthesized id.
        let mintedRow = ArtifactRow(
            aGen: "900000", aId: "000001", bGen: "900000", bId: "000002",
            shard: shardName, kind: .edge,
            file: "\(shardName)/mpeg/900000=000001=900000=000002.mov", thumb: nil,
            width: 1920, height: 1080, fps: 30, loopFrames: 450, transFrames: 360,
            spp: 30, temporal: 1, smoothing: "off", smoothingHw: 0,
            qualityRank: 30.0, bytes: 1234, renderedAt: 0,
            sourceSha: "m", seed: 2, codec: .hevc)
        try await cat.upsertArtifact(esRow)
        try await cat.upsertArtifact(mintedRow)

        let edgesDb = try makeFixtureEdgePairs(rows: [
            ("244", "01535", "244", "01458", "244", "01474"),
            ("244", "09999", "244", "01458", "244", "01474"),
        ])

        let exporter = ListXmlExporter()
        let xmlURL = try await exporter.export(shard: shardName, flockRoot: root,
                                               edgesDb: edgesDb)

        // Written beside the shard dir, at the flock root.
        XCTAssertEqual(xmlURL.lastPathComponent, "\(shardName).xml")
        XCTAssertEqual(xmlURL.deletingLastPathComponent().path, root.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: xmlURL.path))

        // Parse — validates well-formed XML.
        let doc = try XMLDocument(contentsOf: xmlURL, options: [])

        // Exactly one <list> carrying the shard's size; NO `gen` attribute
        // (mixed/non-ES shards have no single ES gen — task Step 4).
        let lists = try doc.nodes(forXPath: "//list")
        XCTAssertEqual(lists.count, 1)
        let listEl = lists[0] as! XMLElement
        XCTAssertEqual(listEl.attribute(forName: "size")?.stringValue, "1920 1080")
        XCTAssertNil(listEl.attribute(forName: "gen"))

        // One <sheep> per artifact, in deterministic (a_gen,a_id,b_gen,b_id)
        // order: "244/01458" sorts before "900000/000001".
        let sheep = try doc.nodes(forXPath: "//sheep")
        XCTAssertEqual(sheep.count, 2)

        // [0] = ES-sourced edge ⇒ recovered lowest edge_id "01535".
        let es = sheep[0] as! XMLElement
        XCTAssertEqual(es.attribute(forName: "id")?.stringValue, "01535")
        XCTAssertEqual(es.attribute(forName: "first")?.stringValue, "244/01458")
        XCTAssertEqual(es.attribute(forName: "last")?.stringValue, "244/01474")
        XCTAssertEqual(es.attribute(forName: "url")?.stringValue,
                       "\(shardName)/mpeg/244=01458=244=01474.mov")

        // [1] = minted edge ⇒ synthesized stable id (collision-free full quad).
        let minted = sheep[1] as! XMLElement
        XCTAssertEqual(minted.attribute(forName: "id")?.stringValue,
                       "minted-900000-000001-900000-000002")
        XCTAssertEqual(minted.attribute(forName: "first")?.stringValue, "900000/000001")
        XCTAssertEqual(minted.attribute(forName: "last")?.stringValue, "900000/000002")
    }

    /// No edges.sqlite ⇒ ES edge synthesizes too (oracle absent); file still
    /// well-formed with one entry per artifact.
    func testExportWithoutEdgesDbSynthesizesAllIds() async throws {
        let root = makeRoot()
        let cat = try FlockCatalog(root: root)
        try await cat.upsertShard(shardSpec())
        try await cat.upsertArtifact(ArtifactRow(
            aGen: "244", aId: "01458", bGen: "244", bId: "01474",
            shard: shardName, kind: .edge,
            file: "\(shardName)/mpeg/244=01458=244=01474.mov", thumb: nil,
            width: 1920, height: 1080, fps: 30, loopFrames: 450, transFrames: 360,
            spp: 30, temporal: 1, smoothing: "off", smoothingHw: 0,
            qualityRank: 30.0, bytes: 1234, renderedAt: 0,
            sourceSha: "es", seed: 1, codec: .hevc))

        let xmlURL = try await ListXmlExporter().export(
            shard: shardName, flockRoot: root, edgesDb: nil)

        let doc = try XMLDocument(contentsOf: xmlURL, options: [])
        let sheep = try doc.nodes(forXPath: "//sheep")
        XCTAssertEqual(sheep.count, 1)
        // No oracle ⇒ synthesized, even though the row is ES-sourced.
        let el = sheep[0] as! XMLElement
        XCTAssertEqual(el.attribute(forName: "id")?.stringValue,
                       "minted-244-01458-244-01474")
    }

    /// Empty shard ⇒ well-formed empty `<list>` (no `<sheep>` children).
    func testExportEmptyShardEmitsWellFormedEmptyList() async throws {
        let root = makeRoot()
        let cat = try FlockCatalog(root: root)
        try await cat.upsertShard(shardSpec())

        let xmlURL = try await ListXmlExporter().export(
            shard: shardName, flockRoot: root, edgesDb: nil)

        let doc = try XMLDocument(contentsOf: xmlURL, options: [])
        XCTAssertEqual(try doc.nodes(forXPath: "//list").count, 1)
        XCTAssertEqual(try doc.nodes(forXPath: "//sheep").count, 0)
        let listEl = try (doc.nodes(forXPath: "//list")[0] as! XMLElement)
        XCTAssertEqual(listEl.attribute(forName: "size")?.stringValue, "1920 1080")
    }

    /// XML escape (defense-in-depth): a file path carrying `&`/`<`/`>` round-
    /// trips through a well-formed document (the escaper emits `&amp;`/`&lt;`/
    /// `&gt;`). Catalog file paths are validated elsewhere, but the exporter
    /// must never emit unescaped data into an attribute value.
    func testExportEscapesAttributeValues() async throws {
        let root = makeRoot()
        let cat = try FlockCatalog(root: root)
        try await cat.upsertShard(shardSpec())
        // Inject a row whose `file` carries XML-special chars directly via the
        // catalog (bypassing the render path's naming validation) to exercise
        // the escaper.
        try await cat.upsertArtifact(ArtifactRow(
            aGen: "244", aId: "00001", bGen: "244", bId: "00002",
            shard: shardName, kind: .edge,
            file: "\(shardName)/mpeg/a&b<c>.mov", thumb: nil,
            width: 1920, height: 1080, fps: 30, loopFrames: 450, transFrames: 360,
            spp: 30, temporal: 1, smoothing: "off", smoothingHw: 0,
            qualityRank: 30.0, bytes: 1234, renderedAt: 0,
            sourceSha: nil, seed: 1, codec: .hevc))

        let xmlURL = try await ListXmlExporter().export(
            shard: shardName, flockRoot: root, edgesDb: nil)

        // Must parse (well-formed) AND the url attribute round-trips the raw chars.
        let doc = try XMLDocument(contentsOf: xmlURL, options: [])
        let el = try (doc.nodes(forXPath: "//sheep")[0] as! XMLElement)
        XCTAssertEqual(el.attribute(forName: "url")?.stringValue,
                       "\(shardName)/mpeg/a&b<c>.mov")
    }
}
