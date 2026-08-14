import XCTest
import Foundation
import AVFoundation   // AVURLAsset duration (loop-reps stitch output)
@testable import EmberweftCLI
@testable import FlameFlock     // FlockCatalog seeding (export-list / browse-with-shard)
@testable import FlameExport    // ExportSettings, ArtifactRow, ShardSpec
import FlameKit
import FlameRenderer   // MetalRenderer.isAvailable (skip probe)

/// Task 14 — `emberweft flock <subcommand>`: the CLI surface over the
/// GenerateCoordinator / StitchCoordinator / FlockCatalog / ListXmlExporter
/// (T10/T11/T7/T13). Drives `EmberweftCLI.flock(...)` via the injectable
/// `out`/`err` hooks the rest of the CLI uses.
///
/// Fast-CPU harness mirrors `GenerateCoordinatorTests`: sierpinski at 48x32,
/// spp 4, a 3-frame loop / 2-frame transition shard (`48x32_30fps_Lf3-Tf2`).
/// The flame-agnostic scope/skip mechanics are covered in FlameFlockTests; here
/// we exercise the dispatch + arg-validation + error paths + lightweight smoke
/// runs that prove the CLI wiring (parser → coordinator → progress → exit code).
final class FlockCommandTests: XCTestCase {

    // MARK: - fixtures

