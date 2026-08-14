import Foundation
import FlameKit
import FlameRenderer
import FlameExport
import FlameFlock

/// The testable Flock view-model (spec §13 / Task 15). `@MainActor @Observable
/// final class`, held by `AppModel` as a single long-lived instance (mirrors
/// `ExportManager` — survives sheet/window teardown, the M4 §13.2 invariant).
/// Carries the three state machines (`generateState` / `stitchState` /
/// `browseState`) and drives the FlameFlock coordinators through injectable
/// factory seams.
///
/// Entry points (`generate(_:)` / `stitch(_:)` / `refreshBrowse()`) are
/// fire-and-forget: they set the initial state, build the coordinator via the
/// factory, spawn the consume `Task`, and RETURN. Tests (and the cancel path)
/// drain the run via `awaitGenerateCompletion()` / `awaitStitchCompletion()`.
///
/// **Concurrency (Swift 6):** the class is `@MainActor`; the consume `Task`
/// inherits MainActor isolation. The coordinators are `actor`s (or injected
/// spies); the request/progress value types are `Sendable`. The consume `Task`
/// uses `[weak self]` (AppModel-owned ⇒ never released mid-run; weak still
/// guards app-teardown). The CANCEL path captures `self` STRONGLY (see
/// `cancelGenerate()`).
@MainActor
@Observable
public final class FlockModel {

    // MARK: - Observed state (spec §13.1)

    public private(set) var generateState: GenerateUIState = .idle
    public private(set) var stitchState: StitchUIState = .idle
    public private(set) var browseState: BrowseUIState = .loading

    /// User-facing backend picker, resolved via `MetalRenderer.isAvailable` (the
    /// probe runs on the MainActor — `FlockModel` is `@MainActor`, so it is
    /// safe). Reuses `ExportManager.BackendChoice` (single source of truth).
    public var backendChoice: BackendChoice = .auto

    // MARK: - Factory seams (mirror ExportManager.coordinatorFactory, line 212)
    //
    // `public` so AppModel (EmberweftGUI, a separate module) can install the
    // production closures at launch (T17) — it owns the real `FlockCatalog` +
    // `ArchiveRenderer` the concrete coordinators need. The DEFAULTS
    // `fatalError` because FlockModel cannot construct a real GenerateCoordinator
    // without the AppModel-owned catalog/renderer; tests ALWAYS override before
    // driving `generate(_:)`. This is honest about the dependency and keeps the
    // seam Sendable (no `self` capture in the closure).

    /// Builds the generate coordinator for a run. Production (AppModel/T17)
    /// installs `{ backend, offMain in GenerateCoordinator(catalog:…, renderer:…,
    /// backend: backend, useOffMainMetal: offMain) }`. Tests install a spy.
    public var generateFactory: (ExportCoordinator.Backend, Bool) -> any GeneratingCoordinating = { _, _ in
        fatalError("FlockModel.generateFactory must be installed by AppModel (T17) before generate(_:).")
    }

    /// Builds the stitch coordinator for a run (twin of `generateFactory`).
    public var stitchFactory: (ExportCoordinator.Backend, Bool) -> any StitchingCoordinating = { _, _ in
        fatalError("FlockModel.stitchFactory must be installed by AppModel (T17) before stitch(_:).")
    }

    /// Provides the `FlockSnapshot` for `refreshBrowse()`. Production (T17)
    /// installs `{ [catalog] in await catalog.snapshot() }`. The default returns
    /// a zero snapshot (graceful: Browse shows `.empty` until wired — no crash).
    public var snapshotProvider: () async throws -> FlockSnapshot = {
        FlockSnapshot(shardCount: 0, artifactCount: 0)
    }

    // MARK: - In-flight state (private)

    private var generateTask: Task<Void, Never>?
    private var stitchTask: Task<Void, Never>?
    /// Held for `cancelGenerate()` — the coordinator actor's `cancelled` flag
    /// is the authoritative stop (M4 §13.2: a bare `Task.cancel()` does NOT
    /// cross actor isolation). Nil at rest.
    private var generateCoord: (any GeneratingCoordinating)?
    private var stitchCoord: (any StitchingCoordinating)?
    /// The fire-and-forget cancel tasks. Stored so the strong-`self` capture has
    /// a slot to clear (mirrors `PlaybackViewModel.beginStop` → `stopTask`,
    /// breaking the self → task → self cycle once the coordinator acknowledges
    /// stop). Nil at rest.
    private var cancelGenerateTask: Task<Void, Never>?
    private var cancelStitchTask: Task<Void, Never>?

