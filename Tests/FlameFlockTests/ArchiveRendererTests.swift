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
                  loopSeconds: 0.4, transSeconds: 0.27,
                  loopFrames: 12, transFrames: 8,
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

    // MARK: - Seam geometry (pure, load-bearing)

    /// The seam half-width is pinned to the smoothing window's constant: if a
    /// future tier widens the smoothing window beyond the artifact geometry's
    /// slice width, boundary windows would clip at the unit's internal seams —
    /// this pin forces the geometry constant to move WITH the tier constant.
    func testSeamHalfWidthMatchesSmoothingCap() {
        XCTAssertEqual(ArchiveRenderer.SeamGeometry.seamHalfWidth,
                       TemporalSmoothing.centeredHalfWidth)
        // Real shards (L > 11) get the full width; the core stays non-empty for
        // degenerate tiny loops (2h < L).
        XCTAssertEqual(ArchiveRenderer.SeamGeometry.halfWidth(loopFrames: 30), 5)
        XCTAssertEqual(ArchiveRenderer.SeamGeometry.halfWidth(loopFrames: 450), 5)
        XCTAssertEqual(ArchiveRenderer.SeamGeometry.halfWidth(loopFrames: 10), 4)
        XCTAssertEqual(ArchiveRenderer.SeamGeometry.halfWidth(loopFrames: 3), 1)
        // Ranges: core `[h, L-h)`; wrap `[2L-h, 2L+h)`; ext `[L-h, L+T+h)`.
        XCTAssertEqual(ArchiveRenderer.SeamGeometry.coreRenderRange(loopFrames: 30), 5..<25)
        XCTAssertEqual(ArchiveRenderer.SeamGeometry.wrapRenderRange(loopFrames: 30), 55..<65)
        XCTAssertEqual(ArchiveRenderer.SeamGeometry.extRenderRange(loopFrames: 30, transFrames: 24),
                       25..<59)
    }

    /// The EXT plan is 3 segments — loop(A), transition(A->B), loop(B) — and the
    /// TRANSITION-slot descriptors are IDENTICAL to the historical 2-segment
    /// lone-edge plan's (same schedule parameters): the edge frames' bytes are
    /// unchanged by the geometry (only the encoded RANGE grew on both sides).
    func testEdgeExtPlanMatchesHistoricalTransitionDescriptors() throws {
        let A = Flame(); let B = Flame()
        let L = 12, T = 8, seed: UInt64 = 3
        let ext = ArchiveRenderer.makeEdgeExtPlan(A: A, B: B, loopFrames: L,
                                                  transFrames: T, seed: seed, temporalSamples: 4)
        XCTAssertEqual(ext.totalFrames, 2 * L + T)
        // Historical 2-segment plan, built inline for comparison.
        var sched = Schedule(librarySize: 2, framesPerSegment: L,
                             transitionFramesPerSegment: T,
                             selector: Sequential(seed: seed), seed: seed)
        let legacy = FramePlan(schedule: &sched, segmentCount: 2, flames: [A, B],
                               loopCycles: 1, temporalSamples: 4)
        for k in L..<(L + T) {
            let de = ext.descriptor(for: k)
            let dl = legacy.descriptor(for: k)
            XCTAssertEqual(de.segmentId, dl.segmentId)
            XCTAssertEqual(de.kind, dl.kind)
            XCTAssertEqual(de.blend, dl.blend, accuracy: 0)
            XCTAssertEqual(de.fromSheep, dl.fromSheep)
            XCTAssertEqual(de.toSheep, dl.toSheep)
            XCTAssertEqual(de.temporal.map(\.delta), dl.temporal.map(\.delta))
            XCTAssertEqual(de.temporal.map(\.weight), dl.temporal.map(\.weight))
        }
        // Segment 2 exists and is loop(B) — the lookahead context.
        let d2 = ext.descriptor(for: L + T)
        XCTAssertEqual(d2.segmentId, 2)
        XCTAssertEqual(d2.kind, .loop)
        XCTAssertEqual(d2.fromSheep, 1)
        XCTAssertEqual(d2.blend, Double(1) / Double(L), accuracy: 0)
    }

    /// The EXT encode range covers h frames of loop A, the T transition frames,
    /// and h frames of loop B — every frame's centered ±h window lies INSIDE the
    /// PLAN (so the smoothing feed-emit's extended range can render it — no
    /// clipped boundary windows), which is the load-bearing seam fix.
    func testEdgeExtRangeWindowsAreInterior() throws {
        let A = Flame(); let B = Flame()
        let L = 12, T = 8
        let plan = ArchiveRenderer.makeEdgeExtPlan(A: A, B: B, loopFrames: L,
                                                   transFrames: T, seed: 1, temporalSamples: 1)
        XCTAssertEqual(plan.totalFrames, 2 * L + T)
        let h = ArchiveRenderer.SeamGeometry.halfWidth(loopFrames: L)
        let range = ArchiveRenderer.SeamGeometry.extRenderRange(loopFrames: L, transFrames: T)
        XCTAssertEqual(range.count, T + 2 * h)
        for m in range {
            XCTAssertTrue(m - h >= 0 && m + h < plan.totalFrames,
                          "window [\(m - h), \(m + h)] of frame \(m) must lie inside the plan")
            _ = plan.descriptor(for: m)   // must not trap
        }
    }

    /// The WRAP plan: 1 segment of 3L frames with `loopCycles: 3` — frame k's
    /// rotation equals the 1-cycle frame `(k mod L)`'s (same per-frame angular
    /// velocity), and the wrap range `[2L-h, 2L+h)`'s windows are interior.
    func testLoopWrapPlanPhasesAndInteriorWindows() throws {
        let A = Flame()
        let L = 12, T = 8
        let plan = ArchiveRenderer.makeLoopWrapPlan(A: A, loopFrames: L, transFrames: T,
                                                    seed: 1, temporalSamples: 1)
        XCTAssertEqual(plan.totalFrames, 3 * L)
        XCTAssertEqual(plan.framesPerSegment, 3 * L)
        // Rotation phase: frame k of the 3-cycle plan spins (k+1)/L turns — the
        // same angular step as the 1-cycle core plan.
        let k = 2 * L - 3
        XCTAssertEqual(plan.descriptor(for: k).blend, Double(k + 1) / Double(3 * L), accuracy: 0)
        let h = ArchiveRenderer.SeamGeometry.halfWidth(loopFrames: L)
        let range = ArchiveRenderer.SeamGeometry.wrapRenderRange(loopFrames: L)
        XCTAssertEqual(range.count, 2 * h)
        for m in range {
            XCTAssertTrue(m - h >= 0 && m + h < 3 * L,
                          "wrap window [\(m - h), \(m + h)] must lie inside the 3-cycle plan")
        }
    }

    /// The CORE plan: 1 segment over L frames, 1 cycle; the core range's windows
    /// are interior; every core frame maps to segment 0 / `.loop`.
    func testLoopCorePlanInteriorWindows() throws {
        let A = Flame()
        let L = 12, T = 8
        let plan = ArchiveRenderer.makeLoopCorePlan(A: A, loopFrames: L, transFrames: T,
                                                    seed: 7, temporalSamples: 1)
        XCTAssertEqual(plan.totalFrames, L)
        let h = ArchiveRenderer.SeamGeometry.halfWidth(loopFrames: L)
        let range = ArchiveRenderer.SeamGeometry.coreRenderRange(loopFrames: L)
        for m in range {
            XCTAssertTrue(m - h >= 0 && m + h < L,
                          "core window [\(m - h), \(m + h)] must lie inside the loop")
            let d = plan.descriptor(for: m)
            XCTAssertEqual(d.segmentId, 0)
            XCTAssertEqual(d.kind, .loop)
        }
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
                                                 spp: 4, framingGate: 1)
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

        // Artifact files at the archive path: the CORE plus the WRAP variant
        // (seam geometry v2 — a loop unit is two files).
        let out = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                 aGen: "248", aId: "00628",
                                                 bGen: "248", bId: "00628", ext: "mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "artifact .mov must exist")
        let wrapOut = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                     aGen: "248", aId: "00628",
                                                     bGen: "248", bId: "00628", ext: "mov",
                                                     variant: FlockNaming.wrapVariant)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrapOut.path),
                      "wrap .mov must exist (seam-aware loop = core + wrap)")
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
        XCTAssertEqual(r.geom, ArchiveRenderer.SeamGeometry.version)
        XCTAssertEqual(r.wrapFile, "\(shard.name)/mpeg/\(wrapOut.lastPathComponent)")
        XCTAssertEqual(r.spp, 4)
        XCTAssertEqual(r.temporal, 1)
        XCTAssertEqual(r.shard, shard.name)
        XCTAssertEqual(r.seed, Int(truncatingIfNeeded: expectedSeed))
        XCTAssertEqual(r.sourceSha, "deadbeef")
        XCTAssertGreaterThan(r.bytes, 0)
        XCTAssertEqual(r.file, "\(shard.name)/mpeg/\(out.lastPathComponent)")
    }

    // MARK: - renderEdge: transition artifact (real render, fast)

    /// Regression pin for the v0.6.0 GUI crash: a caller whose `settings`
    /// `resolution` DISAGREES with the shard (the GUI's `archiveSettings` used
    /// to leave it at the `.p1080` default) must not trap in
    /// `PixelBufferPool.fill` — `renderIntoArchive` force-aligns
    /// `settings.resolution` to the shard dims, and the ENCODED track must come
    /// out at the shard dims (48×32 here), not the stale settings resolution.
    func testRenderLoopAlignsEncoderResolutionToShardWhenSettingsDisagree() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        var settings = archiveSettings(matching: shard)
        settings.resolution = .p1080          // deliberately mismatched (GUI bug shape)
        let A = try parseSierpinski()
        let coord = ExportCoordinator(backend: .cpu)
        let renderer = ArchiveRenderer()
        try await renderer.renderLoop(A: A, aGen: "248", aId: "00628", shard: shard,
                                      settings: settings, coordinator: coord, catalog: catalog,
                                      backend: .cpu, useOffMainMetal: false,
                                      flockRoot: root, sourceSha: nil)
        let out = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                 aGen: "248", aId: "00628",
                                                 bGen: "248", bId: "00628", ext: "mov")
        let track = try await AVURLAsset(url: out).load(.tracks).first
        let size = try await track?.load(.naturalSize)
        XCTAssertEqual(size?.width, 48, "encoded width must be the SHARD's, not settings.resolution's")
        XCTAssertEqual(size?.height, 32, "encoded height must be the SHARD's, not settings.resolution's")
    }


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

        // The EXT range appends T + 2h frames (the transition plus h boundary
        // frames of EACH neighbor loop — seam geometry v2).
        let h = ArchiveRenderer.SeamGeometry.halfWidth(loopFrames: shard.loopFrames)
        let appended = await coord.appendedFrameCount
        XCTAssertEqual(appended, shard.transFrames + 2 * h,
                       "ext edge must append transFrames + 2h boundary frames")

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

    // MARK: - M6.6 framing normalization (flock)

    func testUnitFlamesNormalizesBothEndpointsWhenNormalized() throws {
        let A = try parseSierpinski()                       // authored 320×200, scale 100
        let B = try parseSierpinski()
        let (nA, nB) = ArchiveRenderer.unitFlames(A: A, B: B, renderWidth: 48, renderHeight: 32,
                                                 framing: .normalized)
        XCTAssertEqual(nA.camera.scale, 100.0 * 48.0 / 320.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(nB).camera.scale, 100.0 * 48.0 / 320.0, accuracy: 1e-9)
        XCTAssertNil(ArchiveRenderer.unitFlames(A: A, B: nil, renderWidth: 48, renderHeight: 32,
                                                framing: .normalized).B,
                     "loop: B stays nil")
    }

    func testUnitFlamesFaithfulPassesEndpointsThrough() throws {
        let A = try parseSierpinski()
        let (nA, nB) = ArchiveRenderer.unitFlames(A: A, B: A, renderWidth: 48, renderHeight: 32,
                                                 framing: .faithful)
        XCTAssertEqual(nA, A, "faithful = verbatim genomes (CLI mastering-parity mode)")
        XCTAssertEqual(nB, A)
    }

    /// T7: `makeMetadata` mirrors the row's framing column into the
    /// `emberweft.framing` mdta tag — "1" for normalized, "0" for faithful
    /// (also the legacy no-tag default on rebuild).
    func testMakeMetadataEmitsFramingTag() {
        let shard = shardSpec()
        func tag(_ settings: ExportSettings) -> String? {
            ArchiveRenderer.makeMetadata(stem: "248=00628=248=00628", shard: shard,
                                         settings: settings, seed: 1, sourceSha: nil, spp: 4,
                                         framingGate: settings.framing == .normalized ? 1 : 0)
                .first { ($0.key as? String) == "emberweft.framing" }?.value as? String
        }
        var normalized = archiveSettings(matching: shard)
        normalized.framing = .normalized
        XCTAssertEqual(tag(normalized), "1", "normalized settings must tag 1")
        XCTAssertEqual(tag(archiveSettings(matching: shard)), "0",
                       "faithful settings (the ExportSettings default) must tag 0")
    }

    /// T7 round-trip: a rendered loop's FILE carries the framing tag; the
    /// catalog row records the same value; and `FlockCatalog.rebuild` restores
    /// `ArtifactRow.framing` from the tag after the sqlite is discarded.
    ///
    /// The render phase lives in a scoped helper so its `FlockCatalog` (an actor
    /// holding an open sqlite connection) is RELEASED before `rebuild` moves
    /// flock.sqlite — a live connection leaves stale `-wal` sidecars that make
    /// the fresh catalog open fail with a disk I/O error.
    func testRenderLoopFramingTagRoundTripsThroughRebuild() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shard = shardSpec()

        // Phase 1 (scoped): render a normalized (00628) + a faithful (03194)
        // loop into the same shard; report the FILE tags + the live rows.
        func renderAndRead() async throws -> (tagN: String?, tagF: String?,
                                              rowN: Int?, rowF: Int?) {
            let catalog = try FlockCatalog(root: root)
            try await catalog.upsertShard(shard)
            var normalized = archiveSettings(matching: shard)
            normalized.framing = .normalized
            let faithful = archiveSettings(matching: shard)   // default == .faithful
            let A = try parseSierpinski()
            let coord = ExportCoordinator(backend: .cpu)
            let renderer = ArchiveRenderer()
            try await renderer.renderLoop(A: A, aGen: "248", aId: "00628", shard: shard,
                                          settings: normalized, coordinator: coord, catalog: catalog,
                                          backend: .cpu, useOffMainMetal: false,
                                          flockRoot: root, sourceSha: nil)
            try await renderer.renderLoop(A: A, aGen: "248", aId: "03194", shard: shard,
                                          settings: faithful, coordinator: coord, catalog: catalog,
                                          backend: .cpu, useOffMainMetal: false,
                                          flockRoot: root, sourceSha: nil)

            // The FILES carry the mdta tag with the rendered framing.
            func framingTag(aId: String) async throws -> String? {
                let out = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                         aGen: "248", aId: aId,
                                                         bGen: "248", bId: aId, ext: "mov")
                let all = try await AVURLAsset(url: out).load(.metadata)
                return all.first {
                    $0.keySpace == AVMetadataKeySpace(rawValue: "mdta")
                        && ($0.key as? String) == "emberweft.framing"
                }?.value as? String
            }
            let rowN = try await catalog.lookup(aGen: "248", aId: "00628",
                                                bGen: "248", bId: "00628", shard: shard.name)?.framing
            let rowF = try await catalog.lookup(aGen: "248", aId: "03194",
                                                bGen: "248", bId: "03194", shard: shard.name)?.framing
            return (try await framingTag(aId: "00628"), try await framingTag(aId: "03194"),
                    rowN, rowF)
        }
        let phase1 = try await renderAndRead()
        XCTAssertEqual(phase1.tagN, "1", "normalized loop file must tag 1")
        XCTAssertEqual(phase1.tagF, "0", "faithful loop file must tag 0")
        XCTAssertEqual(phase1.rowN, 1, "the live row must mirror the normalized tag")
        XCTAssertEqual(phase1.rowF, 0, "the live row must mirror the faithful tag")

        // Rebuild discards flock.sqlite and restores framing FROM THE TAG.
        try await FlockCatalog.rebuild(from: root)
        let fresh = try FlockCatalog(root: root)
        let rebuiltN = try await fresh.lookup(aGen: "248", aId: "00628",
                                              bGen: "248", bId: "00628", shard: shard.name)
        let rebuiltF = try await fresh.lookup(aGen: "248", aId: "03194",
                                              bGen: "248", bId: "03194", shard: shard.name)
        XCTAssertEqual(try XCTUnwrap(rebuiltN).framing, 1,
                       "rebuild must restore framing 1 from the emberweft.framing tag")
        XCTAssertEqual(try XCTUnwrap(rebuiltF).framing, 0,
                       "rebuild must restore framing 0 from the emberweft.framing tag")
    }

    /// Portrait twin of `testRenderLoopFramingTagRoundTripsThroughRebuild`
    /// (spec §8's mdta round-trip for gate 2): `renderLoop` at a PORTRAIT shard
    /// (width 32 / height 48 — constructed EXPLICITLY; `shardSpec(name:)`
    /// hardcodes 48×32 landscape, and a W<H name alone does not make a shard
    /// portrait) with framing `.normalized` + the landscape-authored sierpinski
    /// fixture ⇒ the file tags `emberweft.framing == "2"`, the live row records
    /// framing 2, and `FlockCatalog.rebuild(from:)` after discarding
    /// flock.sqlite restores framing 2 (a gate-2 row survives a rebuild — it
    /// can never silently decay into a 0/1 legacy HIT).
    ///
    /// Same scoping as the landscape twin: the render's `FlockCatalog` (an
    /// actor holding an open sqlite connection) is RELEASED before `rebuild`
    /// moves flock.sqlite.
    func testRenderLoopPortraitFramingGateTwoRoundTripsThroughRebuild() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shard = ShardSpec(name: "32x48_30fps", width: 32, height: 48, fps: 30,
                              loopSeconds: 0.4, transSeconds: 0.27,
                              loopFrames: 12, transFrames: 8,
                              isCanonical: false, codec: .h264)

        // Phase 1 (scoped): render a normalized rotated portrait loop; report
        // the FILE tag + the live row.
        func renderAndRead() async throws -> (tag: String?, row: Int?) {
            let catalog = try FlockCatalog(root: root)
            try await catalog.upsertShard(shard)
            var normalized = archiveSettings(matching: shard)
            normalized.framing = .normalized
            let A = try parseSierpinski()   // 320×200 landscape ⇒ gate 2 (rotated)
            let coord = ExportCoordinator(backend: .cpu)
            let renderer = ArchiveRenderer()
            try await renderer.renderLoop(A: A, aGen: "248", aId: "00628", shard: shard,
                                          settings: normalized, coordinator: coord, catalog: catalog,
                                          backend: .cpu, useOffMainMetal: false,
                                          flockRoot: root, sourceSha: nil)
            let out = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                     aGen: "248", aId: "00628",
                                                     bGen: "248", bId: "00628", ext: "mov")
            let all = try await AVURLAsset(url: out).load(.metadata)
            let tag = all.first {
                $0.keySpace == AVMetadataKeySpace(rawValue: "mdta")
                    && ($0.key as? String) == "emberweft.framing"
            }?.value as? String
            let row = try await catalog.lookup(aGen: "248", aId: "00628",
                                               bGen: "248", bId: "00628", shard: shard.name)?.framing
            return (tag, row)
        }
        let phase1 = try await renderAndRead()
        XCTAssertEqual(phase1.tag, "2", "a rotated portrait artifact must tag 2")
        XCTAssertEqual(phase1.row, 2, "the live row must mirror the gate-2 tag")

        // Rebuild discards flock.sqlite and restores framing FROM THE TAG.
        try await FlockCatalog.rebuild(from: root)
        let fresh = try FlockCatalog(root: root)
        let rebuilt = try await fresh.lookup(aGen: "248", aId: "00628",
                                             bGen: "248", bId: "00628", shard: shard.name)
        XCTAssertEqual(try XCTUnwrap(rebuilt).framing, 2,
                       "rebuild must restore framing 2 from the emberweft.framing tag")
    }

    /// Plan-level wiring pin: the CORE plan built by renderLoop from a
    /// normalized render carries the rescaled scale at frame 0 (blend 0 = pure A).
    /// This is the honest byte-level pin for the flock path — the .mov container
    /// is not byte-stable, but the PLAN's genome is deterministic.
    func testLoopCorePlanCarriesNormalizedScale() throws {
        let A = try parseSierpinski()
        let shard = shardSpec()
        let (nA, _) = ArchiveRenderer.unitFlames(A: A, B: nil, renderWidth: shard.width,
                                                 renderHeight: shard.height,
                                                 framing: .normalized)
        let plan = ArchiveRenderer.makeLoopCorePlan(A: nA, loopFrames: shard.loopFrames,
            transFrames: shard.transFrames, seed: 1, temporalSamples: 1)
        let g = plan.descriptor(for: ArchiveRenderer.SeamGeometry.coreRenderRange(loopFrames: shard.loopFrames).lowerBound).blendAt(0)
        XCTAssertEqual(g.camera.scale, 100.0 * Double(shard.width) / 320.0, accuracy: 1e-9,
                       "the plan must carry the normalized scale end-to-end")
    }
}
