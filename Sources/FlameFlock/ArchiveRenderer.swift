// Sources/FlameFlock/ArchiveRenderer.swift
import Foundation
import AVFoundation
import FlameKit
import FlameExport

/// Renders one flock archive unit — a loop OR an edge — into an archive-named
/// `.mov` + `.jpg` thumb + `[AVMetadataItem]` tags (Task 9, spec §14.2 / §4.1).
///
/// The edge uses the **2-segment lone-edge `FramePlan`** (§4.1): segment 0 is
/// `loop(A)` (never rendered — Schedule requires a loop before a transition),
/// segment 1 is `transition(A→B)` (the only slot that is encoded). The render
/// range is therefore `loopFrames..<(loopFrames + transFrames)`.
///
/// Write order is **atomic** (never a catalog row without its file):
/// `renderSegmentRange` writes a temp beside `out`, atomic-renames to `out`,
/// THEN this type writes the thumb and upserts the catalog row LAST. So a
/// failure anywhere before the upsert leaves no row pointing at a missing file.
///
/// **spp source:** `ExportSettings` has no `samplesPerPixel` field; the resolved
/// spp + oversample come from `settings.quality.resolvedSamplesPerPixel(for:)`.
/// They are resolved once per unit and threaded into `RenderParams`, the mdta
/// tags, and the `ArtifactRow` (single source of truth).
public struct ArchiveRenderer: Sendable {
    public init() {}

    // MARK: - FramePlan construction (§4.1, I9)

    /// 1-segment loop plan; segment 0 is `loop(A)`. Render range: `0..<loopFrames`.
    public static func makeLoopPlan(A: Flame, loopFrames: Int, transFrames: Int, seed: UInt64) -> FramePlan {
        var sched = Schedule(librarySize: 1, framesPerSegment: loopFrames,
                             transitionFramesPerSegment: transFrames,
                             selector: Sequential(seed: seed), seed: seed)
        return FramePlan(schedule: &sched, segmentCount: 1, flames: [A],
                         loopCycles: 1, temporalSamples: A.quality.temporalSamples)
    }

    /// 2-segment edge plan; segment 0 = `loop(A)` (NOT rendered), segment 1 =
    /// `transition(A→B)`. Render range: `loopFrames..<(loopFrames + transFrames)`.
    /// The loop-slot frames are NEVER encoded/written — the 2-segment plan exists
    /// only because `Schedule` requires a loop before a transition (§4.1).
    public static func makeEdgePlan(A: Flame, B: Flame, loopFrames: Int, transFrames: Int, seed: UInt64) -> FramePlan {
        var sched = Schedule(librarySize: 2, framesPerSegment: loopFrames,
                             transitionFramesPerSegment: transFrames,
                             selector: Sequential(seed: seed), seed: seed)
        // flames[A, B]: segment 1 reads flames[0]=A, flames[1]=B (fromSheep=0, toSheep=1).
        return FramePlan(schedule: &sched, segmentCount: 2, flames: [A, B],
                         loopCycles: 1, temporalSamples: A.quality.temporalSamples)
    }

    public static func loopRenderRange(loopFrames: Int) -> Range<Int> { 0..<loopFrames }
    public static func edgeRenderRange(loopFrames: Int, transFrames: Int) -> Range<Int> {
        loopFrames..<(loopFrames + transFrames)
    }

    // MARK: - Render one unit → archive file + thumb + tags

    /// Render a loop artifact (self-edge) into `out` (`.mov`) + `.jpg` thumb, then
    /// upsert the catalog row. Atomic: temp → rename (inside `renderSegmentRange`)
    /// → thumb → upsert. `coordinator` is the ExportCoordinator whose
    /// `renderSegmentRange` we drive (single-sourced Metal/CPU dispatch).
    public func renderLoop(
        A: Flame, aGen: String, aId: String, shard: ShardSpec,
        settings: ExportSettings, coordinator: ExportCoordinator,
        catalog: FlockCatalog, backend: ExportCoordinator.Backend, useOffMainMetal: Bool,
        flockRoot: URL, sourceSha: String?
    ) async throws {
        let seed = FlockSeed.seed(shard: shard.name, aGen: aGen, aId: aId, bGen: aGen, bId: aId)
        let out = try FlockNaming.archiveFileURL(flockRoot: flockRoot, shardDir: shard.name,
                                                 aGen: aGen, aId: aId, bGen: aGen, bId: aId, ext: "mov")
        let params = Self.makeParams(A: A, shard: shard, seed: seed, settings: settings)
        let plan = Self.makeLoopPlan(A: A, loopFrames: shard.loopFrames,
                                     transFrames: shard.transFrames, seed: seed)
        let range = Self.loopRenderRange(loopFrames: shard.loopFrames)
        try await renderIntoArchive(plan: plan, params: params, range: range, settings: settings,
            out: out, shard: shard, aGen: aGen, aId: aId, bGen: aGen, bId: aId,
            kind: .loop, backend: backend, useOffMainMetal: useOffMainMetal,
            coordinator: coordinator, catalog: catalog, sourceSha: sourceSha, flockRoot: flockRoot,
            seed: seed, A: A)
    }

