import Foundation
import FlameKit
import FlamePlayer

/// Owns one realtime **multi-genome sequence** session for a collection's
/// "Play as Sequence" window — the playlist counterpart of `PlaybackViewModel`.
///
/// Where `PlaybackViewModel` drives a single-genome loop by hand (position over
/// `Loop.blend`), this view-model drives the validated `PlaybackDispatcher` over
/// the collection's resolved genomes: a `Schedule(librarySize:, selector:
/// Sequential(seed:), …)` with loop+transition segments, an
/// `ArrayFlameProvider` over the pre-loaded flames, and the production
/// `Renderer` / `FlameUI` sink / `WallClock`. The dispatcher is exactly the
/// multi-genome sequencer this feature needs; it is NOT extended.
///
/// **Isolation contract (mirrors `PlaybackViewModel`):** `@MainActor
/// @Observable` (owns the `FlameUI` NSView). `runTask = Task { … }` is created in
/// a `@MainActor` context → inherits MainActor isolation; all reads of VM state
/// and the `sinkView.present` path are on the main actor. No
/// `nonisolated(unsafe)`.
///
/// **Inert body:** the SwiftUI body observes only `isPlaying` / `position` /
/// `loadState`. Frames flow `dispatcher → sink.display → metalLayer.contents`
/// entirely outside SwiftUI, so per-frame presentation does NOT flow through the
/// body — only the transport (bound to `position`) re-evaluates.
///
/// **Pause/resume (documented v1 limitation):** pause cancels the run loop; the
/// dispatcher (and its `globalFrame`) are preserved, so resume continues the
/// sequence in place. The dispatcher paces to a wall-clock origin set on first
/// run, so after a LONG pause, resume may briefly fast-forward to catch up to
/// real time (short pauses are seamless — the origin is only marginally in the
/// past). This is the same dispatcher pacing `PlaybackViewModel` deliberately
/// avoids for single-genome pause/seek; here the payoff (validated multi-genome
/// sequencing) is worth the trade. `restart()` does a clean teardown + replay
/// from the first genome for users who want a fresh start.
@MainActor
@Observable
public final class SequencePlaybackViewModel {

    public let sinkView = FlameUI()

    public private(set) var isPlaying = false
    /// Within-segment blend `0…1` (loop rotation / transition morph), updated per
    /// frame via the sink. The transport slider binds here.
    public var position: Double = 0
    /// `nil` while loading / loaded OK; set when the collection has no renderable
    /// genomes. The window shows an error placeholder when non-nil.
    public private(set) var loadError: String?
    public private(set) var sheepCount: Int = 0
    public private(set) var currentSheep: Int = 0

    /// Live measured framerate (rolling average, ~2 Hz publish — see `FPSMeter`).
    /// Diagnostic only: 0 while paused/loading. Measured at display time (the
    /// dispatcher paces frames internally; this reports the achieved cadence).
    public private(set) var measuredFPS: Double = 0

    /// Read-only view of the loaded flames (M6 export wiring — spec §4.8). The
    /// collection window resolves + loads genomes up front in `load(flames:prefs:)`;
    /// this exposes them to the Export sheet without a behavior change. Empty while
    /// loading / when the collection has no renderable genomes.
    public var resolvedFlames: [Flame] { flames }

    private var flames: [Flame] = []
    private var dispatcher: PlaybackDispatcher?
    private var runTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var renderer: any Renderer = CPUFrameRenderer()
    private var params: RenderParams = RenderParams(seed: 1, width: 1, height: 1,
                                                    oversample: 1, samplesPerPixel: 1)
    /// Read-only outside `load` — the FPS readout's band target.
    public private(set) var targetFPS: Double = 60
    private var framesPerSegment: Int = 160
    private var fpsMeter = FPSMeter()
    private let fpsClock = WallClock()

    public init() {}

    // MARK: - Load

    /// Stage the resolved, pre-loaded flames for a collection and build the
    /// dispatcher (does not start). Non-renderable / empty lists surface as a
    /// `LoadState.failed` so the window can show a clean message.
    public func load(flames: [Flame], prefs: AppPreferences) {
        self.flames = flames
        self.prefsSeed = prefs.seed
        self.params = prefs.previewParams()
        self.renderer = (prefs.backend == .metal) ? MetalFrameRenderer() : CPUFrameRenderer()
        self.targetFPS = Double(prefs.targetFPS)
        self.framesPerSegment = 160
        self.sheepCount = flames.count
        self.position = 0
        fpsMeter.reset()
        measuredFPS = 0
        if flames.isEmpty {
            loadError = "This collection has no renderable genomes."
        } else {
            buildDispatcher()
        }
    }

    private func buildDispatcher() {
        // Sequential selector ⇒ an ordered, cyclic walk of the playlist
        // (genome 0 → 1 → … → n-1 → 0). Deterministic (rule #2): the walk is fixed
        // by librarySize + seed, independent of any hashed collection.
        var schedule = Schedule(librarySize: flames.count,
                                framesPerSegment: framesPerSegment,
                                selector: Sequential(seed: prefsSeed),
                                seed: prefsSeed)
        // The dispatcher materializes segments lazily as `globalFrame` advances;
        // pre-walking segment 0 keeps `schedule.currentSheep` at 0 (start).
        _ = schedule.segment(at: 0)
        let provider = ArrayFlameProvider(flames: flames)
        let sink = SequenceSink(vm: self, sink: sinkView)
        dispatcher = PlaybackDispatcher(
            schedule: schedule,
            sheepProvider: provider,
            renderer: renderer,
            sink: sink,
            clock: WallClock(),
            params: params,
            targetFPS: targetFPS)
    }

