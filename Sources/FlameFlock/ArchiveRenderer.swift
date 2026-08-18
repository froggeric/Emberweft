// Sources/FlameFlock/ArchiveRenderer.swift
import Foundation
import AVFoundation
import FlameKit
import FlameExport

/// Renders one flock archive unit — a loop OR an edge — into archive-named
/// `.mov`(s) + `.jpg` thumb + `[AVMetadataItem]` tags (Task 9, spec §14.2 / §4.1).
///
/// # Seam-aware artifact geometry (M6.5, geometry v2)
///
/// Archive units are rendered STANDALONE and concatenated file-wise, so the
/// centered-box temporal smoothing (GUI default ON, h=5) used to clip at every
/// artifact's frame range: each unit's first/last h frames got one-sided
/// windows, and — because the DE+display of an averaged histogram tracks the
/// BRIGHTEST window member (gamma compression) while edges pass through a much
/// brighter mid-morph state than either endpoint — the boundary frames on the
/// two sides of a file seam showed completely different brightness. Measured on
/// `00628/07385/14501` @ 720p spp 30 (the pre-fix stitch): edge→loop seams
/// jumped up to 80.8 MAD (35.6× the local baseline, Δluma −76), loop→edge up to
/// 64.6 MAD (17.7×, Δluma +61), loop→loop repeats 24.8 MAD (7.3×) — vs the
/// one-shot inline export of the SAME genomes/settings, whose cross-boundary
/// windows turn each boundary into a smooth ~8-frame ramp (≤3× baseline). With
/// smoothing OFF the same stitch was already seam-clean (0.96–1.2×) — the defect
/// is entirely the clipped windows, not the content (the sharp endpoint frames
/// match across the seam to 0.52 MAD).
///
/// The fix re-slices the timeline so every ENCODED frame's centered window lies
/// strictly inside its own unit's plan, and the boundary frames themselves are
/// owned by the unit whose plan contains BOTH sides:
///
/// - **loop = CORE + WRAP (two files, one row).** Core encodes phases
///   `[h, L−h)` of a 1-cycle plan (all windows interior). Wrap encodes
///   `[L−h, L+h)` of a **3-cycle** plan (`loopCycles: 3`, `framesPerSegment:
///   3L`) — the periodic-boundary frames `L−h…L−1, 0…h−1` as one contiguous
///   range, whose windows straddle the cycle wrap INSIDE the plan (a loop is
///   periodic, so this needs no cross-unit context).
/// - **edge = EXT (one file).** A **3-segment** plan `loop(A) + transition(A→B)
///   + loop(B)` encoding `[L−h, L+T+h)`: the transition plus h boundary frames
///   of EACH neighboring loop, whose windows straddle both boundaries. The
///   (A,B) pair fully determines the context (the stitch always orders
///   `edge(A→B)` between loopA and loopB), so this stays context-free.
///
/// A stitch assembles `[core, (wrap, core)×(r−1)] , ext, …` — every consecutive
/// frame pair across every seam has windows sharing `2h` of their `2h+1`
/// members (same as the inline path's intra-timeline frames), which is what
/// removes the jump. The timeline starts at phase h and (for multi-genome
/// sequences) ends at phase L−h: h frames at each end are simply not played
/// (imperceptible on ambient content; documented divergence from geometry v1).
///
/// `SeamGeometry.halfWidth` is FIXED (tier-independent) so artifacts of
/// different quality tiers tile interchangeably — the `geom` column is an exact
/// hit-gate (like `codec`), NOT a rank.
public struct ArchiveRenderer: Sendable {
    public init() {}

    /// The seam-aware artifact geometry (see the type comment). Pure math over
    /// the shard pace; no I/O.
    public enum SeamGeometry {
        /// Geometry version recorded in `ArtifactRow.geom` + the `emberweft.geom`
        /// tag. 1 = the pre-M6.5 monolithic loop/edge; 2 = core+wrap / ext.
        /// Bump ONLY with a timeline-layout change (stitches must not mix).
        public static let version = 2

