// Sources/FlameFlock/StitchCoordinator.swift
import Foundation
import FlameKit
import FlameExport

/// Task 11 — the Path B actor: assemble a long-form video from the flock archive.
/// ONE batched catalog lookup up front resolves every segment's HIT/MISS state
/// (no N+1 `lookup` loop); each MISS is rendered into the archive first
/// (Path-A-style via `ArchiveRenderer`), then every segment file is collected and
/// passthrough-concatenated via `ExportCoordinator.concat` (same-codec ⇒ no
/// re-encode). Cross-shard and codec-mismatched archives are refused.
///
/// Segment model (spec §4.2): for `orderedFlames = [F0, F1, …]` the assembled
/// timeline alternates loop/edge — `loop(F0), edge(F0→F1), loop(F1), edge(F1→F2),
/// …, loop(Fn)` — i.e. one loop per flame plus one edge per adjacent pair. A loop
/// is a self-edge (a==b); both share the composite PK `(a_gen,a_id,b_gen,b_id,
/// shard)` which is the artifacts cache key (D2).
///
/// **Loop repetitions** (`StitchRequest.loopRepetitions`, default 2): each loop
/// SLOT is repeated `r` times in the timeline (`loopA, loopA, edgeAB, loopB,
/// loopB, …`) — the same canonical archive FILE is listed `r` times in the
/// concat input. NOT the removed v0.5.7 frame-repeat (which duplicated frames
/// into half-speed motion): the artifact stays one full-framerate cycle, the
/// archive gains no files, and nothing is re-rendered per repetition. Edges are
/// never repeated. HIT/MISS (D4, `quality_rank`) applies per UNIQUE key, so an
/// upgrade re-renders a loop ONCE no matter how many repetitions reference it.
///
/// Determinism (rule #2): the single `batchLookup` is parameterized SQL (one
/// round trip); the per-segment match is an O(1) `Dictionary<String, ArtifactRow>`
/// keyed by the canonical PK string (a lookup map, NOT a float sum over a hashed
/// collection — built once from the batch result). Counts are scalar arithmetic.
public struct StitchRequest: Sendable {
    public let shard: ShardSpec
    /// Alternating source ids per segment endpoint, in playback order. The
    /// coordinator derives `loop(Fi)` + `edge(Fi→Fi+1)` from this list.
    public let orderedFlames: [(gen: String, id: String, flame: Flame)]
    public let settings: ExportSettings
    public let flockRoot: URL
    public let out: URL
    /// **Loop repetitions (stitch-TIME, default 2)** — how many times each LOOP
    /// slot references its one canonical archive artifact in the assembled
    /// timeline. This is NOT the removed v0.5.7 frame-repeat: the archive keeps
    /// exactly ONE loop artifact per (pair, shard) (one rotation cycle at the
    /// shard's canonical pace — `ArchiveRenderer.makeLoopPlan` stays
    /// `loopCycles: 1`), and the stitch timeline simply lists the SAME file N
    /// times in the concat input (`[loopA, loopA, edgeAB, loopB, loopB, …]`).
    /// Full framerate, zero re-render, seamless because a loop's last frame
    /// equals its first (`R(2π) = R(0°)`); duplicate-file passthrough concat is
    /// decode-clean (the codec-gate test concats `loopB` twice). EDGE slots are
    /// never repeated (a transition plays once). Clamped to ≥ 1 in
    /// `buildSegmentKeys`.
    public let loopRepetitions: Int
    public init(shard: ShardSpec,
                orderedFlames: [(gen: String, id: String, flame: Flame)],
                settings: ExportSettings, flockRoot: URL, out: URL,
                loopRepetitions: Int = 2) {
        self.shard = shard; self.orderedFlames = orderedFlames
        self.settings = settings; self.flockRoot = flockRoot; self.out = out
        self.loopRepetitions = loopRepetitions
    }
}

