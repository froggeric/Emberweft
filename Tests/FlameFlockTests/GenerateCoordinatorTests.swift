// Tests/FlameFlockTests/GenerateCoordinatorTests.swift
import XCTest
@testable import FlameFlock
@testable import FlameExport   // ExportCoordinator test seam (appendedFrameCount)
import FlameKit

/// Task 10 — `GenerateCoordinator` (Path A): the per-unit hit-skip /
/// upgrade-overwrite / unrenderable-skip / scope-filter / progress-stream /
/// resume-via-plan-file actor. Mirrors `ArchiveRendererTests`' fast-CPU harness
/// (sierpinski at 48×32, spp 4, 1–3 frames).
///
/// The renderable flame is `sierpinski.flam3` (the sibling fixture), NOT the
/// curated `electricsheep.248.00628` genome the plan suggested: that genome
/// lives under `Sources/EmberweftGUI/` (a different module whose sources the
/// `FlameFlock` test target cannot reach via `#filePath`), and sierpinski is the
/// established fast+renderable fixture in this target. The ACs are
/// scope/skip/resume mechanics (flame-agnostic), so the fixture choice is
/// immaterial to correctness.
final class GenerateCoordinatorTests: XCTestCase {

    // MARK: - helpers (mirror ArchiveRendererTests)

