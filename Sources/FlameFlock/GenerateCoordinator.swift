// Sources/FlameFlock/GenerateCoordinator.swift
import Foundation
import FlameKit
import FlameExport

/// Path A generation: enumerate units, render each in-scope one into the
/// archive with hit-skip / upgrade-overwrite semantics, stream progress, and
/// resume across interruption via a generate-plan file (spec §D, Task 10).
///
/// Concurrency: an `actor` — the single in-process driver. `FlockCatalog` (also
/// an actor) serializes the row writes. The per-unit render hops off this actor
/// (`await renderer.renderLoop/renderEdge`), so `cancel()` lands between units.
///
/// Determinism (rule #2): the resume key is a pure SHA-canonical string
/// `shard|aGen|aId|bGen|bId` (same fixed order as `FlockSeed`); the plan file is
/// a JSON array of `GeneratePlanKey` written SORTED by
/// `(aGen,aId,bGen,bId,shard)`; `qualityRank` is scalar arithmetic; no FP sum
/// over a `Dictionary`/`Set` (the `Set<GeneratePlanKey>` is for O(1) membership
/// only, never iterated to accumulate).

public enum GenerateScope: String, Sendable { case edges, loops, both }

public enum GenerateUIProgress: Sendable, Equatable {
    case resolving
    case running(skip: Int, render: Int, total: Int)
    case completed(rendered: Int, skipped: Int)
    case failed(String)
    case cancelled
}

public struct GenerateRequest: Sendable {
    public let shard: ShardSpec
    public let units: [GenerateUnit]          // pre-enumerated loops (a==b) + edges (a→b)
    public let scope: GenerateScope
    public let settings: ExportSettings
    public let flockRoot: URL
    /// Default scope is `.edges` (loops opt-in, D10).
    public init(shard: ShardSpec, units: [GenerateUnit],
                scope: GenerateScope = .edges,
                settings: ExportSettings, flockRoot: URL) {
        self.shard = shard; self.units = units; self.scope = scope
        self.settings = settings; self.flockRoot = flockRoot
    }
}

public struct GenerateUnit: Sendable {            // loop OR edge; a==b ⇒ loop
    public let aGen: String, aId: String, bGen: String, bId: String
    public let A: Flame
    public let B: Flame?
    public var isLoop: Bool { aGen == bGen && aId == bId }
    public init(aGen: String, aId: String, bGen: String, bId: String,
                A: Flame, B: Flame? = nil) {
        self.aGen = aGen; self.aId = aId; self.bGen = bGen; self.bId = bId
        self.A = A; self.B = B
    }
}

/// A completed-key record in the generate-plan file. Persisted as a JSON array
/// written SORTED by `(aGen,aId,bGen,bId,shard)` (rule #2 — deterministic bytes,
/// no hash-ordered iteration). `Hashable` for O(1) membership lookup only.
public struct GeneratePlanKey: Codable, Sendable, Equatable, Hashable {
    public let aGen: String
    public let aId: String
    public let bGen: String
    public let bId: String
    public let shard: String
    public init(aGen: String, aId: String, bGen: String, bId: String, shard: String) {
        self.aGen = aGen; self.aId = aId; self.bGen = bGen; self.bId = bId; self.shard = shard
    }
}