        /// The seam half-width used to slice units. FIXED at the smoothing
        /// window's `centeredHalfWidth` (5) so the layout is tier-independent;
        /// a render's smoothing half-width must be ≤ this or its boundary
        /// windows would clip at the unit's internal seams (pinned by
        /// `testSeamHalfWidthMatchesSmoothingCap`).
        public static let seamHalfWidth = TemporalSmoothing.centeredHalfWidth

        /// Effective seam half-width for a shard: clamped so the CORE stays
        /// non-empty (`2h < L`). Shards with `L > 11` (every real shard; the
        /// canonical loop is 450 frames) get the full 5.
        public static func halfWidth(loopFrames L: Int) -> Int {
            min(seamHalfWidth, max(0, (L - 1) / 2))
        }

        /// Core encode range on the 1-cycle plan: phases `[h, L−h)`.
        public static func coreRenderRange(loopFrames L: Int) -> Range<Int> {
            let h = halfWidth(loopFrames: L)
            return h..<(L - h)
        }

        /// Wrap encode range on the 3-CYCLE plan (`framesPerSegment = 3L`,
        /// `loopCycles = 3`): frames `[2L−h, 2L+h)` — phases `L−h…L−1, 0…h−1`
        /// as one contiguous run whose ±h windows straddle the cycle wrap.
        public static func wrapRenderRange(loopFrames L: Int) -> Range<Int> {
            let h = halfWidth(loopFrames: L)
            return (2 * L - h)..<(2 * L + h)
        }

        /// Extended edge encode range on the 3-SEGMENT plan
        /// (`loop(A) + transition + loop(B)`): `[L−h, L+T+h)` — h boundary
        /// frames of loop A, the T transition frames, h boundary frames of B.
        public static func extRenderRange(loopFrames L: Int, transFrames T: Int) -> Range<Int> {
            let h = halfWidth(loopFrames: L)
            return (L - h)..<(L + T + h)
        }
    }

    // MARK: - FramePlan construction (§4.1, I9 + seam geometry v2)

    /// 1-segment CORE plan; segment 0 is `loop(A)` over `L` frames, 1 cycle.
    /// Render range: `SeamGeometry.coreRenderRange` (`[h, L−h)`).
    public static func makeLoopCorePlan(A: Flame, loopFrames: Int, transFrames: Int,
                                        seed: UInt64, temporalSamples: Int) -> FramePlan {
        var sched = Schedule(librarySize: 1, framesPerSegment: loopFrames,
                             transitionFramesPerSegment: transFrames,
                             selector: Sequential(seed: seed), seed: seed)
        return FramePlan(schedule: &sched, segmentCount: 1, flames: [A],
                         loopCycles: 1, temporalSamples: temporalSamples)
    }

    /// 1-segment WRAP plan over a **3-cycle** timeline: `framesPerSegment = 3L`,
    /// `loopCycles = 3` ⇒ frame k's rotation is `(k+1)·2π/L` (the SAME
    /// per-frame angular velocity as the core), and frames `[2L, 3L)` revisit
    /// the loop's phases `[0, L)` one cycle later — giving the wrap range
    /// `[2L−h, 2L+h)` fully-interior ±h windows that straddle the cycle wrap.
    public static func makeLoopWrapPlan(A: Flame, loopFrames: Int, transFrames: Int,
                                        seed: UInt64, temporalSamples: Int) -> FramePlan {
        var sched = Schedule(librarySize: 1, framesPerSegment: 3 * loopFrames,
                             transitionFramesPerSegment: transFrames,
                             selector: Sequential(seed: seed), seed: seed)
        return FramePlan(schedule: &sched, segmentCount: 1, flames: [A],
                         loopCycles: 3, temporalSamples: temporalSamples)
    }

