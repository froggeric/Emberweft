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
    public init(shard: ShardSpec,
                orderedFlames: [(gen: String, id: String, flame: Flame)],
                settings: ExportSettings, flockRoot: URL, out: URL) {
        self.shard = shard; self.orderedFlames = orderedFlames
        self.settings = settings; self.flockRoot = flockRoot; self.out = out
    }
}

public enum StitchUIProgress: Sendable, Equatable {
    case resolving
    case plan(hitCount: Int, missCount: Int)
    case running(hit: Int, generated: Int)
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
        let byPK = Dictionary(existing.map { (pkString($0), $0) },
                              uniquingKeysWith: { a, _ in a })
        let hitCount = keys.filter { byPK[pkStringTuple($0)] != nil }.count
        let missCount = keys.count - hitCount
        continuation.yield(.plan(hitCount: hitCount, missCount: missCount))

        // 6. Per segment: HIT ⇒ collect file URL; MISS ⇒ render into the archive
        //    first (ArchiveRenderer atomic-writes the file THEN upserts the row),
        //    then collect.
        var urls: [URL] = []
        var generated = 0, hit = 0
        for key in keys {
            if cancelled { continuation.yield(.cancelled); break }
            if let row = byPK[pkStringTuple(key)] {
                hit += 1
                urls.append(request.flockRoot.appendingPathComponent(row.file))
            } else {
                do {
                    try await renderSegment(forKey: key, request: request, coordinator: coordinator)
                    generated += 1
                    // Re-read the freshly-upserted row to resolve its archive path.
                    let row = try await catalog.lookup(aGen: key.aGen, aId: key.aId,
                                                       bGen: key.bGen, bId: key.bId, shard: key.shard)
                    guard let row else {
                        continuation.yield(.failed("Rendered segment missing from catalog."))
                        continuation.finish(); return
                    }
                    urls.append(request.flockRoot.appendingPathComponent(row.file))
                } catch {
                    continuation.yield(.failed(String(describing: error)))
                    continuation.finish(throwing: error); return
                }
            }
            continuation.yield(.running(hit: hit, generated: generated))
        }
        if cancelled { continuation.finish(); return }

        // 7. Single-genome (loop-only, one file): copy — `try` (not `try?`) so a
        //    copy failure surfaces instead of being swallowed. No concat.
        if urls.count == 1 {
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
        //    call, single-sourced in `ExportCoordinator.concat`.
        do {
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
    private func buildSegmentKeys(_ r: StitchRequest)
        -> [(aGen: String, aId: String, bGen: String, bId: String, shard: String)] {
        var out: [(aGen: String, aId: String, bGen: String, bId: String, shard: String)] = []
        let fs = r.orderedFlames
        for i in 0..<fs.count {
            let a = fs[i]
            out.append((a.gen, a.id, a.gen, a.id, r.shard.name))        // loop(Fi)
            if i + 1 < fs.count {
                let b = fs[i + 1]
                out.append((a.gen, a.id, b.gen, b.id, r.shard.name))    // edge(Fi → Fi+1)
            }
        }
        return out
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
    private func renderSegment(
        forKey key: (aGen: String, aId: String, bGen: String, bId: String, shard: String),
        request: StitchRequest, coordinator: ExportCoordinator
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
        if isLoop {
            try await renderer.renderLoop(
                A: A, aGen: key.aGen, aId: key.aId, shard: request.shard,
                settings: request.settings, coordinator: coordinator, catalog: archiveCatalog,
                backend: backend, useOffMainMetal: useOffMainMetal,
                flockRoot: request.flockRoot, sourceSha: nil)
        } else {
            guard let B = request.orderedFlames.first(where: { $0.gen == key.bGen && $0.id == key.bId })?.flame else {
                throw StitchError.flameNotFound("\(key.bGen)/\(key.bId)")
            }
            try await renderer.renderEdge(
                A: A, B: B, aGen: key.aGen, aId: key.aId, bGen: key.bGen, bId: key.bId,
                shard: request.shard, settings: request.settings, coordinator: coordinator,
                catalog: archiveCatalog, backend: backend, useOffMainMetal: useOffMainMetal,
                flockRoot: request.flockRoot, sourceSha: nil)
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
