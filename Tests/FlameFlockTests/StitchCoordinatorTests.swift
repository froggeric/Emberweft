// Tests/FlameFlockTests/StitchCoordinatorTests.swift
import XCTest
import AVFoundation
@testable import FlameFlock
@testable import FlameExport   // appendedFrameCount test seam (internal)
import FlameKit

/// Task 11 — `StitchCoordinator` (Path B): the one-batch-lookup + HIT/MISS +
/// passthrough-concat actor. Covers every AC:
///  (a) exactly ONE `catalog.batchLookup` call (pinned via a counting spy);
///  (b) HIT-only fast path (pre-rendered segments collected, none regenerated,
///      passthrough concat ⇒ output duration ≈ sum of sources);
///  (c) MISS ⇒ rendered into the archive first, then collected;
///  (d) cross-shard refused;
///  (e) codec-mismatch refused;
///  (f) empty sequence ⇒ failed;
///  (g) single-genome ⇒ loop-only copy, no concat.
///
/// The spy-based tests (a, b, d, e) drive `FlockCatalogStitching` (the single
/// testability seam) so `batchLookup`/`lookup` calls are countable. The
/// render-into-archive tests (c, g) use a real `FlockCatalog` + real
/// `ArchiveRenderer` on the fast `sierpinski.flam3` fixture at 48×32 spp 4 CPU.
final class StitchCoordinatorTests: XCTestCase {

    // MARK: - helpers (mirror ArchiveRendererTests)