    /// 3-segment EXT plan: segment 0 = `loop(A)`, segment 1 =
    /// `transition(A→B)`, segment 2 = `loop(B)`. Render range:
    /// `SeamGeometry.extRenderRange` (`[L−h, L+T+h)`). The edge-slot frames'
    /// descriptors are IDENTICAL to the historical 2-segment plan's (same
    /// schedule parameters, same blends) — the plan merely adds loop(B) so the
    /// transition's last frames' smoothing windows reach into real B content
    /// (the inline one-shot path's behavior).
    public static func makeEdgeExtPlan(A: Flame, B: Flame, loopFrames: Int, transFrames: Int,
                                       seed: UInt64, temporalSamples: Int) -> FramePlan {
        var sched = Schedule(librarySize: 2, framesPerSegment: loopFrames,
                             transitionFramesPerSegment: transFrames,
                             selector: Sequential(seed: seed), seed: seed)
        // flames[A, B]: segment 1 reads flames[0]=A, flames[1]=B (fromSheep=0, toSheep=1);
        // segment 2 (loop) reads flames[1]=B — exactly the genome the stitch
        // plays after this edge.
        return FramePlan(schedule: &sched, segmentCount: 3, flames: [A, B],
                         loopCycles: 1, temporalSamples: temporalSamples)
    }

    /// Historical geometry-v1 ranges (kept for the migration tests + docs).
    public static func loopRenderRange(loopFrames: Int) -> Range<Int> { 0..<loopFrames }
    public static func edgeRenderRange(loopFrames: Int, transFrames: Int) -> Range<Int> {
        loopFrames..<(loopFrames + transFrames)
    }

    // MARK: - Render one unit → archive file(s) + thumb + tags

    /// Render a loop unit (self-edge) as CORE + WRAP (seam geometry v2), then
    /// upsert ONE catalog row referencing both files. Atomic per file (temp →
    /// rename inside `renderSegmentRange`); the row is upserted LAST, after both
    /// files + the thumb exist — a failure anywhere before leaves no row.
    /// `perFrame` receives 1-indexed progress over the UNIT's `loopFrames`
    /// (core then wrap), not per-file totals.
    public func renderLoop(
        A: Flame, aGen: String, aId: String, shard: ShardSpec,
        settings: ExportSettings, coordinator: ExportCoordinator,
        catalog: FlockCatalog, backend: ExportCoordinator.Backend, useOffMainMetal: Bool,
        flockRoot: URL, sourceSha: String?,
        perFrame: (@Sendable (_ frame: Int, _ frameTotal: Int) -> Void)? = nil
    ) async throws {
        let seed = FlockSeed.seed(shard: shard.name, aGen: aGen, aId: aId, bGen: aGen, bId: aId)
        let out = try FlockNaming.archiveFileURL(flockRoot: flockRoot, shardDir: shard.name,
                                                 aGen: aGen, aId: aId, bGen: aGen, bId: aId, ext: "mov")
        let wrapOut = try FlockNaming.archiveFileURL(flockRoot: flockRoot, shardDir: shard.name,
                                                     aGen: aGen, aId: aId, bGen: aGen, bId: aId,
                                                     ext: "mov", variant: FlockNaming.wrapVariant)
        let (nA, _) = Self.unitFlames(A: A, B: nil, renderWidth: shard.width,
                                      framing: settings.framing)
        let params = Self.makeParams(A: nA, shard: shard, seed: seed, settings: settings)
        let corePlan = Self.makeLoopCorePlan(A: nA, loopFrames: shard.loopFrames,
                                             transFrames: shard.transFrames, seed: seed,
                                             temporalSamples: settings.temporalSamples)
        let coreRange = SeamGeometry.coreRenderRange(loopFrames: shard.loopFrames)
        let wrapPlan = Self.makeLoopWrapPlan(A: nA, loopFrames: shard.loopFrames,
                                             transFrames: shard.transFrames, seed: seed,
                                             temporalSamples: settings.temporalSamples)
        let wrapRange = SeamGeometry.wrapRenderRange(loopFrames: shard.loopFrames)
        // Unit-wide progress: core frames are 1…coreCount, wrap frames
        // coreCount+1…loopFrames of the SAME unit total (the UI reads one bar).
        let coreCount = coreRange.count
        let unitTotal = shard.loopFrames
        var corePerFrame: (@Sendable (Int, Int) -> Void)? = nil
        if let cb = perFrame {
            corePerFrame = { frame, _ in cb(frame, unitTotal) }
        }
        try await renderIntoArchive(plan: corePlan, params: params, range: coreRange, settings: settings,
            out: out, shard: shard, aGen: aGen, aId: aId, bGen: aGen, bId: aId,
            kind: .loop, backend: backend, useOffMainMetal: useOffMainMetal,
            coordinator: coordinator, catalog: catalog, sourceSha: sourceSha, flockRoot: flockRoot,
            seed: seed, A: nA, wrapOut: wrapOut, wrapPlan: wrapPlan, wrapRange: wrapRange,
            perFrame: corePerFrame)
    }