    // MARK: - Transport

    public func play() {
        guard dispatcher != nil, !isPlaying else { return }
        isPlaying = true
        startLoop()
    }

    public func pause() {
        isPlaying = false
        runTask?.cancel()
        runTask = nil
        fpsMeter.reset()
        measuredFPS = 0
    }

    public func togglePlaying() { isPlaying ? pause() : play() }

    /// Clean replay from the first genome: tear down the dispatcher + build a
    /// fresh one (new wall-clock origin), then play. Sidesteps the catch-up
    /// behavior of resume after a long pause.
    public func restart() {
        runTask?.cancel(); runTask = nil
        dispatcher = nil
        isPlaying = false
        position = 0
        fpsMeter.reset()
        measuredFPS = 0
        if !flames.isEmpty { buildDispatcher(); play() }
    }

    /// Apply new preview params (preset/quality/target-FPS/backend change from the
    /// preview-quality popover). The dispatcher captures params at build time and
    /// paces to `targetFPS`, so a live swap isn't supported — this rebuilds it with
    /// the new params and RESUMES if the user was playing (position resets to the
    /// first genome; the FPS readout then reflects the new quality). If paused,
    /// the rebuild is staged and applies on the next `play()`.
    public func updateParams(prefs: AppPreferences) {
        let wasPlaying = isPlaying
        self.params = prefs.previewParams()
        self.renderer = (prefs.backend == .metal) ? MetalFrameRenderer() : CPUFrameRenderer()
        self.targetFPS = Double(prefs.targetFPS)
        runTask?.cancel(); runTask = nil
        dispatcher = nil
        isPlaying = false
        position = 0
        fpsMeter.reset()
        measuredFPS = 0
        guard !flames.isEmpty else { return }
        buildDispatcher()
        if wasPlaying { play() }
    }

    /// Fire-and-forget teardown for `.onDisappear` (strong self — see
    /// `PlaybackViewModel.beginStop` rationale: keeps the VM alive long enough to
    /// quiesce the dispatcher; the task then clears itself).
    public func beginStop() {
        guard stopTask == nil else { return }
        stopTask = Task {
            await self.stop()
            self.stopTask = nil
        }
    }

    public func stop() async {
        isPlaying = false
        runTask?.cancel()
        runTask = nil
        fpsMeter.reset()
        measuredFPS = 0
        await dispatcher?.stop()
    }

    // MARK: - Per-frame position (called from the MainActor sink)

    /// Record the latest frame: update the within-segment position + current
    /// sheep index for the transport readout. `info.blend ∈ (0, 1]`.
    fileprivate func consumeFrame(_ info: FrameInfo) {
        position = info.blend
        // Loop segment ids are even; the sheep for loop segment `s` is `s/2`.
        if info.kind == .loop { currentSheep = info.segmentId / 2 % max(sheepCount, 1) }
        if let measured = fpsMeter.record(now: fpsClock.now()) {
            measuredFPS = measured
        }
    }

    // MARK: - Run loop

    /// Drive the dispatcher in bounded batches. The dispatcher paces each frame
    /// internally (deadline = origin + globalFrame / fps); the batch size only
    /// bounds how often this loop re-enters the actor. Cooperative cancellation:
    /// `pause()`/`stop()` cancel this task, which the dispatcher's internal
    /// `Task.isCancelled` check honors at the next frame.
    private func startLoop() {
        runTask?.cancel()
        guard let dispatcher else { return }
        let batch = max(framesPerSegment, 60)
        runTask = Task { [weak self, dispatcher] in
            while !(Task.isCancelled) {
                await dispatcher.run(frameCount: batch)
                guard let self, self.isPlaying else { break }
            }
        }
    }

    /// Seed reserved for the `Sequential` selector (recorded for reproducibility;
    /// `Sequential` itself ignores it — its walk is fixed by `librarySize`).
    /// Captured from `prefs.seed` in `load(flames:prefs:)` so `restart()` can
    /// rebuild with the same seed without re-reading prefs.
    private var prefsSeed: UInt64 = 1

    /// Test-visible: is the play loop currently alive?
    internal var debugLoopAlive: Bool {
        runTask != nil && !(runTask?.isCancelled ?? true)
    }
}

// MARK: - Indexed flame provider

/// `SheepProvider` over a pre-loaded array of flames. The collection window
/// resolves + loads genomes up front (filtering non-renderable ones), so the
/// provider just indexes — no on-demand parse, no non-optional-Flame fallback
/// edge cases. `Flame` is `Sendable`; the struct is `Sendable`.
private struct ArrayFlameProvider: SheepProvider {
    let flames: [Flame]
    func sheep(at index: Int) async -> Flame {
        // Defensive clamp (the dispatcher only asks for `0..<librarySize`).
        flames[min(max(index, 0), max(flames.count - 1, 0))]
    }
}

// MARK: - Position-tracking sink

/// `FrameSink` wrapper that delegates presentation to the `FlameUI` and records
/// the frame info on the view-model (weakly — breaks the VM→dispatcher→sink→VM
/// cycle; if the VM is gone, the sink no-ops). `@MainActor` ⇒ implicitly
/// `Sendable`, satisfying `FrameSink: Sendable`.
@MainActor
private final class SequenceSink: FrameSink {
    private weak var vm: SequencePlaybackViewModel?
    private let sink: FlameUI

    init(vm: SequencePlaybackViewModel, sink: FlameUI) {
        self.vm = vm
        self.sink = sink
    }

    func display(_ image: RGBA8Image, info: FrameInfo) async -> Void {
        await sink.display(image, info: info)
        vm?.consumeFrame(info)
    }
}
