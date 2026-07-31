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

    private var flame: Flame?
    private var params: RenderParams = RenderParams(seed: 1, width: 1, height: 1,
                                                    oversample: 1, samplesPerPixel: 1)
    private var renderer: any Renderer = CPUFrameRenderer()
    private var targetFPS: Double = 60
    private var framesPerSegment: Int = 160
    private var clock: any PlaybackClock = WallClock()
    private var loopTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

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
    }

    public func togglePlaying() { isPlaying ? pause() : play() }

    /// Set the loop position (0…1). While **paused**, renders that frame on
    /// demand (scrub). While playing, the loop picks the new position up next frame.
    public func scrub(to p: Double) async {
        position = min(max(p, 0), 1)
        if !isPlaying { await renderOnce(at: position) }
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
                if !self.isPlaying || Task.isCancelled { break }
                n += 1
                await self.clock.sleep(until: origin + Double(n) / self.targetFPS)
            }
        }
    }
}
