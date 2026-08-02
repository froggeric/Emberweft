import Foundation
import FlameKit
import FlamePlayer

/// Owns one realtime preview session for a `PlaybackView` — a **single-genome
/// loop** driven by position, not the multi-genome `PlaybackDispatcher`.
///
/// The click-to-play preview is `librarySize: 1` (one loop), so playback is just
/// `Loop.blend(flame, t:)` over `t ∈ [0,1]`. Driving `position` directly gives
/// play / pause / scrub trivially and deterministically, without extending the
/// validated dispatcher with pause/seek. The dispatcher + `FlamePlayerTests`
/// remain available for future multi-genome sequencing.
///
/// **Isolation contract:** `@MainActor @Observable` (owns the `FlameUI` NSView).
/// `loopTask = Task { … }` is created in a `@MainActor` context → inherits
/// MainActor isolation; all reads of `position`/`flame`/`isPlaying` and the
/// `sinkView.present` call are on the main actor. No `nonisolated(unsafe)`.
///
/// **Inert body:** the SwiftUI body observes only `isPlaying` + `position`.
/// `FlameUIView` captures the `sinkView` once and never reads VM state, so
/// per-frame presentation does NOT flow through SwiftUI — only the transport
/// slider (bound to `position`) re-evaluates per frame.
@MainActor
@Observable
public final class PlaybackViewModel {

    public let sinkView = FlameUI()

    public private(set) var isPlaying = false
    public var position: Double = 0          // 0…1; the transport slider binds here
    public var cycles: Int = 1               // loop rotations over [0,1]

    /// Live measured framerate (rolling average, ~2 Hz publish — see `FPSMeter`).
    /// Diagnostic only: 0 while paused/loading (the readout shows an em dash).
    public private(set) var measuredFPS: Double = 0

    private var flame: Flame?
    private var params: RenderParams = RenderParams(seed: 1, width: 1, height: 1,
                                                    oversample: 1, samplesPerPixel: 1)
    private var renderer: any Renderer = CPUFrameRenderer()
    /// Read-only outside `load` — the transport readouts (frame N/total, M:SS)
    /// and `nudgeFrame` derive from these. `public private(set)`.
    public private(set) var targetFPS: Double = 60
    public private(set) var framesPerSegment: Int = 160
    private var clock: any PlaybackClock = WallClock()
    private var loopTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var fpsMeter = FPSMeter()

    public init() {}

    // MARK: - Load

    /// Stage a flame + params for playback (does not start). The first frame
    /// renders when `play()` begins the loop (or on an explicit `scrub`/`renderOnce`).
    public func load(flame: Flame,
                     params: RenderParams,
                     backend: AppPreferences.Backend,
                     targetFPS: Double,
                     framesPerSegment: Int = 160,
                     cycles: Int = 1) {
        self.flame = flame
        self.params = params
        self.renderer = (backend == .metal) ? MetalFrameRenderer() : CPUFrameRenderer()
        self.targetFPS = targetFPS
        self.framesPerSegment = framesPerSegment
        self.cycles = cycles
        self.position = 0
        fpsMeter.reset()
        measuredFPS = 0
    }

    /// Hot-swap render params / backend / target FPS mid-playback WITHOUT resetting
    /// position or play state — the loop picks up `params`/`targetFPS` on the next
    /// frame. Used by the preview-quality popover so the user can tune and watch
    /// the FPS readout respond live. The FPS meter is left running (its rolling
    /// average adapts to the new frame cost over ~0.5 s, a smooth transition
    /// rather than a "—" blip per tweak). Determinism is per-frame (rule #2): a
    /// given `position` + `params` always renders the same pixels.
    public func updateParams(_ params: RenderParams,
                             backend: AppPreferences.Backend,
                             targetFPS: Double) {
        self.params = params
        self.renderer = (backend == .metal) ? MetalFrameRenderer() : CPUFrameRenderer()
        self.targetFPS = targetFPS
    }

    // MARK: - Transport

    public func play() {
        guard flame != nil, !isPlaying else { return }
        isPlaying = true
        startLoop()
    }

    public func pause() {
        isPlaying = false
        loopTask?.cancel()
        loopTask = nil
        fpsMeter.reset()
        measuredFPS = 0
    }

    public func togglePlaying() { isPlaying ? pause() : play() }

    /// Set the loop position (0…1). While **paused**, renders that frame on
    /// demand (scrub). While playing, the loop picks the new position up next frame.
    public func scrub(to p: Double) async {
        position = min(max(p, 0), 1)
        if !isPlaying { await renderOnce(at: position) }
    }

    /// Step the loop position by `delta` whole frames (←/→ keys). One frame =
    /// `1/framesPerSegment` of the loop. Delegates to `scrub(to:)`, so it clamps
    /// to `[0,1]` and renders once while paused (and while playing just advances
    /// `position` — the loop picks it up next frame). Deterministic (rule #2).
    public func nudgeFrame(_ delta: Int) async {
        guard framesPerSegment > 0 else { return }
        let step = Double(delta) / Double(framesPerSegment)
        await scrub(to: position + step)
    }

    /// Render one frame at `p` (pure `Loop.blend` → renderer → layer). Deterministic
    /// at fixed seed: same `flame`/`params`/`p` ⇒ identical pixels.
    public func renderOnce(at p: Double) async {
        guard let flame, flame.isRenderable else { return }
        let blended = Loop.blend(flame, t: min(max(p, 0), 1), cycles: cycles)
        let image = await renderer.render(flame: blended, params: params)
        sinkView.present(image)
    }

    public func stop() async {
        isPlaying = false
        loopTask?.cancel()
        loopTask = nil
        position = 0
        fpsMeter.reset()
        measuredFPS = 0
    }

    /// Fire-and-forget teardown for `.onDisappear`. Captures self STRONGLY: the VM
    /// is `@State` owned by the sheet, and on dismissal SwiftUI may release it
    /// before a `[weak self]` task can run — leaking the loop task. Strong self
    /// keeps it alive just long enough to stop; the task clears `stopTask` on
    /// completion, breaking the self→stopTask→task→self cycle.
    public func beginStop() {
        guard stopTask == nil else { return }
        stopTask = Task {
            await self.stop()
            self.stopTask = nil
        }
    }

    /// Test-visible: is the play loop currently alive?
    internal var debugLoopAlive: Bool {
        loopTask != nil && !(loopTask?.isCancelled ?? true)
    }

    /// Test hooks: inject a fake renderer / clock (no Metal, no real sleep).
    internal func setRenderer(_ r: any Renderer) { renderer = r }
    internal func setClock(_ c: any PlaybackClock) { clock = c }

    // MARK: - Loop

    private func startLoop() {
        loopTask?.cancel()
        let fps = framesPerSegment
        let startN = Int((position * Double(fps)).rounded())   // resume from position
        loopTask = Task { [weak self] in
            guard let self else { return }
            let origin = self.clock.now()
            var n = startN
            while !Task.isCancelled {
                let p = Double(n).truncatingRemainder(dividingBy: Double(fps)) / Double(fps)
                self.position = p
                await self.renderOnce(at: p)
                if let measured = self.fpsMeter.record(now: self.clock.now()) {
                    self.measuredFPS = measured
                }
                if !self.isPlaying || Task.isCancelled { break }
                n += 1
                await self.clock.sleep(until: origin + Double(n) / self.targetFPS)
            }
        }
    }
}