    /// `#filePath` (not `#file`): in Swift 6.2 `#file` returns a basename. This
    /// file is at `Tests/EmberweftCLITests/`; two `deletingLastPathComponent()`
    /// land on `Tests/`, then `Goldens/genomes/sierpinski.flam3`.
    private func sierpinskiURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3")
    }

    private func makeFlockRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flock-cli-\(UUID().uuidString)")
    }

    /// Tiny render profile: 3 loop / 2 transition frames at 48x32. Non-canonical
    /// (`_Lf3-Tf2`) so loop/trans frames are tiny (canonical would be 450/360).
    private let shardName = "48x32_30fps_Lf3-Tf2"

    /// A temp dir of ES-named sierpinski copies (distinct ids ⇒ edges exist).
    /// `count` genomes → `count` loops + `count-1` edges.
    private func makeFromDir(genomeCount: Int) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flock-from-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: sierpinskiURL())
        for i in 1...genomeCount {
            // electricsheep.<gen>.<id>.flam3 ⇒ ES passthrough (gen, id).
            let id = String(format: "%05d", i)
            try bytes.write(to: dir.appendingPathComponent("electricsheep.248.\(id).flam3"))
        }
        return dir
    }

    /// Captures `EmberweftCLI.out` into a String. Restores the hook on teardown.
    private func captureOut(_ body: () async throws -> Void) async rethrows -> String {
        var captured = ""
        let original = EmberweftCLI.out
        EmberweftCLI.out = { captured += $0 }
        defer { EmberweftCLI.out = original }
        try await body()
        return captured
    }
    /// Captures `EmberweftCLI.err` into a String.
    private func captureErr(_ body: () async throws -> Void) async rethrows -> String {
        var captured = ""
        let original = EmberweftCLI.err
        EmberweftCLI.err = { captured += $0 }
        defer { EmberweftCLI.err = original }
        try await body()
        return captured
    }

    // MARK: - dispatch (AC: subcommand routing + exit codes)

    func testNoSubcommandExitsTwo() async throws {
        let rc = await EmberweftCLI.flock([])
        XCTAssertEqual(rc, 2)
        let err = await captureErr { _ = await EmberweftCLI.flock([]) }
        XCTAssertTrue(err.contains("subcommand"), "stderr should mention subcommand: \(err)")
    }

    func testUnknownSubcommandExitsTwo() async throws {
        let rc = await EmberweftCLI.flock(["bogus"])
        XCTAssertEqual(rc, 2)
        let err = await captureErr { _ = await EmberweftCLI.flock(["bogus"]) }
        XCTAssertTrue(err.lowercased().contains("unknown"), "stderr should say unknown: \(err)")
    }

    func testBrowseEmptyFlockPrintsZeroShards() async throws {
        let root = makeFlockRoot()
        let out = await captureOut {
            let rc = await EmberweftCLI.flock(["browse", "--flock", root.path])
            XCTAssertEqual(rc, 0)
        }
        XCTAssertTrue(out.contains("0 shards"), "empty flock should report 0 shards: \(out)")
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - arg validation (AC: required flags)

    func testGenerateMissingFromErrors() async throws {
        let rc = await EmberweftCLI.flock(["generate", "--shard", shardName])
        XCTAssertNotEqual(rc, 0)
        let err = await captureErr {
            _ = await EmberweftCLI.flock(["generate", "--shard", shardName])
        }
        XCTAssertTrue(err.lowercased().contains("--from"), "should name the missing flag: \(err)")
    }

    func testGenerateMissingShardErrors() async throws {
        let from = try makeFromDir(genomeCount: 1)
        defer { try? FileManager.default.removeItem(at: from) }
        let rc = await EmberweftCLI.flock(["generate", "--from", from.path])
        XCTAssertNotEqual(rc, 0)
    }

    // MARK: - generate smoke (AC: drives GenerateCoordinator, prints skip/render)

    /// Two ES-named genomes, `--scope both` ⇒ 2 loops + 1 edge render. Tiny
    /// 48x32 / spp 4 / 3+2-frame shard keeps it fast. Asserts exit 0, that the
    /// archive files land, that browse reports the shard, and that progress
    /// mentioning "render" was printed.
    func testGenerateBothScopeRendersLoopsAndEdges() async throws {
        let root = makeFlockRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = try makeFromDir(genomeCount: 2)
        defer { try? FileManager.default.removeItem(at: from) }
        let progress = try await captureOut {
            let rc = await EmberweftCLI.flock([
                "generate", "--from", from.path, "--shard", shardName,
                "--scope", "both", "--quality", "4", "--codec", "h264",
                "--backend", "cpu", "--flock", root.path,
            ])
            XCTAssertEqual(rc, 0, "generate should succeed")
        }
        XCTAssertTrue(progress.contains("render"), "progress should report render count: \(progress)")

        // Loop + edge archive files exist under <root>/<shard>/mpeg/.
        let mpeg = root.appendingPathComponent(shardName).appendingPathComponent("mpeg")
        let loopFile = mpeg.appendingPathComponent("248=00001=248=00001.mov")
        let edgeFile = mpeg.appendingPathComponent("248=00001=248=00002.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: loopFile.path), "loop must render")
        XCTAssertTrue(FileManager.default.fileExists(atPath: edgeFile.path), "edge must render")

        // browse now reports 1 shard + ≥3 artifacts (2 loops + 1 edge).
        let browse = await captureOut {
            let rc = await EmberweftCLI.flock(["browse", "--shard", shardName, "--flock", root.path])
            XCTAssertEqual(rc, 0)
        }
        XCTAssertTrue(browse.contains("1 shards") || browse.contains("1 shard"), "browse: 1 shard: \(browse)")
        XCTAssertTrue(browse.contains(shardName), "browse should name the shard: \(browse)")
    }

    /// `--scope edges` renders ONLY the edge (the 2 loops are skipped by scope).
    func testGenerateScopeEdgesSkipsLoops() async throws {
        let root = makeFlockRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = try makeFromDir(genomeCount: 2)
        defer { try? FileManager.default.removeItem(at: from) }
        let rc = await EmberweftCLI.flock([
            "generate", "--from", from.path, "--shard", shardName,
            "--scope", "edges", "--quality", "4", "--codec", "h264",
            "--backend", "cpu", "--flock", root.path,
        ])
        XCTAssertEqual(rc, 0)
        let mpeg = root.appendingPathComponent(shardName).appendingPathComponent("mpeg")
        let edgeFile = mpeg.appendingPathComponent("248=00001=248=00002.mov")
        let loopFile = mpeg.appendingPathComponent("248=00001=248=00001.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: edgeFile.path), "edge must render under .edges")
        XCTAssertFalse(FileManager.default.fileExists(atPath: loopFile.path), "loop must NOT render under .edges")
        // EXACTLY one artifact (the single edge); no loops leak under .edges.
        let movs = (try? FileManager.default.contentsOfDirectory(atPath: mpeg.path)) ?? []
        XCTAssertEqual(movs.filter { $0.hasSuffix(".mov") }.sorted(),
                       ["248=00001=248=00002.mov"],
                       "--scope edges must produce exactly the one edge file")
    }

    /// D10 order + count pin. A 2-genome `--scope both` generate produces EXACTLY
    /// 2 loops + 1 edge (3 files), and — because `GenerateUnit.enumerate` emits
    /// edges first — the EDGE is the FIRST unit rendered. The CLI prints
    /// `unit 1/N frame 1/<frameTotal>` per frame; the first such line's
    /// `<frameTotal>` is the edge's `transFrames` (2), NOT a loop's `loopFrames`
    /// (3). A loops-first regression would make this 3.
    func testGenerateBothScopeProducesTwoLoopsOneEdge_TimelineOrder() async throws {
        let root = makeFlockRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = try makeFromDir(genomeCount: 2)
        defer { try? FileManager.default.removeItem(at: from) }
        let progress = await captureOut {
            let rc = await EmberweftCLI.flock([
                "generate", "--from", from.path, "--shard", shardName,
                "--scope", "both", "--quality", "4", "--codec", "h264",
                "--backend", "cpu", "--flock", root.path,
            ])
            XCTAssertEqual(rc, 0, "generate should succeed")
        }
        // EXACTLY 3 files: 2 loops + 1 edge.
        let mpeg = root.appendingPathComponent(shardName).appendingPathComponent("mpeg")
        let movs = ((try? FileManager.default.contentsOfDirectory(atPath: mpeg.path)) ?? [])
            .filter { $0.hasSuffix(".mov") }.sorted()
        XCTAssertEqual(movs,
                       ["248=00001=248=00001.mov", "248=00001=248=00002.mov", "248=00002=248=00002.mov"],
                       "--scope both must produce exactly 2 loops + 1 edge")

        // TIMELINE order (owner decision 2026-08-13): the units render as loop,
        // edge, loop — matching the collection order — so the per-unit first-frame
        // totals are [loopFrames=3, transFrames=2, loopFrames=3].
        let frameTotals = progress.split(separator: "\n").lazy.compactMap { line -> Int? in
            let s = String(line)
            guard let range = s.range(of: " frame 1/") else { return nil }
            return Int(s[range.upperBound...].prefix { $0.isNumber })
        }
        XCTAssertEqual(Array(frameTotals), [3, 2, 3],
                       "units must render in timeline order (loop, edge, loop): \(progress)")
    }

    // MARK: - stitch smoke (AC: HIT/will-gen plan + single-file copy)

    /// Generate a single loop, then stitch the same sequence. Every segment is a
    /// HIT (just rendered) ⇒ no MISS render, and a single segment ⇒ the copy
    /// path (urls.count == 1). Fast; proves the stitch wiring end-to-end.
    func testStitchSingleGenomeCopiesLoopFile() async throws {
        let root = makeFlockRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = try makeFromDir(genomeCount: 1)
        defer { try? FileManager.default.removeItem(at: from) }
        // 1. Generate the loop into the archive.
        let genRC = await EmberweftCLI.flock([
            "generate", "--from", from.path, "--shard", shardName,
            "--scope", "loops", "--quality", "4", "--codec", "h264",
            "--backend", "cpu", "--flock", root.path,
        ])
        XCTAssertEqual(genRC, 0)

        // 2. Stitch: the plan should be all-HIT (will-gen 0); out is a copy of the loop.
        // `--loop-reps 1` keeps the single-slot copy path (the default 2 would
        // concat two copies — pinned by testStitchLoopRepsDefaultsToTwo below).
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flock-stitch-\(UUID().uuidString).mov")
        let progress = try await captureOut {
            let rc = await EmberweftCLI.flock([
                "stitch", "--sequence", from.path, "--shard", shardName,
                "--codec", "h264", "--quality", "4", "--backend", "cpu",
                "--loop-reps", "1",
                "--flock", root.path, "--out", out.path,
            ])
            XCTAssertEqual(rc, 0, "stitch should succeed")
        }
        XCTAssertTrue(progress.lowercased().contains("hit") || progress.contains("will-gen"),
                      "stitch should print HIT/will-gen plan: \(progress)")
        XCTAssertTrue(progress.contains("concatenating 1 segment"),
                      "reps=1 single genome ⇒ the copy path (1 segment): \(progress)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "stitch out must exist")
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "stitch out must be non-empty")
        try? FileManager.default.removeItem(at: out)
    }

    /// `--loop-reps` DEFAULT is 2 (mirrors the GUI): a single-genome stitch
    /// without the flag builds a 2-slot timeline `[loopA, loopA]` ⇒ concat of
    /// two copies of the ONE canonical loop file (NOT the single-file copy
    /// path, and NOT a re-render — the archive keeps exactly one loop).
    func testStitchLoopRepsDefaultsToTwo() async throws {
        let root = makeFlockRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = try makeFromDir(genomeCount: 1)
        defer { try? FileManager.default.removeItem(at: from) }
        let genRC = await EmberweftCLI.flock([
            "generate", "--from", from.path, "--shard", shardName,
            "--scope", "loops", "--quality", "4", "--codec", "h264",
            "--backend", "cpu", "--flock", root.path,
        ])
        XCTAssertEqual(genRC, 0)

        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flock-stitch-\(UUID().uuidString).mov")
        let progress = try await captureOut {
            let rc = await EmberweftCLI.flock([
                "stitch", "--sequence", from.path, "--shard", shardName,
                "--codec", "h264", "--quality", "4", "--backend", "cpu",
                "--flock", root.path, "--out", out.path,
            ])
            XCTAssertEqual(rc, 0, "stitch should succeed")
        }
        // The banner reports the reps-aware slot count + the reps value.
        XCTAssertTrue(progress.contains("segments=2"), "default loop-reps=2 ⇒ 2 slots: \(progress)")
        XCTAssertTrue(progress.contains("loop-reps=2"), "the banner should print loop-reps: \(progress)")
        // All-HIT plan over UNIQUE keys (1 loop) with 2 timeline slots.
        XCTAssertTrue(progress.contains("HIT=1 will-gen=0 segments=2"),
                      "plan counts unique work (1 HIT) + slot total (2): \(progress)")
        // The 2-slot timeline goes through CONCAT, not the single-file copy.
        XCTAssertTrue(progress.contains("concatenating 2 segments"),
                      "default reps=2 single genome ⇒ concat of 2 copies: \(progress)")
        // The archive still holds EXACTLY ONE loop file (repetition never
        // duplicates archive artifacts).
        let mpeg = root.appendingPathComponent(shardName).appendingPathComponent("mpeg")
        let movs = ((try? FileManager.default.contentsOfDirectory(atPath: mpeg.path)) ?? [])
            .filter { $0.hasSuffix(".mov") }
        XCTAssertEqual(movs, ["248=00001=248=00001.mov"],
                       "reps duplicate timeline slots, never archive files")
        // The output plays the loop twice (≈2× the single loop's frames).
        let single = try await AVURLAsset(url: mpeg.appendingPathComponent(movs[0])).load(.duration).seconds
        let doubled = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(doubled, 2 * single, accuracy: 0.2,
                       "stitched output ≈ 2× the canonical loop duration")
        try? FileManager.default.removeItem(at: out)
    }

    /// `--loop-reps` validation: out-of-range / non-integer values exit 2.
    func testStitchLoopRepsRejectsInvalidValues() async throws {
        for bad in ["0", "-1", "abc", "6"] {
            let rc = await EmberweftCLI.flock([
                "stitch", "--sequence", "/tmp", "--shard", shardName,
                "--codec", "h264", "--loop-reps", bad, "--flock", "/tmp/nowhere",
            ])
            XCTAssertEqual(rc, 2, "--loop-reps \(bad) must be rejected")
        }
    }

    // MARK: - rebuild (AC: rebuild flock.sqlite)

    /// `rebuild` on a fresh (empty) flock root creates a valid empty catalog and
    /// exits 0 (no shard dirs ⇒ no-op repopulation). Proves the wiring without a
    /// render.
    func testRebuildEmptyFlockRootSucceeds() async throws {
        let root = makeFlockRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rc = await EmberweftCLI.flock(["rebuild", "--flock", root.path])
        XCTAssertEqual(rc, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("flock.sqlite").path),
                      "rebuild should leave a flock.sqlite")
    }

    /// `rebuild` repopulates from `<shard>/mpeg/*.mov` filenames + embedded tags.
    /// Generate one real `.mov` (tagged) into a source root, COPY it into a fresh
    /// rebuild root (no prior catalog, no live catalog connection), then rebuild
    /// and confirm browse reports the shard.
    ///
    /// Why the copy: rebuilding the SAME root generate just wrote to flakes —
    /// `FlockCatalog.rebuild` moves only `flock.sqlite` to `.bak`, leaving the
    /// stale `-wal`/`-shm` from generate's still-live catalog actor connection,
    /// and the new connection chokes with a SQLite "disk I/O error". A fresh
    /// rebuild root with just the `.mov` (no prior sqlite) isolates rebuild's
    /// repopulation path deterministically — the resilience scenario rebuild
    /// exists for (catalog lost/corrupt, mpeg/ intact).
    func testRebuildRepopulatesFromMpegFilenames() async throws {
        // 1. Generate a real tagged .mov into a source root.
        let srcRoot = makeFlockRoot()
        defer { try? FileManager.default.removeItem(at: srcRoot) }
        let from = try makeFromDir(genomeCount: 1)
        defer { try? FileManager.default.removeItem(at: from) }
        let genRC = await EmberweftCLI.flock([
            "generate", "--from", from.path, "--shard", shardName,
            "--scope", "loops", "--quality", "4", "--codec", "h264",
            "--backend", "cpu", "--flock", srcRoot.path,
        ])
        XCTAssertEqual(genRC, 0)
        let srcMov = srcRoot.appendingPathComponent(shardName)
            .appendingPathComponent("mpeg").appendingPathComponent("248=00001=248=00001.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcMov.path), "generate should produce the .mov")

        // 2. Fresh rebuild root: just the mpeg file, no prior catalog.
        let rebuildRoot = makeFlockRoot()
        defer { try? FileManager.default.removeItem(at: rebuildRoot) }
        let dstMpeg = rebuildRoot.appendingPathComponent(shardName)
            .appendingPathComponent("mpeg").appendingPathComponent("248=00001=248=00001.mov")
        try FileManager.default.createDirectory(at: dstMpeg.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: srcMov, to: dstMpeg)

        // 3. rebuild reconstructs the catalog from the .mov filename + tags.
        let rc = await EmberweftCLI.flock(["rebuild", "--flock", rebuildRoot.path])
        XCTAssertEqual(rc, 0)
        let browse = await captureOut {
            _ = await EmberweftCLI.flock(["browse", "--flock", rebuildRoot.path])
        }
        XCTAssertTrue(browse.contains("1 shard"), "rebuilt catalog should have the shard: \(browse)")
    }

    // MARK: - export-list (AC: writes the <list> XML)

    /// Seed a catalog directly (no render), then `export-list` writes a
    /// well-formed `<list>` beside the shard dir with one `<sheep>` per artifact.
    func testExportListWritesXml() async throws {
        let root = makeFlockRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cat = try FlockCatalog(root: root)
        let shard = ShardSpec(name: shardName, width: 48, height: 32, fps: 30,
                              loopSeconds: 0.1, transSeconds: 0.07,
                              loopFrames: 3, transFrames: 2,
                              isCanonical: false, codec: .h264)
        try await cat.upsertShard(shard)
        try await cat.upsertArtifact(ArtifactRow(
            aGen: "248", aId: "00001", bGen: "248", bId: "00002",
            shard: shardName, kind: .edge,
            file: "\(shardName)/mpeg/248=00001=248=00002.mov", thumb: nil,
            width: 48, height: 32, fps: 30, loopFrames: 3, transFrames: 2,
            spp: 4, temporal: 1, smoothing: "off", smoothingHw: 0,
            qualityRank: 4.0, bytes: 999, renderedAt: 0,
            sourceSha: nil, seed: 0, codec: .h264))

        let out = await captureOut {
            let rc = await EmberweftCLI.flock([
                "export-list", "--shard", shardName, "--flock", root.path,
            ])
            XCTAssertEqual(rc, 0)
        }
        let xmlURL = root.appendingPathComponent("\(shardName).xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: xmlURL.path), "export-list should write the XML")

        let doc = try XMLDocument(contentsOf: xmlURL, options: [])
        XCTAssertEqual(try doc.nodes(forXPath: "//list").count, 1)
        let sheep = try doc.nodes(forXPath: "//sheep")
        XCTAssertEqual(sheep.count, 1, "one <sheep> per artifact")
        let el = sheep[0] as! XMLElement
        XCTAssertEqual(el.attribute(forName: "first")?.stringValue, "248/00001")
        // Minted id (no edges.sqlite supplied ⇒ synthesized).
        XCTAssertEqual(el.attribute(forName: "id")?.stringValue, "minted-248-00001-248-00002")
        XCTAssertTrue(out.contains(".xml"), "export-list should print the written path: \(out)")
    }

    /// `export-list` for an unknown shard ⇒ nonzero exit + error.
    func testExportListUnknownShardErrors() async throws {
        let root = makeFlockRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rc = await EmberweftCLI.flock([
            "export-list", "--shard", "does-not-exist", "--flock", root.path,
        ])
        XCTAssertNotEqual(rc, 0)
    }
}