    private func sierpinskiURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3")
    }
    private func parseSierpinski() throws -> Flame {
        try Flam3Parser.parse(Data(contentsOf: sierpinskiURL()))[0]
    }
    private func makeRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flock-stitch-\(UUID().uuidString)")
        // Create the dir so `defer { removeItem }` cleans up without an ENOENT
        // (the spy-only tests never touch the filesystem, so nothing else would
        // create it; FlockCatalog.init creates it for the render tests).
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    /// Render profile with enough frames for a robust concat-duration comparison
    /// (loopFrames=6, transFrames=4 at 30 fps ⇒ 0.2 s / 0.133 s per segment).
    private func shardSpec(name: String = "48x32_30fps", codec: ExportSettings.Codec = .h264) -> ShardSpec {
        ShardSpec(name: name, width: 48, height: 32, fps: 30,
                  loopSeconds: 0.2, transSeconds: 0.133,
                  loopFrames: 6, transFrames: 4,
                  isCanonical: false, codec: codec)
    }
    private func archiveSettings(matching shard: ShardSpec, spp: Int = 4) -> ExportSettings {
        var s = ExportSettings()
        s.codec = shard.codec
        s.container = .mov
        s.resolution = .custom(width: shard.width, height: shard.height)
        s.fps = shard.fps
        s.quality = .spp(spp)
        s.temporalSamples = 1
        return s
    }
    private func outURL(root: URL) -> URL { root.appendingPathComponent("stitch-out.mov") }

    /// Canonical PK string (mirrors `StitchCoordinator`'s private `pkString`).
    private func pk(_ aGen: String, _ aId: String, _ bGen: String, _ bId: String, _ shard: String) -> String {
        "\(aGen)|\(aId)|\(bGen)|\(bId)|\(shard)"
    }
    private func duration(of url: URL) async throws -> TimeInterval {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    /// Drain a stitch stream into an array of progress values (gate failures and
    /// successes finish without throwing; the array's last element is terminal).
    private func drain(_ stream: AsyncThrowingStream<StitchUIProgress, Error>) async throws -> [StitchUIProgress] {
        var out: [StitchUIProgress] = []
        for try await p in stream { out.append(p) }
        return out
    }

    // MARK: - (a) + (b): ONE batchLookup + HIT-only fast path

    /// All segments pre-rendered ⇒ the spy serves every key as a HIT, so:
    /// • exactly ONE `batchLookup` call (the N+1 gate);
    /// • `lookup` is NEVER called (the MISS branch, which re-reads after render,
    ///   is never reached — proves nothing was regenerated);
    /// • passthrough concat produces an output whose duration ≈ the sum of the
    ///   source durations.
    func testHitOnlyFastPathOneBatchLookupAndConcatDuration() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let realCatalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await realCatalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)

        // Pre-render the 3 segments of a 2-genome sequence into the real archive
        // (loop A, edge A→B, loop B), then read their ground-truth rows back —
        // the spy will return these same rows (their `.file` paths are real).
        let A = try parseSierpinski(), B = A
        let coord = ExportCoordinator(backend: .cpu)
        let renderer = ArchiveRenderer()
        try await renderer.renderLoop(A: A, aGen: "248", aId: "00001", shard: shard,
                                      settings: settings, coordinator: coord, catalog: realCatalog,
                                      backend: .cpu, useOffMainMetal: false, flockRoot: root, sourceSha: nil)
        try await renderer.renderEdge(A: A, B: B, aGen: "248", aId: "00001", bGen: "248", bId: "00002",
                                      shard: shard, settings: settings, coordinator: coord, catalog: realCatalog,
                                      backend: .cpu, useOffMainMetal: false, flockRoot: root, sourceSha: nil)
        try await renderer.renderLoop(A: B, aGen: "248", aId: "00002", shard: shard,
                                      settings: settings, coordinator: coord, catalog: realCatalog,
                                      backend: .cpu, useOffMainMetal: false, flockRoot: root, sourceSha: nil)
        let rowLoopA = try await realCatalog.lookup(aGen: "248", aId: "00001", bGen: "248", bId: "00001", shard: shard.name)
        let rowEdge  = try await realCatalog.lookup(aGen: "248", aId: "00001", bGen: "248", bId: "00002", shard: shard.name)
        let rowLoopB = try await realCatalog.lookup(aGen: "248", aId: "00002", bGen: "248", bId: "00002", shard: shard.name)
        XCTAssertNotNil(rowLoopA); XCTAssertNotNil(rowEdge); XCTAssertNotNil(rowLoopB)

        let spy = CatalogSpy(rows: [rowLoopA!, rowEdge!, rowLoopB!])
        let stitcher = StitchCoordinator(catalog: spy, renderer: renderer, backend: .cpu, useOffMainMetal: false)
        let request = StitchRequest(
            shard: shard,
            orderedFlames: [("248", "00001", A), ("248", "00002", B)],
            settings: settings, flockRoot: root, out: outURL(root: root),
            loopRepetitions: 1)

        let progress = try await drain(stitcher.stitch(request, coordinator: coord))

        // (a) exactly ONE batchLookup call.
        let batchCount = await spy.batchLookupCount
        XCTAssertEqual(batchCount, 1, "stitch must issue exactly ONE batchLookup (the N+1 gate)")
        // (b) HIT-only ⇒ the MISS branch (which calls `lookup`) is never reached.
        let lookupCount = await spy.lookupCount
        XCTAssertEqual(lookupCount, 0, "all-HIT ⇒ no MISS ⇒ lookup must not be called (nothing regenerated)")
        // Terminal = completed, and the plan reports the right hit/miss split.
        XCTAssertEqual(progress.first, .resolving)
        XCTAssertNotNil(progress.firstIndex(where: { if case .plan = $0 { return true } else { return false } }))
        let planIdx = progress.firstIndex(where: { if case .plan = $0 { return true } else { return false } })!
        XCTAssertEqual(progress[planIdx], .plan(hitCount: 3, missCount: 0, segmentCount: 3))
        XCTAssertEqual(progress.last, .completed(out: outURL(root: root)))

        // Passthrough concat ⇒ output duration ≈ sum of the 3 source durations.
        let out = outURL(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "concat output must exist")
        let outDur = try await duration(of: out)
        let srcLoopA = try await duration(of: root.appendingPathComponent(rowLoopA!.file))
        let srcEdge  = try await duration(of: root.appendingPathComponent(rowEdge!.file))
        let srcLoopB = try await duration(of: root.appendingPathComponent(rowLoopB!.file))
        let sum = srcLoopA + srcEdge + srcLoopB
        XCTAssertEqual(outDur, sum, accuracy: 0.3,
                       "passthrough concat output duration (\(outDur)s) must ≈ sum of sources (\(sum)s)")
        // Multi-file concat ⇒ out is longer than any single source.
        XCTAssertGreaterThan(outDur, max(srcLoopA, srcEdge, srcLoopB),
                             "out must be longer than any single source (proves multi-segment concat)")
    }

    // MARK: - (c): MISS ⇒ render into the archive first, then collect

    /// An empty archive ⇒ every segment is a MISS, so each is rendered into the
    /// archive (catalog rows + files materialize) BEFORE collection, and the
    /// passthrough concat stitches the freshly-rendered files.
    func testMissRendersIntoArchiveThenCollects() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)   // empty archive
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let A = try parseSierpinski(), B = A

        let coord = ExportCoordinator(backend: .cpu)
        let stitcher = StitchCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                         backend: .cpu, useOffMainMetal: false)
        let request = StitchRequest(
            shard: shard,
            orderedFlames: [("248", "00001", A), ("248", "00002", B)],
            settings: settings, flockRoot: root, out: outURL(root: root),
            loopRepetitions: 1)

        let progress = try await drain(stitcher.stitch(request, coordinator: coord))

        XCTAssertEqual(progress.last, .completed(out: outURL(root: root)))
        // The plan saw 3 misses (loop A, edge A→B, loop B), 0 hits.
        let planIdx = try XCTUnwrap(progress.firstIndex(where: { if case .plan = $0 { return true } else { return false } }))
        XCTAssertEqual(progress[planIdx], .plan(hitCount: 0, missCount: 3, segmentCount: 3))

        // MISS ⇒ rendered INTO the archive first: all 3 rows now exist there.
        let rLoopA = try await catalog.lookup(aGen: "248", aId: "00001", bGen: "248", bId: "00001", shard: shard.name)
        let rEdge  = try await catalog.lookup(aGen: "248", aId: "00001", bGen: "248", bId: "00002", shard: shard.name)
        let rLoopB = try await catalog.lookup(aGen: "248", aId: "00002", bGen: "248", bId: "00002", shard: shard.name)
        XCTAssertNotNil(rLoopA, "MISS loop A must be rendered into the archive")
        XCTAssertNotNil(rEdge,  "MISS edge A→B must be rendered into the archive")
        XCTAssertNotNil(rLoopB, "MISS loop B must be rendered into the archive")
        XCTAssertEqual(rLoopA?.kind, .loop)
        XCTAssertEqual(rEdge?.kind, .edge)
        XCTAssertEqual(rLoopB?.kind, .loop)
        // The archive files exist on disk (render-into-archive ⇒ file + row).
        for r in [rLoopA!, rEdge!, rLoopB!] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(r.file).path),
                          "MISS segment archive file must exist: \(r.file)")
        }
        // Every MISS frame was rendered (loop 6 + edge 4 + loop 6 = 16 frames).
        let appended = await coord.appendedFrameCount
        XCTAssertEqual(appended, shard.loopFrames + shard.transFrames + shard.loopFrames,
                       "all 3 MISS segments must be rendered into the archive")
        // The concat output exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL(root: root).path))
    }

    // MARK: - (c2): MISS renders stream per-frame progress + a concat phase

    /// v0.5.9 — the owner symptom fix: a MISS render must NOT go dark. Every
    /// MISS segment streams `.rendering` per encoded frame (plus a pre-render
    /// `frame == 0` yield), labeled loop/edge and positioned over ALL segments
    /// ("segment 3/5" the way the plan counted them), and the remux tail yields
    /// `.concatenating` between the last `.running` and `.completed`.
    func testMissEmitsPerFrameRenderingAndConcatenatingProgress() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)   // empty archive ⇒ all MISS
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let A = try parseSierpinski(), B = A

        let coord = ExportCoordinator(backend: .cpu)
        let stitcher = StitchCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                         backend: .cpu, useOffMainMetal: false)
        let request = StitchRequest(
            shard: shard, orderedFlames: [("248", "00001", A), ("248", "00002", B)],
            settings: settings, flockRoot: root, out: outURL(root: root),
            loopRepetitions: 1)

        let progress = try await drain(stitcher.stitch(request, coordinator: coord))

        // Segment 1 = loop(A) over 6 frames: a frame-0 pre-render yield + one
        // `.rendering` per encoded frame.
        let seg1 = progress.filter {
            if case .rendering(1, 3, true, _, _) = $0 { return true } else { return false }
        }
        XCTAssertEqual(seg1.count, shard.loopFrames + 1,
                       "loop MISS must yield frame-0 + one .rendering per encoded frame")
        if case .rendering(_, _, _, let f0, let ft)? = seg1.first {
            XCTAssertEqual(f0, 0, "the first .rendering of a segment is the pre-render yield")
            XCTAssertEqual(ft, shard.loopFrames, "loop frameTotal = shard.loopFrames")
        } else {
            XCTFail("segment 1 should carry .rendering events")
        }
        // Segment 2 = edge(A→B) over the transFrames-only range (4 frames).
        let seg2 = progress.filter {
            if case .rendering(2, 3, false, _, _) = $0 { return true } else { return false }
        }
        XCTAssertEqual(seg2.count, shard.transFrames + 1, "edge MISS over the transition range")
        // Segment 3 = loop(B), 6 frames.
        let seg3 = progress.filter {
            if case .rendering(3, 3, true, _, _) = $0 { return true } else { return false }
        }
        XCTAssertEqual(seg3.count, shard.loopFrames + 1)

        // No stray segments/positions and no rendering events for HITs (none here).
        let allRendering = progress.filter {
            if case .rendering = $0 { return true } else { return false }
        }
        XCTAssertEqual(allRendering.count,
                       (shard.loopFrames + 1) + (shard.transFrames + 1) + (shard.loopFrames + 1),
                       "exactly the three MISS segments' worth of .rendering events")

        // The concat phase is yielded between the last .running and .completed.
        let concatIdx = try XCTUnwrap(progress.firstIndex(where: {
            if case .concatenating = $0 { return true } else { return false }
        }), "multi-segment stitch must yield .concatenating")
        XCTAssertEqual(progress[concatIdx], .concatenating(segments: 3))
        let lastRunningIdx = try XCTUnwrap(progress.lastIndex(where: {
            if case .running = $0 { return true } else { return false }
        }))
        let completedIdx = try XCTUnwrap(progress.lastIndex(where: {
            if case .completed = $0 { return true } else { return false }
        }))
        XCTAssertLessThan(lastRunningIdx, concatIdx, ".concatenating comes after the last segment")
        XCTAssertLessThan(concatIdx, completedIdx, ".concatenating comes before .completed")
    }

    /// The single-file copy tail also yields `.concatenating(segments: 1)` — no
    /// silent gap on the loop-only path either.
    func testSingleFileCopyYieldsConcatenatingPhase() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let A = try parseSierpinski()

        let coord = ExportCoordinator(backend: .cpu)
        let stitcher = StitchCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                         backend: .cpu, useOffMainMetal: false)
        let request = StitchRequest(
            shard: shard, orderedFlames: [("248", "00001", A)],
            settings: settings, flockRoot: root, out: outURL(root: root),
            loopRepetitions: 1)

        let progress = try await drain(stitcher.stitch(request, coordinator: coord))
        XCTAssertTrue(progress.contains(.concatenating(segments: 1)),
                      "the single-genome copy path must yield .concatenating(segments: 1): \(progress)")
        XCTAssertEqual(progress.last, .completed(out: outURL(root: root)))
    }

    // MARK: - (d): cross-shard refused

    /// A stored row referencing a shard other than `request.shard` ⇒ refuse.
    func testCrossShardRefused() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shard = shardSpec()   // "48x32_30fps", codec h264 (matches the row)
        // Row has a DIFFERENT shard than the request (correct codec so the codec
        // gate does not fire first — this isolates the cross-shard gate).
        let stray = makeRow(aGen: "248", aId: "00001", bGen: "248", bId: "00001",
                            shard: "OTHER_shard", codec: shard.codec)
        let spy = CatalogSpy(rows: [stray])
        let coord = ExportCoordinator(backend: .cpu)
        let stitcher = StitchCoordinator(catalog: spy, renderer: ArchiveRenderer(),
                                         backend: .cpu, useOffMainMetal: false)
        let request = StitchRequest(
            shard: shard,
            orderedFlames: [("248", "00001", Flame()), ("248", "00002", Flame())],
            settings: archiveSettings(matching: shard), flockRoot: root, out: outURL(root: root))

        let progress = try await drain(stitcher.stitch(request, coordinator: coord))

        XCTAssertEqual(progress.last, .failed("Stitch requires a single shard."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outURL(root: root).path),
                       "no output on a cross-shard refuse")
    }

    // MARK: - (e): codec-mismatch refused

    /// A stored row whose codec differs from `request.shard.codec` ⇒ refuse with
    /// the rebuild hint.
    func testCodecMismatchRefused() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shard = shardSpec(codec: .h264)
        // Row matches the shard name (so the cross-shard gate stays quiet) but has
        // a DIFFERENT codec (hevc vs h264) ⇒ codec-uniformity gate fires.
        let mixed = makeRow(aGen: "248", aId: "00001", bGen: "248", bId: "00001",
                            shard: shard.name, codec: .hevc)
        let spy = CatalogSpy(rows: [mixed])
        let coord = ExportCoordinator(backend: .cpu)
        let stitcher = StitchCoordinator(catalog: spy, renderer: ArchiveRenderer(),
                                         backend: .cpu, useOffMainMetal: false)
        let request = StitchRequest(
            shard: shard,
            orderedFlames: [("248", "00001", Flame()), ("248", "00002", Flame())],
            settings: archiveSettings(matching: shard), flockRoot: root, out: outURL(root: root))

        let progress = try await drain(stitcher.stitch(request, coordinator: coord))

        XCTAssertEqual(progress.last, .failed("Archive shard has mixed codecs. Run 'flock rebuild'."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outURL(root: root).path),
                       "no output on a codec-mismatch refuse")
    }

    // MARK: - (f): empty sequence refused

    func testEmptySequenceRefused() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shard = shardSpec()
        let spy = CatalogSpy(rows: [])   // never consulted (empty short-circuits first)
        let coord = ExportCoordinator(backend: .cpu)
        let stitcher = StitchCoordinator(catalog: spy, renderer: ArchiveRenderer(),
                                         backend: .cpu, useOffMainMetal: false)
        let request = StitchRequest(
            shard: shard, orderedFlames: [],
            settings: archiveSettings(matching: shard), flockRoot: root, out: outURL(root: root))

        let progress = try await drain(stitcher.stitch(request, coordinator: coord))

        XCTAssertEqual(progress.last, .failed("Sequence is empty."))
        // The empty short-circuit precedes the batchLookup ⇒ zero calls.
        let batchCount = await spy.batchLookupCount
        XCTAssertEqual(batchCount, 0, "empty sequence must short-circuit before batchLookup")
    }

    // MARK: - (g): single-genome ⇒ loop-only copy, no concat

    /// One genome ⇒ one loop segment ⇒ `urls.count == 1` ⇒ the file is COPIED
    /// (byte-identical to the single archive file), NOT concatenated. Only a loop
    /// row is created (no edge).
    func testSingleGenomeLoopOnlyCopyNoConcat() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let A = try parseSierpinski()

        let coord = ExportCoordinator(backend: .cpu)
        let stitcher = StitchCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                         backend: .cpu, useOffMainMetal: false)
        let out = outURL(root: root)
        let request = StitchRequest(
            shard: shard, orderedFlames: [("248", "00001", A)],
            settings: settings, flockRoot: root, out: out,
            loopRepetitions: 1)

        let progress = try await drain(stitcher.stitch(request, coordinator: coord))

        XCTAssertEqual(progress.last, .completed(out: out))
        // Exactly one loop row; no edge row (single genome ⇒ loop-only).
        let rLoop = try await catalog.lookup(aGen: "248", aId: "00001", bGen: "248", bId: "00001", shard: shard.name)
        let rEdge = try await catalog.lookup(aGen: "248", aId: "00001", bGen: "248", bId: "00002", shard: shard.name)
        let loopRow = try XCTUnwrap(rLoop, "single-genome MISS ⇒ loop rendered into the archive")
        XCTAssertEqual(loopRow.kind, .loop)
        XCTAssertNil(rEdge, "single genome ⇒ no edge segment")
        // The loop slot was rendered (loopFrames), the edge slot was not.
        let appended = await coord.appendedFrameCount
        XCTAssertEqual(appended, shard.loopFrames, "only the loop slot is rendered for a single genome")

        // Copy, not concat: out is byte-identical to the single archive file.
        let archiveFile = root.appendingPathComponent(loopRow.file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveFile.path),
                      "the source loop archive file must still exist (copy, not move)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "the copy output must exist")
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: out.path, andPath: archiveFile.path),
                      "single-genome output must be byte-identical to the loop archive file (copy, not concat)")
    }

    // MARK: - (h): loop repetitions (stitch-time, default 2)

    /// reps=2 timeline shape on the ALL-HIT path: the keys list is
    /// `[loopA, loopA, edgeAB, loopB, loopB]` — 5 timeline slots from 3 unique
    /// keys. The plan counts UNIQUE archive work (3 HIT, 0 will-gen) while the
    /// slot total is 5; the concat input carries `loopA`'s and `loopB`'s file
    /// URLs TWICE each, and the output duration ≈ 2·loopA + edge + 2·loopB.
    /// `loopRepetitions` is OMITTED here — this also pins the default == 2.
    func testLoopRepetitionsDefaultTwoShapeAllHit() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let realCatalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await realCatalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)

        // Pre-render the 3 unique segments (loop A, edge A→B, loop B).
        let A = try parseSierpinski(), B = A
        let coord = ExportCoordinator(backend: .cpu)
        let renderer = ArchiveRenderer()
        try await renderer.renderLoop(A: A, aGen: "248", aId: "00001", shard: shard,
                                      settings: settings, coordinator: coord, catalog: realCatalog,
                                      backend: .cpu, useOffMainMetal: false, flockRoot: root, sourceSha: nil)
        try await renderer.renderEdge(A: A, B: B, aGen: "248", aId: "00001", bGen: "248", bId: "00002",
                                      shard: shard, settings: settings, coordinator: coord, catalog: realCatalog,
                                      backend: .cpu, useOffMainMetal: false, flockRoot: root, sourceSha: nil)
        try await renderer.renderLoop(A: B, aGen: "248", aId: "00002", shard: shard,
                                      settings: settings, coordinator: coord, catalog: realCatalog,
                                      backend: .cpu, useOffMainMetal: false, flockRoot: root, sourceSha: nil)
        let rowLoopA = try await realCatalog.lookup(aGen: "248", aId: "00001", bGen: "248", bId: "00001", shard: shard.name)
        let rowEdge  = try await realCatalog.lookup(aGen: "248", aId: "00001", bGen: "248", bId: "00002", shard: shard.name)
        let rowLoopB = try await realCatalog.lookup(aGen: "248", aId: "00002", bGen: "248", bId: "00002", shard: shard.name)

        let spy = CatalogSpy(rows: [rowLoopA!, rowEdge!, rowLoopB!])
        let stitcher = StitchCoordinator(catalog: spy, renderer: renderer, backend: .cpu, useOffMainMetal: false)
        let request = StitchRequest(
            shard: shard, orderedFlames: [("248", "00001", A), ("248", "00002", B)],
            settings: settings, flockRoot: root, out: outURL(root: root))   // reps default = 2

        let progress = try await drain(stitcher.stitch(request, coordinator: coord))

        // Plan: UNIQUE counts (3 HIT / 0 will-gen) + the slot total (5).
        let planIdx = try XCTUnwrap(progress.firstIndex(where: {
            if case .plan = $0 { return true } else { return false }
        }))
        XCTAssertEqual(progress[planIdx], .plan(hitCount: 3, missCount: 0, segmentCount: 5),
                       "reps=2: 3 unique HIT keys, 5 timeline slots")
        XCTAssertEqual(progress.last, .completed(out: outURL(root: root)))
        // The final running tally counts SLOTS: 5 assembled (3 first-occurrence
        // HITs + 2 repeat-reference HITs), 0 generated.
        let lastRunning = try XCTUnwrap(progress.last(where: {
            if case .running = $0 { return true } else { return false }
        }))
        XCTAssertEqual(lastRunning, .running(hit: 5, generated: 0),
                       "all 5 slots are HITs (repeats reuse the same row)")
        // Concat of 5 slots (the two loop files listed twice each).
        XCTAssertTrue(progress.contains(.concatenating(segments: 5)),
                      "5-slot timeline ⇒ 5-file concat input: \(progress)")
        // Duration ≈ 2·loopA + edge + 2·loopB (the reps actually extend the
        // assembled timeline — the point of the feature).
        let out = outURL(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let srcLoopA = try await duration(of: root.appendingPathComponent(rowLoopA!.file))
        let srcEdge  = try await duration(of: root.appendingPathComponent(rowEdge!.file))
        let srcLoopB = try await duration(of: root.appendingPathComponent(rowLoopB!.file))
        let outDur = try await duration(of: out)
        XCTAssertEqual(outDur, 2 * srcLoopA + srcEdge + 2 * srcLoopB, accuracy: 0.4,
                       "reps=2 output duration must ≈ 2·loopA + edge + 2·loopB")
    }

    /// reps=2 on the ALL-MISS path: each loop is rendered EXACTLY ONCE (the
    /// canonical artifact), and its repetitions are HITs — NOT re-renders. The
    /// timeline positions advance over all 5 slots (the repeated loop's second
    /// occurrence occupies position 2 with no render). Edges are never repeated.
    func testLoopRepetitionsTwoMissRendersEachLoopOnce() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)   // empty ⇒ all unique keys MISS
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let A = try parseSierpinski(), B = A

        let coord = ExportCoordinator(backend: .cpu)
        let stitcher = StitchCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                         backend: .cpu, useOffMainMetal: false)
        let request = StitchRequest(
            shard: shard, orderedFlames: [("248", "00001", A), ("248", "00002", B)],
            settings: settings, flockRoot: root, out: outURL(root: root),
            loopRepetitions: 2)

        let progress = try await drain(stitcher.stitch(request, coordinator: coord))

        XCTAssertEqual(progress.last, .completed(out: outURL(root: root)))
        let planIdx = try XCTUnwrap(progress.firstIndex(where: {
            if case .plan = $0 { return true } else { return false }
        }))
        XCTAssertEqual(progress[planIdx], .plan(hitCount: 0, missCount: 3, segmentCount: 5),
                       "3 unique will-gens (loopA, edge, loopB) across 5 timeline slots")

        // Each loop rendered ONCE: loop 6 + edge 4 + loop 6 = 16 frames total
        // (NOT 6+6+4+6+6 = 28 — repetitions never re-render).
        let appended = await coord.appendedFrameCount
        XCTAssertEqual(appended, shard.loopFrames + shard.transFrames + shard.loopFrames,
                       "reps=2 must render each loop exactly once (the canonical artifact)")

        // Timeline positions: slot 1 = loopA MISS (renders), slot 2 = loopA
        // repeat HIT (NO rendering events at position 2), slot 3 = edge MISS,
        // slot 4 = loopB MISS, slot 5 = loopB repeat HIT (no position-5 events).
        XCTAssertTrue(progress.contains { if case .rendering(1, 5, true, _, _) = $0 { return true } else { return false } },
                      "slot 1 (loopA) renders at position 1/5")
        XCTAssertTrue(progress.contains { if case .rendering(3, 5, false, _, _) = $0 { return true } else { return false } },
                      "slot 3 (edge) renders at position 3/5")
        XCTAssertTrue(progress.contains { if case .rendering(4, 5, true, _, _) = $0 { return true } else { return false } },
                      "slot 4 (loopB) renders at position 4/5")
        XCTAssertFalse(progress.contains { if case .rendering(2, _, _, _, _) = $0 { return true } else { return false } },
                       "slot 2 is a repeated-loop HIT — it must NOT render")
        XCTAssertFalse(progress.contains { if case .rendering(5, _, _, _, _) = $0 { return true } else { return false } },
                       "slot 5 is a repeated-loop HIT — it must NOT render")

        // The archive gained EXACTLY 3 rows / 3 files (no per-repetition files).
        let mpeg = root.appendingPathComponent(shard.name).appendingPathComponent("mpeg")
        let movs = ((try? FileManager.default.contentsOfDirectory(atPath: mpeg.path)) ?? [])
            .filter { $0.hasSuffix(".mov") }
        XCTAssertEqual(movs.count, 3, "reps duplicate TIMELINE slots, never archive files: \(movs)")
        // Final running tally: 5 slots assembled (3 generated + 2 repeat HITs).
        let lastRunning = try XCTUnwrap(progress.last(where: {
            if case .running = $0 { return true } else { return false }
        }))
        XCTAssertEqual(lastRunning, .running(hit: 2, generated: 3))
    }

    /// Single genome × reps=2 ⇒ `urls.count == 2` ⇒ the CONCAT path (two copies
    /// of the one loop file), NOT the single-file copy path. The archive still
    /// holds exactly ONE loop row and the loop renders once.
    func testSingleGenomeTwoRepsConcatsTwoCopiesNotCopy() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let A = try parseSierpinski()

        let coord = ExportCoordinator(backend: .cpu)
        let stitcher = StitchCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                         backend: .cpu, useOffMainMetal: false)
        let out = outURL(root: root)
        let request = StitchRequest(
            shard: shard, orderedFlames: [("248", "00001", A)],
            settings: settings, flockRoot: root, out: out,
            loopRepetitions: 2)

        let progress = try await drain(stitcher.stitch(request, coordinator: coord))

        XCTAssertEqual(progress.last, .completed(out: out))
        // Concat of 2 segments — NOT the single-file copy (segments == 1).
        XCTAssertTrue(progress.contains(.concatenating(segments: 2)),
                      "single genome × reps=2 must concat 2 copies: \(progress)")
        XCTAssertFalse(progress.contains(.concatenating(segments: 1)),
                       "the copy path must NOT fire when reps > 1")
        // Rendered once; one archive row; output duration ≈ 2× the loop.
        let appended = await coord.appendedFrameCount
        XCTAssertEqual(appended, shard.loopFrames, "the loop renders once regardless of reps")
        let loopRowOpt = try await catalog.lookup(aGen: "248", aId: "00001",
                                                  bGen: "248", bId: "00001", shard: shard.name)
        let loopRow = try XCTUnwrap(loopRowOpt)
        let srcDur = try await duration(of: root.appendingPathComponent(loopRow.file))
        let outDur = try await duration(of: out)
        XCTAssertEqual(outDur, 2 * srcDur, accuracy: 0.3,
                       "single genome × reps=2 output ≈ 2× the canonical loop duration")
        XCTAssertFalse(FileManager.default.contentsEqual(atPath: out.path,
                                                         andPath: root.appendingPathComponent(loopRow.file).path),
                       "out is a 2-copy concat, not a byte-copy of the single archive file")
    }

    // MARK: - (i): HIT respects the D4 quality rank (upgrade-overwrite)

    /// A stored row below the REQUESTED rank is NOT a HIT: it is re-rendered
    /// (upgrade-overwrite at the same archive path), and the row's quality comes
    /// up to the request. A second stitch at the SAME quality then HITs (no
    /// re-render). This mirrors `GenerateCoordinator`'s D4 rule on the stitch path.
    func testHitRespectsQualityRankUpgradesLowerRankRow() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        let low = archiveSettings(matching: shard, spp: 2)     // rank 2
        let high = archiveSettings(matching: shard, spp: 4)    // rank 4
        let A = try parseSierpinski()

        // Seed the archive with a LOW-rank loop (as a prior generate would).
        let coord = ExportCoordinator(backend: .cpu)
        let renderer = ArchiveRenderer()
        try await renderer.renderLoop(A: A, aGen: "248", aId: "00001", shard: shard,
                                      settings: low, coordinator: coord, catalog: catalog,
                                      backend: .cpu, useOffMainMetal: false, flockRoot: root, sourceSha: nil)
        let seededOpt = try await catalog.lookup(aGen: "248", aId: "00001",
                                                 bGen: "248", bId: "00001", shard: shard.name)
        let seeded = try XCTUnwrap(seededOpt)
        XCTAssertEqual(seeded.spp, 2, "seed row is the low-quality artifact")

        // Stitch 1 at the HIGHER quality: the low-rank row must NOT hit ⇒
        // upgrade re-render (MISS), then collect.
        let stitcher = StitchCoordinator(catalog: catalog, renderer: renderer,
                                         backend: .cpu, useOffMainMetal: false)
        let out1 = root.appendingPathComponent("upgrade.mov")
        let progress1 = try await drain(stitcher.stitch(
            StitchRequest(shard: shard, orderedFlames: [("248", "00001", A)],
                          settings: high, flockRoot: root, out: out1, loopRepetitions: 1),
            coordinator: coord))
        XCTAssertEqual(progress1.last, .completed(out: out1))
        let plan1 = try XCTUnwrap(progress1.firstIndex(where: {
            if case .plan = $0 { return true } else { return false }
        }))
        XCTAssertEqual(progress1[plan1], .plan(hitCount: 0, missCount: 1, segmentCount: 1),
                       "a lower-rank row is a MISS at the higher requested quality")
        let upgradedOpt = try await catalog.lookup(aGen: "248", aId: "00001",
                                                   bGen: "248", bId: "00001", shard: shard.name)
        let upgraded = try XCTUnwrap(upgradedOpt)
        XCTAssertEqual(upgraded.spp, 4, "the row must be upgraded to the requested quality")

        // Stitch 2 at the SAME quality: now the row's rank meets the request ⇒
        // HIT, nothing regenerated (the coordinator's lookup is only used on
        // MISS — assert via the frame counter instead: no new frames appended).
        let appendedBefore = await coord.appendedFrameCount
        let out2 = root.appendingPathComponent("hit.mov")
        let progress2 = try await drain(stitcher.stitch(
            StitchRequest(shard: shard, orderedFlames: [("248", "00001", A)],
                          settings: high, flockRoot: root, out: out2, loopRepetitions: 1),
            coordinator: coord))
        XCTAssertEqual(progress2.last, .completed(out: out2))
        let plan2 = try XCTUnwrap(progress2.firstIndex(where: {
            if case .plan = $0 { return true } else { return false }
        }))
        XCTAssertEqual(progress2[plan2], .plan(hitCount: 1, missCount: 0, segmentCount: 1),
                       "an equal-rank row IS a HIT")
        let appendedAfter = await coord.appendedFrameCount
        XCTAssertEqual(appendedBefore, appendedAfter, "the HIT must not re-render any frame")
    }

    // MARK: - fixtures

    /// Synthesize an `ArtifactRow` with default fields for the spy-only tests
    /// (cross-shard / codec-mismatch), where no real file is ever opened.
    private func makeRow(aGen: String, aId: String, bGen: String, bId: String,
                         shard: String, codec: ExportSettings.Codec,
                         file: String = "stub.mov") -> ArtifactRow {
        ArtifactRow(
            aGen: aGen, aId: aId, bGen: bGen, bId: bId, shard: shard,
            kind: (aGen == bGen && aId == bId) ? .loop : .edge,
            file: file, thumb: nil, width: 48, height: 32, fps: 30,
            loopFrames: 6, transFrames: 4, spp: 4, temporal: 1,
            smoothing: "off", smoothingHw: 0, qualityRank: 4.0, bytes: 0,
            renderedAt: 0, sourceSha: nil, seed: 0, codec: codec)
    }
}

