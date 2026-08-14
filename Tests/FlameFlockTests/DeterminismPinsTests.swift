// Tests/FlameFlockTests/DeterminismPinsTests.swift
import XCTest
import CryptoKit
@testable import FlameFlock
@testable import FlameExport   // appendedFrameCount test seam (internal)
import FlameKit

/// Task 12 — the three rule-#2 / byte-stability / no-regeneration pins from spec
/// §10/§17. These PIN T9–T11: a failing pin is a determinism bug in T9–T11, not a
/// problem with the pin (do not weaken it — report the bug).
///
/// Harness mirrors `ArchiveRendererTests` / `StitchCoordinatorTests`: the frozen
/// `sierpinski.flam3` fixture at 48×32, spp 4, ts 1, smoothing OFF (α=1.0 ⇒ the
/// byte-sharp mastering path), CPU backend. Small frame counts keep each render
/// to a handful of CPU frames.
final class DeterminismPinsTests: XCTestCase {

    // MARK: - helpers

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
    private func makeRoot(_ tag: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flock-det-\(tag)-\(UUID().uuidString)")
    }

    /// Fast render profile: a few frames at 48×32 spp 4.
    private func shardSpec(name: String = "48x32_30fps") -> ShardSpec {
        ShardSpec(name: name, width: 48, height: 32, fps: 30,
                  loopSeconds: 0.1, transSeconds: 0.07,
                  loopFrames: 3, transFrames: 2,
                  isCanonical: false, codec: .h264)
    }

    /// OFF smoothing (α=1.0 ⇒ hw=0) so the mastering path is byte-sharp and the
    /// archive edge is byte-comparable to a one-shot. Container is `.mov` (the
    /// real archive format — custom `mdta` tags persist to `.mov`).
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