    /// Render an edge artifact (A→B). Same shape; 2-segment plan, transition range only.
    public func renderEdge(
        A: Flame, B: Flame, aGen: String, aId: String, bGen: String, bId: String, shard: ShardSpec,
        settings: ExportSettings, coordinator: ExportCoordinator,
        catalog: FlockCatalog, backend: ExportCoordinator.Backend, useOffMainMetal: Bool,
        flockRoot: URL, sourceSha: String?
    ) async throws {
        let seed = FlockSeed.seed(shard: shard.name, aGen: aGen, aId: aId, bGen: bGen, bId: bId)
        let out = try FlockNaming.archiveFileURL(flockRoot: flockRoot, shardDir: shard.name,
                                                 aGen: aGen, aId: aId, bGen: bGen, bId: bId, ext: "mov")
        let params = Self.makeParams(A: A, shard: shard, seed: seed, settings: settings)
        let plan = Self.makeEdgePlan(A: A, B: B, loopFrames: shard.loopFrames,
                                     transFrames: shard.transFrames, seed: seed)
        let range = Self.edgeRenderRange(loopFrames: shard.loopFrames, transFrames: shard.transFrames)
        try await renderIntoArchive(plan: plan, params: params, range: range, settings: settings,
            out: out, shard: shard, aGen: aGen, aId: aId, bGen: bGen, bId: bId,
            kind: .edge, backend: backend, useOffMainMetal: useOffMainMetal,
            coordinator: coordinator, catalog: catalog, sourceSha: sourceSha, flockRoot: flockRoot,
            seed: seed, A: A)
    }

    /// Shared body: drive `renderSegmentRange` (temp→atomic-rename handled inside
    /// it), write the thumb, THEN upsert the catalog row (order matters — never a
    /// row without its file). Bypasses `ExportCheckpoint.sanitizedStem` (the
    /// archive path is its own root under `<flockRoot>/<shard>/mpeg/`).
    private func renderIntoArchive(
        plan: FramePlan, params: RenderParams, range: Range<Int>, settings: ExportSettings,
        out: URL, shard: ShardSpec, aGen: String, aId: String, bGen: String, bId: String,
        kind: ArtifactRow.Kind, backend: ExportCoordinator.Backend, useOffMainMetal: Bool,
        coordinator: ExportCoordinator, catalog: FlockCatalog, sourceSha: String?, flockRoot: URL,
        seed: UInt64, A: Flame
    ) async throws {
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // spp is resolved ONCE from the quality tier + the base flame (there is no
        // settings.samplesPerPixel field). Threaded into tags + the row identically.
        let (spp, _) = settings.quality.resolvedSamplesPerPixel(for: A)
        let metadata = Self.makeMetadata(stem: out.deletingPathExtension().lastPathComponent,
                                         shard: shard, settings: settings, seed: seed,
                                         sourceSha: sourceSha, spp: spp)
        // renderSegmentRange writes a temp beside `out`, then atomic-renames to `out`.
        // If it throws (e.g. ProRes-in-mp4, cancel, disk-full) no file lands at
        // `out` and we rethrow BEFORE the thumb/upsert — the atomic invariant.
        try await coordinator.renderSegmentRange(
            plan: plan, params: params, budget: nil, useMetal: backend == .metal,
            range: range, smoothingAlpha: settings.smoothingAlpha, settings: settings,
            out: out, metadata: metadata)
        // Thumb (representative frame: frame 0 of the asset).
        try await Self.writeThumbnail(from: out,
                                      to: try FlockNaming.thumbURL(flockRoot: flockRoot, shardDir: shard.name,
                                                                   aGen: aGen, aId: aId, bGen: bGen, bId: bId))
        // Catalog upsert LAST (atomic invariant — file is already on disk).
        let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        let smoothingHw = TemporalSmoothing.halfWidth(forAlpha: settings.smoothingAlpha)
        let row = ArtifactRow(
            aGen: aGen, aId: aId, bGen: bGen, bId: bId, shard: shard.name, kind: kind,
            file: Self.archiveRelativePath(shard: shard.name, file: out.lastPathComponent),
            thumb: Self.thumbRelativePath(shard: shard.name, aGen: aGen, aId: aId, bGen: bGen, bId: bId),
            width: shard.width, height: shard.height, fps: shard.fps,
            loopFrames: shard.loopFrames, transFrames: shard.transFrames,
            spp: spp, temporal: settings.temporalSamples,
            smoothing: settings.smoothingAlpha < 1.0 ? "auto" : "off",
            smoothingHw: smoothingHw,
            qualityRank: Self.qualityRank(spp: spp, temporal: settings.temporalSamples, smoothingHw: smoothingHw),
            bytes: bytes, renderedAt: Int(Date().timeIntervalSince1970), sourceSha: sourceSha,
            // `seed` is a full-range UInt64 (SHA-256 truncation); `Int(seed)`
            // traps when the high bit is set (~50% of seeds). Lossless on 64-bit
            // (same width) + never traps + round-trips via UInt64(bitPattern:).
            // Stored as the SIGNED decimal so FlockCatalog.rebuild's
            // `Int(tags["emberweft.seed"])` parses it back identically.
            seed: Int(truncatingIfNeeded: seed), codec: settings.codec)
        try await catalog.upsertArtifact(row)
    }