    /// Render an edge artifact (A→B) with the seam-aware EXT geometry: a
    /// 3-segment plan `loop(A) + transition + loop(B)`, encoding
    /// `[L−h, L+T+h)` — the transition plus h boundary frames of each neighbor
    /// loop, so the transition's boundary frames' smoothing windows straddle
    /// into real loop content exactly as the inline one-shot path's do.
    public func renderEdge(
        A: Flame, B: Flame, aGen: String, aId: String, bGen: String, bId: String, shard: ShardSpec,
        settings: ExportSettings, coordinator: ExportCoordinator,
        catalog: FlockCatalog, backend: ExportCoordinator.Backend, useOffMainMetal: Bool,
        flockRoot: URL, sourceSha: String?,
        perFrame: (@Sendable (_ frame: Int, _ frameTotal: Int) -> Void)? = nil
    ) async throws {
        let seed = FlockSeed.seed(shard: shard.name, aGen: aGen, aId: aId, bGen: bGen, bId: bId)
        let out = try FlockNaming.archiveFileURL(flockRoot: flockRoot, shardDir: shard.name,
                                                 aGen: aGen, aId: aId, bGen: bGen, bId: bId, ext: "mov")
        let (nA, nB) = Self.unitFlames(A: A, B: B, renderWidth: shard.width,
                                        framing: settings.framing)
        let params = Self.makeParams(A: nA, shard: shard, seed: seed, settings: settings)
        let plan = Self.makeEdgeExtPlan(A: nA, B: nB ?? nA, loopFrames: shard.loopFrames,
                                        transFrames: shard.transFrames, seed: seed,
                                        temporalSamples: settings.temporalSamples)
        let range = SeamGeometry.extRenderRange(loopFrames: shard.loopFrames,
                                                transFrames: shard.transFrames)
        try await renderIntoArchive(plan: plan, params: params, range: range, settings: settings,
            out: out, shard: shard, aGen: aGen, aId: aId, bGen: bGen, bId: bId,
            kind: .edge, backend: backend, useOffMainMetal: useOffMainMetal,
            coordinator: coordinator, catalog: catalog, sourceSha: sourceSha, flockRoot: flockRoot,
            seed: seed, A: nA, wrapOut: nil, wrapPlan: nil, wrapRange: nil, perFrame: perFrame)
    }