    /// `#filePath` (not `#file`): in Swift 6.2 `#file` returns a basename. This
    /// file is at `Tests/FlameFlockTests/`; two `deletingLastPathComponent()`
    /// land on `Tests/`, then `Goldens/genomes/sierpinski.flam3`.
    private func sierpinskiURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3")
    }
    private func parseSierpinski() throws -> Flame {
        try Flam3Parser.parse(Data(contentsOf: sierpinskiURL()))[0]
    }

    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flock-generate-\(UUID().uuidString)")
    }

    /// Fast render profile: 3 loop / 2 transition frames at 48×32 spp 4.
    private func shardSpec(name: String = "48x32_30fps") -> ShardSpec {
        ShardSpec(name: name, width: 48, height: 32, fps: 30,
                  loopSeconds: 0.1, transSeconds: 0.07,
                  loopFrames: 3, transFrames: 2,
                  isCanonical: false, codec: .h264)
    }

    /// OFF smoothing (α=1.0 ⇒ hw=0) so the mastering path is byte-sharp and
    /// `qualityRank = spp × temporal × 1`. `.spp(4)` ⇒ requested rank 4.
    private func archiveSettings(matching shard: ShardSpec) -> ExportSettings {
        var s = ExportSettings()
        s.codec = .h264
        s.container = .mov
        s.resolution = .custom(width: shard.width, height: shard.height)
        s.fps = shard.fps
        s.quality = .spp(4)
        s.temporalSamples = 1
        // smoothingAlpha stays 1.0 (OFF) — the default.
        return s
    }

    /// A loop (self-edge) unit: aGen==bGen, aId==bId.
    private func loopUnit(id: String = "00628", flame: Flame? = nil) throws -> GenerateUnit {
        let A = try flame ?? parseSierpinski()
        return GenerateUnit(aGen: "248", aId: id, bGen: "248", bId: id, A: A, B: A)
    }

    /// An edge unit: distinct (bGen,bId) endpoint.
    private func edgeUnit(aId: String = "00628", bId: String = "03194",
                          A: Flame? = nil, B: Flame? = nil) throws -> GenerateUnit {
        let a = try A ?? parseSierpinski()
        return GenerateUnit(aGen: "248", aId: aId, bGen: "248", bId: bId, A: a, B: B ?? a)
    }

    /// Catalog row pre-upsert helper (sentinel `file` — the real archive path is
    /// asserted separately; the row's `file` string is just a record).
    private func artifactRow(aGen: String, aId: String, bGen: String, bId: String,
                             shard: String, kind: ArtifactRow.Kind,
                             qualityRank: Double) -> ArtifactRow {
        ArtifactRow(aGen: aGen, aId: aId, bGen: bGen, bId: bId, shard: shard, kind: kind,
                    file: "\(shard)/mpeg/sentinel.mov", thumb: nil,
                    width: 48, height: 32, fps: 30, loopFrames: 3, transFrames: 2,
                    spp: 4, temporal: 1, smoothing: "off", smoothingHw: 0,
                    qualityRank: qualityRank, bytes: 999, renderedAt: 0,
                    sourceSha: nil, seed: 0, codec: .h264)
    }

    /// Collect the full progress stream to completion.
    private func collect(_ stream: AsyncThrowingStream<GenerateUIProgress, Error>) async throws -> [GenerateUIProgress] {
        var events: [GenerateUIProgress] = []
        for try await e in stream { events.append(e) }
        return events
    }

    /// Assert the stream terminated with `.completed(rendered:skipped:)` carrying
    /// the expected counts. (Named tuples don't conform to `Equatable`, so the
    /// components are compared individually.)
    private func assertCompleted(_ events: [GenerateUIProgress], rendered: Int, skipped: Int,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard case let .completed(r, s) = events.last else {
            XCTFail("expected .completed, got \(String(describing: events.last))", file: file, line: line)
            return
        }
        XCTAssertEqual(r, rendered, "rendered", file: file, line: line)
        XCTAssertEqual(s, skipped, "skipped", file: file, line: line)
    }

    // MARK: - AC (a): scope. Default = edges; .loops / .both opt-in.

    /// Default scope `.edges` renders only edge units — the loop unit in the set
    /// is NOT rendered (no loop artifact file, no loop catalog row).
    func testDefaultScopeEdgesRendersOnlyEdges() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec(); try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let gen = GenerateCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                       backend: .cpu, useOffMainMetal: false)
        let req = GenerateRequest(shard: shard,
                                  units: [try loopUnit(), try edgeUnit()],
                                  scope: .edges, settings: settings, flockRoot: root)
        let events = try await collect(gen.generate(req, coordinator: ExportCoordinator(backend: .cpu)))
        assertCompleted(events, rendered: 1, skipped: 0)
        // Edge artifact present; loop artifact absent.
        let edgeFile = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                      aGen: "248", aId: "00628", bGen: "248", bId: "03194", ext: "mov")
        let loopFile = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                      aGen: "248", aId: "00628", bGen: "248", bId: "00628", ext: "mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: edgeFile.path), "edge must render under .edges")
        XCTAssertFalse(FileManager.default.fileExists(atPath: loopFile.path), "loop must NOT render under .edges")
    }

    func testScopeLoopsRendersOnlyLoops() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec(); try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let gen = GenerateCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                       backend: .cpu, useOffMainMetal: false)
        let req = GenerateRequest(shard: shard,
                                  units: [try loopUnit(), try edgeUnit()],
                                  scope: .loops, settings: settings, flockRoot: root)
        let events = try await collect(gen.generate(req, coordinator: ExportCoordinator(backend: .cpu)))
        assertCompleted(events, rendered: 1, skipped: 0)
        let loopFile = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                      aGen: "248", aId: "00628", bGen: "248", bId: "00628", ext: "mov")
        let edgeFile = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                      aGen: "248", aId: "00628", bGen: "248", bId: "03194", ext: "mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: loopFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: edgeFile.path))
    }

    func testScopeBothRendersLoopsAndEdges() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec(); try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let gen = GenerateCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                       backend: .cpu, useOffMainMetal: false)
        let req = GenerateRequest(shard: shard,
                                  units: [try loopUnit(), try edgeUnit()],
                                  scope: .both, settings: settings, flockRoot: root)
        let events = try await collect(gen.generate(req, coordinator: ExportCoordinator(backend: .cpu)))
        assertCompleted(events, rendered: 2, skipped: 0)
    }

    // MARK: - AC (g): enumeration order — edges first (D10)

    /// `GenerateUnit.enumerate` emits units in TIMELINE order matching the
    /// collection/selection order (owner decision 2026-08-13): loop(A), edge(A→B),
    /// loop(B), edge(B→C), loop(C). For 3 genomes: 3 loops + 2 edges interleaved.
    /// The archive thus builds in the order Stitch consumes it (a partial generate
    /// covers the earliest timeline first).
    func testEnumerateInterleavesTimelineOrder() throws {
        let A = try parseSierpinski()
        let flames: [(gen: String, id: String, flame: Flame)] = [
            ("248", "00001", A), ("248", "00002", A), ("248", "00003", A),
        ]
        let units = GenerateUnit.enumerate(flames)
        // 3 loops + 2 edges = 5 units, interleaved.
        XCTAssertEqual(units.count, 5)
        XCTAssertTrue(units[0].isLoop, "unit 0 must be loop(00001)")
        XCTAssertEqual(units[0].aId, "00001"); XCTAssertEqual(units[0].bId, "00001")
        XCTAssertFalse(units[1].isLoop, "unit 1 must be edge(00001→00002)")
        XCTAssertEqual(units[1].aId, "00001"); XCTAssertEqual(units[1].bId, "00002")
        XCTAssertTrue(units[2].isLoop, "unit 2 must be loop(00002)")
        XCTAssertEqual(units[2].aId, "00002"); XCTAssertEqual(units[2].bId, "00002")
        XCTAssertFalse(units[3].isLoop, "unit 3 must be edge(00002→00003)")
        XCTAssertEqual(units[3].aId, "00002"); XCTAssertEqual(units[3].bId, "00003")
        XCTAssertTrue(units[4].isLoop, "unit 4 must be loop(00003)")
        XCTAssertEqual(units[4].aId, "00003")
    }

    /// A single genome ⇒ one loop, no edges (no adjacent pair).
    func testEnumerateSingleGenomeIsOneLoop() throws {
        let A = try parseSierpinski()
        let units = GenerateUnit.enumerate([("248", "00001", A)])
        XCTAssertEqual(units.count, 1)
        XCTAssertTrue(units[0].isLoop)
    }

    /// Empty input ⇒ empty unit list (no crash).
    func testEnumerateEmptyIsEmpty() {
        XCTAssertTrue(GenerateUnit.enumerate([]).isEmpty)
    }

    /// The edges-first reorder changes only render ORDER, never the unit SET: the
    /// same artifacts land regardless of order. This pins the membership for 2
    /// genomes (1 edge + 2 loops) so a future caller cannot silently drop a unit.
    func testEnumerateTwoGenomesProducesOneEdgeTwoLoops() throws {
        let A = try parseSierpinski()
        let units = GenerateUnit.enumerate([
            ("248", "00001", A), ("248", "00002", A),
        ])
        let loops = units.filter { $0.isLoop }
        let edges = units.filter { !$0.isLoop }
        XCTAssertEqual(loops.count, 2, "2 genomes ⇒ 2 loops")
        XCTAssertEqual(edges.count, 1, "2 genomes ⇒ 1 edge")
        XCTAssertEqual(edges[0].aId, "00001"); XCTAssertEqual(edges[0].bId, "00002")
    }

    // MARK: - AC (b): hit-skip (stored quality_rank >= requested ⇒ skip, file untouched)

    func testHitSkipWhenStoredQualityRankMeetsRequest() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec(); try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)   // requested rank = 4
        // Pre-upsert a row whose quality_rank (100) >= requested (4) ⇒ HIT.
        try await catalog.upsertArtifact(artifactRow(aGen: "248", aId: "00628",
                                                     bGen: "248", bId: "03194",
                                                     shard: shard.name, kind: .edge, qualityRank: 100))
        let gen = GenerateCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                       backend: .cpu, useOffMainMetal: false)
        let req = GenerateRequest(shard: shard, units: [try edgeUnit()],
                                  scope: .edges, settings: settings, flockRoot: root)
        let events = try await collect(gen.generate(req, coordinator: ExportCoordinator(backend: .cpu)))
        assertCompleted(events, rendered: 0, skipped: 1)   // HIT must skip, not render
        // File untouched: the archive .mov was never created.
        let edgeFile = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                      aGen: "248", aId: "00628", bGen: "248", bId: "03194", ext: "mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: edgeFile.path),
                       "hit-skip must not touch the archive file")
        // Row is the pre-upserted one (quality_rank 100 unchanged).
        let row = try await catalog.lookup(aGen: "248", aId: "00628",
                                           bGen: "248", bId: "03194", shard: shard.name)
        XCTAssertEqual(try XCTUnwrap(row).qualityRank, 100, "hit-skip must not rewrite the row")
    }

    // MARK: - AC (c): upgrade-overwrite (higher quality_rank ⇒ overwrite file + update row)

    func testUpgradeOverwriteWhenStoredQualityRankLower() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec(); try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)   // requested rank = 4
        // Pre-upsert a row whose quality_rank (1) < requested (4) ⇒ upgrade render.
        try await catalog.upsertArtifact(artifactRow(aGen: "248", aId: "00628",
                                                     bGen: "248", bId: "03194",
                                                     shard: shard.name, kind: .edge, qualityRank: 1))
        let gen = GenerateCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                       backend: .cpu, useOffMainMetal: false)
        let req = GenerateRequest(shard: shard, units: [try edgeUnit()],
                                  scope: .edges, settings: settings, flockRoot: root)
        let events = try await collect(gen.generate(req, coordinator: ExportCoordinator(backend: .cpu)))
        assertCompleted(events, rendered: 1, skipped: 0)   // upgrade must re-render
        // File now exists at the archive path (overwritten).
        let edgeFile = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                      aGen: "248", aId: "00628", bGen: "248", bId: "03194", ext: "mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: edgeFile.path))
        // Row updated: quality_rank promoted to the requested 4.0, bytes>0.
        let row = try await catalog.lookup(aGen: "248", aId: "00628",
                                           bGen: "248", bId: "03194", shard: shard.name)
        let r = try XCTUnwrap(row)
        XCTAssertEqual(r.qualityRank, 4.0, accuracy: 1e-9, "row must be upgraded to the requested rank")
        XCTAssertGreaterThan(r.bytes, 0)
    }

    // MARK: - AC (d): unrenderable genome skipped with notice

    func testUnrenderableGenomeSkippedWithNotice() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec(); try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        // `Flame()` has no xforms ⇒ isRenderable == false.
        let bad = Flame()
        XCTAssertFalse(bad.isRenderable, "fixture must be unrenderable")
        let gen = GenerateCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                       backend: .cpu, useOffMainMetal: false)
        let req = GenerateRequest(shard: shard,
                                  units: [try edgeUnit(A: bad, B: bad)],
                                  scope: .both, settings: settings, flockRoot: root)
        let events = try await collect(gen.generate(req, coordinator: ExportCoordinator(backend: .cpu)))
        assertCompleted(events, rendered: 0, skipped: 1)   // unrenderable must be skipped, not rendered
        let edgeFile = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                      aGen: "248", aId: "00628", bGen: "248", bId: "03194", ext: "mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: edgeFile.path))
        let row = try await catalog.lookup(aGen: "248", aId: "00628",
                                           bGen: "248", bId: "03194", shard: shard.name)
        XCTAssertNil(row, "unrenderable must not produce a catalog row")
    }

    // MARK: - AC (e): progress stream yields (skip, render, total)

    func testProgressStreamReportsSkipRenderTotal() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec(); try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        // One hit-skip (rank 100 >= 4) + one render ⇒ the stream must surface
        // both a skip and a render count over total 2.
        try await catalog.upsertArtifact(artifactRow(aGen: "248", aId: "00628",
                                                     bGen: "248", bId: "03194",
                                                     shard: shard.name, kind: .edge, qualityRank: 100))
        let gen = GenerateCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                       backend: .cpu, useOffMainMetal: false)
        let req = GenerateRequest(shard: shard,
                                  units: [try edgeUnit(), try edgeUnit(aId: "00628", bId: "02847")],
                                  scope: .edges, settings: settings, flockRoot: root)
        let events = try await collect(gen.generate(req, coordinator: ExportCoordinator(backend: .cpu)))
        XCTAssertEqual(events.first, .resolving)
        // Every running event carries the constant total 2.
        let running = events.compactMap { ev -> (skip: Int, render: Int, total: Int)? in
            if case let .running(skip, render, total) = ev { return (skip, render, total) }
            return nil
        }
        XCTAssertFalse(running.isEmpty, "stream must yield at least one .running")
        XCTAssertTrue(running.allSatisfy { $0.total == 2 }, "total must be the in-scope count (2)")
        // The final running pair matches the terminal completed counts (skip 1, render 1).
        let last = try XCTUnwrap(running.last)
        XCTAssertEqual(last.skip, 1)
        XCTAssertEqual(last.render, 1)
        XCTAssertEqual(events.last, .completed(rendered: 1, skipped: 1))
    }

    // MARK: - AC (f): resume via the generate-plan file (no redo of completed units)

    /// A generate-plan file pre-populated with the edge's completed key ⇒ on
    /// resume, the edge is NOT re-rendered (file absent), the loop IS rendered.
    func testResumeSkipsUnitsRecordedInPlanFile() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec(); try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        // Pre-write the plan with E's key "completed" (simulating a prior
        // cancelled run that finished E). The plan is a sorted JSON list of
        // GeneratePlanKey (the coordinator's own resume format).
        let planURL = GenerateCoordinator.planFileURL(flockRoot: root)
        let edgeKey = GeneratePlanKey(aGen: "248", aId: "00628", bGen: "248", bId: "03194",
                                      shard: shard.name)
        let planData = try JSONEncoder().encode([edgeKey])
        try planData.write(to: planURL, options: .atomic)

        let gen = GenerateCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                       backend: .cpu, useOffMainMetal: false)
        let req = GenerateRequest(shard: shard,
                                  units: [try loopUnit(), try edgeUnit()],
                                  scope: .both, settings: settings, flockRoot: root)
        let events = try await collect(gen.generate(req, coordinator: ExportCoordinator(backend: .cpu)))
        assertCompleted(events, rendered: 1, skipped: 1)   // resume must skip E, render L
        // E (resume-skipped) file absent; L (rendered) file present.
        let edgeFile = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                      aGen: "248", aId: "00628", bGen: "248", bId: "03194", ext: "mov")
        let loopFile = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                      aGen: "248", aId: "00628", bGen: "248", bId: "00628", ext: "mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: edgeFile.path),
                       "resume must not redo the completed edge")
        XCTAssertTrue(FileManager.default.fileExists(atPath: loopFile.path))
        // A successful run consumes its plan file (everything is done).
        XCTAssertFalse(FileManager.default.fileExists(atPath: planURL.path),
                       "completed run must remove the plan file")
    }

    /// `cancel()` before the run starts ⇒ the stream yields `.cancelled`, no
    /// units render, no plan file is written. (Deterministic cancel: avoids the
    /// mid-stream cancel timing race — the resume test above covers the
    /// plan-file mechanism this cooperates with.)
    func testCancelBeforeStartYieldsCancelled() async throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec(); try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let gen = GenerateCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                       backend: .cpu, useOffMainMetal: false)
        await gen.cancel()   // flip the flag BEFORE the run
        let req = GenerateRequest(shard: shard,
                                  units: [try loopUnit(), try edgeUnit()],
                                  scope: .both, settings: settings, flockRoot: root)
        let events = try await collect(gen.generate(req, coordinator: ExportCoordinator(backend: .cpu)))
        XCTAssertEqual(events.first, .resolving)
        XCTAssertEqual(events.last, .cancelled, "a pre-cancelled run must terminate with .cancelled")
        // No artifacts.
        let loopFile = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                      aGen: "248", aId: "00628", bGen: "248", bId: "00628", ext: "mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: loopFile.path))
        let planURL = GenerateCoordinator.planFileURL(flockRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: planURL.path),
                       "cancel with no completions must not write a plan file")
    }
}