public enum StitchUIProgress: Sendable, Equatable {
    case resolving
    /// The HIT/MISS plan after the single batched lookup. `hitCount`/`missCount`
    /// count UNIQUE segment keys (the actual archive work — a repeated loop that
    /// must be generated is ONE will-gen, not `loopRepetitions`), while
    /// `segmentCount` is the TIMELINE slot total (duplicates included — the
    /// denominator for the running/rendering progress bars). With
    /// `loopRepetitions == 1` (or no loops repeated) the two are equal.
    case plan(hitCount: Int, missCount: Int, segmentCount: Int)
    case running(hit: Int, generated: Int)
    /// Per-frame progress DURING a MISS render (the v0.5.9 blackout fix — mirrors
    /// `GenerateUIProgress.rendering`). `segment` is the 1-indexed position of
    /// the segment among ALL segments (HIT + MISS), `total` the full segment
    /// count, `isLoop` labels loop vs edge, `frame`/`frameTotal` the within-unit
    /// encode progress (`frame` 1-indexed; `frame == 0` is a pre-render yield so
    /// the UI moves the instant the render starts instead of one frame-time
    /// later). Without this, a MISS render emitted ZERO events for its whole
    /// duration (the "4 HIT, 1 will-gen, then nothing while the GPU churns"
    /// owner symptom).
    case rendering(segment: Int, total: Int, isLoop: Bool, frame: Int, frameTotal: Int)
    /// The remux/copy tail phase (passthrough concat takes seconds; the UI used
    /// to show nothing between the last segment and `.completed`).
    /// `segments` is the file count being joined (1 ⇒ single-file copy).
    case concatenating(segments: Int)
    case completed(out: URL)
    case failed(String)
    case cancelled
}

/// Read-only catalog surface used by `StitchCoordinator`. Abstracted as a protocol
/// (single seam) so the **exactly-one `batchLookup`** AC can be pinned by a
/// counting double in tests; `FlockCatalog` conforms via the extension below.
/// Production passes a real `FlockCatalog`; the MISS render path downcasts it back
/// to the concrete actor that `ArchiveRenderer` upserts into.
public protocol FlockCatalogStitching: Sendable {
    func batchLookup(_ keys: [(aGen: String, aId: String, bGen: String,
                               bId: String, shard: String)]) async throws -> [ArtifactRow]
    func lookup(aGen: String, aId: String, bGen: String, bId: String,
                shard: String) async throws -> ArtifactRow?
}
extension FlockCatalog: FlockCatalogStitching {}

