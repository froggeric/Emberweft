import Foundation
import FlameKit
import FlamePlayer

/// Owns one realtime playback session for a `PlaybackView`.
///
/// `@MainActor @Observable` (it owns the `FlameUI` NSView, which is `@MainActor`).
/// Invariant: **at most one live `PlaybackDispatcher`** per view-model. `start()`
/// tears down any prior session before building a new one; `stop()` is idempotent.
///
/// Inert-body guarantee (rule for the thin realtime gate): the only published
/// property is `isPlaying`, which flips on start/stop — never per frame. Frame
/// info from `FlameUI` is NOT published through the view body.
@MainActor
@Observable
public final class PlaybackViewModel {

    public let sinkView = FlameUI()

    public private(set) var isPlaying = false

    private var dispatcher: PlaybackDispatcher?
    private var runTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    public init() {}

    /// Begin loop-only playback of `flame`. Tears down any existing session first
    /// (≤1 dispatcher invariant). Loop segment length defaults to 160 frames
    /// (the realtime ES budget).
    public func start(flame: Flame,
                      params: RenderParams,
                      backend: AppPreferences.Backend,
                      targetFPS: Double,
                      framesPerSegment: Int = 160,
                      seed: UInt64 = 1) async {
        await stop()  // guarantee no prior dispatcher outlives this start

        let provider = SingleFlameProvider(flame)
        let renderer: any Renderer = (backend == .metal) ? MetalFrameRenderer() : CPUFrameRenderer()
        let schedule = Schedule(
            librarySize: 1,
            framesPerSegment: framesPerSegment,
            selector: Sequential(seed: seed),
            seed: seed)
        let dispatcher = PlaybackDispatcher(
            schedule: schedule,
            sheepProvider: provider,
            renderer: renderer,
            sink: sinkView,
            clock: WallClock(),
            params: params,
            targetFPS: targetFPS)

        self.dispatcher = dispatcher
        isPlaying = true

        runTask = Task { [weak self, weak dispatcher] in
            await dispatcher?.run(frameCount: .max)
            // When the run ends (cancel/stop), clear state if still current.
            guard let self else { return }
            await self.runDidEnd(dispatcher)
        }
    }

    /// Idempotent teardown: cancel the run, await `dispatcher.stop()` (settles
    /// any in-flight prefetch), drop references.
    public func stop() async {
        runTask?.cancel()
        await dispatcher?.stop()
        dispatcher = nil
        runTask = nil
        isPlaying = false
    }

    /// Fire-and-forget teardown for synchronous SwiftUI lifecycle hooks
    /// (`.onDisappear`). Stores the `Task` on `self` and captures `self`
    /// STRONGLY: the view-model is `@State` owned by the sheet, and on dismissal
    /// SwiftUI may release it before a `[weak self]` task can run — which would
    /// leak the dispatcher (its infinite `run` loop stays alive via the in-flight
    /// async call, keeping the GPU busy forever). Strong self keeps the vm alive
    /// just long enough for `stop()` to settle and quiesce the dispatcher. The
    /// task clears `stopTask` on completion, breaking the self→stopTask→task→self
    /// cycle.
    public func beginStop() {
        guard stopTask == nil else { return }
        stopTask = Task {
            await self.stop()
            self.stopTask = nil
        }
    }

    /// Test-visible count of live dispatchers (0 or 1).
    internal var debugDispatcherCount: Int { dispatcher == nil ? 0 : 1 }

    // MARK: - Internals

    private func runDidEnd(_ expected: PlaybackDispatcher?) async {
        // Only clear if this run was for the still-current dispatcher.
        guard dispatcher === expected else { return }
        dispatcher = nil
        runTask = nil
        isPlaying = false
    }
}