    /// SHA-256 of a file's bytes (CryptoKit, no shell-out). `SHA256.Digest` is
    /// `Equatable`, so two files compare equal iff their bytes are identical.
    private func sha256(of url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url))
    }

    /// Count archive `.mov` files materialized under `<root>/<shard>/mpeg/` whose
    /// stem matches the (aGen,aId,bGen,bId) key. The deterministic path means at
    /// most one file can exist for a key — a count > 1 would indicate
    /// regeneration under a different name; a count of 0 means missing.
    private func archiveFileCount(root: URL, shard: String,
                                  aGen: String, aId: String,
                                  bGen: String, bId: String) throws -> Int {
        let dir = root.appendingPathComponent(shard).appendingPathComponent("mpeg")
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        let stem = "\(aGen)=\(aId)=\(bGen)=\(bId)"
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { name in
                // stem is the file name minus the trailing ".mov"; exact-match
                // the key so a sibling edge/loop key doesn't double-count.
                (name as NSString).deletingPathExtension == stem
            }
            .count
    }

    /// Drain a generate stream to completion (terminal `.completed` / `.failed` /
    /// `.cancelled` finishes without throwing).
    private func drain(_ stream: AsyncThrowingStream<GenerateUIProgress, Error>) async throws -> [GenerateUIProgress] {
        var out: [GenerateUIProgress] = []
        for try await e in stream { out.append(e) }
        return out
    }
    /// Drain a stitch stream to completion.
    private func drain(_ stream: AsyncThrowingStream<StitchUIProgress, Error>) async throws -> [StitchUIProgress] {
        var out: [StitchUIProgress] = []
        for try await p in stream { out.append(p) }
        return out
    }

    // MARK: - Pin 1: EdgePairNoRegeneration (T10 — GenerateCoordinator hit-skip)

    /// Render the same edge pair `(A→B)` twice through `GenerateCoordinator`
    /// (same flockRoot). The second run MUST be a HIT (quality_rank meets the
    /// request) ⇒ it skips the unit entirely:
    ///   • the run reports `completed(rendered: 0, skipped: 1)` — nothing re-rendered;
    ///   • exactly ONE archive file exists on disk for the key (not regenerated,
    ///     not overwritten — the file's bytes are unchanged across both runs);
    ///   • the catalog holds exactly one row for the key (the PK is the DB primary
    ///     key; `lookup` returning the same row both times == one row).
    ///
    /// Robust because it asserts file COUNT + UNCHANGED bytes + run progress,
    /// not byte-equality against a frozen golden.
    func testEdgePairNoRegeneration() async throws {
        let root = makeRoot("edge-noregen")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let A = try parseSierpinski()
        let unit = GenerateUnit(aGen: "248", aId: "00628", bGen: "248", bId: "03194",
                                A: A, B: A)   // edge (distinct bId)

        // --- Run 1: MISS ⇒ render the edge into the archive. ---
        let coord1 = ExportCoordinator(backend: .cpu)
        let gen1 = GenerateCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                       backend: .cpu, useOffMainMetal: false)
        let req = GenerateRequest(shard: shard, units: [unit],
                                  scope: .edges, settings: settings, flockRoot: root)
        let events1 = try await drain(gen1.generate(req, coordinator: coord1))
        guard case let .completed(rendered1, skipped1) = try XCTUnwrap(events1.last) else {
            XCTFail("run 1 must terminate .completed, got \(String(describing: events1.last))"); return
        }
        XCTAssertEqual(rendered1, 1, "run 1 (empty archive) must render the edge")
        XCTAssertEqual(skipped1, 0)

        // Exactly one archive file + one row exist for the key after run 1.
        let edgeFile = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: shard.name,
                                                      aGen: "248", aId: "00628",
                                                      bGen: "248", bId: "03194", ext: "mov")
        XCTAssertEqual(try archiveFileCount(root: root, shard: shard.name,
                                            aGen: "248", aId: "00628",
                                            bGen: "248", bId: "03194"), 1,
                       "run 1 must materialize exactly one archive file for the key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: edgeFile.path))
        let row1 = try await catalog.lookup(aGen: "248", aId: "00628",
                                            bGen: "248", bId: "03194", shard: shard.name)
        XCTAssertNotNil(row1, "run 1 must create the catalog row")
        // Capture the file's bytes after run 1 — run 2 must NOT change them.
        let shaAfterRun1 = try sha256(of: edgeFile)

        // --- Run 2: same flockRoot, same unit ⇒ HIT (quality_rank ≥ request). ---
        let coord2 = ExportCoordinator(backend: .cpu)
        let gen2 = GenerateCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                       backend: .cpu, useOffMainMetal: false)
        let events2 = try await drain(gen2.generate(req, coordinator: coord2))
        guard case let .completed(rendered2, skipped2) = try XCTUnwrap(events2.last) else {
            XCTFail("run 2 must terminate .completed, got \(String(describing: events2.last))"); return
        }
        XCTAssertEqual(rendered2, 0, "run 2 MUST be all-skip (HIT ⇒ no re-render)")
        XCTAssertEqual(skipped2, 1)

        // Still exactly one archive file (not regenerated, not duplicated).
        XCTAssertEqual(try archiveFileCount(root: root, shard: shard.name,
                                            aGen: "248", aId: "00628",
                                            bGen: "248", bId: "03194"), 1,
                       "run 2 (HIT) must not add or regenerate the archive file")
        // File bytes UNCHANGED across the two runs ⇒ it was not re-rendered.
        let shaAfterRun2 = try sha256(of: edgeFile)
        XCTAssertEqual(shaAfterRun2, shaAfterRun1,
                       "HIT-skip must not overwrite the archive file (bytes unchanged)")
        // The catalog still holds the single row from run 1 (same seed + rank).
        let row2 = try await catalog.lookup(aGen: "248", aId: "00628",
                                            bGen: "248", bId: "03194", shard: shard.name)
        let r2 = try XCTUnwrap(row2, "the row must persist after the HIT-skip run")
        XCTAssertEqual(r2.seed, try XCTUnwrap(row1).seed)
        XCTAssertEqual(r2.qualityRank, try XCTUnwrap(row1).qualityRank, accuracy: 1e-9)
    }

    // MARK: - Pin 2: StitchByteStability (T11 — StitchCoordinator passthrough concat)

    /// Stitch the same sequence+shard twice (into two different `out` paths, same
    /// flockRoot). The first stitch MISS-renders every segment into the archive
    /// then passthrough-concats them; the second stitch HITs every archive file
    /// (now on disk) and concats the SAME files. Because concat is passthrough
    /// (same-codec ⇒ no re-encode) and the source files are identical, the two
    /// `out` files MUST be byte-identical.
    ///
    /// Robust per the task hint: the second stitch HITs the cache and concats the
    /// SAME files — no re-encode, no re-render.
    func testStitchByteStability() async throws {
        let root = makeRoot("stitch-bytes")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try FlockCatalog(root: root)
        let shard = shardSpec()
        try await catalog.upsertShard(shard)
        let settings = archiveSettings(matching: shard)
        let A = try parseSierpinski(), B = A

        // Stitch 1 — MISS-renders loop A, edge A→B, loop B into the archive, then
        // passthrough-concats them into out1.
        let out1 = root.appendingPathComponent("stitch-1.mov")
        let coord = ExportCoordinator(backend: .cpu)
        let stitcher = StitchCoordinator(catalog: catalog, renderer: ArchiveRenderer(),
                                         backend: .cpu, useOffMainMetal: false)
        let request1 = StitchRequest(
            shard: shard,
            orderedFlames: [("248", "00001", A), ("248", "00002", B)],
            settings: settings, flockRoot: root, out: out1)
        let progress1 = try await drain(stitcher.stitch(request1, coordinator: coord))
        XCTAssertEqual(progress1.last, .completed(out: out1),
                       "stitch 1 must complete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out1.path))

        // Stitch 2 — same sequence + shard, different `out`. Every segment is now
        // a HIT (the archive holds them from stitch 1), so no frame is re-rendered
        // and concat stitches the SAME files.
        let out2 = root.appendingPathComponent("stitch-2.mov")
        let progress2 = try await drain(stitcher.stitch(
            StitchRequest(shard: shard,
                          orderedFlames: [("248", "00001", A), ("248", "00002", B)],
                          settings: settings, flockRoot: root, out: out2),
            coordinator: coord))
        XCTAssertEqual(progress2.last, .completed(out: out2),
                       "stitch 2 must complete (all-HIT fast path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out2.path))

        // The two outputs are byte-identical (equal shasum / contentsEqual) —
        // passthrough concat of the same archive files is a pure file operation.
        XCTAssertEqual(try sha256(of: out1), try sha256(of: out2),
                       "two stitches of the same sequence+shard must be byte-identical")
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: out1.path, andPath: out2.path),
                      "contentsEqual must agree with the shasum pin")
    }

    // MARK: - Pin 3: ArtifactDeterminism (T9 — ArchiveRenderer)

    /// Render the SAME artifact into TWO FRESH temp roots (no shared cache) and
    /// compare.
    ///
    /// **Pinned level: deterministic INPUT (not encoded bytes).** The spec AC is
    /// `shasum` of the two `.mov` files equal, but the `.mov` container is NOT
    /// byte-stable run-to-run on a single machine for two independent reasons:
    ///   (1) `ArchiveRenderer.makeMetadata` embeds a wall-clock timestamp tag
    ///       `emberweft.rendered = ISO8601DateFormatter().string(from: Date())`
    ///       (ArchiveRenderer.swift:213) that differs per render — flaky at the
    ///       one-second boundary even on the same machine;
    ///   (2) CLAUDE.md documents that VideoToolbox `.mov` bytes are not guaranteed
    ///       byte-stable across machines/OSes ("encoded .mp4 bytes are not
    ///       byte-stable across machines/OSes; frame pixels are deterministic").
    /// Per the task's explicit fallback, this does NOT pin the (flaky, non-robust)
    /// container bytes; it pins the load-bearing deterministic CHAIN that
    /// determines the frame pixels:
    ///   same (shard,key) ⇒ identical `FlockSeed.seed(...)` (pure SHA-256 ⇒ UInt64)
    ///                    ⇒ identical `RenderParams.seed` (via `makeParams`)
    ///                    ⇒ identical frames (the archive reuses the deterministic
    ///                       `renderFrames` primitive; CPU backend, ts=1, smoothing
    ///                       OFF ⇒ byte-sharp mastering path).
    ///
    /// The `.mov` encode is the mastering layer (provenance tags + VideoToolbox);
    /// its bytes are intentionally not pinned here. See the report-back for the
    /// `emberweft.rendered` timestamp finding in T9.
    func testArtifactDeterminism() async throws {
        let shard = shardSpec()
        let settings = archiveSettings(matching: shard)
        let A = try parseSierpinski()
        let aGen = "248", aId = "00628", bGen = "248", bId = "00628"   // a loop artifact

        // (a) `FlockSeed.seed(...)` is a pure function: same (shard,key) ⇒ same
        //     UInt64, call after call. This is the root of the determinism chain.
        let seedCall1 = FlockSeed.seed(shard: shard.name, aGen: aGen, aId: aId,
                                       bGen: bGen, bId: bId)
        let seedCall2 = FlockSeed.seed(shard: shard.name, aGen: aGen, aId: aId,
                                       bGen: bGen, bId: bId)
        XCTAssertEqual(seedCall1, seedCall2,
                       "FlockSeed.seed must be pure (same key ⇒ identical UInt64)")

        // (b) Two independent `ArchiveRenderer.makeParams(...)` calls — one per
        //     fresh render root — construct identical `RenderParams.seed`, width,
        //     height, spp, and oversample. This is the bridge from the seed to the
        //     deterministic `renderFrames` primitive the archive shares with export.
        let paramsA = ArchiveRenderer.makeParams(A: A, shard: shard, seed: seedCall1, settings: settings)
        let paramsB = ArchiveRenderer.makeParams(A: A, shard: shard, seed: seedCall2, settings: settings)
        XCTAssertEqual(paramsA.seed, paramsB.seed, "both renders thread the identical seed into RenderParams")
        XCTAssertEqual(paramsA.seed, seedCall1, "RenderParams.seed equals the canonical FlockSeed")
        XCTAssertEqual(paramsA.width, paramsB.width)
        XCTAssertEqual(paramsA.height, paramsB.height)
        XCTAssertEqual(paramsA.samplesPerPixel, paramsB.samplesPerPixel)
        XCTAssertEqual(paramsA.oversample, paramsB.oversample)
        XCTAssertEqual(paramsA.spatialFilterRadius, paramsB.spatialFilterRadius)

        // (c) Empirically render the same artifact into two FRESH temp roots (no
        //     shared cache, independent coordinators) and assert the FRAME-DETERMINING
        //     invariants hold: both artifacts materialize at the deterministic
        //     archive path, both catalog rows carry the identical canonical seed,
        //     and both files are non-empty valid `.mov` outputs. (The `.mov` BYTES
        //     are not asserted equal — see the method doc for why; the row seed is
        //     the deterministic-input pin.)
        let root1 = makeRoot("artifact-1"), root2 = makeRoot("artifact-2")
        defer { try? FileManager.default.removeItem(at: root1); try? FileManager.default.removeItem(at: root2) }
        let cat1 = try FlockCatalog(root: root1), cat2 = try FlockCatalog(root: root2)
        try await cat1.upsertShard(shard); try await cat2.upsertShard(shard)
        let renderer = ArchiveRenderer()
        let coord1 = ExportCoordinator(backend: .cpu), coord2 = ExportCoordinator(backend: .cpu)
        try await renderer.renderLoop(A: A, aGen: aGen, aId: aId, shard: shard,
                                      settings: settings, coordinator: coord1, catalog: cat1,
                                      backend: .cpu, useOffMainMetal: false,
                                      flockRoot: root1, sourceSha: nil)
        try await renderer.renderLoop(A: A, aGen: aGen, aId: aId, shard: shard,
                                      settings: settings, coordinator: coord2, catalog: cat2,
                                      backend: .cpu, useOffMainMetal: false,
                                      flockRoot: root2, sourceSha: nil)

        let out1 = try FlockNaming.archiveFileURL(flockRoot: root1, shardDir: shard.name,
                                                  aGen: aGen, aId: aId, bGen: bGen, bId: bId, ext: "mov")
        let out2 = try FlockNaming.archiveFileURL(flockRoot: root2, shardDir: shard.name,
                                                  aGen: aGen, aId: aId, bGen: bGen, bId: bId, ext: "mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out2.path))
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: out1.path)[.size] as? Int ?? 0, 0)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: out2.path)[.size] as? Int ?? 0, 0)

        // Seam geometry v2: a loop unit is CORE + WRAP — both files materialize
        // at the deterministic paths in BOTH roots, and both rows record the
        // identical wrapFile relative path.
        let wrap1 = try FlockNaming.archiveFileURL(flockRoot: root1, shardDir: shard.name,
                                                   aGen: aGen, aId: aId, bGen: bGen, bId: bId,
                                                   ext: "mov", variant: FlockNaming.wrapVariant)
        let wrap2 = try FlockNaming.archiveFileURL(flockRoot: root2, shardDir: shard.name,
                                                   aGen: aGen, aId: aId, bGen: bGen, bId: bId,
                                                   ext: "mov", variant: FlockNaming.wrapVariant)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrap1.path), "wrap file must exist (root 1)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrap2.path), "wrap file must exist (root 2)")

        // Both catalog rows carry the identical canonical seed (the deterministic
        // input that drives `renderFrames`); same spp/temporal/qualityRank.
        // (`XCTUnwrap`'s autoclosure can't `await`, so resolve the actor calls
        // into temporaries first, then unwrap.)
        let r1Opt = try await cat1.lookup(aGen: aGen, aId: aId, bGen: bGen, bId: bId, shard: shard.name)
        let r2Opt = try await cat2.lookup(aGen: aGen, aId: aId, bGen: bGen, bId: bId, shard: shard.name)
        let row1 = try XCTUnwrap(r1Opt), row2 = try XCTUnwrap(r2Opt)
        XCTAssertEqual(row1.seed, row2.seed, "both renders' rows carry the identical canonical seed")
        XCTAssertEqual(row1.seed, Int(truncatingIfNeeded: seedCall1))
        XCTAssertEqual(row1.spp, row2.spp)
        XCTAssertEqual(row1.temporal, row2.temporal)
        XCTAssertEqual(row1.qualityRank, row2.qualityRank, accuracy: 1e-9)
        XCTAssertEqual(row1.wrapFile, row2.wrapFile, "both rows record the identical wrap path")
        XCTAssertEqual(row1.geom, row2.geom)
        XCTAssertEqual(row1.geom, ArchiveRenderer.SeamGeometry.version)

        // As an attempted empirical check (the spec AC): compare the encoded
        // bytes. On the same machine this MAY pass when both renders land in the
        // same wall-clock second (identical `emberweft.rendered` tag) AND
        // VideoToolbox is run-to-run deterministic. It is NOT load-bearing here
        // — recorded only as a diagnostic (an unconditional XCTAssert would make
        // the pin flaky at the second boundary, which is why the input level is
        // the pin). Documented in the report-back.
        let sha1 = try sha256(of: out1), sha2 = try sha256(of: out2)
        print("[testArtifactDeterminism] .mov shasum match (diagnostic, non-load-bearing): \(sha1 == sha2)")
    }
}