/// Counting catalog double conforming to `FlockCatalogStitching`. A test DOUBLE:
/// `batchLookup` returns its canned rows verbatim (it does NOT filter by the
/// requested PKs). This is deliberate — a real `FlockCatalog.batchLookup` filters
/// by the full PK including shard, so a stray-shard / stray-codec row can never
/// come back from it; to exercise those gates the double must INJECT such rows
/// itself. For the all-HIT test the canned rows are exactly the requested PKs, so
/// returning them verbatim is the faithful result anyway. Both methods increment
/// counters so tests can pin the exactly-one-batch-lookup invariant and the
/// all-HIT ⇒ no-`lookup` invariant.
private actor CatalogSpy: FlockCatalogStitching {
    private let rows: [ArtifactRow]
    private(set) var batchLookupCount = 0
    private(set) var lookupCount = 0
    init(rows: [ArtifactRow]) { self.rows = rows }

    func batchLookup(_ keys: [(aGen: String, aId: String, bGen: String,
                               bId: String, shard: String)]) async throws -> [ArtifactRow] {
        batchLookupCount += 1
        return rows   // verbatim — see class doc
    }

    func lookup(aGen: String, aId: String, bGen: String, bId: String, shard: String) async throws -> ArtifactRow? {
        lookupCount += 1
        return rows.first {
            $0.aGen == aGen && $0.aId == aId && $0.bGen == bGen && $0.bId == bId && $0.shard == shard
        }
    }
}