    /// Build the `RenderParams` for one archive unit. spp + oversample are
    /// resolved from `settings.quality.resolvedSamplesPerPixel(for: A)` (the
    /// single source of truth — `ExportSettings` has no direct `samplesPerPixel`
    /// field). `spatialFilterRadius` threads the genome's `filter` attr so the
    /// grid-gutter width matches the inline export path.
    static func makeParams(A: Flame, shard: ShardSpec, seed: UInt64, settings: ExportSettings) -> RenderParams {
        let (spp, oversample) = settings.quality.resolvedSamplesPerPixel(for: A)
        return RenderParams(seed: seed, width: shard.width, height: shard.height,
                            oversample: oversample, samplesPerPixel: spp,
                            spatialFilterRadius: A.quality.filterRadius)
    }

    /// quality_rank = spp × temporal × √(2·smoothing_hw + 1) (D4 upgrade ordering).
    /// Pure scalar arithmetic (rule #2 — no float sum over a hashed collection).
    static func qualityRank(spp: Int, temporal: Int, smoothingHw: Int) -> Double {
        Double(spp) * Double(temporal) * Double(2 * smoothingHw + 1).squareRoot()
    }

    /// `emberweft.*` tags + a common-key title (§5.4). Read back by
    /// `FlockCatalog.rebuild` via the `mdta` keyspace filter.
    ///
    /// **mdta keyspace is load-bearing:** a custom-named keyspace (e.g. literal
    /// `"emberweft"`) is silently dropped by `AVAssetWriter` on `.mov` (T1
    /// finding). The namespace is encoded in the KEY (`emberweft.*`, mirroring
    /// Apple's `com.apple.quicktime.*` convention), and the keyspace is `mdta`.
    /// `spp` is passed in (resolved by the caller) because `ExportSettings` has
    /// no `samplesPerPixel` field.
    static func makeMetadata(stem: String, shard: ShardSpec, settings: ExportSettings,
                             seed: UInt64, sourceSha: String?, spp: Int) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func custom(_ key: String, _ value: String) {
            let m = AVMutableMetadataItem()
            m.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            m.key = key as NSString
            m.value = value as NSString
            items.append(m)
        }
        let title = AVMutableMetadataItem()
        // `AVMutableMetadataItem.commonKey` is get-only on the macOS 26 SDK; set
        // via the `.common` keyspace + `commonKeyTitle.rawValue` (AVFoundation
        // resolves `commonKey` from that pair).
        title.keySpace = .common
        title.key = AVMetadataKey.commonKeyTitle.rawValue as NSString
        title.value = stem as NSString
        title.extendedLanguageTag = "und"
        items.append(title)
        let smoothingHw = TemporalSmoothing.halfWidth(forAlpha: settings.smoothingAlpha)
        custom("emberweft.spp", String(spp))
        custom("emberweft.ts", String(settings.temporalSamples))
        custom("emberweft.smoothing", settings.smoothingAlpha < 1.0 ? "auto" : "off")
        custom("emberweft.smoothing_hw", String(smoothingHw))
        custom("emberweft.quality_rank",
               String(qualityRank(spp: spp, temporal: settings.temporalSamples, smoothingHw: smoothingHw)))
        custom("emberweft.source_sha", sourceSha ?? "")
        // Signed decimal of the bit-pattern (see ArtifactRow.seed) — rebuild parses
        // this via `Int(tag)`, so the tag and the row must agree.
        custom("emberweft.seed", String(Int(truncatingIfNeeded: seed)))
        custom("emberweft.rendered", ISO8601DateFormatter().string(from: Date()))
        custom("emberweft.shard", shard.name)
        return items
    }

    /// Extract frame 0 of `src` as a `.jpg` at `dst`. `AVAssetImageGenerator`
    /// handles the codec decode (HEVC/H.264/ProRes); `public.jpeg` via
    /// `CGImageDestination` writes a baseline JPEG.
    static func writeThumbnail(from src: URL, to dst: URL) async throws {
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let asset = AVURLAsset(url: src)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let cg = try gen.copyCGImage(at: .zero, actualTime: nil)
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Relative archive path under the flock root: `<shard>/mpeg/<file>`.
    static func archiveRelativePath(shard: String, file: String) -> String {
        "\(shard)/mpeg/\(file)"
    }
    /// Relative thumb path under the flock root: `<shard>/jpeg/<stem>.jpg`.
    static func thumbRelativePath(shard: String, aGen: String, aId: String,
                                  bGen: String, bId: String) -> String {
        "\(shard)/jpeg/\(FlockNaming.fileName(aGen: aGen, aId: aId, bGen: bGen, bId: bId, ext: "jpg"))"
    }
}
