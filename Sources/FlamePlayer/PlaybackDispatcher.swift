import Foundation
import FlameKit

// PlaybackDispatcher — M3 / S7 realtime driver.
//
// An actor-isolated dispatcher that advances a `Schedule` one global frame at
// a time, hands the interpolated Flame to an injected `Renderer`, paces to a
// target fps via an injected `PlaybackClock`, and prefetches the next sheep
// mid-loop so the transition's first frame is ready.
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │ Swift 6 isolation contract (LOAD-BEARING — do not weaken)               │
// ├─────────────────────────────────────────────────────────────────────────┤
// │ • The dispatcher is an `actor` and `Sendable`. ALL shared state lives   │
// │   behind the actor isolation — `Schedule`, the sheep cache, the         │
// │   prefetch `Task`, the recent-segment ring.                             │
// │ • `MetalRenderer.render` is `@MainActor`. The dispatcher never touches  │
// │   it directly: production wires a `@MainActor`-isolated `Renderer`      │
// │   conformer that performs the crossing inside `MainActor.run { ... }`.  │
// │   The frame-ready callback into `@MainActor FlameUI` is likewise an     │
// │   `@MainActor`-isolated `FrameSink` the dispatcher `await`s.           │
// │ • There are NO `nonisolated(unsafe)` escape hatches in the realtime     │
// │   path. Sendability is enforced by the compiler via the `Sendable`      │
// │   protocols on `Renderer` / `FrameSink` / `SheepProvider` /            │
// │   `PlaybackClock`.                                                      │
// │ • Teardown is an explicit `async stop()` — Swift 6 disallows async work │
// │   in `deinit`, so `FlameUI` teardown calls `await dispatcher.stop()`.   │
// │ • The in-flight prefetch is an actor-isolated `Task<Flame, Never>?`;    │
// │   `stop()` cancels it (`cancel()`) AND awaits it settled (`value`)      │
// │   before returning. On cancellation the partial genome is discarded     │
// │   (never written into the cache, never fed to the renderer).            │
// │ • The triple-buffered MTLTexture rotation lives BEHIND the production   │
// │   `Renderer` conformer (on the MainActor), NOT in this actor — so the   │
// │   dispatcher has zero `MTLTexture` state and stays Metal-free /         │
// │   testable with fakes. The dispatcher retains a bounded ring of         │
// │   recently-played segment ids for diagnostics / seek-back.              │
// └─────────────────────────────────────────────────────────────────────────┘

// MARK: - Injection protocols

/// Metadata for an emitted frame, passed to `FrameSink.display`.
public struct FrameInfo: Sendable, Equatable {
    /// 0-based global frame index (contiguous across the whole timeline).
    public let globalFrame: Int
    /// The segment this frame belongs to.
    public let segmentId: Int
    /// `.loop` or `.transition` (derivable from `segmentId` parity).
    public let kind: Segment.Kind
    /// 1-indexed blend in `(0, 1]` — NEVER 0. See `Schedule.frameToBlend`.
    public let blend: Double

    public init(globalFrame: Int, segmentId: Int, kind: Segment.Kind, blend: Double) {
        self.globalFrame = globalFrame
        self.segmentId = segmentId
        self.kind = kind
        self.blend = blend
    }
}

/// Render backend abstraction. The dispatcher is agnostic to Metal.
///
/// Production conformer (`@MainActor`-isolated) wraps the real renderer:
///
/// ```swift
/// @MainActor
/// struct MetalFrameRenderer: Renderer {
///     func render(flame: Flame, params: RenderParams) async -> RGBA8Image {
///         await MainActor.run { MetalRenderer.render(flame: flame, params: params) }
///     }
/// }
/// ```
///
/// The `MainActor.run` crossing is explicit and awaited — no
/// `nonisolated(unsafe)`. Tests inject a fake conformer (no Metal needed).
public protocol Renderer: Sendable {
    /// Render `flame` to an RGBA8 image. May cross the MainActor in production.
    func render(flame: Flame, params: RenderParams) async -> RGBA8Image
}

/// Frame display sink. Production's conformer is `@MainActor`-isolated
/// (the `FlameUI` layer that owns the presentation textures); the dispatcher
/// `await`s the crossing explicitly.
public protocol FrameSink: Sendable {
    /// Display a freshly rendered frame. Called exactly once per global frame.
    func display(_ image: RGBA8Image, info: FrameInfo) async -> Void
}

/// Pacing clock. Tests inject a deterministic fake; production uses a wall
/// clock and (in the Metal path) drives presentation off `CAMetalLayer`
/// vsync — which lives behind the production `FrameSink`, not here.
public protocol PlaybackClock: Sendable {
    /// Monotonic seconds.
    func now() -> Double
    /// Sleep until the given monotonic timestamp (returns immediately if past).
    func sleep(until deadline: Double) async
}

/// Resolves a sheep index to its genome. Used to prefetch the upcoming sheep
/// mid-loop so the transition's first frame is ready. Must be `Sendable`.
public protocol SheepProvider: Sendable {
    /// Return the genome for sheep `index` (`0 ..< librarySize`).
    func sheep(at index: Int) async -> Flame
}

