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
            generateState = .running(skip: skip, render: render, total: total)
        case .completed(let rendered, let skipped):
            generateState = .completed(rendered: rendered, skipped: skipped)
        case .failed(let message):
            generateState = .failed(message)
        case .cancelled:
            generateState = .cancelled
        }
    }

    private func applyStitch(_ p: StitchUIProgress) {
        switch p {
        case .resolving:
            stitchState = .resolving
        case .plan(let hitCount, let missCount):
            stitchState = .plan(hit: hitCount, miss: missCount)
        case .running(let hit, let generated):
            stitchState = .running(hit: hit, generated: generated)
        case .completed(let out):
            stitchState = .completed(out)
        case .failed(let message):
            stitchState = .failed(message)
        case .cancelled:
            stitchState = .cancelled
        }
    }
}