public actor StitchCoordinator {
    private let catalog: any FlockCatalogStitching
    private let renderer: ArchiveRenderer
    private let backend: ExportCoordinator.Backend
    private let useOffMainMetal: Bool
    private var cancelled = false

    public init(catalog: any FlockCatalogStitching, renderer: ArchiveRenderer,
                backend: ExportCoordinator.Backend, useOffMainMetal: Bool) {
        self.catalog = catalog; self.renderer = renderer
        self.backend = backend; self.useOffMainMetal = useOffMainMetal
    }

    public func cancel() async { cancelled = true }

    public func stitch(_ request: StitchRequest,
                       coordinator: ExportCoordinator) -> AsyncThrowingStream<StitchUIProgress, Error> {
        AsyncThrowingStream { continuation in
            // Unstructured Task captures `self` (the Sendable actor) + the Sendable
            // continuation; `await self.stitchBody(...)` runs the whole flow on the
            // actor so `cancelled` reads are direct isolated reads.
            Task { [self] in
                await self.stitchBody(request, coordinator: coordinator, continuation: continuation)
            }
        }
    }

    // MARK: - Body (actor-isolated)

    private func stitchBody(
        _ request: StitchRequest,
        coordinator: ExportCoordinator,
        continuation: AsyncThrowingStream<StitchUIProgress, Error>.Continuation
    ) async {
        if request.orderedFlames.isEmpty {
            continuation.yield(.failed("Sequence is empty.")); continuation.finish(); return
        }
        continuation.yield(.resolving)

        // 1. Build the alternating loop/edge key list: loop(F0), edge(F0→F1), …
        let keys = buildSegmentKeys(request)

        // 2. ONE batched catalog lookup (the N+1 gate — no per-segment `lookup`
        //    before the render decision).
        let existing: [ArtifactRow]
        do {
            existing = try await catalog.batchLookup(keys)
        } catch {
            continuation.yield(.failed(String(describing: error))); continuation.finish(); return
        }

        // 3. Codec-uniformity gate (D12): every stored row must match the shard's
        //    codec, else the archive is internally inconsistent.
        if existing.contains(where: { $0.codec != request.shard.codec }) {
            continuation.yield(.failed("Archive shard has mixed codecs. Run 'flock rebuild'."))
            continuation.finish(); return
        }
        // 4. Cross-shard gate: the request carries ONE shard; every stored row
        //    must reference it. `batchLookup` keys are scoped to
        //    `request.shard.name`, so a stray-shard row implies catalog corruption.
        if existing.contains(where: { $0.shard != request.shard.name }) {
            continuation.yield(.failed("Stitch requires a single shard."))
            continuation.finish(); return
        }

        // 5. O(1) per-segment match: ONE Dictionary keyed by the canonical PK
        //    string, built from the single batchLookup result (rule-#2-safe — a
        //    lookup Dict, not an FP accumulation). This replaces the plan's O(n)
        //    `.first(where: { …full-PK tuple… })` per key (O(n·m) total).
        //    `uniquingKeysWith` is defensive only — the artifacts PK is the DB
        //    primary key, so duplicate rows cannot occur on a real catalog.
        //    `var` because a MISS render upserts a fresh row that later
        //    DUPLICATE occurrences of the same key (loop repetitions) must HIT.
        var byPK = Dictionary(existing.map { (pkString($0), $0) },
                              uniquingKeysWith: { a, _ in a })

        // 5b. D4 upgrade rule (same as `GenerateCoordinator`): an existing row is
        //     a HIT only if its `qualityRank` meets/exceeds the rank REQUESTED by
        //     `request.settings`; a lower-rank row ⇒ MISS ⇒ re-render
        //     (upgrade-overwrite at the same archive path). The requested rank
        //     resolves per UNIQUE key (spp is flame-resolved for the genome tier)
        //     and is memoized in a lookup Dict keyed by the canonical PK string
        //     (rule #2 — a lookup map, never iterated for FP accumulation).
        var requestedRankByPK: [String: Double] = [:]
        var hitCount = 0, missCount = 0
        var seenPKs = Set<String>()
        for key in keys {
            let pk = pkStringTuple(key)
            guard seenPKs.insert(pk).inserted else { continue }   // duplicates ⇒ ONE plan entry
            let requested: Double
            do { requested = try requestedRank(for: key, in: request, memo: &requestedRankByPK) }
            catch {
                continuation.yield(.failed(String(describing: error)))
                continuation.finish(); return
            }
            if let row = byPK[pk], row.qualityRank >= requested { hitCount += 1 }
            else { missCount += 1 }
        }
        continuation.yield(.plan(hitCount: hitCount, missCount: missCount,
                                 segmentCount: keys.count))

        // 6. Per TIMELINE SLOT (duplicate loop keys included): HIT ⇒ collect the
        //    file URL (the same loop file may be collected `loopRepetitions`
        //    times — duplicate-file passthrough concat is decode-clean); MISS ⇒
        //    render into the archive first (ArchiveRenderer atomic-writes the
        //    file THEN upserts the row), then collect — and the fresh row is
        //    written back into `byPK` so the key's LATER occurrences HIT instead
        //    of re-rendering (a repeated loop is ONE canonical artifact, never
        //    re-rendered per repetition). `position` is the 1-indexed slot index
        //    over ALL slots so the per-frame `.rendering` events read
        //    "segment 3/5" the way the timeline counted them.
        var urls: [URL] = []
        var generated = 0, hit = 0
        let segmentTotal = keys.count
        for (idx, key) in keys.enumerated() {
            if cancelled { continuation.yield(.cancelled); break }
            let pk = pkStringTuple(key)
            let requested = requestedRankByPK[pk] ?? 0   // memoized in step 5b
            if let row = byPK[pk], row.qualityRank >= requested {
                hit += 1
                urls.append(request.flockRoot.appendingPathComponent(row.file))
            } else {
                do {
                    try await renderSegment(forKey: key, request: request, coordinator: coordinator,
                                            position: idx + 1, total: segmentTotal,
                                            yield: { continuation.yield($0) })
                    generated += 1
                    // Re-read the freshly-upserted row to resolve its archive path.
                    let row = try await catalog.lookup(aGen: key.aGen, aId: key.aId,
                                                       bGen: key.bGen, bId: key.bId, shard: key.shard)
                    guard let row else {
                        continuation.yield(.failed("Rendered segment missing from catalog."))
                        continuation.finish(); return
                    }
                    // Publish the fresh row (rank == requested — identical
                    // settings) so this key's LATER duplicate occurrences HIT.
                    byPK[pk] = row
                    urls.append(request.flockRoot.appendingPathComponent(row.file))
                } catch {
                    continuation.yield(.failed(String(describing: error)))
                    continuation.finish(throwing: error); return
                }
            }
            continuation.yield(.running(hit: hit, generated: generated))
        }
        if cancelled { continuation.finish(); return }

        // 7. Single SLOT (one loop file, i.e. a single-genome sequence at
        //    `loopRepetitions == 1`): copy — `try` (not `try?`) so a copy failure
        //    surfaces instead of being swallowed. No concat. At reps > 1 the same
        //    loop file appears `reps` times in `urls`, so the concat below runs
        //    instead (N copies of one file). `.concatenating` is yielded first so
        //    the (possibly multi-second) copy/remux tail phase is never a silent
        //    gap.
        if urls.count == 1 {
            continuation.yield(.concatenating(segments: 1))
            do {
                try FileManager.default.copyItem(at: urls[0], to: request.out)
                continuation.yield(.completed(out: request.out))
                continuation.finish()
            } catch {
                continuation.yield(.failed(String(describing: error)))
                continuation.finish(throwing: error)
            }
            return
        }

        // 8. Passthrough concat (same-codec ⇒ no re-encode) — the load-bearing
        //    call, single-sourced in `ExportCoordinator.concat`. Yields
        //    `.concatenating` FIRST: the remux takes seconds and previously
        //    showed nothing between the last `.running` and `.completed`.
        do {
            continuation.yield(.concatenating(segments: urls.count))
            try await coordinator.concat(segments: urls, container: .mov, to: request.out)
            continuation.yield(.completed(out: request.out))
            continuation.finish()
        } catch {
            continuation.yield(.failed(String(describing: error)))
            continuation.finish(throwing: error)
        }
    }

    // MARK: - Helpers

    /// Build the alternating loop/edge key list from `orderedFlames`. Each key
    /// carries the request's single shard name; loops are self-edges (a==b).
    ///
    /// **Loop repetitions (stitch-time):** each loop key appears
    /// `max(1, loopRepetitions)` times, edges exactly once —
    /// `[loopA ×r, edgeAB, loopB ×r, …]`. Duplicate keys reference the SAME
    /// canonical archive artifact (one rotation cycle); they are NOT re-rendered
    /// per repetition and the archive never gains extra files. `reps == 1`
    /// reproduces the classic one-loop-per-flame timeline exactly.
    private func buildSegmentKeys(_ r: StitchRequest)
        -> [(aGen: String, aId: String, bGen: String, bId: String, shard: String)] {
        var out: [(aGen: String, aId: String, bGen: String, bId: String, shard: String)] = []
        let fs = r.orderedFlames
        let reps = max(1, r.loopRepetitions)
        for i in 0..<fs.count {
            let a = fs[i]
            for _ in 0..<reps {
                out.append((a.gen, a.id, a.gen, a.id, r.shard.name))    // loop(Fi) × reps
            }
            if i + 1 < fs.count {
                let b = fs[i + 1]
                out.append((a.gen, a.id, b.gen, b.id, r.shard.name))    // edge(Fi → Fi+1), once
            }
        }
        return out
    }

    /// The D4 quality rank REQUESTED by `request.settings` for one segment key
    /// — computed exactly the way `GenerateCoordinator` does (and the way the
    /// row's own rank is computed in `ArchiveRenderer.renderIntoArchive`):
    /// `qualityRank(spp: temporal: smoothingHw:)` with spp resolved against the
    /// key's A-flame (the genome tier resolves per-flame). Memoized in `memo`
    /// (keyed by the canonical PK string — a lookup Dict, rule #2-safe).
    private func requestedRank(
        for key: (aGen: String, aId: String, bGen: String, bId: String, shard: String),
        in request: StitchRequest,
        memo: inout [String: Double]
    ) throws -> Double {
        let pk = pkStringTuple(key)
        if let cached = memo[pk] { return cached }
        guard let A = request.orderedFlames
            .first(where: { $0.gen == key.aGen && $0.id == key.aId })?.flame else {
            throw StitchError.flameNotFound("\(key.aGen)/\(key.aId)")
        }
        let (spp, _) = request.settings.quality.resolvedSamplesPerPixel(for: A)
        let smoothingHw = TemporalSmoothing.halfWidth(forAlpha: request.settings.smoothingAlpha)
        let rank = ArchiveRenderer.qualityRank(
            spp: spp, temporal: request.settings.temporalSamples, smoothingHw: smoothingHw)
        memo[pk] = rank
        return rank
    }

    /// Canonical PK string for an `ArtifactRow` (same field order as the DB PK +
    /// `FlockSeed`): `aGen|aId|bGen|bId|shard`.
    private func pkString(_ r: ArtifactRow) -> String {
        "\(r.aGen)|\(r.aId)|\(r.bGen)|\(r.bId)|\(r.shard)"
    }
    /// Canonical PK string for a segment key tuple (mirrors `pkString(_:)`).
    private func pkStringTuple(_ k: (aGen: String, aId: String, bGen: String,
                                     bId: String, shard: String)) -> String {
        "\(k.aGen)|\(k.aId)|\(k.bGen)|\(k.bId)|\(k.shard)"
    }

    /// Render one MISS segment into the archive (atomic file write → row upsert,
    /// performed inside `ArchiveRenderer.renderLoop`/`renderEdge`). Resolves the
    /// Flame pair from `request.orderedFlames` by `(gen, id)` (small array ⇒ a
    /// linear `first(where:)` is fine and rule-#2-safe — ordered collection).
    ///
    /// `position`/`total` (1-indexed position among ALL segments) + `yield`
    /// (the stream continuation's yield) build the per-frame callback handed to
    /// `ArchiveRenderer` (its `perFrame` param — the same hook
    /// `GenerateCoordinator` uses), so a MISS render streams `.rendering` events
    /// instead of going dark for its whole duration.
    private func renderSegment(
        forKey key: (aGen: String, aId: String, bGen: String, bId: String, shard: String),
        request: StitchRequest, coordinator: ExportCoordinator,
        position: Int, total: Int,
        yield: @escaping @Sendable (StitchUIProgress) -> Void
    ) async throws {
        guard let A = request.orderedFlames.first(where: { $0.gen == key.aGen && $0.id == key.aId })?.flame else {
            throw StitchError.flameNotFound("\(key.aGen)/\(key.aId)")
        }
        // `ArchiveRenderer` takes the concrete `FlockCatalog` actor (it upserts the
        // row after the atomic file write). The lookup catalog and the render
        // catalog are the SAME object in production + the MISS tests (both a real
        // `FlockCatalog`); the test spy double is used only in all-HIT scenarios
        // where this render path is never reached.
        guard let archiveCatalog = catalog as? FlockCatalog else {
            throw StitchError.concreteCatalogRequiredForRender
        }
        let isLoop = key.aGen == key.bGen && key.aId == key.bId
        // The unit's frame total is the shard pace for its kind (loops encode
        // loopFrames; edges encode only the transFrames range — see
        // `ArchiveRenderer.loopRenderRange`/`edgeRenderRange`), so a frame-0
        // yield can go out BEFORE the render starts (kills the one-frame-time
        // blackout between `.plan`/`.running` and the first encoded frame).
        let frameTotal = isLoop ? request.shard.loopFrames : request.shard.transFrames
        let perFrame: @Sendable (_ frame: Int, _ frameTotal: Int) -> Void = { frame, frameTotal in
            yield(.rendering(segment: position, total: total, isLoop: isLoop,
                             frame: frame, frameTotal: frameTotal))
        }
        yield(.rendering(segment: position, total: total, isLoop: isLoop,
                         frame: 0, frameTotal: frameTotal))
        if isLoop {
            try await renderer.renderLoop(
                A: A, aGen: key.aGen, aId: key.aId, shard: request.shard,
                settings: request.settings, coordinator: coordinator, catalog: archiveCatalog,
                backend: backend, useOffMainMetal: useOffMainMetal,
                flockRoot: request.flockRoot, sourceSha: nil, perFrame: perFrame)
        } else {
            guard let B = request.orderedFlames.first(where: { $0.gen == key.bGen && $0.id == key.bId })?.flame else {
                throw StitchError.flameNotFound("\(key.bGen)/\(key.bId)")
            }
            try await renderer.renderEdge(
                A: A, B: B, aGen: key.aGen, aId: key.aId, bGen: key.bGen, bId: key.bId,
                shard: request.shard, settings: request.settings, coordinator: coordinator,
                catalog: archiveCatalog, backend: backend, useOffMainMetal: useOffMainMetal,
                flockRoot: request.flockRoot, sourceSha: nil, perFrame: perFrame)
        }
    }
}

enum StitchError: Error, LocalizedError {
    case flameNotFound(String)
    case concreteCatalogRequiredForRender
    var errorDescription: String? {
        switch self {
        case .flameNotFound(let s): return "Flame not found in orderedFlames: \(s)"
        case .concreteCatalogRequiredForRender:
            return "Stitch MISS path requires a concrete FlockCatalog (the spy double is all-HIT only)."
        }
    }
}
