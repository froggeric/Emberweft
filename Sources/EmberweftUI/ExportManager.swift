import Foundation
import FlameKit
import FlameRenderer
import FlameExport

/// Terminal/non-terminal export state observed by the banner (spec §4.4 / §5.1).
/// `.completed` carries the output URL (single/sequence: the file; batch: the
/// directory). `.failed` carries a localized message.
///
/// M6.1 adds `.pausing` (cooperative pause requested; the run loop will throw
/// `.paused` at the next chunk boundary) and `.paused(out:checkpoint:reason:)`
/// (the export is suspended with a checkpoint on disk; `reason == nil` = user
/// pause, non-nil = a recoverable error paused it). `.paused` is non-terminal:
/// the banner offers Resume / Discard.
public enum ExportState: Sendable, Equatable {
    case idle
    case running
    case pausing
    case cancelling
    case completed(URL)
    case failed(String)
    case cancelled
    case paused(out: URL, checkpoint: URL, reason: String?)
}

/// A single normalized progress sample for the banner (spec §4.4). Pure value
/// type; `fraction` is computed from `currentFrame`/`totalFrames` (deterministic,
/// rule #2 — no float sum over a hashed collection). `jobIndex`/`totalJobs`
/// carry batch context (`0`/`1` for single/sequence).
///
/// `etaSeconds` is the smoothed (EMA) estimated time-remaining for the current
/// job (v0.5.0). Nil ⇒ cold-start ("estimating…"): fewer than `coldStartFloor`
/// rendering snapshots have been sampled. Frozen (carried over) on non-rendering
/// phases (`.encoding`/`.concatenating`/`.finalizing`) so the banner shows a
/// stable ETA instead of snapping back to "estimating…" mid-finalize. The static
/// `snapshot(from:)` mapper produces `etaSeconds == nil` (pure); the VM's EMA
/// overwrites it per rendering sample. Diagnostic only — does not affect pixels.
public struct ExportProgressSnapshot: Sendable, Equatable {
    public var phase: ExportProgress.Phase
    public var currentFrame: Int
    public var totalFrames: Int
    public var elapsed: TimeInterval
    public var renderFPS: Double
    public var jobIndex: Int
    public var totalJobs: Int
    public var etaSeconds: TimeInterval?

    public var fraction: Double {
        totalFrames > 0 ? Double(currentFrame) / Double(totalFrames) : 0
    }

    public init(phase: ExportProgress.Phase, currentFrame: Int, totalFrames: Int,
                elapsed: TimeInterval, renderFPS: Double, jobIndex: Int, totalJobs: Int,
                etaSeconds: TimeInterval? = nil) {
        self.phase = phase
        self.currentFrame = currentFrame
        self.totalFrames = totalFrames
        self.elapsed = elapsed
        self.renderFPS = renderFPS
        self.jobIndex = jobIndex
        self.totalJobs = totalJobs
        self.etaSeconds = etaSeconds
    }

    /// Identity element (no frames yet). `totalJobs == 1` so `fraction` is 0
    /// (not divide-by-zero); `etaSeconds == nil` (cold-start).
    public static let empty = ExportProgressSnapshot(
        phase: .rendering, currentFrame: 0, totalFrames: 0, elapsed: 0,
        renderFPS: 0, jobIndex: 0, totalJobs: 1, etaSeconds: nil)
}

/// User-facing backend picker for the sheet. `.auto` probes `MetalRenderer.isAvailable`
/// on the MainActor (inside `ExportManager`) and falls back to CPU if Metal is
/// unavailable (spec §4.4 / G6).
public enum BackendChoice: String, Sendable, CaseIterable, Hashable {
    case auto
    case cpu
    case metal
}

/// The testable export view-model (spec §4.4 / G2). `@MainActor @Observable`,
/// held by `AppModel` (survives sheet/window teardown — G9). Wraps ONE
/// `ExportCoordinator` at a time (single concurrent export; `canStart` gates).
///
/// Entry points (`exportSingle`/`exportSequence`/`exportBatch`) are
/// fire-and-forget: they validate the source, resolve settings via the shared
/// `ExportSettings.resolve(…)`, build the `ExportJob(s)`, set `state = .running`,
/// acquire the `ProcessInfo` sleep token (G10), create the coordinator via
/// `coordinatorFactory`, spawn `consumeTask`, and RETURN. The sheet dismisses
/// right after; the export runs on `consumeTask`.
///
/// **Concurrency (Swift 6):** the class is `@MainActor`; `consumeTask` inherits
/// MainActor isolation. The coordinator is an `actor` (or an injected fake);
/// `ExportJob`/`ExportSettings`/`ExportProgress`/`Backend` are `Sendable`.
/// `consumeTask` uses `[weak self]` (AppModel-owned ⇒ not sheet-released; weak
/// still guards app-teardown) and guards `coordinator` (no force-unwrap).
@MainActor
@Observable
public final class ExportManager {
    public private(set) var state: ExportState = .idle
    public private(set) var snapshot: ExportProgressSnapshot = .empty

    /// A transient label for the source (display name / count), for the banner.
    public private(set) var sourceLabel: String = ""

    /// Transparency notice when an export silently dropped unrenderable genomes
    /// (`renderable.count < flames.count`). Nil when nothing was filtered. Set in
    /// `exportSequence`/`exportBatch`; cleared in `reset()`. (Behavior is
    /// unchanged — the export continues with the renderable subset; this only
    /// surfaces the skip so it isn't a silent shortening of the timeline.)
    public private(set) var skipNotice: String?