    // MARK: - Generate ETA (v0.5.8)
    // Per-unit wall-clock EMA → ETA, mirroring `ExportManager`'s per-frame EMA at
    // unit granularity. The VM observes wall-clock cadence between the first
    // frame of a unit (`.rendering(frame: 1)`) and the unit-boundary `.running`
    // that completes it; only RENDER completions are sampled (skips emit
    // `.running` with `render` unchanged ⇒ not sampled). Reset on each run.
    private var eta = GenerateETAEstimator()
    private var unitStartAt: ContinuousClock.Instant?
    private var lastRenderCount = 0

    // MARK: - Stitch ETA + elapsed (v0.5.9)
    // The stitch twin of the generate ETA state, at MISS-SEGMENT granularity
    // (only generated segments are timed — HITs are instant catalog reads).
    // `stitchPlanTotal`/`stitchMissTotal` come from the `.plan` event, so the
    // `.running` state can carry a state-driven total (NOT the view's own
    // sequence count, which can go stale mid-run).
    private var stitchEta = GenerateETAEstimator()
    private var stitchSegmentStartAt: ContinuousClock.Instant?
    private var stitchLastGenerated = 0
    private var stitchPlanTotal = 0
    private var stitchMissTotal = 0

    // MARK: - Run elapsed (v0.5.9 completion feedback)
    // Set when the run starts; the completed-state elapsed is derived from it and
    // published alongside the terminal state (completion feedback: a summary
    // with elapsed, not a flash).
    private var generateStartAt: ContinuousClock.Instant?
    private var stitchStartAt: ContinuousClock.Instant?
    /// Wall-clock seconds of the LAST completed generate run (nil until then).
    public private(set) var generateElapsedSeconds: Double?
    /// Wall-clock seconds of the LAST completed stitch run (nil until then).
    public private(set) var stitchElapsedSeconds: Double?

    public init() {}

    // MARK: - Backend resolution

    /// Resolve the concrete backend (mirrors `ExportManager.resolveBackend`).
    /// `.auto`/`.metal` fall back to CPU when Metal is unavailable. Pure given
    /// `metalAvailable`; the probe is hoisted to the caller's context.
    internal func resolveBackend(metalAvailable: Bool) -> ExportCoordinator.Backend {
        switch backendChoice {
        case .auto:  return metalAvailable ? .metal : .cpu
        case .cpu:   return .cpu
        case .metal: return metalAvailable ? .metal : .cpu
        }
    }

    // MARK: - Generate (Path A)

