// Tests/FlameFlockTests/ArchiveRendererTests.swift
import XCTest
import AVFoundation
@testable import FlameFlock
@testable import FlameExport   // appendedFrameCount test seam (internal)
import FlameKit

/// Task 9 — `ArchiveRenderer`: the lone-edge 2-segment `FramePlan`, the loop
/// 1-segment plan, the deterministic seed, the atomic write order
/// (temp → rename → catalog upsert), the mdta tags, and the `.jpg` thumb.
///
/// The load-bearing invariant is `testLoneEdgePlanRendersOnlyTransitionSlot`
/// (from the plan): a 2-segment edge plan renders ONLY the transition slot
/// (`loopFrames..<(loopFrames+transFrames)`), and frame 0 of that range maps to
/// `segmentId == 1` / `.transition` — proving the transition sits at segment 1,
/// NOT segment 0.
final class ArchiveRendererTests: XCTestCase {

    // MARK: - helpers

    /// `#filePath` (not `#file`): in Swift 6.2 `#file` returns a basename which
    /// collapses the directory chain and resolves the genome wrong. This file is
    /// at `Tests/FlameFlockTests/`, so two `deletingLastPathComponent()` land on
    /// `Tests/`, then `Goldens/genomes/sierpinski.flam3` (a small, fast,
    /// renderable synthetic flame — the same fixture the export batch tests use).
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
            .appendingPathComponent("flock-archive-\(UUID().uuidString)")
    }

    /// Small + fast render profile. `loopFrames=3` / `transFrames=2` keep both
    /// the loop and edge renders to a handful of CPU frames at 48×32 spp 4.
    private func shardSpec(name: String = "48x32_30fps") -> ShardSpec {
        ShardSpec(name: name, width: 48, height: 32, fps: 30,
                  loopSeconds: 0.1, transSeconds: 0.07,
                  loopFrames: 3, transFrames: 2,
                  isCanonical: false, codec: .h264)
    }

    /// Settings whose `resolution` matches the shard dimensions (the encoder
    /// dimensions MUST equal the rendered frame dimensions), `quality = .spp(4)`
    /// for a deterministic resolved spp, `temporalSamples = 1` (sharp/fast), and
    /// the DEFAULT `smoothingAlpha = 1.0` (OFF — the determinism / byte-identity
    /// mastering path; the archive edge is byte-comparable to a one-shot only
    /// with smoothing OFF).
    ///
    /// Container is `.mov` (the real archive format per spec D12, and the
    /// container FlockNaming names the file with): custom `mdta` tags persist to
    /// `.mov` but are silently dropped from `.mp4` (the mirror of the T1 finding).
    /// The failure-injection test forces `.mp4` back off this default.
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

    // MARK: - Lone-edge plan (load-bearing, pure — no render)

    /// The lone-edge construction (§4.1): a 2-segment FramePlan renders ONLY the
    /// transition slot; frame 0 of the rendered range maps to `.transition`.
    func testLoneEdgePlanRendersOnlyTransitionSlot() throws {
        let A = Flame(); let B = Flame()
        let loopFrames = 8, transFrames = 6
        let plan = ArchiveRenderer.makeEdgePlan(A: A, B: B, loopFrames: loopFrames,
                                                transFrames: transFrames, seed: 1)
        let range = ArchiveRenderer.edgeRenderRange(loopFrames: loopFrames, transFrames: transFrames)
        XCTAssertEqual(range, loopFrames..<(loopFrames + transFrames))   // only the transition slot
        // Frame 0 of the rendered range (== global frame loopFrames) maps to
        // segmentId 1 (the transition segment) — proves the 2-segment plan puts
        // the transition at segment 1, NOT segment 0 (which is loop(A)).
        let d = plan.descriptor(for: range.lowerBound)
        XCTAssertEqual(d.segmentId, 1, "edge range lowerBound must map to segment 1 (transition)")
        XCTAssertEqual(d.kind, .transition)
        // Velocity match (§4.1 invariant): the rotRatio the plan feeds
        // Transition.blend is transFrames/loopFrames (re-derived from the plan's
        // public per-kind counts; FramePlan stores framesPerSegment +
        // transitionFramesPerSegment as public lets).
        XCTAssertEqual(Double(plan.transitionFramesPerSegment) / Double(plan.framesPerSegment),
                       Double(transFrames) / Double(loopFrames), accuracy: 1e-12)
    }

    // MARK: - Loop plan (pure)

    /// The loop construction: a 1-segment FramePlan; render range `0..<loopFrames`;
    /// frame 0 maps to segmentId 0 / `.loop`.
    func testLoopPlanRendersOnlyLoopSlot() throws {
        let A = Flame()
        let loopFrames = 5, transFrames = 4
        let plan = ArchiveRenderer.makeLoopPlan(A: A, loopFrames: loopFrames,
                                                transFrames: transFrames, seed: 7)
        XCTAssertEqual(ArchiveRenderer.loopRenderRange(loopFrames: loopFrames), 0..<loopFrames)
        let d0 = plan.descriptor(for: 0)
        XCTAssertEqual(d0.segmentId, 0)
        XCTAssertEqual(d0.kind, .loop)
        // A 1-segment plan emits exactly loopFrames frames.
        XCTAssertEqual(plan.totalFrames, loopFrames)
        XCTAssertEqual(plan.framesPerSegment, loopFrames)
        XCTAssertEqual(plan.transitionFramesPerSegment, transFrames)
    }

    /// The edge plan is structurally 2 segments: loop(A) at segment 0, transition
    /// at segment 1, totaling `loopFrames + transFrames`. The loop slot exists in
    /// the plan (Schedule requires a loop before a transition) but is NEVER
    /// rendered — `edgeRenderRange` starts at `loopFrames`.
    func testEdgePlanIsLoopThenTransitionTwoSegments() throws {
        let A = Flame(); let B = Flame()
        let loopFrames = 8, transFrames = 6
        let plan = ArchiveRenderer.makeEdgePlan(A: A, B: B, loopFrames: loopFrames,
                                                transFrames: transFrames, seed: 1)
        XCTAssertEqual(plan.totalFrames, loopFrames + transFrames)
        XCTAssertEqual(plan.framesPerSegment, loopFrames)
        XCTAssertEqual(plan.transitionFramesPerSegment, transFrames)
        // segment 0 = loop(A), segment 1 = transition(A→B).
        let dl = plan.descriptor(for: 0)
        XCTAssertEqual(dl.segmentId, 0); XCTAssertEqual(dl.kind, .loop)
        XCTAssertEqual(dl.fromSheep, 0); XCTAssertEqual(dl.toSheep, 0)
        let dt = plan.descriptor(for: loopFrames)
        XCTAssertEqual(dt.segmentId, 1); XCTAssertEqual(dt.kind, .transition)
        XCTAssertEqual(dt.fromSheep, 0); XCTAssertEqual(dt.toSheep, 1)
    }

    // MARK: - Deterministic seed (pure)

    /// `makeParams` threads the canonical `FlockSeed.seed(...)` into
    /// `RenderParams.seed` and uses the resolved spp/oversample for the shard
    /// dimensions. (`settings.samplesPerPixel` is NOT a field — spp comes from
    /// `settings.quality.resolvedSamplesPerPixel(for:)`.)
    func testMakeParamsThreadsDeterministicSeedAndResolvedSpp() throws {
        let A = try parseSierpinski()
        let shard = shardSpec()
        let settings = archiveSettings(matching: shard)
        let seed = FlockSeed.seed(shard: shard.name, aGen: "248", aId: "00628",
                                  bGen: "248", bId: "00628")
        let params = ArchiveRenderer.makeParams(A: A, shard: shard, seed: seed, settings: settings)
        XCTAssertEqual(params.seed, seed)
        XCTAssertEqual(params.width, shard.width)
        XCTAssertEqual(params.height, shard.height)
        // .spp(4) resolves to (spp=4, oversample=1).
        XCTAssertEqual(params.samplesPerPixel, 4)
        XCTAssertEqual(params.oversample, 1)
        // spatialFilterRadius threads the genome's filter radius.
        XCTAssertEqual(params.spatialFilterRadius, A.quality.filterRadius)
    }

    // MARK: - qualityRank formula (pure)

    /// qualityRank = spp × temporal × √(2·smoothing_hw + 1).
    func testQualityRankFormula() {
        // OFF smoothing (hw 0): rank = spp × temporal × 1.
        XCTAssertEqual(ArchiveRenderer.qualityRank(spp: 4, temporal: 1, smoothingHw: 0), 4.0)
        // h=5 (α=0.2): √(11) ≈ 3.3166.
        XCTAssertEqual(ArchiveRenderer.qualityRank(spp: 30, temporal: 4, smoothingHw: 5),
                       30.0 * 4.0 * (11.0).squareRoot(), accuracy: 1e-9)
    }

    // MARK: - makeMetadata uses the mdta keyspace (pure)

    /// The `emberweft.*` tags MUST be in the `mdta` keyspace (a literal
    /// "emberweft" keyspace is silently dropped by AVAssetWriter on `.mov` — the
    /// T1 finding). Plus a `.common` title.
    func testMakeMetadataUsesMdtaKeyspaceAndCommonTitle() {
        let shard = shardSpec()
        let settings = archiveSettings(matching: shard)
        let items = ArchiveRenderer.makeMetadata(stem: "248=00628=248=00628", shard: shard,
                                                 settings: settings, seed: 42, sourceSha: "abc",
                                                 spp: 4)
        // Title via `.common` keyspace + commonKeyTitle.
        let title = items.first { $0.keySpace == .common }
        XCTAssertNotNil(title)
        XCTAssertEqual(title?.key as? String, AVMetadataKey.commonKeyTitle.rawValue)
        XCTAssertEqual(title?.value as? String, "248=00628=248=00628")
        // Every emberweft.* tag is in the mdta keyspace.
        let ember = items.filter { ($0.key as? String)?.hasPrefix("emberweft.") == true }
        XCTAssertFalse(ember.isEmpty, "must emit at least one emberweft.* tag")
        XCTAssertTrue(ember.allSatisfy { $0.keySpace == AVMetadataKeySpace(rawValue: "mdta") },
                      "emberweft.* tags must use the mdta keyspace")
        // The load-bearing spp + seed tags are present with the resolved spp.
        let spp = items.first { ($0.key as? String) == "emberweft.spp" }
        XCTAssertEqual(spp?.value as? String, "4")
        let seed = items.first { ($0.key as? String) == "emberweft.seed" }
        XCTAssertEqual(seed?.value as? String, "42")
    }

    // MARK: - Atomic write order: failure injection (fast — no render)

    /// If the atomic rename never happens (here: ProRes-in-`.mp4` makes
    /// `VideoEncoder.start()` throw `proResRequiresMOV` inside
    /// `renderSegmentRange`, BEFORE any file is materialized at `out`), the
    /// catalog upsert MUST NOT run — never a row without its file.
    func testAtomicOrderNoRowWhenFileAbsent() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await catalog.upsertShard(shard)

        // ProRes requires `.mov`; `.mp4` ⇒ start() throws proResRequiresMOV.
        var settings = archiveSettings(matching: shard)
        settings.codec = .proRes422HQ
        settings.container = .mp4

        let A = try parseSierpinski()
        let coord = ExportCoordinator(backend: .cpu)
        let renderer = ArchiveRenderer()
        do {
            try await renderer.renderLoop(A: A, aGen: "248", aId: "00628", shard: shard,
                                          settings: settings, coordinator: coord, catalog: catalog,
                                          backend: .cpu, useOffMainMetal: false,
                                          flockRoot: root, sourceSha: nil)
            XCTFail("renderLoop should have thrown for ProRes-in-mp4")
        } catch {
            // Expected — the rename never happened.
        }
        // No artifact file at the archive path...
        let out = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                 aGen: "248", aId: "00628",
                                                 bGen: "248", bId: "00628", ext: "mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "no file at out when the rename was skipped")
        // ...therefore NO catalog row for the key.
        let row = try await catalog.lookup(aGen: "248", aId: "00628",
                                           bGen: "248", bId: "00628", shard: shard.name)
        XCTAssertNil(row, "upsert must not run when the file is absent (atomic order)")
    }

    // MARK: - renderLoop: file + thumb + tags + catalog row (real render, fast)

    /// A successful loop render produces: the `.mov` at the archive path, a
    /// `.jpg` thumb, the mdta `emberweft.spp` tag, and a catalog row keyed by
    /// the composite PK with `kind == .loop`, the resolved spp, and the
    /// deterministic seed threaded into `RenderParams.seed` / `row.seed`.
    func testRenderLoopProducesArtifactThumbTagsAndRow() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let A = try parseSierpinski()
        let expectedSeed = FlockSeed.seed(shard: shard.name, aGen: "248", aId: "00628",
                                          bGen: "248", bId: "00628")

        let coord = ExportCoordinator(backend: .cpu)
        let renderer = ArchiveRenderer()
        try await renderer.renderLoop(A: A, aGen: "248", aId: "00628", shard: shard,
                                      settings: settings, coordinator: coord, catalog: catalog,
                                      backend: .cpu, useOffMainMetal: false,
                                      flockRoot: root, sourceSha: "deadbeef")

        // Artifact file at the archive path.
        let out = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                 aGen: "248", aId: "00628",
                                                 bGen: "248", bId: "00628", ext: "mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "artifact .mov must exist")
        // Thumb .jpg at the thumb path.
        let thumb = try FlockNaming.thumbURL(flockRoot: root, shardDir: shard.name,
                                             aGen: "248", aId: "00628",
                                             bGen: "248", bId: "00628")
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumb.path), "thumb .jpg must exist")

        // mdta `emberweft.spp` tag readable from the file.
        let asset = AVURLAsset(url: out)
        let allMeta = try await asset.load(.metadata)
        let sppItem = allMeta.first {
            $0.keySpace == AVMetadataKeySpace(rawValue: "mdta")
                && ($0.key as? String) == "emberweft.spp"
        }
        XCTAssertEqual(sppItem?.value as? String, "4", "file must carry emberweft.spp mdta tag")
        let seedItem = allMeta.first {
            $0.keySpace == AVMetadataKeySpace(rawValue: "mdta")
                && ($0.key as? String) == "emberweft.seed"
        }
        XCTAssertEqual(seedItem?.value as? String, String(Int(truncatingIfNeeded: expectedSeed)))

        // Catalog row keyed by the composite PK; self-edge ⇒ kind=.loop.
        let row = try await catalog.lookup(aGen: "248", aId: "00628",
                                           bGen: "248", bId: "00628", shard: shard.name)
        let r = try XCTUnwrap(row, "catalog row must exist after a successful render")
        XCTAssertEqual(r.kind, .loop)
        XCTAssertEqual(r.spp, 4)
        XCTAssertEqual(r.temporal, 1)
        XCTAssertEqual(r.shard, shard.name)
        XCTAssertEqual(r.seed, Int(truncatingIfNeeded: expectedSeed))
        XCTAssertEqual(r.sourceSha, "deadbeef")
        XCTAssertGreaterThan(r.bytes, 0)
        XCTAssertEqual(r.file, "\(shard.name)/mpeg/\(out.lastPathComponent)")
    }

    // MARK: - renderEdge: transition artifact (real render, fast)

    /// A successful edge render produces a `.mov` + row with `kind == .edge`.
    /// The plan is the 2-segment lone-edge; only the transition frames are
    /// encoded. (A==B genome data is fine here — Transition.blend still runs and
    /// produces a valid stream; the AC is the file + kind, not the morph.)
    func testRenderEdgeProducesTransitionArtifact() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let A = try parseSierpinski()
        let B = A   // same genome data; distinct ids make it an edge record.

        let coord = ExportCoordinator(backend: .cpu)
        // Drive the coordinator's frame-count seam via renderEdge: the lone-edge
        // plan must append exactly transFrames (2) — the loop slot is skipped.
        let renderer = ArchiveRenderer()
        try await renderer.renderEdge(A: A, B: B, aGen: "248", aId: "00628",
                                      bGen: "248", bId: "03194", shard: shard,
                                      settings: settings, coordinator: coord, catalog: catalog,
                                      backend: .cpu, useOffMainMetal: false,
                                      flockRoot: root, sourceSha: nil)

        // Exactly transFrames frames were appended (the loop slot was NOT rendered).
        let appended = await coord.appendedFrameCount
        XCTAssertEqual(appended, shard.transFrames,
                       "lone-edge must append exactly transFrames (loop slot skipped)")

        let out = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                 aGen: "248", aId: "00628",
                                                 bGen: "248", bId: "03194", ext: "mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let row = try await catalog.lookup(aGen: "248", aId: "00628",
                                           bGen: "248", bId: "03194", shard: shard.name)
        XCTAssertEqual(try XCTUnwrap(row).kind, .edge)
        XCTAssertEqual(try XCTUnwrap(row).seed,
                       Int(truncatingIfNeeded: FlockSeed.seed(shard: shard.name, aGen: "248", aId: "00628",
                                          bGen: "248", bId: "03194")))
    }
}