    /// Shared body: drive `renderSegmentRange` (temp→atomic-rename handled inside
    /// it), optionally the WRAP file, then the thumb, THEN upsert the catalog row
    /// (order matters — never a row without its files). Bypasses
    /// `ExportCheckpoint.sanitizedStem` (the archive path is its own root under
    /// `<flockRoot>/<shard>/mpeg/`).
    private func renderIntoArchive(
        plan: FramePlan, params: RenderParams, range: Range<Int>, settings: ExportSettings,
        out: URL, shard: ShardSpec, aGen: String, aId: String, bGen: String, bId: String,
        kind: ArtifactRow.Kind, backend: ExportCoordinator.Backend, useOffMainMetal: Bool,
        coordinator: ExportCoordinator, catalog: FlockCatalog, sourceSha: String?, flockRoot: URL,
        seed: UInt64, A: Flame,
        wrapOut: URL?, wrapPlan: FramePlan?, wrapRange: Range<Int>?,
        perFrame: (@Sendable (_ frame: Int, _ frameTotal: Int) -> Void)? = nil
    ) async throws {
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // spp is resolved ONCE from the quality tier + the base flame (there is no
        // settings.samplesPerPixel field). Threaded into tags + the row identically.
        // `[AVMetadataItem]` is not Sendable, so a FRESH array is built per
        // renderSegmentRange call (core + wrap) instead of reusing one across
        // actor hops.
        // The encoder (`VideoEncoder`) sizes its `PixelBufferPool` + the output
        // track from `settings.resolution`, while `makeParams` renders at the
        // SHARD's width/height — a caller leaving `resolution` at its default
        // (the GUI's `archiveSettings` used to) traps in `PixelBufferPool.fill`
        // for any shard ≠ 1080p (v0.6.0 crash). Force the two to agree here, at
        // the single choke point every flock caller (GUI Generate/Stitch, CLI)
        // funnels through.
        var aligned = settings
        aligned.resolution = .custom(width: shard.width, height: shard.height)
        let settings = aligned
        let (spp, _) = settings.quality.resolvedSamplesPerPixel(for: A)
        let stem = out.deletingPathExtension().lastPathComponent
        func makeMeta() -> [AVMetadataItem] {
            Self.makeMetadata(stem: stem, shard: shard, settings: settings, seed: seed,
                              sourceSha: sourceSha, spp: spp)
        }
        // renderSegmentRange writes a temp beside `out`, then atomic-renames to `out`.
        // If it throws (e.g. ProRes-in-mp4, cancel, disk-full) no file lands at
        // `out` and we rethrow BEFORE the thumb/upsert — the atomic invariant.
        try await coordinator.renderSegmentRange(
            plan: plan, params: params, budget: nil, useMetal: backend == .metal,
            range: range, smoothingAlpha: settings.smoothingAlpha, settings: settings,
            out: out, metadata: makeMeta(), perFrame: perFrame)
        // WRAP file (loops only): same params/seed, the 3-cycle wrap range. If it
        // throws, the core file exists but the row does not (still atomic).
        var wrapRel: String? = nil
        if let wrapOut, let wrapPlan, let wrapRange {
            let coreCount = range.count
            let unitTotal = shard.loopFrames
            var wrapPerFrame: (@Sendable (Int, Int) -> Void)? = nil
            if let cb = perFrame {
                wrapPerFrame = { frame, _ in cb(coreCount + frame, unitTotal) }
            }
            try await coordinator.renderSegmentRange(
                plan: wrapPlan, params: params, budget: nil, useMetal: backend == .metal,
                range: wrapRange, smoothingAlpha: settings.smoothingAlpha, settings: settings,
                out: wrapOut, metadata: makeMeta(), perFrame: wrapPerFrame)
            wrapRel = Self.archiveRelativePath(shard: shard.name, file: wrapOut.lastPathComponent)
        }
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
            wrapFile: wrapRel,
            geom: SeamGeometry.version,
            // M6.6 framing exact hit-gate: 0 = faithful, 1 = normalized — the
            // mode `unitFlames` actually applied for THIS render (same
            // `settings`), so the row records reality.
            framing: settings.framing == .normalized ? 1 : 0,
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

    /// M6.6 (D6, reconciled): the flock archive renders endpoints at their
    /// AUTHORED framing regardless of shard width, gated on settings.framing
    /// (the GUI has no toggle ⇒ GUI-driven runs are always normalized; the
    /// CLI's --framing faithful is the mastering-parity escape hatch). Pure
    /// step shared by renderLoop/renderEdge so loops and edges blend
    /// normalized values (the interpolator's log-space scale blend then
    /// operates on consistent endpoints). Framing is NOT identity (D8): same
    /// seed, same archive path — a framing change re-renders + overwrites in
    /// place.
    static func unitFlames(A: Flame, B: Flame?, renderWidth: Int,
                           framing: ExportSettings.FramingMode) -> (A: Flame, B: Flame?) {
        guard framing == .normalized else { return (A, B) }
        return (Framing.normalize(flame: A, renderWidth: renderWidth),
                B.map { Framing.normalize(flame: $0, renderWidth: renderWidth) })
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
        // Seam-geometry version (read back by `FlockCatalog.rebuild` into
        // `ArtifactRow.geom` — the exact hit-gate alongside `codec`).
        custom("emberweft.geom", String(SeamGeometry.version))
        // M6.6 framing exact hit-gate (read back by `FlockCatalog.rebuild` into
        // `ArtifactRow.framing`): 1 = normalized, 0 = faithful/legacy (a file
        // with no tag decodes 0 on rebuild, so legacy rows MISS a normalized
        // request — never silently reused).
        custom("emberweft.framing", settings.framing == .normalized ? "1" : "0")
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