    /// M6.1 Task 8: true iff the in-flight (or just-finished) export runs the
    /// pausable `.runResumable` path. The banner gates the Pause button on this
    /// (hidden for `.runJob`/`.runBatch` — those have no checkpoint, so a pause
    /// is meaningless). Set in `startExport`/`resume`; cleared on every exit from
    /// the in-flight states (terminal + discard). Read synchronously by the
    /// banner's `runningContent`.
    public private(set) var isPausable: Bool = false

    // The editable config (bound two-way by the sheet):
    public var codec: ExportSettings.Codec = .proRes422HQ
    public var container: ExportSettings.Container = .mov
    public var resolution: ExportSettings.Resolution = .p1080
    public var fps: Int = 30
    public var qualityChoice: ExportQualityChoice = .genomeDefault
    public var backendChoice: BackendChoice = .auto
    /// 1 ⇒ genome default (resolved, motion blur); see `ExportSettings.resolve`.
    public var temporalSamples: Int = 1
    /// M6.1 slice 2 / Task 10: temporal-smoothing toggle. `.auto` ⇒ derive α
    /// from the quality tier via `TemporalSmoothing.alpha(for:)` (the continuous
    /// ramp); `.off` ⇒ force α = 1.0 (byte-identical to the unsmoothed path).
    /// Threaded through `resolveSettings` → `ExportSettings.resolve`. The sheet
    /// binds this two-way (`.auto` ⇄ `.off`); at `.genomeDefault` quality the
    /// toggle is a no-op (α collapses to 1.0 regardless), so the sheet disables
    /// it there. Default `.auto` matches the `ExportSettings.resolve` default.
    public var temporalSmoothing: TemporalSmoothing = .auto
    /// Loop duration in seconds ⇒ `framesPerSegment = round(loopDurationSeconds * fps)`.
    /// Default 15 s — the owner's optimal loop render length. Combined with
    /// `loopRepeatCount == 2`, a 15 s loop renders once (15 s of render cost)
    /// and outputs twice = 30 s perceived, halving the per-second render cost
    /// while staying seamless (`R(360°)=R(0°)`). Above ES "standard" (~11 s @
    /// 30 fps) and short of the ~30 s vigilance-decrement floor. Tunable via
    /// the export sheet stepper (0.1–120 s).
    public var loopDurationSeconds: Double = 15.0
    /// Transition ("edge") duration in seconds ⇒
    /// `transitionFramesPerSegment = round(transitionDurationSeconds * fps)`.
    /// Default 12 s — the owner's optimal edge length. A transition spins both
    /// endpoints a full 360°, so its rotation velocity is
    /// 360°/transitionDuration and the loop→transition boundary is a velocity
    /// jump of `loopDuration/transitionDuration`. At 15 s loop / 12 s edge the
    /// ratio is ~1.25× (gentle); longer edges trade screen time on the morph
    /// for a smoother boundary. Tunable via the export sheet stepper.
    public var transitionDurationSeconds: Double = 12.0
    /// Loop render-once-repeat (v0.5.0). Default 2 — the owner's "15 s render +
    /// repeat×2 = 30 s perceived loop" optimal. Each loop segment renders once
    /// and outputs `loopRepeatCount`× (seamless); transitions never repeat. The
    /// coordinator refuses a repeat>1 job whose per-loop cache would exceed the
    /// safe RAM threshold (`ExportError.loopRepeatMemoryExceeded`); the sheet
    /// surfaces the estimate. 1 = no-op (render every output frame).
    public var loopRepeatCount: Int = 2
    public var bitrate: ExportSettings.Bitrate = .auto

    /// M6.1: checkpoint cadence (frames) for the resumable path. The GUI sheet
    /// stepper binds here (Task 8; range 5–300). Smaller ⇒ finer pause
    /// granularity + less re-render on resume, at the cost of more encoder
    /// sessions. Default 30 — a per-second-at-30fps balance.
    public var checkpointIntervalFrames: Int = 30

    /// M6.1: the most recent paused-export checkpoint URL. Written when the run
    /// pauses (spec §5.4) and cleared on `.completed` / discard / cancel. Task 7
    /// persists this across relaunches via the `writeRememberedCheckpointURL` hook;
    /// here it is the VM-authoritative copy the state machine + tests observe.
    /// `public var` so AppModel (EmberweftGUI) can SEED it from prefs at launch;
    /// every internal MUTATION routes through `setRememberedCheckpointURL(_:)` so
    /// the hook fires (the seed assignment intentionally bypasses the hook — its
    /// value came FROM prefs).
    public var rememberedCheckpointURL: URL?

    /// M6.1 Task 7: write-back hook forwarding every `rememberedCheckpointURL`
    /// mutation to AppPreferences (via AppModel) so it survives relaunches.
    /// Default no-op so the VM stays unit-testable WITHOUT AppPreferences/AppModel;
    /// AppModel installs the real `{ prefs.rememberedCheckpointURL = url; save() }`.
    /// `public` so EmberweftGUI (a separate module) can install the closure.
    public var writeRememberedCheckpointURL: (URL?) -> Void = { _ in }

    // MARK: - In-flight state (private)

    private var coordinator: (any ExportCoordinating)?
    private var consumeTask: Task<Void, Never>?
    private var activityToken: NSObjectProtocol?   // ProcessInfo sleep token (G10)
    /// M6.1: the job + interval captured from the fresh `.runResumable` run, so
    /// `resume()` can re-drive `coord.runResumable(..., resumeFrom: checkpoint)`
    /// without re-issuing the export (the checkpoint's recipe is authoritative
    /// on resume; the VM still passes the original job for `out`/partial paths).
    private var resumableJob: ExportJob?
    private var resumableInterval: Int = 30