public actor GenerateCoordinator {
    private let catalog: FlockCatalog
    private let renderer: ArchiveRenderer
    private let backend: ExportCoordinator.Backend
    private let useOffMainMetal: Bool
    private var cancelled = false

    public init(catalog: FlockCatalog, renderer: ArchiveRenderer,
                backend: ExportCoordinator.Backend, useOffMainMetal: Bool) {
        self.catalog = catalog; self.renderer = renderer
        self.backend = backend; self.useOffMainMetal = useOffMainMetal
    }

    public func cancel() async { cancelled = true }

    /// `<flockRoot>/flock-generate-plan.json` — sibling of `flock.sqlite`. Holds
    /// the sorted completed-key list consumed on resume.
    public static func planFileURL(flockRoot: URL) -> URL {
        flockRoot.appendingPathComponent("flock-generate-plan.json")
    }

    /// Stream progress; render each in-scope unit. Hit-skip and
    /// upgrade-overwrite via `quality_rank` (D4). The `ExportCoordinator` is
    /// constructed by the caller and reused (single `ThreadSeedBudget`
    /// memoization lives inside it).
    public func generate(_ request: GenerateRequest,
                         coordinator: ExportCoordinator) -> AsyncThrowingStream<GenerateUIProgress, Error> {
        AsyncThrowingStream { continuation in
            // Unstructured Task captures `self` (the Sendable actor) + the
            // Sendable continuation; `await self.generateBody(...)` hops onto
            // the actor for the whole run, so `cancelled` reads are direct.
            Task { [self] in
                await self.generateBody(request, coordinator: coordinator, continuation: continuation)
            }
        }
    }

    // MARK: - Body (actor-isolated: reads/writes `cancelled` directly)

    private func generateBody(
        _ request: GenerateRequest,
        coordinator: ExportCoordinator,
        continuation: AsyncThrowingStream<GenerateUIProgress, Error>.Continuation
    ) async {
        continuation.yield(.resolving)
        let planURL = Self.planFileURL(flockRoot: request.flockRoot)

        // Resume set: completed keys from a prior cancelled/interrupted run.
        var done: Set<GeneratePlanKey> = loadDoneSet(planURL: planURL)

        let scopedUnits = request.units.filter { inScope($0, scope: request.scope) }
        let total = scopedUnits.count
        var skip = 0, render = 0
        continuation.yield(.running(skip: skip, render: render, total: total))

        for unit in scopedUnits {
            // Cooperative cancel — checked at the top of every unit (the render
            // itself is atomic; cancel lands between units). Persist whatever
            // has completed so resume picks up here.
            if cancelled {
                persistPlan(planURL: planURL, done: done)
                continuation.yield(.cancelled)
                continuation.finish()
                return
            }
            let key = GeneratePlanKey(aGen: unit.aGen, aId: unit.aId,
                                      bGen: unit.bGen, bId: unit.bId, shard: request.shard.name)
            if done.contains(key) {                     // resume-skip
                skip += 1
                continuation.yield(.running(skip: skip, render: render, total: total))
                continue
            }
            if !unit.A.isRenderable {                   // unrenderable — skip with notice
                skip += 1
                continuation.yield(.running(skip: skip, render: render, total: total))
                continue
            }
            do {
                let (spp, _) = request.settings.quality.resolvedSamplesPerPixel(for: unit.A)
                let smoothingHw = TemporalSmoothing.halfWidth(forAlpha: request.settings.smoothingAlpha)
                let requestedRank = ArchiveRenderer.qualityRank(
                    spp: spp, temporal: request.settings.temporalSamples, smoothingHw: smoothingHw)
                let existing = try await catalog.lookup(aGen: unit.aGen, aId: unit.aId,
                                                        bGen: unit.bGen, bId: unit.bId,
                                                        shard: request.shard.name)
                if let existing, existing.qualityRank >= requestedRank {
                    // HIT — stored quality meets/exceeds the request. Skip; the
                    // archive file is untouched. Recorded in the plan so resume
                    // doesn't re-evaluate it.
                    skip += 1
                    done.insert(key)
                    persistPlan(planURL: planURL, done: done)
                    continuation.yield(.running(skip: skip, render: render, total: total))
                    continue
                }
                // Render (upgrade-overwrite at the same archive path:
                // ArchiveRenderer atomic-writes the file THEN upserts the row).
                if unit.isLoop {
                    try await renderer.renderLoop(
                        A: unit.A, aGen: unit.aGen, aId: unit.aId, shard: request.shard,
                        settings: request.settings, coordinator: coordinator, catalog: catalog,
                        backend: backend, useOffMainMetal: useOffMainMetal,
                        flockRoot: request.flockRoot, sourceSha: nil)
                } else {
                    let B = unit.B ?? unit.A
                    try await renderer.renderEdge(
                        A: unit.A, B: B, aGen: unit.aGen, aId: unit.aId,
                        bGen: unit.bGen, bId: unit.bId, shard: request.shard,
                        settings: request.settings, coordinator: coordinator, catalog: catalog,
                        backend: backend, useOffMainMetal: useOffMainMetal,
                        flockRoot: request.flockRoot, sourceSha: nil)
                }
                render += 1
                done.insert(key)
                persistPlan(planURL: planURL, done: done)
                continuation.yield(.running(skip: skip, render: render, total: total))
            } catch {
                // Persist completions so resume picks up before the failure.
                persistPlan(planURL: planURL, done: done)
                continuation.yield(.failed(String(describing: error)))
                continuation.finish(throwing: error)
                return
            }
        }
        // Success — the run is complete; consume the plan file (no resume needed).
        try? FileManager.default.removeItem(at: planURL)
        continuation.yield(.completed(rendered: render, skipped: skip))
        continuation.finish()
    }

    // MARK: - Scope (pure)

    private func inScope(_ unit: GenerateUnit, scope: GenerateScope) -> Bool {
        switch scope {
        case .loops: return unit.isLoop
        case .edges: return !unit.isLoop
        case .both:  return true
        }
    }

    // MARK: - Plan file I/O (pure file/JSON; called from the isolated body)

    private func loadDoneSet(planURL: URL) -> Set<GeneratePlanKey> {
        guard let data = try? Data(contentsOf: planURL),
              let keys = try? JSONDecoder().decode([GeneratePlanKey].self, from: data) else {
            return []
        }
        return Set(keys)
    }

    /// Write the completed-key set as a SORTED JSON array (rule #2). Skipped
    /// when empty (a run with no completions writes no plan file).
    private func persistPlan(planURL: URL, done: Set<GeneratePlanKey>) {
        guard !done.isEmpty else { return }
        let sorted = done.sorted {
            ($0.aGen, $0.aId, $0.bGen, $0.bId, $0.shard) <
            ($1.aGen, $1.aId, $1.bGen, $1.bId, $1.shard)
        }
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        try? FileManager.default.createDirectory(at: planURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? data.write(to: planURL, options: .atomic)
    }
}