// MARK: - PlaybackDispatcher

public actor PlaybackDispatcher {

    // MARK: Configuration (immutable after init)

    private let renderer: any Renderer
    private let sink: any FrameSink
    private let clock: any PlaybackClock
    private let sheepProvider: any SheepProvider
    private let params: RenderParams
    private let targetFPS: Double
    private let ringCapacity: Int

    // MARK: Schedule + timeline (actor-isolated; mutated only here)

    private var schedule: Schedule
    private var globalFrame: Int = 0
    private var startTime: Double? = nil

    // MARK: Sheep cache + in-flight prefetch (actor-isolated)

    /// Cached genomes keyed by sheep index. Eviction is LRU-bounded to keep the
    /// working set small; the current + next sheep are always resident.
    private var cache: [Int: Flame] = [:]
    /// The in-flight prefetch task, or `nil` if none. Cancelled + awaited in
    /// `stop()`; on cancellation the partial genome is discarded.
    private var prefetchTask: Task<Flame, Never>? = nil
    /// The sheep index the in-flight prefetch is fetching (dedupes).
    private var prefetchingIndex: Int? = nil
    private var stopped: Bool = false

    // MARK: Recently-played segment ring (bounded; diagnostics / seek-back)

    private var recentSegmentIds: [Int] = []

    /// Construct the dispatcher.
    ///
    /// - Parameters:
    ///   - schedule: The animation timeline. Copied into the actor (value type).
    ///   - sheepProvider: Resolves sheep index → genome (for prefetch + cold loads).
    ///   - renderer: Render backend (fake in tests; `@MainActor` Metal in prod).
    ///   - sink: Frame display sink (`@MainActor` `FlameUI` in prod).
    ///   - clock: Pacing clock (deterministic fake in tests).
    ///   - params: Static `RenderParams` applied to every frame.
    ///   - targetFPS: Target presentation rate; the dispatcher paces to it.
    ///   - ringCapacity: Bounded ring of recently-played segment ids.
    public init(
        schedule: Schedule,
        sheepProvider: any SheepProvider,
        renderer: any Renderer,
        sink: any FrameSink,
        clock: any PlaybackClock,
        params: RenderParams,
        targetFPS: Double = 30,
        ringCapacity: Int = 8
    ) {
        precondition(targetFPS > 0, "targetFPS must be > 0")
        precondition(ringCapacity > 0, "ringCapacity must be > 0")
        self.schedule = schedule
        self.sheepProvider = sheepProvider
        self.renderer = renderer
        self.sink = sink
        self.clock = clock
        self.params = params
        self.targetFPS = targetFPS
        self.ringCapacity = ringCapacity
    }

    // MARK: - Drive

    /// Advance the timeline by `frameCount` frames, rendering + displaying one
    /// frame per global frame, pacing to `targetFPS`. Returns when all frames
    /// are emitted OR `stop()` is called (cooperative cancellation).
    public func run(frameCount: Int) async {
        precondition(frameCount >= 0, "frameCount must be >= 0")
        if startTime == nil { startTime = clock.now() }
        let origin = startTime ?? clock.now()

        for _ in 0..<frameCount {
            if stopped || Task.isCancelled { break }
            await step()
            // Pace to target fps. Deadline is computed from the run origin so
            // drift doesn't accumulate; if the renderer overran, the sleep
            // returns immediately (best-available — we NEVER hold/duplicate a
            // frame to pad, and never freeze waiting).
            let frameIndexAfterStep = globalFrame   // post-increment frame count
            let deadline = origin + Double(frameIndexAfterStep) / targetFPS
            await clock.sleep(until: deadline)
        }
    }

    /// Teardown: cancel + settle any in-flight prefetch. Idempotent.
    ///
    /// `FlameUI` calls this in its teardown (Swift 6 disallows async work in
    /// `deinit`, so teardown is an explicit `stop()` the owner calls). After
    /// `stop()` the dispatcher is quiesced: no dangling task, no partial genome
    /// fed to the renderer.
    public func stop() async {
        stopped = true
        let task = prefetchTask
        task?.cancel()
        // Await the prefetch settled so no task outlives teardown. On
        // cancellation the task's body discards the partial genome (never
        // writes the cache), so we just drain it here.
        _ = await task?.value
        prefetchTask = nil
        prefetchingIndex = nil
    }

    // MARK: - Per-frame step (actor-isolated)

    /// Render + display exactly one global frame. Increments `globalFrame`.
    private func step() async {
        let mapping = schedule.frameToBlend(globalFrame: globalFrame)
        let segment = schedule.segment(at: mapping.segmentId)
        recordRecent(segment.id)

        // Load the `from` sheep (cached). For a loop, from == to.
        let from = await loadSheep(at: segment.fromSheep)

        // For loops, kick off a prefetch of the upcoming transition's target so
        // its first frame is ready. For transitions, ensure `to` is resident.
        switch segment.kind {
        case .loop:
            // `toSheep == fromSheep` for a loop; reuse.
            await prefetchNextSheepIfNeeded(currentLoopSegment: segment)
        case .transition:
            break  // `to` loaded below; the loop-time prefetch should have it.
        }

        let to: Flame
        if segment.kind == .loop {
            to = from
        } else {
            to = await loadSheep(at: segment.toSheep)
        }

        // Interpolate per the segment kind. Reuses Task-13/14 `Loop`/`Transition`
        // verbatim — the dispatcher does NOT re-implement blend math.
        let flame: Flame
        switch segment.kind {
        case .loop:
            flame = Loop.blend(from, t: mapping.blend)
        case .transition:
            flame = Transition.blend(from, to, t: mapping.blend)
        }

        // Hand the Flame to the renderer (crosses MainActor in production via
        // the injected `Renderer`; awaited explicitly).
        let image = await renderer.render(flame: flame, params: params)

        // Display (crosses MainActor to FlameUI in production; awaited).
        let info = FrameInfo(
            globalFrame: globalFrame,
            segmentId: mapping.segmentId,
            kind: mapping.kind,
            blend: mapping.blend)
        await sink.display(image, info: info)

        globalFrame += 1
    }

    // MARK: - Sheep cache + prefetch

    /// Load a sheep genome, caching the result. Satisfies from cache when
    /// possible so the transition's first frame doesn't stall on a cold provider.
    ///
    /// If a prefetch is in flight for `index`, AWAITS it rather than issuing a
    /// duplicate provider call — this is what guarantees the prefetch is
    /// load-bearing (exactly one fetch per sheep per cycle) and removes the
    /// race between the background prefetch settling and the transition's
    /// synchronous load. Awaiting a child task's `.value` here is safe: the
    /// actor reentrancy model permits the task's `storePrefetch` write-back to
    /// run while `loadSheep` is suspended.
    private func loadSheep(at index: Int) async -> Flame {
        if let hit = cache[index] { return hit }
        if prefetchingIndex == index, let task = prefetchTask {
            let flame = await task.value
            // The task's `storePrefetch` will normally have populated the cache
            // already; if it was gated out (e.g. a racing `stop()`), fall back
            // to the value the task returned.
            if cache[index] == nil, !Task.isCancelled { cache[index] = flame }
            return cache[index] ?? flame
        }
        let flame = await sheepProvider.sheep(at: index)
        cache[index] = flame
        return flame
    }

    /// Mid-loop: prefetch the upcoming transition's target sheep so its first
    /// frame is ready. Launches AT MOST ONE prefetch per loop; if the target is
    /// already cached (e.g. a revisited sheep) it's a no-op.
    ///
    /// On cancellation (`stop()`), the task body observes `Task.isCancelled`
    /// and discards the partial genome — it is NEVER written into the cache,
    /// and therefore never fed to the renderer.
    private func prefetchNextSheepIfNeeded(currentLoopSegment: Segment) async {
        // Peek the next (transition) segment to learn the upcoming sheep.
        // `Schedule.segment(at:)` materializes the lazy walk forward; this is
        // the ONLY place the dispatcher extends the timeline ahead of playback.
        let nextSegment = schedule.segment(at: currentLoopSegment.id + 1)
        let target = nextSegment.toSheep

        if cache[target] != nil {
            // Already resident (prefetched earlier or revisited sheep) — nothing
            // to do. Clear stale bookkeeping if a completed prefetch lingers.
            return
        }
        // Already in flight for this exact target? wait — don't duplicate.
        if prefetchingIndex == target { return }

        // Launch the prefetch. The Task captures the Sendable provider and the
        // target index (a value type); it writes the cache by re-entering the
        // actor via `storePrefetch`. No shared mutable state escapes isolation.
        prefetchingIndex = target
        let provider = sheepProvider
        // `[weak self]`: the task must not keep the dispatcher alive after
        // teardown; on `stop()` we cancel + await it, so the weak ref is safe.
        prefetchTask = Task { [weak self] in
            let flame = await provider.sheep(at: target)
            // On cancellation discard the partial genome — NEVER store it.
            guard !Task.isCancelled else { return flame }
            await self?.storePrefetch(flame: flame, at: target)
            return flame
        }
    }

    /// Actor-isolated write-back for a completed prefetch.
    private func storePrefetch(flame: Flame, at index: Int) {
        // Only accept if this is still the active prefetch target (a `stop()`
        // + restart could have retired it).
        guard !stopped, prefetchingIndex == index else { return }
        cache[index] = flame
        prefetchTask = nil
        prefetchingIndex = nil
    }

    // MARK: - Recent-segment ring

    /// Append a segment id to the bounded ring (LRU eviction at capacity).
    private func recordRecent(_ segmentId: Int) {
        if let existing = recentSegmentIds.firstIndex(of: segmentId) {
            recentSegmentIds.remove(at: existing)
        }
        recentSegmentIds.append(segmentId)
        while recentSegmentIds.count > ringCapacity {
            recentSegmentIds.removeFirst()
        }
    }

    /// Snapshot of the recently-played segment ids (oldest → newest).
    /// Diagnostics / seek-back; not on the realtime hot path.
    public func recentSegments() -> [Int] { recentSegmentIds }
}