    // EMA of per-frame wall-clock duration for the ETA estimate (v0.5.0). Lives
    // in the VM (NOT the coordinator): the coordinator yields raw phase/frame
    // events; only the VM observes wall-clock cadence and computes a smoothed
    // time-remaining. Reset in `startExport` and on terminal transitions.
    // Deterministic (rule #2): the EMA is a pure function of the (scripted/real)
    // snapshot timestamps via `nowProvider` — no hashed-collection float sums.
    private var frameSecondsEMA: Double = 0
    private var lastSnapshotAt: ContinuousClock.Instant?
    private var renderedSinceStart: Int = 0
    private var lastComputedETA: TimeInterval? = nil   // carried over on non-rendering phases
    private let emaAlpha: Double = 0.2          // ~last 8–9 frames dominant (1/alpha ≈ 5)
    private let coldStartFloor: Int = 8         // < this many samples ⇒ "estimating…"

    // MARK: - Test seams

    /// Wall-clock source for the ETA EMA (v0.5.0). Defaults to
    /// `ContinuousClock.now`; tests install a scripted clock so the EMA is a
    /// deterministic pure function of the scripted instants (rule #2).
    internal var nowProvider: () -> ContinuousClock.Instant = { ContinuousClock.now }

    /// Factory for the coordinator. Production constructs
    /// `ExportCoordinator(backend:useOffMainMetal:)` (GUI off-main path). Tests
    /// inject a fake `ExportCoordinating` (no Metal/AVFoundation).
    internal var coordinatorFactory: (
        _ backend: ExportCoordinator.Backend,
        _ useOffMainMetal: Bool
    ) -> any ExportCoordinating = { backend, useOffMainMetal in
        ExportCoordinator(backend: backend, useOffMainMetal: useOffMainMetal)
    }