    /// Drive a generate run. Empty `units` fails immediately (FlockModel-side
    /// guard, spec line 1833) — no coordinator is constructed. Otherwise sets
    /// `.resolving`, builds the coordinator, spawns the consume `Task`, returns.
    public func generate(_ request: GenerateRequest) async {
        generateCoord = nil
        guard !request.units.isEmpty else {
            generateState = .failed("No genomes to generate from.")
            return
        }
        generateState = .resolving
        // Reset ETA state for the fresh run (mirrors ExportManager.resetETAState).
        eta.reset(); unitStartAt = nil; lastRenderCount = 0
        generateStartAt = ContinuousClock.now; generateElapsedSeconds = nil
        let backend = resolveBackend(metalAvailable: MetalRenderer.isAvailable)
        let gen = generateFactory(backend, true)
        generateCoord = gen
        // The ExportCoordinator is the render engine passed INTO generate — each
        // unit's render hops through it. Cheap to construct (an actor with no
        // Metal/AVFoundation resources until `run` is called); the spy ignores it.
        let exportCoord = ExportCoordinator(backend: backend, useOffMainMetal: true)
        generateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await gen.generate(request, coordinator: exportCoord)
                for try await p in stream {
                    self.applyGenerate(p)
                }
            } catch is CancellationError {
                self.generateState = .cancelled
            } catch {
                self.generateState = .failed(String(describing: error))
            }
            self.generateTask = nil
            self.generateCoord = nil
        }
    }

    /// M4 §13.2 teardown safety: cancel BOTH the structured `Task` (propagates
    /// `CancellationError` into the stream iteration) AND the coordinator
    /// actor's own `cancelled` flag (the actor's loop checks `self.cancelled`,
    /// which a bare `Task.cancel` does NOT set — the actor is a separate
    /// isolation domain).
    ///
    /// The strong-`self` capture in the cancel `Task` is deliberate: it keeps
    /// `FlockModel` alive until the coordinator acknowledges stop, so a sheet
    /// dismissal cannot orphan a GPU-running actor. The `Task` is stored as
    /// `cancelGenerateTask` and self-cleared on completion, breaking the
    /// self → cancelGenerateTask → task → self cycle (mirrors
    /// `PlaybackViewModel.beginStop`).
    public func cancelGenerate() {
        generateTask?.cancel()
        let coord = generateCoord
        cancelGenerateTask = Task { [self] in
            await coord?.cancel()
            self.cancelGenerateTask = nil
        }
    }

    // MARK: - Stitch (Path B)

    /// Drive a stitch run. Sets `.resolving`, builds the coordinator, spawns the
    /// consume `Task`, returns. The empty-sequence / cross-shard / codec-mismatch
    /// guards live in `StitchCoordinator` (it yields `.failed(…)`); FlockModel
    /// applies them. No FlockModel-side empty guard (asymmetric with generate by
    /// design — generate's empty guard is spec line 1833).
    public func stitch(_ request: StitchRequest) async {
        stitchCoord = nil
        stitchState = .resolving
        // Reset stitch ETA/elapsed state for the fresh run (twin of generate).
        stitchEta.reset(); stitchSegmentStartAt = nil; stitchLastGenerated = 0
        stitchPlanTotal = 0; stitchMissTotal = 0
        stitchStartAt = ContinuousClock.now; stitchElapsedSeconds = nil
        let backend = resolveBackend(metalAvailable: MetalRenderer.isAvailable)
        let st = stitchFactory(backend, true)
        stitchCoord = st
        let exportCoord = ExportCoordinator(backend: backend, useOffMainMetal: true)
        stitchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await st.stitch(request, coordinator: exportCoord)
                for try await p in stream {
                    self.applyStitch(p)
                }
            } catch is CancellationError {
                self.stitchState = .cancelled
            } catch {
                self.stitchState = .failed(String(describing: error))
            }
            self.stitchTask = nil
            self.stitchCoord = nil
        }
    }

    /// Cancel the in-flight stitch run (twin of `cancelGenerate()`; same M4
    /// §13.2 teardown-safe strong-self + actor-flag cancel, stored as
    /// `cancelStitchTask` and self-cleared on completion).
    public func cancelStitch() {
        stitchTask?.cancel()
        let coord = stitchCoord
        cancelStitchTask = Task { [self] in
            await coord?.cancel()
            self.cancelStitchTask = nil
        }
    }

    // MARK: - Browse

    /// Refresh the catalog snapshot. Hops to `snapshotProvider` (production: the
    /// catalog actor's `snapshot()`), then sets `.loaded` / `.empty` / `.failed`.
    public func refreshBrowse() async {
        browseState = .loading
        do {
            let snap = try await snapshotProvider()
            if snap.shardCount == 0 && snap.artifactCount == 0 {
                browseState = .empty
            } else {
                browseState = .loaded(snap)
            }
        } catch {
            browseState = .failed(String(describing: error))
        }
    }

    // MARK: - Test/await hooks

    /// Block until the in-flight generate `Task` finishes. Production never calls
    /// this (fire-and-forget); tests call it to assert terminal state without
    /// polling. Captures the Task reference before the consume `Task` nils it at
    /// its tail.
    internal func awaitGenerateCompletion() async {
        guard let task = generateTask else { return }
        await task.value
    }

    /// Block until the in-flight stitch `Task` finishes (twin of above).
    internal func awaitStitchCompletion() async {
        guard let task = stitchTask else { return }
        await task.value
    }

    // MARK: - Progress → state (pure mappers)

    private func applyGenerate(_ p: GenerateUIProgress) {
        switch p {
        case .resolving:
            generateState = .resolving
        case .running(let skip, let render, let total):
            // A render unit completed iff `render` increased and we timed its
            // render (skips/resume-skip emit `.running` with `render` unchanged ⇒
            // `unitStartAt` is nil or stale; not sampled). Record the wall-clock
            // duration into the EMA.
            if render > lastRenderCount, let start = unitStartAt {
                eta.record(unitSeconds: Self.seconds(from: ContinuousClock.now - start))
            }
            lastRenderCount = render
            unitStartAt = nil
            let etaSec = eta.etaSeconds(remainingUnits: Double(max(0, total - skip - render)))
            generateState = .running(skip: skip, render: render, total: total, etaSeconds: etaSec)
        case .rendering(let skip, let render, let total, let frame, let frameTotal):
            // First frame of a unit marks the render start (the catalog lookup
            // ran between the prior `.running` and this; measuring here captures
            // render time only, not lookup). Overwrite is correct: a new unit's
            // first frame always follows its preceding `.running` completion.
            if frame == 1 { unitStartAt = ContinuousClock.now }
            // Smooth within-unit ETA: the in-flight unit is partially done, so
            // subtract its completed fraction from the remaining count.
            let remainingWhole = Double(max(0, total - skip - render - 1))
            let fracDone = Double(max(0, frame - 1)) / Double(max(1, frameTotal))
            let remaining = remainingWhole + (1.0 - fracDone)
            let etaSec = eta.etaSeconds(remainingUnits: remaining)
            generateState = .rendering(skip: skip, render: render, total: total,
                                       frame: frame, frameTotal: frameTotal, etaSeconds: etaSec)
        case .completed(let rendered, let skipped):
            generateElapsedSeconds = elapsedSince(generateStartAt)
            generateState = .completed(rendered: rendered, skipped: skipped)
        case .failed(let message):
            generateState = .failed(message)
        case .cancelled:
            generateState = .cancelled
        }
    }

    /// Duration → seconds (Double), mirroring `ExportManager.seconds(from:)`.
    /// `Duration.components` splits into (seconds, attoseconds); recombine.
    private static func seconds(from duration: Duration) -> Double {
        let (s, attos) = duration.components
        return Double(s) + Double(attos) / 1e18
    }

    private func applyStitch(_ p: StitchUIProgress) {
        switch p {
        case .resolving:
            stitchState = .resolving
        case .plan(let hitCount, let missCount):
            // Capture the plan tallies: `running` carries the state-driven total
            // (hit + miss), and the ETA's remaining-unit count is the MISS count.
            stitchPlanTotal = hitCount + missCount
            stitchMissTotal = missCount
            stitchState = .plan(hit: hitCount, miss: missCount)
        case .running(let hit, let generated):
            // A MISS render completed iff `generated` increased AND the pre-render
            // `.rendering(frame: 0)` marked its start (HIT segments complete
            // instantly and emit `.running` with `generated` unchanged ⇒ not
            // sampled). Record the wall-clock duration into the EMA.
            if generated > stitchLastGenerated, let start = stitchSegmentStartAt {
                stitchEta.record(unitSeconds: Self.seconds(from: ContinuousClock.now - start))
            }
            stitchLastGenerated = generated
            stitchSegmentStartAt = nil
            let etaSec = stitchEta.etaSeconds(
                remainingUnits: Double(max(0, stitchMissTotal - generated)))
            stitchState = .running(hit: hit, generated: generated,
                                   total: stitchPlanTotal, etaSeconds: etaSec)
        case .rendering(let segment, let total, let isLoop, let frame, let frameTotal):
            // frame == 0 is the pre-render yield (see StitchCoordinator) — the
            // render's true start; the first encoded frame (1) follows.
            if frame == 0 { stitchSegmentStartAt = ContinuousClock.now }
            // Smooth within-segment ETA, mirroring generate: the in-flight MISS is
            // partially done, so subtract its completed fraction from the
            // remaining count.
            let remainingWhole = Double(max(0, stitchMissTotal - stitchLastGenerated - 1))
            let fracDone = Double(max(0, frame - 1)) / Double(max(1, frameTotal))
            let remaining = remainingWhole + (1.0 - fracDone)
            let etaSec = stitchEta.etaSeconds(remainingUnits: remaining)
            stitchState = .rendering(segment: segment, total: total, isLoop: isLoop,
                                     frame: frame, frameTotal: frameTotal, etaSeconds: etaSec)
        case .concatenating(let segments):
            stitchState = .concatenating(segments: segments)
        case .completed(let out):
            stitchElapsedSeconds = elapsedSince(stitchStartAt)
            stitchState = .completed(out)
        case .failed(let message):
            stitchState = .failed(message)
        case .cancelled:
            stitchState = .cancelled
        }
    }

    /// Seconds since `start` (0 when start is nil — defensive; the run always
    /// sets it before events can arrive).
    private func elapsedSince(_ start: ContinuousClock.Instant?) -> Double {
        guard let start else { return 0 }
        return Self.seconds(from: ContinuousClock.now - start)
    }

    // MARK: - Global activity summary (sidebar presence, v0.5.9)

    /// What the flock is doing RIGHT NOW for global surfaces (the sidebar Flock
    /// row): nil ⇒ idle (nothing shown — no animation at rest). When BOTH a
    /// generate and a stitch are in flight, the most recently STARTED one wins
    /// (the owner's current focus; deterministic — the start instants are set
    /// synchronously at run start). Pure scalar mapping of the two states.
    public var flockActivity: FlockActivitySummary? {
        let gen = generateActivity
        let st = stitchActivity
        switch (gen, st) {
        case (let g?, let s?):
            return (generateStartAt ?? ContinuousClock.now) >= (stitchStartAt ?? ContinuousClock.now) ? g : s
        case (let g?, nil): return g
        case (nil, let s?): return s
        default: return nil
        }
    }

    private var generateActivity: FlockActivitySummary? {
        switch generateState {
        case .resolving:
            return FlockActivitySummary(kind: .generate, fraction: nil,
                                        completed: nil, total: nil, etaSeconds: nil)
        case .running(let skip, let render, let total, let eta):
            return FlockActivitySummary(kind: .generate,
                                        fraction: unitFraction(skip + render, 0, 1, total),
                                        completed: skip + render, total: total, etaSeconds: eta)
        case .rendering(let skip, let render, let total, let frame, let frameTotal, let eta):
            return FlockActivitySummary(kind: .generate,
                                        fraction: unitFraction(skip + render, frame, frameTotal, total),
                                        completed: skip + render, total: total, etaSeconds: eta)
        case .idle, .completed, .failed, .cancelled:
            return nil
        }
    }

    private var stitchActivity: FlockActivitySummary? {
        switch stitchState {
        case .resolving, .plan:
            // In flight but not yet at a countable phase (plan → segment loop is
            // immediate) — indeterminate spinner.
            return FlockActivitySummary(kind: .stitch, fraction: nil,
                                        completed: nil, total: nil, etaSeconds: nil)
        case .running(let hit, let generated, let total, let eta):
            return FlockActivitySummary(kind: .stitch,
                                        fraction: unitFraction(hit + generated, 0, 1, total),
                                        completed: hit + generated, total: total, etaSeconds: eta)
        case .rendering(let segment, let total, _, let frame, let frameTotal, let eta):
            return FlockActivitySummary(kind: .stitch,
                                        fraction: unitFraction(segment - 1, frame, frameTotal, total),
                                        completed: segment - 1, total: total, etaSeconds: eta)
        case .concatenating:
            return FlockActivitySummary(kind: .stitch, fraction: nil,
                                        completed: nil, total: nil, etaSeconds: nil)
        case .idle, .completed, .failed, .cancelled:
            return nil
        }
    }

    /// Overall 0…1 fraction: `(wholeUnitsDone + withinUnitFrame/frameTotal) / total`,
    /// clamped. Pure scalar arithmetic (rule #2).
    private func unitFraction(_ whole: Int, _ frame: Int, _ frameTotal: Int, _ total: Int) -> Double {
        let inner = Double(frame) / Double(max(1, frameTotal))
        return min(1, max(0, (Double(whole) + inner) / Double(max(1, total))))
    }
}