    /// Sleep-token lifecycle hooks (G10). Defaults perform the REAL
    /// `ProcessInfo` activity (prevents display/system sleep during export).
    /// Tests override to no-ops and observe the counters below.
    internal var beginSleepActivity: () -> NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "Emberweft video export")
    }
    internal var endSleepActivity: (NSObjectProtocol) -> Void = { token in
        ProcessInfo.processInfo.endActivity(token)
    }

    /// Sleep-token counters (spec §9.4 test hooks). The token must be acquired
    /// exactly once at run start and released exactly once on each terminal
    /// state (success, cancel, failure).
    internal private(set) var activityAcquireCount: Int = 0
    internal private(set) var activityReleaseCount: Int = 0

    /// Convenience observers: true iff acquired/released exactly once.
    internal func activityAcquired() -> Bool { activityAcquireCount == 1 }
    internal func activityReleased() -> Bool { activityReleaseCount == 1 }

    public init() {}

    // MARK: - Public predicates

    /// True iff an export can start now. D1 (spec §5.1): excludes the in-flight
    /// states (`.running`/`.cancelling`/`.pausing`) AND `.paused` — a paused
    /// export owns a checkpoint on disk; the user must Discard (or Resume) before
    /// starting a new one (never silently orphan a checkpoint).
    public var canStart: Bool {
        switch state {
        case .running, .cancelling, .pausing, .paused: return false
        default: return true
        }
    }

    /// Resolve the concrete backend (G6). The availability probe is passed in
    /// (callers read `MetalRenderer.isAvailable` on the MainActor); this keeps
    /// the mapping pure + unit-testable without touching MetalRenderer.
    ///
    /// `.auto`/`.metal` fall back to CPU when Metal is unavailable (the sheet
    /// surfaces a notice when the user explicitly picked Metal).
    internal func resolveBackend(metalAvailable: Bool) -> ExportCoordinator.Backend {
        switch backendChoice {
        case .auto:  return metalAvailable ? .metal : .cpu
        case .cpu:   return .cpu
        case .metal: return metalAvailable ? .metal : .cpu
        }
    }

    // MARK: - Source entry points (fire-and-forget)

    /// Export a single genome (one loop). When `sources` is non-empty the run
    /// routes to the M6.1 RESUMABLE path (`.runResumable`): the timeline is
    /// chunked at `checkpointIntervalFrames` edges, a checkpoint is written after
    /// each chunk, and the export is pause/resume/crash-recoverable. When
    /// `sources` is empty (default) the run uses the legacy `.runJob` path
    /// (single continuous encode; byte-identical to the pre-M6.1 behavior). The
    /// GUI (Task 8) threads `LibraryEntry.fileURL`s; the D6-strong path needs
    /// file-backed sources so resume re-reads the exact bytes (SHA-256-gated).
    public func exportSingle(flame: Flame, displayName: String, out: URL, seed: UInt64,
                             sources: [ExportCheckpoint.Source] = []) async {
        guard canStart else { return }
        guard flame.isRenderable else {
            state = .failed("Genome is not renderable (degenerate camera or no xforms).")
            return
        }
        let backend = resolveBackend(metalAvailable: MetalRenderer.isAvailable)
        let settings = resolveSettings(baseFlame: flame, backend: backend)
        let framesPerSegment = max(1, Int(loopDurationSeconds * Double(fps)))
        let transitionFramesPerSegment = max(1, Int(transitionDurationSeconds * Double(fps)))
        let job = ExportJob(
            settings: settings, flames: [flame], framesPerSegment: framesPerSegment,
            transitionFramesPerSegment: transitionFramesPerSegment,
            segmentCount: 1, selector: .sequential, seed: seed,
            loopCycles: 1, stagger: 0.0, out: out, loopRepeatCount: loopRepeatCount)
        if sources.isEmpty {
            startExport(.runJob(job: job), label: displayName, backend: backend)
        } else {
            startExport(.runResumable(job: job, sources: sources,
                                      checkpointIntervalFrames: checkpointIntervalFrames),
                        label: displayName, backend: backend)
        }
    }

    /// Export a sequence (loop + transitions) as one continuous encode. Routed
    /// to `coordinator.run(job)` with `segmentCount == 2N-1`.
    ///
    /// `Schedule` alternates loop/transition by segment-id parity (seg0=loop(g0),
    /// seg1=trans(g0→g1), seg2=loop(g1), …). A full pass through N genomes (each
    /// looped once + transitions between consecutive ones) = N loops + (N−1)
    /// transitions = `2N − 1` segments. Passing only `renderable.count` (N) walked
    /// the first N segments = loop,trans,loop,trans,loop = ⌈(N+1)/2⌉ genomes (the
    /// "3 of 5" truncation bug). N=1 → 1 segment (the single-loop case).
    public func exportSequence(flames: [Flame], displayName: String, out: URL, seed: UInt64,
                               sources: [ExportCheckpoint.Source] = []) async {
        guard canStart else { return }
        let renderable = flames.filter(\.isRenderable)
        guard !renderable.isEmpty else {
            state = .failed("No renderable genomes in the sequence.")
            return
        }
        skipNotice = skipNoticeFor(dropped: flames.count - renderable.count, total: flames.count)
        let baseFlame = renderable[0]   // first renderable (matches CLI renderable[0])
        let backend = resolveBackend(metalAvailable: MetalRenderer.isAvailable)
        let settings = resolveSettings(baseFlame: baseFlame, backend: backend)
        let framesPerSegment = max(1, Int(loopDurationSeconds * Double(fps)))
        let transitionFramesPerSegment = max(1, Int(transitionDurationSeconds * Double(fps)))
        let segmentCount = max(1, 2 * renderable.count - 1)
        let job = ExportJob(
            settings: settings, flames: renderable, framesPerSegment: framesPerSegment,
            transitionFramesPerSegment: transitionFramesPerSegment,
            segmentCount: segmentCount, selector: .sequential, seed: seed,
            loopCycles: 1, stagger: 0.0, out: out, loopRepeatCount: loopRepeatCount)
        if sources.isEmpty {
            startExport(.runJob(job: job), label: displayName, backend: backend)
        } else {
            startExport(.runResumable(job: job, sources: sources,
                                      checkpointIntervalFrames: checkpointIntervalFrames),
                        label: displayName, backend: backend)
        }
    }

    /// Export a batch (one job per item, serial). Routed to
    /// `coordinator.runBatch(jobs, failFast: false)`. Each item's `out` is
    /// resolved via `BatchPath.resolve` (the D13 gate) and deduped within the
    /// batch with a `-2/-3` suffix.
    public func exportBatch(items: [(flame: Flame, name: String)], baseDir: URL, seed: UInt64) async {
        guard canStart else { return }
        let renderable = items.filter { $0.flame.isRenderable }
        guard !renderable.isEmpty else {
            state = .failed("No renderable genomes in the selection.")
            return
        }
        skipNotice = skipNoticeFor(dropped: items.count - renderable.count, total: items.count)
        let backend = resolveBackend(metalAvailable: MetalRenderer.isAvailable)
        let framesPerSegment = max(1, Int(loopDurationSeconds * Double(fps)))
        let transitionFramesPerSegment = max(1, Int(transitionDurationSeconds * Double(fps)))
        var jobs: [ExportJob] = []
        var usedNames = Set<String>()
        for item in renderable {
            let settings = resolveSettings(baseFlame: item.flame, backend: backend)
            let out = resolveBatchOut(name: item.name, baseDir: baseDir, usedNames: &usedNames)
            let job = ExportJob(
                settings: settings, flames: [item.flame], framesPerSegment: framesPerSegment,
                transitionFramesPerSegment: transitionFramesPerSegment,
                segmentCount: 1, selector: .sequential, seed: seed,
                loopCycles: 1, stagger: 0.0, out: out, loopRepeatCount: loopRepeatCount)
            jobs.append(job)
        }
        startExport(.runBatch(jobs: jobs, baseDir: baseDir),
                    label: "\(renderable.count) genome\(renderable.count == 1 ? "" : "s")",
                    backend: backend)
    }

    /// Cancel the in-flight export (D-G13 + M6.1 D3). Now accepts `.running` AND
    /// `.pausing` (cancel is symmetric and always reachable); from `.paused` it
    /// discards the checkpoint + chunks and reaches `.cancelled`. Sets
    /// `.cancelling`, then `await coordinator?.cancel()` (the coordinator's flag
    /// is the authoritative stop — checked between frames/chunks). The in-flight
    /// frame/chunk finishes, the next iteration throws `.cancelled`, and
    /// `consumeTask`'s catch sets `.cancelled` + (for `.runResumable`) discards
    /// the checkpoint (P3 — GUI cancel = abandon; the CLI's SIGINT path does NOT
    /// discard, since it never reaches this VM).
    ///
    /// Does NOT `consumeTask?.cancel()` as the cancel path: the coordinator's
    /// inner `Task` is not a child of `consumeTask`, so `Task.cancel()` does not
    /// reach it; only `coordinator.cancel()` (the flag) does.
    public func cancel() async {
        switch state {
        case .running, .pausing:
            state = .cancelling
            await coordinator?.cancel()
        case .paused(let out, _, _):
            // Cancel-from-paused = discard + done (D3).
            let container = readContainerFromCheckpoint(out: out) ?? .mov
            ExportCoordinator.discardCheckpointAndChunks(out: out, container: container)
            setRememberedCheckpointURL(nil)
            state = .cancelled
            isPausable = false
        default:
            break   // idle/completed/failed/cancelled — no-op
        }
    }

    /// M6.1: request a cooperative pause (spec §5.4). Idempotent under a double-
    /// click (guard `state == .running` ⇒ a second click while `.pausing` is a
    /// no-op). Sets `.pausing`, then `await coordinator?.pause()` (the actor
    /// flag; `runResumableBody` throws `.paused` at the next chunk boundary).
    /// `consumeTask`'s catch then sets `.paused(out, checkpoint, reason: nil)`.
    /// No-op for `.runJob`/`.runBatch` (the legacy paths don't checkpoint; their
    /// run loops ignore the flag — a pause on them is effectively ignored, which
    /// is correct: there's nothing to resume).
    public func pause() async {
        guard state == .running else { return }
        state = .pausing
        await coordinator?.pause()
    }

    /// M6.1: resume a paused export (spec §5.4). Rebuilds a coordinator via
    /// `coordinatorFactory`, reacquires the sleep token (a resume is a new run),
    /// and drives `coord.runResumable(..., resumeFrom: checkpoint)`. The
    /// checkpoint's recipe is authoritative on resume; `sources:` is `[]` (the
    /// checkpoint read in the resume branch supplies the sources — spec §5.3).
    /// No-op unless `.paused`.
    public func resume() async {
        guard case .paused(let out, let checkpoint, _) = state else { return }
        guard let job = resumableJob else { return }
        let interval = resumableInterval
        let backend = resolveBackend(metalAvailable: MetalRenderer.isAvailable)
        let coord = coordinatorFactory(backend, true)
        coordinator = coord
        state = .running
        isPausable = true   // a resumed run is always pausable
        acquireActivity()
        consumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await coord.runResumable(job, sources: [],
                                                      checkpointIntervalFrames: interval,
                                                      resumeFrom: checkpoint)
                for try await event in stream {
                    if Task.isCancelled { break }
                    self.applyETA(to: .single(event))
                }
                self.state = .completed(out)
                self.setRememberedCheckpointURL(nil)
            } catch {
                self.handleRunError(error, out: out, isResumable: true)
            }
            self.releaseActivity()
            self.coordinator = nil
            self.consumeTask = nil
            self.isPausable = false
            self.resetETAState()
        }
    }

    /// M6.1: discard a paused export's checkpoint + chunks and return to idle
    /// (spec §5.4 / D4). No coordinator is needed (pause nilled it) — the static
    /// helper sweeps by the `emberweft-chunk-` prefix beside `out`. Resilient:
    /// `readContainerFromCheckpoint` returns nil ⇒ `.mov` (the GUI mastering
    /// default) so the sweep uses the right extension.
    public func discardPaused() {
        guard case .paused(let out, _, _) = state else { return }
        let container = readContainerFromCheckpoint(out: out) ?? .mov
        ExportCoordinator.discardCheckpointAndChunks(out: out, container: container)
        setRememberedCheckpointURL(nil)
        state = .idle
        snapshot = .empty
        sourceLabel = ""
        isPausable = false
    }

    /// M6.1: read just `settings.container` from the checkpoint beside `out`
    /// (resilient — corrupt/missing ⇒ nil, callers default to `.mov`). Used by
    /// `cancel()`/`discardPaused()` so the chunk sweep uses the right extension
    /// without bloating the `.paused` state enum with a redundant container.
    internal func readContainerFromCheckpoint(out: URL) -> ExportSettings.Container? {
        decodedCheckpoint(out: out)?.settings.container
    }

    /// M6.1 slice 2 / Task 9: decode the FULL checkpoint beside `out` (resilient —
    /// corrupt/missing ⇒ nil). Shared by `readContainerFromCheckpoint` (container
    /// only) and `resumeWarmupNotice` (full checkpoint for the F computation).
    internal func decodedCheckpoint(out: URL) -> ExportCheckpoint? {
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        guard let data = try? Data(contentsOf: cpURL),
              let cp = try? JSONDecoder().decode(ExportCheckpoint.self, from: data) else {
            return nil
        }
        return cp
    }

    /// M6.1 slice 2 / Task 9 (S15): CPU warmup notice for the paused surface.
    /// When the resolved backend is `.cpu`, smoothing is active (α < 1.0), and
    /// there are completed chunks to warm up over (F > 0), returns a notice
    /// estimating the CPU warmup cost before resume. Nil otherwise (Metal resume,
    /// smoothing OFF, fresh run F==0, or not paused). A NOTICE — the resume still
    /// proceeds; this only surfaces the cost so the user can switch to Metal.
    ///
    /// Computed (pure derivation from `state`/`resumableJob`/the checkpoint file):
    /// re-evaluates when `state` changes (the `@Observable` tracking fires on the
    /// `state` read inside). `F` = first global frame of the first incomplete
    /// chunk, matching the coordinator's warmup [0,F) range exactly.
    public var resumeWarmupNotice: String? {
        guard case .paused(let out, _, _) = state else { return nil }
        guard let job = resumableJob else { return nil }
        guard resolveBackend(metalAvailable: MetalRenderer.isAvailable) == .cpu else { return nil }
        guard job.settings.smoothingAlpha < 1.0 else { return nil }
        guard let cp = decodedCheckpoint(out: out) else { return nil }
        let safeInterval = max(1, cp.checkpointIntervalFrames)
        let firstIncomplete = (0..<cp.chunkCount).first { !cp.completedChunkIndexes.contains($0) }
            ?? cp.chunkCount
        let F = min(firstIncomplete * safeInterval, cp.totalGlobalFrames)
        guard F > 0 else { return nil }
        // Rough CPU per-frame render cost (CLAUDE.md: ~6–17 s/frame on CPU).
        let perFrameCPUSeconds = 10.0
        let warmupSeconds = Int(Double(F) * perFrameCPUSeconds)
        return "CPU warmup: ~\(F) frames (~\(warmupSeconds) s) before resume. "
            + "Consider Metal for faster resume."
    }

    /// M6.1 Task 7: the SINGLE funnel for `rememberedCheckpointURL` mutations.
    /// Writes the in-memory authoritative copy AND forwards to the persistence
    /// hook (`writeRememberedCheckpointURL`) so AppPreferences/AppModel stay in
    /// sync. Every state-machine assignment MUST route through here so launch-synth
    /// reflects the last pause and `.completed`/discard/cancel clear it persistently.
    /// (The launch SEED assignment in AppModel bypasses this — its value came FROM
    /// prefs; re-saving would be a redundant no-op.)
    private func setRememberedCheckpointURL(_ url: URL?) {
        rememberedCheckpointURL = url
        writeRememberedCheckpointURL(url)
    }

    /// M6.1 Task 7 / spec §5.5: launch-time synth. If `rememberedCheckpointURL`
    /// points at a checkpoint that exists + decodes, synthesize
    /// `.paused(out:checkpoint:reason:nil)` so the banner offers Resume/Discard
    /// with NO coordinator running (Resume rebuilds it via `coordinatorFactory`).
    /// Missing / corrupt / unreadable ⇒ leave `.idle`, no crash (D14); the stale
    /// remembered URL is cleared via the hook so a later launch doesn't re-try.
    /// Only fires from `.idle` (never overwrites a live state). Called once by
    /// AppModel after seeding the URL + wiring the hook.
    public func synthesizePausedStateIfNeeded() {
        guard state == .idle else { return }
        guard let url = rememberedCheckpointURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            setRememberedCheckpointURL(nil)   // stale — checkpoint gone
            return
        }
        guard let data = try? Data(contentsOf: url),
              let cp = try? JSONDecoder().decode(ExportCheckpoint.self, from: data) else {
            setRememberedCheckpointURL(nil)   // corrupt — no crash (D14)
            return
        }
        // Valid checkpoint ⇒ synthesize .paused. The remembered URL already holds
        // `url` (read above), so no hook re-fire is needed on the success path.
        state = .paused(out: cp.out, checkpoint: url, reason: nil)
    }

    /// Reset to `.idle` (clears snapshot/result so the banner dismisses).
    /// No-op while an export is in flight (safety). D2 (spec §5.1): `.pausing`
    /// behaves like `.running`/`.cancelling` (never reset mid-flight); `.paused`
    /// resets to `.idle` (the caller owns discard via `discardPaused()` — reset
    /// itself does NOT delete the checkpoint, it just clears the transient UI).
    public func reset() {
        switch state {
        case .running, .cancelling, .pausing:
            break
        case .idle, .completed, .failed, .cancelled, .paused:
            state = .idle
            snapshot = .empty
            sourceLabel = ""
            skipNotice = nil
            isPausable = false
        }
    }

    // MARK: - Test/await hook

    /// Blocks until the in-flight `consumeTask` finishes. Production code never
    /// calls this (fire-and-forget). Tests call it to make deterministic
    /// assertions about terminal state without polling.
    internal func awaitCompletion() async {
        // Capture the Task reference before consumeTask self-nilifies at its tail.
        guard let task = consumeTask else { return }
        await task.value
    }

    // MARK: - Internals

    /// What the entry point built. `runJob` covers the legacy single+sequence
    /// path (one continuous encode via `coordinator.run`); `runResumable` (M6.1)
    /// is the chunked+checkpointed single/sequence path (file-backed sources);
    /// `runBatch` covers batch (serial `coordinator.runBatch`).
    private enum ExportKind {
        case runJob(job: ExportJob)
        case runResumable(job: ExportJob, sources: [ExportCheckpoint.Source], checkpointIntervalFrames: Int)
        case runBatch(jobs: [ExportJob], baseDir: URL)
    }

    /// Resolve the concrete `ExportSettings` from the sheet's editable config.
    /// `internal` (not `private`) so `EmberweftUITests` can pin the
    /// `temporalSmoothing` threading (Task 10) — `@testable import` reaches
    /// `internal` but not `private`. Pure value derivation; no I/O.
    internal func resolveSettings(baseFlame: Flame, backend: ExportCoordinator.Backend) -> ExportSettings {
        ExportSettings.resolve(
            quality: qualityChoice.exportQuality,
            temporalSamples: temporalSamples,
            codec: codec, container: container, fps: fps, bitrate: bitrate,
            resolution: resolution, segmentFrameBudget: 0,
            baseFlame: baseFlame, backend: backend,
            temporalSmoothing: temporalSmoothing)
    }

    /// Resolve a batch item's `out` via `BatchPath.resolve` (the D13 gate) and
    /// dedupe within the batch + against existing files with a `-2/-3` suffix.
    ///
    /// `BatchPath.resolve` returns the bare stem with NO extension (it's a generic
    /// name resolver; the GUI adds the container extension, unlike single/sequence
    /// where `NSSavePanel` supplies `.mp4`). The extension is appended here on
    /// both the resolved and sanitized-fallback paths, BEFORE `dedupeOut` so the
    /// deduped `-2/-3` suffix keeps it (mirrors the CLI batch naming). The CLI's
    /// batch path is unaffected — it doesn't route through this method.
    private func resolveBatchOut(name: String, baseDir: URL, usedNames: inout Set<String>) -> URL {
        let ext = container == .mov ? "mov" : "mp4"
        // BatchPath.resolve rejects absolute / `..` / hidden / illegal chars.
        // On rejection (shouldn't happen for curated names) fall back to a safe
        // sanitized leaf so the batch never aborts on one bad name.
        let resolved: URL
        if let ok = try? BatchPath.resolve(name, base: baseDir) {
            resolved = ok.appendingPathExtension(ext)
        } else {
            let safe = name.unicodeScalars
                .filter { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-").contains($0) }
                .map(String.init)
                .joined()
            resolved = baseDir
                .appendingPathComponent(safe.isEmpty ? "output" : safe)
                .appendingPathExtension(ext)
        }
        return dedupeOut(resolved, usedNames: &usedNames)
    }

    /// The transparency notice for silent `isRenderable` skips, or nil when
    /// nothing was filtered (`dropped == 0`).
    private func skipNoticeFor(dropped: Int, total: Int) -> String? {
        dropped > 0 ? "Skipped \(dropped) of \(total) genomes (unrenderable)." : nil
    }

    /// Append `-2`, `-3`, … to avoid collisions within the batch and with
    /// existing files on disk (mirrors the CLI's batch naming).
    private func dedupeOut(_ resolved: URL, usedNames: inout Set<String>) -> URL {
        let dir = resolved.deletingLastPathComponent()
        let stem = resolved.deletingPathExtension().lastPathComponent
        let ext = resolved.pathExtension
        var candidate = resolved
        var n = 2
        let leaf = { (suffix: String) -> String in
            ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
        }
        while usedNames.contains(candidate.lastPathComponent)
              || FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(leaf("-\(n)"))
            n += 1
        }
        usedNames.insert(candidate.lastPathComponent)
        return candidate
    }

    /// Common fire-and-forget driver: set up state + token, spawn `consumeTask`.
    private func startExport(_ kind: ExportKind, label: String, backend: ExportCoordinator.Backend) {
        sourceLabel = label
        snapshot = .empty
        resetETAState()
        let coord = coordinatorFactory(backend, true)
        coordinator = coord
        state = .running
        acquireActivity()
        // Resolve the completion URL + whether this run is resumable BEFORE the
        // Task, so the catch ladder (which runs after a thrown error) can reach
        // them without re-deriving from a partially-consumed `kind`.
        let completionURL: URL
        let isResumable: Bool
        switch kind {
        case .runJob(let job):
            completionURL = job.out; isResumable = false
        case .runResumable(let job, _, let interval):
            completionURL = job.out; isResumable = true
            // Remember for resume(): the checkpoint's recipe is authoritative on
            // resume, but the VM still passes the original job (for `out`) and
            // interval to the coordinator's resume entry. `sources` is consumed
            // by the Task's own switch on `kind` below (re-bound there).
            resumableJob = job
            resumableInterval = interval
        case .runBatch(_, let baseDir):
            completionURL = baseDir; isResumable = false
        }
        isPausable = isResumable   // only `.runResumable` checkpoints ⇒ is pausable
        consumeTask = Task { [weak self] in
            // [weak self] is SAFE here: ExportManager is held by AppModel
            // (app-lifetime @State), so it is never released mid-export. Weak
            // still guards the theoretical app-teardown path.
            guard let self else { return }
            guard let coord = self.coordinator else { return }   // no force-unwrap
            do {
                switch kind {
                case .runJob(let job):
                    let stream = await coord.run(job)
                    for try await event in stream {
                        if Task.isCancelled { break }
                        self.applyETA(to: .single(event))
                    }
                case .runResumable(let job, let sources, let interval):
                    let stream = await coord.runResumable(job, sources: sources,
                                                          checkpointIntervalFrames: interval,
                                                          resumeFrom: nil)
                    for try await event in stream {
                        if Task.isCancelled { break }
                        self.applyETA(to: .single(event))
                    }
                case .runBatch(let jobs, _):
                    let stream = await coord.runBatch(jobs, failFast: false)
                    for try await event in stream {
                        if Task.isCancelled { break }
                        self.applyETA(to: .batch(event))
                    }
                }
                self.state = .completed(completionURL)
                if isResumable {
                    self.setRememberedCheckpointURL(nil)   // clean completion ⇒ no checkpoint to remember
                }
            } catch {
                self.handleRunError(error, out: completionURL, isResumable: isResumable)
            }
            // ALWAYS release the sleep token (G10), then clear the cycle.
            self.releaseActivity()
            self.coordinator = nil
            self.consumeTask = nil   // break self → consumeTask → task → self
            self.isPausable = false   // run ended — banner's Pause no longer applies
            self.resetETAState()     // clear EMA so a later run starts cold
        }
    }

    /// M6.1: the shared error→state catch ladder (spec §5.4 + P3 + P12). Branches
    /// on `isResumable` because the recoverable→`.paused` mapping and the
    /// cancel-discard BOTH apply ONLY to `.runResumable` runs (the only kind with
    /// a checkpoint). For `.runJob`/`.runBatch` the existing `.failed`/`.cancelled`
    /// mapping is preserved verbatim (no checkpoint exists).
    ///
    /// - P12: `.diskFull`/`.encodeFailed`/`.metalUnavailable` ⇒ `.paused(reason:)`
    ///   when resumable (checkpoint survives for resume, D7); ⇒ `.failed` otherwise.
    /// - P3: `.cancelled` ⇒ `.cancelled` AND discards checkpoint+chunks when
    ///   resumable (D3 GUI-cancel-deletes; the CLI SIGINT path never reaches here).
    /// - `.paused` (cooperative) ⇒ `.paused(out, checkpoint, reason: nil)`.
    /// - `.checkpointSourceChanged`/`.checkpointUnreadable`/`.checkpointSchemaUnsupported`
    ///   ⇒ `.failed` (terminal; the checkpoint can't be used).
    private func handleRunError(_ error: Error, out: URL, isResumable: Bool) {
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        switch error {
        case is CancellationError:
            state = .cancelled
            if isResumable {
                let container = readContainerFromCheckpoint(out: out) ?? .mov
                ExportCoordinator.discardCheckpointAndChunks(out: out, container: container)
            }
            setRememberedCheckpointURL(nil)
        case ExportError.cancelled:
            state = .cancelled
            if isResumable {   // P3: GUI cancel = abandon (D3)
                let container = readContainerFromCheckpoint(out: out) ?? .mov
                ExportCoordinator.discardCheckpointAndChunks(out: out, container: container)
            }
            setRememberedCheckpointURL(nil)
        case ExportError.paused:   // cooperative pause (only reachable from .runResumable)
            state = .paused(out: out, checkpoint: cpURL, reason: nil)
            setRememberedCheckpointURL(cpURL)
        case ExportError.diskFull:
            if isResumable {
                state = .paused(out: out, checkpoint: cpURL,
                                reason: "Not enough free disk space. Free space and resume.")
                setRememberedCheckpointURL(cpURL)
            } else {
                state = .failed("Not enough free disk space.")
            }
        case ExportError.encodeFailed:
            if isResumable {
                state = .paused(out: out, checkpoint: cpURL,
                                reason: "The video encoder failed. Resume from the last checkpoint.")
                setRememberedCheckpointURL(cpURL)
            } else {
                state = .failed("The video encoder encountered an error.")
            }
        case ExportError.metalUnavailable:
            if isResumable {
                state = .paused(out: out, checkpoint: cpURL,
                                reason: "Metal is unavailable. Switch to CPU and resume.")
                setRememberedCheckpointURL(cpURL)
            } else {
                state = .failed("Metal is unavailable. Try the CPU backend.")
            }
        case ExportError.checkpointSourceChanged:
            state = .failed("A source genome changed since the export was paused.")
            setRememberedCheckpointURL(nil)
        case ExportError.checkpointUnreadable:
            state = .failed("The export checkpoint is unreadable. Start a new export.")
            setRememberedCheckpointURL(nil)
        case ExportError.checkpointSchemaUnsupported:
            state = .failed("The export checkpoint format is unsupported by this version.")
            setRememberedCheckpointURL(nil)
        default:
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - ETA EMA (v0.5.0)

    /// Zero the EMA state (called at run start and on terminal transition).
    private func resetETAState() {
        frameSecondsEMA = 0
        lastSnapshotAt = nil
        renderedSinceStart = 0
        lastComputedETA = nil
    }

    /// Normalize the event to a snapshot, then overlay the ETA estimate. For
    /// `.rendering` snapshots, advance the EMA of per-frame wall-clock duration
    /// and compute `etaSeconds = remaining × EMA` once past the cold-start floor.
    /// For non-rendering phases, freeze `etaSeconds` at its last computed value
    /// (the banner shows "Finalizing…" regardless). The static `snapshot(from:)`
    /// mapper stays pure (produces `etaSeconds == nil`); this method overwrites.
    private func applyETA(to event: ProgressEvent) {
        var snap = Self.snapshot(from: event)
        if snap.phase == .rendering {
            let now = nowProvider()
            // First sample has no delta (cold start) → dt = 0, so the EMA ramps
            // from 0 over the next several frames (the cold-start floor absorbs
            // this transient before any ETA is shown).
            let dtSeconds = lastSnapshotAt.map { Self.seconds(from: now - $0) } ?? 0
            // Clamp a single stalled frame so one outlier can't blow up the ETA.
            // Only after the EMA has a real value (don't clamp during cold start,
            // where frameSecondsEMA is still 0).
            let effectiveDt = frameSecondsEMA > 0
                ? min(dtSeconds, 3 * frameSecondsEMA)
                : dtSeconds
            frameSecondsEMA = emaAlpha * effectiveDt + (1 - emaAlpha) * frameSecondsEMA
            renderedSinceStart += 1
            lastSnapshotAt = now
            if renderedSinceStart >= coldStartFloor {
                let remaining = max(0, snap.totalFrames - snap.currentFrame)
                let eta = Double(remaining) * frameSecondsEMA
                snap.etaSeconds = eta
                lastComputedETA = eta
            } else {
                snap.etaSeconds = nil   // cold start — "estimating…"
            }
        } else {
            // Non-rendering phase: freeze etaSeconds at the last computed value
            // (carried over), so the banner doesn't snap to "estimating…".
            snap.etaSeconds = lastComputedETA
        }
        self.snapshot = snap
    }

    /// Duration → seconds (Double). `Duration.components` splits into
    /// (seconds, attoseconds); recombine for a single Double.
    private static func seconds(from duration: Duration) -> Double {
        let (s, attos) = duration.components
        return Double(s) + Double(attos) / 1e18
    }

    private func acquireActivity() {
        activityToken = beginSleepActivity()
        activityAcquireCount += 1
    }

    private func releaseActivity() {
        if let token = activityToken {
            endSleepActivity(token)
            activityToken = nil
            activityReleaseCount += 1
        }
    }

    /// Pure normalization of either event type into a snapshot (rule #2 — pure
    /// value mapping, no Dict/Set iteration). Single/sequence events normalize
    /// to `jobIndex == 0, totalJobs == 1`; batch events carry their own.
    internal static func snapshot(from event: ProgressEvent) -> ExportProgressSnapshot {
        switch event {
        case .single(let p):
            return ExportProgressSnapshot(
                phase: p.phase, currentFrame: p.currentFrame, totalFrames: p.totalFrames,
                elapsed: p.elapsed, renderFPS: p.renderFPS,
                jobIndex: 0, totalJobs: 1)
        case .batch(let b):
            return ExportProgressSnapshot(
                phase: .rendering, currentFrame: b.jobFrame, totalFrames: b.jobTotalFrames,
                elapsed: 0, renderFPS: 0,
                jobIndex: b.jobIndex, totalJobs: b.totalJobs)
        }
    }
}

/// Internal sum type for `snapshot(from:)` (the two stream element types).
internal enum ProgressEvent {
    case single(ExportProgress)
    case batch(BatchProgress)
}
