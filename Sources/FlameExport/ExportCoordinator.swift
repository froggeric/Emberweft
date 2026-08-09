import Foundation
import AVFoundation      // AVAssetWriter/AVMutableComposition/AVAssetExportSession
import CryptoKit         // SHA-256 source verification on resume (spec §2.3/D6)
import FlameKit
import FlameReference
import FlameRenderer

/// Drives one continuous export: `FramePlan → renderer → VideoEncoder`, off-main,
/// yielding progress via an `AsyncThrowingStream`. Honors cooperative cancel
/// between frames. The atomic-encode target (`job.partialURL`) is renamed to
/// `job.out` only after `finish()` succeeds, so a failed/cancelled run never
/// partially overwrites a good `out`.
///
/// `ExportCoordinator` is an `actor`: each `run(_:)` is serialized, and the
/// `VideoEncoder` it owns is single-task within that serialization. Cancel flips
/// a flag checked at the top of each frame iteration.
public actor ExportCoordinator: ExportCoordinating {
    public enum Backend: Sendable { case cpu, metal }
    private let backend: Backend
    /// When `true` AND `backend == .metal`, `renderFrames` dispatches each frame
    /// via `MetalRenderer.renderOffMain` / `renderTemporalOffMain` inside a
    /// `Task.detached` — never touching the MainActor, so it cannot freeze the UI
    /// (the GUI export path). Default `false`: the CLI path renders via the
    /// existing `await MainActor.run { MetalRenderer.render(…) }` (byte-for-byte
    /// unchanged; all single-arg `ExportCoordinator(backend:)` call sites
    /// preserved). The off-main render cores are byte-identical to the `@MainActor`
    /// path (pinned by `MetalFrameRendererSmokeTests` + M6-G.1's
    /// `OffMainTemporalParityTests`); nil ⇒ `.metalUnavailable`.
    private let useOffMainMetal: Bool
    private var cancelled = false
    /// M6.1: set by `pause()` (Task 4) and checked at the top of each frame in
    /// `renderFramesInterleaved` (single pause site — spec D5). The flag itself
    /// is added in Task 3 so the interleaved loop compiles; Task 4 adds the
    /// `pause()` method that sets it. Unrelated to the existing `renderFrames`
    /// (which never reads it).
    private var paused = false

    /// Test seam: number of images produced by the render dispatch
    /// (`renderImage`) in this coordinator's lifetime. Counts each frame ONCE —
    /// a loop repeated `loopRepeatCount`× via the cache still increments this
    /// once per rendered (cached) frame, not per output append. Pure side-channel
    /// (no effect on bytes/PTS → byte-identity-safe).
    internal private(set) var renderCallCount: Int = 0
    /// Test seam: number of frames appended to the encoder (output frame count).
    /// A loop repeated `loopRepeatCount`× increments this `loopRepeatCount`× per
    /// cached frame. Pure side-channel.
    internal private(set) var appendedFrameCount: Int = 0

    /// M6.1 test seams (deterministic between-chunk pause/cancel for
    /// `RunResumableTests`). The value is the chunkIndex at whose TOP the flag
    /// flips — so to keep chunk 0 and stop before chunk 1, set `1`. They set the
    /// SAME `paused`/`cancelled` flags the real `pause()`/`cancel()` set, so the
    /// exact chunk-top code path is exercised (not a parallel path). Production
    /// code never reads these. Set via the actor-isolated setters below (an
    /// actor's stored properties cannot be written directly from outside).
    internal var _testPauseAfterChunk: Int?
    internal var _testCancelAfterChunk: Int?
    internal func _setTestPauseAfterChunk(_ index: Int?) { _testPauseAfterChunk = index }
    internal func _setTestCancelAfterChunk(_ index: Int?) { _testCancelAfterChunk = index }

    /// `backend` is the ALREADY-RESOLVED choice. Metal availability + the
    /// `--strict-backend` fallback/refuse decision are made by `ExportCommand`
    /// (which can `await MainActor.run { MetalRenderer.isAvailable }` from its
    /// async context) BEFORE constructing the coordinator. The actor MUST NOT
    /// probe `MetalRenderer.isAvailable` itself: that property's getter calls
    /// `MainActor.assumeIsolated`, which traps when invoked off the main actor
    /// (the actor's executor is not the main actor). This is why the probe is
    /// hoisted to the caller (spec D3/D15; resolves the prior resolvedBackend
    /// crash).
    ///
    /// `useOffMainMetal` defaults to `false` so every existing single-arg
    /// `ExportCoordinator(backend:)` call site (the CLI, all `FlameExportTests`)
    /// keeps the original MainActor dispatch path byte-for-byte. The GUI export
    /// path (M6-G.5 `ExportManager`) passes `true` to avoid freezing the UI.
    public init(backend: Backend, useOffMainMetal: Bool = false) {
        self.backend = backend
        self.useOffMainMetal = useOffMainMetal
    }

    /// Single continuous export. Yields progress; on success the file is at
    /// `job.out`. Honors `cancel()` between frames.
    public func run(_ job: ExportJob) -> AsyncThrowingStream<ExportProgress, Error> {
        AsyncThrowingStream { continuation in
            // Unstructured Task captures `self` (the actor, which is Sendable) and
            // the Sendable continuation. `runJob` is actor-isolated, so the
            // `await self.runJob(...)` hops onto the actor. For a short-lived CLI
            // export the lifecycle is bounded by the process; if a GUI consumer
            // drops the stream mid-iteration, call `cancel()` to stop the run.
            Task { [self] in
                do { try await self.runJob(job) { p in continuation.yield(p) }; continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
        }
    }

    public func cancel() async { cancelled = true }

    /// M6.1: cooperative pause. Sets the `paused` flag, checked at each chunk
    /// top (and per-frame inside `renderFramesInterleaved`) in `runResumableBody`.
    /// The in-flight chunk is abandoned (its temp is removed; it is NOT
    /// checkpointed) and re-renders from its start on resume. The checkpoint +
    /// completed chunks survive. `paused` is reset to `false` at the top of
    /// `runResumableBody` (P10) so a second run after a pause does not re-throw.
    public func pause() async { paused = true }

    /// Batch (serial) export. Runs `jobs` in input array order on ONE
    /// `ExportCoordinator` (self) — Metal is single-device, so serial dispatch
    /// is both deterministic (rule #2: job order + per-job progress →
    /// aggregateFraction, no float sum over a hashed collection) and
    /// thermal-safe. Continue-by-default: a failed job (degenerate genome OR a
    /// thrown render/encode error) is recorded (`BatchProgress.failed == true`,
    /// exactly one event per failed job) and the batch proceeds to the next job;
    /// the batch exit code is `failures.isEmpty ? 0 : 1`. When `failFast` is
    /// true, the first failure stops the batch (no later jobs start).
    ///
    /// Cancel scope = CURRENT job + remaining. A cancel (`coord.cancel()` or
    /// `Task.isCancelled`) lands between frames in the in-flight job (the inner
    /// `run`/`runLongForm` per-frame guard throws `ExportError.cancelled`,
    /// cleaning up that job's partial + temps via the existing atomic-handoff
    /// path), then propagates here: cancel is ALWAYS a batch stop (regardless of
    /// `failFast`), and the `cancelled` flag is checked at the top of each job
    /// iteration so remaining jobs never start.
    ///
    /// Per-job work reuses the existing `run`/`runLongForm` streams (selected by
    /// `settings.segmentFrameBudget > 0`, same dispatch as `ExportCommand`);
    /// each `ExportProgress` is mapped to a `BatchProgress` with
    /// `aggregateFraction = (jobIndex + jobFrame/jobTotalFrames) / totalJobs`.
    public func runBatch(_ jobs: [ExportJob], failFast: Bool) -> AsyncThrowingStream<BatchProgress, Error> {
        AsyncThrowingStream { continuation in
            // Same unstructured-Task pattern as `run`/`runLongForm`: captures
            // `self` (Sendable actor) + the Sendable continuation; `runBatchBody`
            // is actor-isolated so the `await` hops onto the actor, serializing
            // batch iteration against any `cancel()` message.
            Task { [self] in
                do {
                    try await self.runBatchBody(jobs, failFast: failFast) { p in continuation.yield(p) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Long-form (chunked) export. Splits the timeline on Schedule-segment edges
    /// (whole loops/transitions — never mid-segment), encodes each chunk to a
    /// temp `.mov` beside `out`, then concatenates via `AVMutableComposition` +
    /// `AVAssetExportSession` passthrough (no re-encode → keyframes preserved as-is).
    /// Temps are registered at creation and removed in a `defer` that runs on
    /// success, cancel, AND failure. Identical codec/timescale/resolution across
    /// chunks is guaranteed by construction (one shared `ExportSettings`).
    ///
    /// Dispatched by `ExportCommand` when `settings.segmentFrameBudget > 0`.
    /// Progress is the same `AsyncThrowingStream<ExportProgress, Error>` as `run`:
    /// per-frame `.rendering` during each chunk, then one `.concatenating` event.
    public func runLongForm(_ job: ExportJob) -> AsyncThrowingStream<ExportProgress, Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                do { try await self.runLongFormJob(job) { p in continuation.yield(p) }; continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
        }
    }

    /// M6.1: resumable dispatch (fresh-run path; resume is Task 5). Chunks the
    /// timeline at frame-count edges, encodes each chunk via
    /// `renderFramesInterleaved` (byte-identical per-frame loop), writes the
    /// checkpoint after each chunk, concats all chunks, atomic-renames to `out`,
    /// deletes checkpoint + chunks on success. `pause()` between chunks throws
    /// `.paused` (checkpoint + completed chunks survive); `cancel()` throws
    /// `.cancelled` (P3: the coordinator does NOT discard on cancel — discard is
    /// the caller's job; it cannot tell GUI Cancel from CLI SIGINT apart). Same
    /// unstructured-Task + Sendable-continuation shape as `run`/`runLongForm`.
    public func runResumable(_ job: ExportJob, sources: [ExportCheckpoint.Source],
                             checkpointIntervalFrames: Int,
                             resumeFrom checkpointURL: URL?) -> AsyncThrowingStream<ExportProgress, Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                do {
                    try await self.runResumableBody(job, sources: sources, interval: checkpointIntervalFrames,
                                                   resumeFrom: checkpointURL) { p in continuation.yield(p) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Shared params/plan/budget construction for `runJob`/`runLongFormJob`/
    /// `runResumableBody` (P9). Performs `diskPrecheck` (accurate for all three:
    /// the resumable path emits loop frames `loopRepeatCount×` inline, so the
    /// frame count matches `diskPrecheck`'s formula). Does NOT perform
    /// `checkLoopRepeatMemory` — the caller decides (resumable skips it: no
    /// per-segment cache → O(1) memory). Pure extraction of the block that lived
    /// inline in `runJob`/`runLongFormJob`; behavior-identical. Returns `schedule`
    /// too because `runLongFormJob`'s chunk loop still queries
    /// `schedule.frameOffset(ofSegment:)` (`runJob`/`runResumableBody` ignore it).
    private func buildRenderContext(for job: ExportJob) throws
        -> (plan: FramePlan, params: RenderParams, budget: MetalRenderer.ThreadSeedBudget?,
            useMetal: Bool, schedule: Schedule) {
        let res = job.settings.resolution
        let (spp, os) = job.settings.quality.resolvedSamplesPerPixel(for: job.flames[0])
        let params = RenderParams(seed: job.seed, width: max(1, res.width), height: max(1, res.height),
                                  oversample: os, samplesPerPixel: spp)
        let useMetal = (backend == .metal)
        try Self.diskPrecheck(job: job)
        let selector = makeSelector(job.selector)
        var schedule = Schedule(librarySize: job.flames.count, framesPerSegment: job.framesPerSegment,
                                transitionFramesPerSegment: job.transitionFramesPerSegment,
                                selector: selector, seed: job.seed)
        let plan = FramePlan(schedule: &schedule, segmentCount: job.segmentCount, flames: job.flames,
                             loopCycles: job.loopCycles, stagger: job.stagger,
                             temporalSamples: max(1, job.settings.temporalSamples))
        let budget: MetalRenderer.ThreadSeedBudget? = useMetal ? MetalRenderer.ThreadSeedBudget(baseSeed: params.seed) : nil
        return (plan, params, budget, useMetal, schedule)
    }

    /// `yield` is `@Sendable` so the closure built in `run`'s unstructured Task
    /// (which captures the `AsyncThrowingStream.Continuation`, itself Sendable)
    /// crosses the actor boundary cleanly under Swift 6 strict concurrency.
    private func runJob(_ job: ExportJob, yield: @Sendable (ExportProgress) -> Void) async throws {
        // Loop-repeat memory guard (v0.5.0) — checked BEFORE disk/encoder so a
        // refused job leaves no partial file. No-op when loopRepeatCount == 1.
        // Width/height are read directly from settings (the same values
        // `buildRenderContext` computes internally); this call stays BEFORE
        // `buildRenderContext` so the side-effect order is unchanged
        // (memory guard → disk precheck → encoder).
        try Self.checkLoopRepeatMemory(job: job,
                                       width: max(1, job.settings.resolution.width),
                                       height: max(1, job.settings.resolution.height))
        let ctx = try buildRenderContext(for: job)
        let plan = ctx.plan
        let params = ctx.params
        let budget = ctx.budget
        let useMetal = ctx.useMetal

        let encoder = try VideoEncoder(settings: job.settings, outputURL: job.partialURL)
        try encoder.start()
        do {
            // Per-frame render loop shared with `runLongForm` (Task 6). Range
            // `[0, totalFrames)` into one encoder = byte-identical to the prior
            // inline loop; the extraction only factors the body into a helper.
            try await renderFrames(plan: plan, params: params, budget: budget, useMetal: useMetal,
                                   range: 0..<plan.totalFrames, loopRepeatCount: job.loopRepeatCount,
                                   into: encoder, yield: yield)
            try await encoder.finish()
        } catch {
            encoder.cancel(); try? FileManager.default.removeItem(at: job.partialURL); throw error
        }
        // Atomic handoff (D13). Replace any existing `out` atomically (same volume
        // as the partial → rename is atomic).
        if FileManager.default.fileExists(atPath: job.out.path) { try FileManager.default.removeItem(at: job.out) }
        try FileManager.default.moveItem(at: job.partialURL, to: job.out)
    }

    /// Shared per-frame render loop (Task 6 extraction). Renders global frames
    /// `range` into the PROVIDED, already-started `encoder`, yielding one
    /// `.rendering` progress event per frame (denominator = `plan.totalFrames`,
    /// so a chunk's progress is comparable to a single export's). Honors
    /// cooperative cancel between frames (throws `ExportError.cancelled`); does
    /// NOT cancel the encoder or remove files — the caller owns cleanup so it
    /// can target the right URL (`job.partialURL` for single, the chunk temp for
    /// long-form). Both `runJob` (range = whole timeline) and `runLongFormJob`
    /// (range = one chunk) call this, so the per-frame code path is identical.
    ///
    /// `loopRepeatCount` (v0.5.0): when `> 1`, each **loop** segment in `range`
    /// is rendered ONCE into a per-segment `[RGBA8Image]` cache, then each cached
    /// frame is appended `loopRepeatCount`× (a loop is seamless — `R(360°)=R(0°)`
    /// — so the repeats are invisible). Transition segments are rendered +
    /// appended once (a morph isn't seamless). A running `outputIndex` (scoped to
    /// the encoder session) replaces `gf - range.lowerBound` as the append PTS in
    /// this branch. When `== 1` the EXACT pre-change per-frame loop runs
    /// byte-for-byte (the cache/replay branch is not entered → every byte-identity
    /// pin stays green). Determinism (rule #2): each loop frame is rendered once
    /// and the identical bytes are written `repeatCount`× — no re-render/reseed.
    private func renderFrames(
        plan: FramePlan,
        params: RenderParams,
        budget: MetalRenderer.ThreadSeedBudget?,
        useMetal: Bool,
        range: Range<Int>,
        loopRepeatCount: Int = 1,
        into encoder: VideoEncoder,
        yield: @Sendable (ExportProgress) -> Void
    ) async throws {
        let start = ProcessInfo.processInfo.systemUptime

        // --- repeat == 1: the byte-for-byte pre-change path (untouched) ---
        // Every animate↔export byte-identity pin routes through here. The only
        // change vs the original is the render dispatch is now a call to the
        // extracted `renderImage` (identical operations, identical order →
        // identical bytes). Do NOT alter the PTS math or progress values here.
        if loopRepeatCount <= 1 {
            for gf in range {
                if cancelled || Task.isCancelled { throw ExportError.cancelled }
                let d = plan.descriptor(for: gf)
                let img = try await renderImage(descriptor: d, plan: plan, params: params,
                                                budget: budget, useMetal: useMetal)
                renderCallCount += 1
                // PTS is LOCAL to this encoder's session (session always starts at
                // .zero). For `runJob` range.lowerBound == 0 so this is identical to
                // the prior inline `atFrame: gf`. For a long-form chunk the local
                // index resets per chunk → each chunk is an independent N-frame
                // stream; the concat shifts each to its cumulative offset. Passing
                // the GLOBAL index here would leave a `lowerBound`-frame black gap
                // at the front of every chunk's stream.
                try await encoder.append(img, atFrame: gf - range.lowerBound)
                appendedFrameCount += 1
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                yield(ExportProgress(phase: .rendering, currentFrame: gf + 1, totalFrames: plan.totalFrames,
                                     elapsed: elapsed, renderFPS: elapsed > 0 ? Double(gf + 1) / elapsed : 0))
            }
            return
        }

        // --- repeat > 1: coordinator-level cache + replay (loops only) ---
        // Walk `range` segment-by-segment. `range` always aligns to segment edges
        // (`runJob` passes `0..<plan.totalFrames`; long-form chunks split on
        // segment edges — never mid-segment), so the cursor `gf` is always at a
        // segment start when the while-body runs. For a loop segment, render its
        // N frames once into a local cache (cancel-check per render), append each
        // `loopRepeatCount`× at a running `outputIndex`, then discard the cache.
        // For a transition segment, render + append each frame once.
        var outputIndex = 0
        var rendered = 0
        var gf = range.lowerBound
        while gf < range.upperBound {
            if cancelled || Task.isCancelled { throw ExportError.cancelled }
            let d = plan.descriptor(for: gf)
            switch d.kind {
            case .loop:
                // Loop segment: spans `framesPerSegment` frames from `gf` (clamped
                // to range — a trailing partial loop can't happen given the
                // segment-edge alignment, but the clamp is defensive).
                let segLen = plan.framesPerSegment
                let segEnd = min(gf + segLen, range.upperBound)
                var cache: [RGBA8Image] = []
                cache.reserveCapacity(segEnd - gf)
                for f in gf..<segEnd {
                    if cancelled || Task.isCancelled { throw ExportError.cancelled }
                    let fd = plan.descriptor(for: f)
                    let img = try await renderImage(descriptor: fd, plan: plan, params: params,
                                                    budget: budget, useMetal: useMetal)
                    cache.append(img)
                    renderCallCount += 1
                    rendered += 1
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    yield(ExportProgress(phase: .rendering, currentFrame: rendered,
                                         totalFrames: plan.totalFrames, elapsed: elapsed,
                                         renderFPS: elapsed > 0 ? Double(rendered) / elapsed : 0))
                }
                // Replay: append each cached frame `loopRepeatCount`×. The cached
                // bytes are written verbatim (rule #2: identical bytes, no reseed).
                for img in cache {
                    for _ in 0..<loopRepeatCount {
                        try await encoder.append(img, atFrame: outputIndex)
                        outputIndex += 1
                        appendedFrameCount += 1
                    }
                }
                cache.removeAll()
                gf = segEnd
            case .transition:
                // Transition segment: never repeated (a morph isn't seamless).
                let segLen = plan.transitionFramesPerSegment
                let segEnd = min(gf + segLen, range.upperBound)
                for f in gf..<segEnd {
                    if cancelled || Task.isCancelled { throw ExportError.cancelled }
                    let fd = plan.descriptor(for: f)
                    let img = try await renderImage(descriptor: fd, plan: plan, params: params,
                                                    budget: budget, useMetal: useMetal)
                    renderCallCount += 1
                    rendered += 1
                    try await encoder.append(img, atFrame: outputIndex)
                    outputIndex += 1
                    appendedFrameCount += 1
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    yield(ExportProgress(phase: .rendering, currentFrame: rendered,
                                         totalFrames: plan.totalFrames, elapsed: elapsed,
                                         renderFPS: elapsed > 0 ? Double(rendered) / elapsed : 0))
                }
                gf = segEnd
            }
        }
    }

    /// NEW (M6.1): per-global-frame render loop for the resumable path ONLY. Renders
    /// each frame once, appends `reps`× inline (reps = loopRepeatCount for a loop frame,
    /// 1 for a transition frame). Byte-identical to `renderFrames` (pinned). O(1) memory
    /// (no per-segment cache). `reps` decided per frame ⇒ frame-count chunks can span a
    /// loop→transition boundary (the F2 case the existing renderFrames repeat>1 path
    /// mishandles). See spec §4.5.
    private func renderFramesInterleaved(
        plan: FramePlan, params: RenderParams, budget: MetalRenderer.ThreadSeedBudget?,
        useMetal: Bool, range: Range<Int>, loopRepeatCount: Int,
        into encoder: VideoEncoder, globalRendered: inout Int, total: Int,
        yield: @Sendable (ExportProgress) -> Void
    ) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        var outputIndex = 0
        for gf in range {
            if cancelled || Task.isCancelled { throw ExportError.cancelled }
            if paused { throw ExportError.paused }
            let d = plan.descriptor(for: gf)
            let img = try await renderImage(descriptor: d, plan: plan, params: params,
                                            budget: budget, useMetal: useMetal)
            renderCallCount += 1
            let reps = (d.kind == .loop) ? max(1, loopRepeatCount) : 1
            for _ in 0..<reps {
                try await encoder.append(img, atFrame: outputIndex)
                outputIndex += 1
                appendedFrameCount += 1
            }
            globalRendered += 1
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            yield(ExportProgress(phase: .rendering, currentFrame: globalRendered, totalFrames: total,
                                 elapsed: elapsed, renderFPS: elapsed > 0 ? Double(globalRendered) / elapsed : 0))
        }
    }

    /// The 3-branch render dispatch (off-main Metal / MainActor Metal / CPU),
    /// factored out of `renderFrames` so the repeat=1 and repeat>1 paths share
    /// one identical render codepath. Field names mirror the original inline
    /// block verbatim (`d.blend`/`d.blendAt`/`d.temporal`/`d.sumfilt`; single-vs-
    /// temporal via `plan.temporalSamples > 1`). The SAME `budget` is forwarded.
    /// Extraction is operation-identical (same calls, same order) → byte-identical
    /// to the prior inline form (pinned by the animate↔export byte-identity tests).
    private func renderImage(
        descriptor d: FrameDescriptor,
        plan: FramePlan,
        params: RenderParams,
        budget: MetalRenderer.ThreadSeedBudget?,
        useMetal: Bool
    ) async throws -> RGBA8Image {
        if useMetal && useOffMainMetal {
            // GUI export path (M6-G.2): render off-main via
            // `renderOffMain`/`renderTemporalOffMain` inside a `Task.detached`,
            // so the MainActor is never blocked (no UI freeze). nil ⇒ Metal
            // unavailable / render failed ⇒ `.metalUnavailable`.
            let maybeImg: RGBA8Image? = await Task.detached(priority: .userInitiated) {
                plan.temporalSamples > 1
                    ? MetalRenderer.renderTemporalOffMain(
                        blendAt: d.blendAt, centerTime: d.blend,
                        temporal: d.temporal, sumfilt: d.sumfilt,
                        params: params, seedBudget: budget)
                    : MetalRenderer.renderOffMain(
                        flame: d.blendAt(d.blend), params: params, seedBudget: budget)
            }.value
            guard let offMainImg = maybeImg else { throw ExportError.metalUnavailable }
            return offMainImg
        } else if useMetal {
            return await MainActor.run {
                autoreleasepool {
                    plan.temporalSamples > 1
                        ? MetalRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                               temporal: d.temporal, sumfilt: d.sumfilt, params: params, seedBudget: budget)
                        : MetalRenderer.render(flame: d.blendAt(d.blend), params: params, seedBudget: budget)
                }
            }
        } else {
            return await Task.detached(priority: .userInitiated) {
                plan.temporalSamples > 1
                    ? ReferenceRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                               temporal: d.temporal, sumfilt: d.sumfilt, params: params)
                    : ReferenceRenderer.render(flame: d.blendAt(d.blend), params: params)
            }.value
        }
    }

    /// Passthrough-concatenate already-encoded chunk files (in array order) into
    /// `partialURL` (no re-encode → keyframes preserved). Caller does the atomic
    /// rename to `out`. Shared by `runLongFormJob` and `runResumableBody`
    /// (spec §3.4). Pure extraction of the block that lived inline in
    /// `runLongFormJob`; behavior-identical.
    private func concatChunks(urls: [URL], container: ExportSettings.Container,
                              partialURL: URL) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.encodeFailed
        }
        var cursor = CMTime.zero
        for segURL in urls {
            let segAsset = AVURLAsset(url: segURL)
            let segTracks = try await segAsset.loadTracks(withMediaType: .video)
            guard let segTrack = segTracks.first else { throw ExportError.encodeFailed }
            let segDuration = try await segAsset.load(.duration)
            let segRange = CMTimeRange(start: .zero, duration: segDuration)
            try track.insertTimeRange(segRange, of: segTrack, at: cursor)
            cursor = CMTimeAdd(cursor, segRange.duration)
        }
        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.encodeFailed
        }
        exporter.outputURL = partialURL
        exporter.outputFileType = container == .mov ? .mov : .mp4
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed: cont.resume()
                case .cancelled: cont.resume(throwing: ExportError.cancelled)
                default: cont.resume(throwing: exporter.error ?? ExportError.encodeFailed)
                }
            }
        }
    }

    /// Long-form body. Same setup as `runJob` (params/plan/budget), then chunk
    /// the timeline on segment edges, encode each chunk to a temp `.mov`, concat
    /// via passthrough, atomic-rename to `out`.
    private func runLongFormJob(_ job: ExportJob, yield: @Sendable (ExportProgress) -> Void) async throws {
        // Loop-repeat memory guard (v0.5.0) — same gate as single export. Kept
        // BEFORE `buildRenderContext` so the side-effect order is unchanged
        // (memory guard → disk precheck → encoder). Width/height are read
        // directly from settings (same values `buildRenderContext` computes).
        try Self.checkLoopRepeatMemory(job: job,
                                       width: max(1, job.settings.resolution.width),
                                       height: max(1, job.settings.resolution.height))
        let ctx = try buildRenderContext(for: job)
        let plan = ctx.plan
        let params = ctx.params
        let budget = ctx.budget
        let useMetal = ctx.useMetal
        let schedule = ctx.schedule

        // Chunk size in SEGMENTS (AC4: never mid-segment). Each chunk covers
        // `chunkSegments` whole Schedule segments → chunk frame ranges span whole
        // segments. The chunk SIZE estimate uses the loop N (the larger kind);
        // the actual frame RANGE is computed from cumulative per-kind offsets via
        // `schedule.frameOffset(ofSegment:)` so variable transition counts land
        // on true segment edges (never mid-segment).
        let N = job.framesPerSegment
        let chunkSegments = max(1, job.settings.segmentFrameBudget / N)
        let totalSegs = job.segmentCount
        let totalFrames = plan.totalFrames

        // Temps live beside `out` (same volume → observable cleanup; consistent
        // with `partialURL`). Registered at creation, removed on EVERY exit path
        // (success/cancel/failure) by this `defer` (crash-safe `try?`).
        var temps: [URL] = []
        defer {
            for u in temps { try? FileManager.default.removeItem(at: u) }
        }
        let outDir = job.out.deletingLastPathComponent()
        let chunkExt = job.settings.container == .mov ? "mov" : "mp4"

        var segStart = 0
        while segStart < totalSegs {
            // Honor cancel between chunks (avoids starting a fresh encoder for a
            // cancelled run). Per-frame cancel is checked inside `renderFrames`.
            if cancelled || Task.isCancelled { throw ExportError.cancelled }
            let segEnd = min(segStart + chunkSegments, totalSegs)
            let frameStart = schedule.frameOffset(ofSegment: segStart)
            let frameEnd = min(schedule.frameOffset(ofSegment: segEnd), totalFrames)
            // UUID suffix → unique across concurrent runs (parallel tests / GUI).
            let tempURL = outDir.appendingPathComponent("m6-seg-\(UUID().uuidString).\(chunkExt)")
            temps.append(tempURL)
            // Defensive: clear any stale file at that path (UUID collision is
            // astronomically unlikely, but AVAssetWriter refuses to overwrite).
            try? FileManager.default.removeItem(at: tempURL)
            let encoder = try VideoEncoder(settings: job.settings, outputURL: tempURL)
            try encoder.start()
            do {
                try await renderFrames(plan: plan, params: params, budget: budget, useMetal: useMetal,
                                       range: frameStart..<frameEnd, loopRepeatCount: job.loopRepeatCount,
                                       into: encoder, yield: yield)
                try await encoder.finish()
            } catch {
                encoder.cancel(); try? FileManager.default.removeItem(at: tempURL); throw error
            }
            segStart = segEnd
        }

        // --- Concatenate via AVMutableComposition + passthrough (no re-encode) ---
        yield(ExportProgress(phase: .concatenating, currentFrame: totalFrames, totalFrames: totalFrames,
                             elapsed: 0, renderFPS: 0))
        try await concatChunks(urls: temps, container: job.settings.container, partialURL: job.partialURL)
        // Atomic handoff (same pattern as `runJob`). `partialURL` is beside `out`
        // on the same volume → rename is atomic.
        if FileManager.default.fileExists(atPath: job.out.path) { try FileManager.default.removeItem(at: job.out) }
        try FileManager.default.moveItem(at: job.partialURL, to: job.out)
    }

    /// M6.1: resumable body (fresh-run path; resume read-branch is Task 5).
    /// Chunk the timeline at frame-count edges, encode each chunk via
    /// `renderFramesInterleaved`, write the checkpoint after each chunk, concat
    /// via `concatChunks`, atomic-rename to `out`, delete checkpoint + chunks on
    /// success. SKIPS `checkLoopRepeatMemory` (the interleaved loop builds NO
    /// per-segment cache → O(1) memory; `diskPrecheck` runs inside
    /// `buildRenderContext` and is accurate — it scales by `loopRepeatCount`,
    /// and the interleaved path emits loop frames `loopRepeatCount×` inline).
    ///
    /// P10: `paused` is reset to `false` at the top (a second run after a pause
    /// must not re-throw). P3 (D18): the cancel AND pause paths remove ONLY the
    /// in-progress chunk temp (`encoder.cancel()` + `try? rm chunk temp`) and
    /// rethrow — they NEVER touch the checkpoint or completed chunks. There is
    /// NO `defer { remove chunks }` (that pattern in `runLongFormJob` would
    /// delete chunks on pause). Discard happens exclusively on success (here)
    /// and via the VM/`discardPaused` (caller — the coordinator cannot
    /// distinguish GUI Cancel from CLI SIGINT).
    private func runResumableBody(_ job: ExportJob, sources passedSources: [ExportCheckpoint.Source],
                                  interval: Int, resumeFrom: URL?,
                                  yield: @Sendable (ExportProgress) -> Void) async throws {
        // P10: a leftover `paused` from a prior run must not poison this one.
        paused = false

        // Task 5: resume branch. The checkpoint's recipe is AUTHORITATIVE (D11):
        // on resume, rebuild the ExportJob from the checkpoint + SHA-256-verified
        // re-parsed flames, then drive the context/plan/budget from the rebuilt
        // job. A schema mismatch (≠1) or the fresh-run path falls through using
        // the caller's `job`. `var job` shadows the param so all downstream
        // `job.` refs (chunkURL/partialURL/settings) track the rebuilt job.
        var job = job
        var decodedCP: ExportCheckpoint? = nil
        if let checkpointURL = resumeFrom {
            // Read + decode (corrupt/unreadable ⇒ `.checkpointUnreadable`).
            let cpData: Data
            do {
                cpData = try Data(contentsOf: checkpointURL)
            } catch {
                throw ExportError.checkpointUnreadable
            }
            let decoded: ExportCheckpoint
            do {
                decoded = try JSONDecoder().decode(ExportCheckpoint.self, from: cpData)
            } catch {
                throw ExportError.checkpointUnreadable
            }
            // Schema gate (D12): ≠ 1 ⇒ ignore + fresh start (never crash). The
            // incompatible checkpoint is overwritten by the fresh run below.
            if decoded.schemaVersion == 1 {
                // Verify each Source (re-read + SHA-256 + compare + re-parse).
                // Hash mismatch or a vanishing flame index ⇒ `.checkpointSourceChanged`.
                let flames = try Self.reparseSources(decoded.sources)
                job = ExportJob(
                    settings: decoded.settings, flames: flames,
                    framesPerSegment: decoded.framesPerSegment,
                    transitionFramesPerSegment: decoded.transitionFramesPerSegment,
                    segmentCount: decoded.segmentCount, selector: decoded.selector,
                    seed: decoded.seed, loopCycles: decoded.loopCycles,
                    stagger: decoded.stagger, out: decoded.out,
                    loopRepeatCount: decoded.loopRepeatCount)
                decodedCP = decoded
            }
        }

        let ctx = try buildRenderContext(for: job)
        let plan = ctx.plan
        let params = ctx.params
        let budget = ctx.budget
        let useMetal = ctx.useMetal
        let total = plan.totalFrames

        // Finalize the checkpoint. Fresh-run builds one from `job` + the just-
        // computed total. Resume reuses the decoded one, dropping any completed
        // chunk index whose file is no longer on disk (it re-renders).
        let cp: ExportCheckpoint
        if let decoded = decodedCP {
            let container = decoded.settings.container
            let completed = decoded.completedChunkIndexes.filter {
                FileManager.default.fileExists(
                    atPath: ExportCheckpoint.chunkURL(out: decoded.out, index: $0,
                                                      container: container).path)
            }
            cp = ExportCheckpoint(
                settings: decoded.settings, framesPerSegment: decoded.framesPerSegment,
                transitionFramesPerSegment: decoded.transitionFramesPerSegment,
                segmentCount: decoded.segmentCount, selector: decoded.selector,
                seed: decoded.seed, loopCycles: decoded.loopCycles, stagger: decoded.stagger,
                out: decoded.out, loopRepeatCount: decoded.loopRepeatCount,
                checkpointIntervalFrames: decoded.checkpointIntervalFrames,
                totalGlobalFrames: decoded.totalGlobalFrames,
                completedChunkIndexes: completed, sources: decoded.sources)
        } else {
            cp = ExportCheckpoint(
                settings: job.settings, framesPerSegment: job.framesPerSegment,
                transitionFramesPerSegment: job.transitionFramesPerSegment,
                segmentCount: job.segmentCount, selector: job.selector, seed: job.seed,
                loopCycles: job.loopCycles, stagger: job.stagger, out: job.out,
                loopRepeatCount: job.loopRepeatCount, checkpointIntervalFrames: interval,
                totalGlobalFrames: total, completedChunkIndexes: [],
                sources: Self.finalizeFreshSources(passed: passedSources, for: job))
        }
        var completed = cp.completedChunkIndexes
        let chunkCount = cp.chunkCount
        let container = job.settings.container
        let checkpointURL = ExportCheckpoint.checkpointURL(out: job.out)

        // Seeding progress (D9): fresh starts at 0; resume seeds at
        // `Σ completed-chunk frame counts` so the bar does NOT jump to 0. One
        // event so the bar starts at the true position.
        let safeInterval = max(1, cp.checkpointIntervalFrames)
        var globalRendered = 0
        for i in completed {
            globalRendered += min((i + 1) * safeInterval, total) - i * safeInterval
        }
        yield(ExportProgress(phase: .rendering, currentFrame: globalRendered, totalFrames: total,
                             elapsed: 0, renderFPS: 0))

        for chunkIndex in 0..<chunkCount {
            let chunkURL = ExportCheckpoint.chunkURL(out: job.out, index: chunkIndex, container: container)

            // Test seam (deterministic between-chunk stop): set the same flag the
            // real `cancel()`/`pause()` set, so the chunk-top check below fires.
            if let cancelAfter = _testCancelAfterChunk, cancelAfter == chunkIndex { cancelled = true }
            // Chunk-top checks (P3: NO checkpoint/completed-chunk discard here —
            // only the in-progress chunk temp, defensively; at a fresh chunk-top
            // it does not exist yet so this is a no-op).
            if cancelled || Task.isCancelled {
                try? FileManager.default.removeItem(at: chunkURL)
                throw ExportError.cancelled
            }
            if let pauseAfter = _testPauseAfterChunk, pauseAfter == chunkIndex { paused = true }
            if paused {
                try? FileManager.default.removeItem(at: chunkURL)
                throw ExportError.paused
            }

            // Skip a completed chunk whose file is still present (Task 5's resume
            // drops a completed index whose file is missing → re-render). On a
            // fresh run `completed` is always empty here.
            if completed.contains(chunkIndex)
                && FileManager.default.fileExists(atPath: chunkURL.path) {
                continue
            }

            let range = chunkIndex * safeInterval ..< min((chunkIndex + 1) * safeInterval, total)
            // Defensive: clear any stale temp at this path (crash recovery /
            // re-render of a dropped chunk; AVAssetWriter refuses to overwrite).
            try? FileManager.default.removeItem(at: chunkURL)
            let encoder = try VideoEncoder(settings: job.settings, outputURL: chunkURL)
            try encoder.start()
            do {
                try await renderFramesInterleaved(plan: plan, params: params, budget: budget,
                                                  useMetal: useMetal, range: range,
                                                  loopRepeatCount: job.loopRepeatCount,
                                                  into: encoder, globalRendered: &globalRendered,
                                                  total: total, yield: yield)
                try await encoder.finish()
            } catch {
                // P3: remove ONLY this in-progress chunk's temp; the checkpoint
                // and completed chunks are untouched (discard is the caller's job).
                encoder.cancel()
                try? FileManager.default.removeItem(at: chunkURL)
                throw error
            }
            // Chunk done: record it + rewrite the checkpoint (atomic + sorted
            // keys → byte-stable across writes, rule #2). The checkpoint's own
            // `encode(to:)` already sorts `completedChunkIndexes`; `.sortedKeys`
            // also orders the field-name keys (belt-and-suspenders).
            completed.insert(chunkIndex)
            let updated = ExportCheckpoint(
                settings: cp.settings, framesPerSegment: cp.framesPerSegment,
                transitionFramesPerSegment: cp.transitionFramesPerSegment,
                segmentCount: cp.segmentCount, selector: cp.selector, seed: cp.seed,
                loopCycles: cp.loopCycles, stagger: cp.stagger, out: cp.out,
                loopRepeatCount: cp.loopRepeatCount,
                checkpointIntervalFrames: cp.checkpointIntervalFrames,
                totalGlobalFrames: cp.totalGlobalFrames,
                completedChunkIndexes: completed, sources: cp.sources)
            let encoderJSON = JSONEncoder()
            encoderJSON.outputFormatting = [.sortedKeys]
            let data = try encoderJSON.encode(updated)
            try data.write(to: checkpointURL, options: [.atomic])
        }

        // Concatenate all chunks in index order (passthrough — no re-encode).
        yield(ExportProgress(phase: .concatenating, currentFrame: total, totalFrames: total,
                             elapsed: 0, renderFPS: 0))
        let chunkURLs = (0..<chunkCount).map {
            ExportCheckpoint.chunkURL(out: job.out, index: $0, container: container)
        }
        try await concatChunks(urls: chunkURLs, container: container, partialURL: job.partialURL)
        // Atomic handoff (same pattern as `runJob`/`runLongFormJob`).
        if FileManager.default.fileExists(atPath: job.out.path) { try FileManager.default.removeItem(at: job.out) }
        try FileManager.default.moveItem(at: job.partialURL, to: job.out)
        // Success cleanup: delete the checkpoint + ALL chunk temps.
        Self.discardCheckpointAndChunks(out: job.out, container: container)
    }

    /// Build checkpoint `Source`s for a fresh run from the job's flames. The
    /// coordinator has no source file URLs (the VM threads those in Task 6), so
    /// this uses the `serializedText` fallback (`Flam3Serializer.serialize`).
    /// Each source is a SINGLE-flame document ⇒ `flameIndex: 0` (the parse
    /// result always has exactly 1 element; `job` flame ORDER is preserved by
    /// array position, not by `flameIndex`).
    private static func freshSources(for job: ExportJob) -> [ExportCheckpoint.Source] {
        job.flames.enumerated().map { (i, flame) in
            ExportCheckpoint.Source(fileURL: nil, flameIndex: 0, sha256: nil,
                                    serializedText: Flam3Serializer.serialize([flame]),
                                    displayName: "flame \(i)")
        }
    }

    /// D6-primary source finalization for a fresh run. The caller (VM/CLI)
    /// threads `sources` from the loaded genomes' file URLs; this fills the
    /// SHA-256 of each URL's CURRENT bytes so the checkpoint locks the source
    /// content (a later tamper is caught on resume by `reparseSources`'s hash
    /// check). A URL-less source keeps its `serializedText` (the caller may have
    /// pre-serialized an in-memory flame). When the caller passed NO sources
    /// (`passed.isEmpty` — the Task-4/5 fallback, and the CLI's URL-less path),
    /// this falls back to `freshSources(for:)` so those tests stay valid.
    /// Determinism (rule #2): SHA-256 is a pure function of the file bytes; no
    /// Dict/Set iteration is involved.
    private static func finalizeFreshSources(passed: [ExportCheckpoint.Source],
                                             for job: ExportJob) -> [ExportCheckpoint.Source] {
        guard !passed.isEmpty else { return freshSources(for: job) }
        return passed.map { source in
            if let fileURL = source.fileURL {
                let hash: String? = (try? Data(contentsOf: fileURL)).map {
                    SHA256.hash(data: $0).map { String(format: "%02x", Int($0)) }.joined()
                }
                return ExportCheckpoint.Source(
                    fileURL: fileURL, flameIndex: source.flameIndex,
                    sha256: hash, serializedText: nil, displayName: source.displayName)
            } else {
                return source   // already carries serializedText (URL-less flame)
            }
        }
    }

    /// Task 5 resume (spec §2.3/D6): re-read + SHA-256-verify + re-parse each
    /// checkpoint `Source`. A `fileURL` source re-reads the file bytes, compares
    /// the hex SHA-256 to the stored hash (mismatch or unreadable file ⇒
    /// `.checkpointSourceChanged(index:)`), then selects `flameIndex` from the
    /// parse result. A URL-less source falls back to `serializedText`. This is
    /// the determinism guarantee (rule #2): same source bytes (hash-gated) →
    /// same parse → identical `Flame` → pixel-identical resume frames.
    private static func reparseSources(_ sources: [ExportCheckpoint.Source]) throws -> [Flame] {
        var flames: [Flame] = []
        flames.reserveCapacity(sources.count)
        for (idx, source) in sources.enumerated() {
            let flame: Flame
            if let fileURL = source.fileURL {
                guard let bytes = try? Data(contentsOf: fileURL) else {
                    throw ExportError.checkpointSourceChanged(index: idx)
                }
                if let stored = source.sha256 {
                    let hash = SHA256.hash(data: bytes)
                        .map { String(format: "%02x", Int($0)) }.joined()
                    if hash != stored {
                        throw ExportError.checkpointSourceChanged(index: idx)
                    }
                }
                let parsed = try Flam3Parser.parse(bytes)
                guard source.flameIndex < parsed.count else {
                    throw ExportError.checkpointSourceChanged(index: idx)
                }
                flame = parsed[source.flameIndex]
            } else if let text = source.serializedText {
                let parsed = try Flam3Parser.parse(Data(text.utf8))
                guard source.flameIndex < parsed.count else {
                    throw ExportError.checkpointSourceChanged(index: idx)
                }
                flame = parsed[source.flameIndex]
            } else {
                throw ExportError.checkpointSourceChanged(index: idx)
            }
            flames.append(flame)
        }
        return flames
    }

    /// M6.1 (D4): delete the checkpoint + ALL chunk temps beside `out`. `static`
    /// — no actor, no coordinator — so it works after pause has nilled the
    /// coordinator (the real post-pause condition). Sweeps by the
    /// `emberweft-chunk-` prefix (D16: distinct from `runLongForm`'s `m6-seg-`).
    /// Called here on success; by the VM's `discardPaused` / GUI-cancel catch
    /// (Task 6); never by the CLI SIGINT path (D3′ — keeps for `--resume`).
    public static func discardCheckpointAndChunks(out: URL, container: ExportSettings.Container) {
        let cp = ExportCheckpoint.checkpointURL(out: out)
        try? FileManager.default.removeItem(at: cp)
        let dir = out.deletingLastPathComponent()
        let stem = ExportCheckpoint.sanitizedStem(out)
        let prefix = "\(stem).emberweft-chunk-"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for e in entries where e.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(e))
            }
        }
    }

    /// Batch body (actor-isolated). Iterates `jobs.indices` in order. For each
    /// job: (1) honor cancel at the top (remaining jobs never start once
    /// cancelled); (2) health-gate `flames` via `isRenderable` — an empty
    /// renderable set records `failed` and continues (or stops on `failFast`);
    /// (3) drive the per-job `run`/`runLongForm` sub-stream, mapping each
    /// `ExportProgress` to a `BatchProgress`. A thrown error from the sub-stream
    /// is either cancel (always stop the batch) or a render/encode failure
    /// (record + continue, or stop on `failFast`).
    ///
    /// The sub-stream's own unstructured Task calls `await self.runJob(...)` /
    /// `runLongFormJob(...)`; when this body `for try await`s the sub-stream it
    /// SUSPENDS, releasing the actor so the sub-stream's Task can re-enter and
    /// do the per-frame work. Only one sub-stream is alive at a time (serial),
    /// so there is no reentrancy hazard.
    private func runBatchBody(_ jobs: [ExportJob], failFast: Bool,
                              yield: @Sendable (BatchProgress) -> Void) async throws {
        let total = jobs.count
        guard total > 0 else { return }
        for j in jobs.indices {
            // Cancel scope = remaining jobs: a cancel observed between jobs
            // short-circuits before any work for job `j` begins.
            if cancelled || Task.isCancelled { throw ExportError.cancelled }
            let job = jobs[j]

            // Health gate (mirrors ExportCommand's `flames.filter { isRenderable }`).
            let renderable = job.flames.filter { $0.isRenderable }
            if renderable.isEmpty {
                yield(BatchProgress(jobIndex: j, totalJobs: total, jobFrame: 0, jobTotalFrames: 0,
                                    aggregateFraction: Double(j) / Double(total), failed: true))
                if failFast { return }
                continue
            }
            // Rebuild with the filtered flames when some were dropped (keeps the
            // per-job path's "degenerate genomes skipped" contract; no-op when
            // all flames are renderable, which is the common case).
            let effective: ExportJob = renderable.count == job.flames.count ? job
                : ExportJob(settings: job.settings, flames: renderable, framesPerSegment: job.framesPerSegment,
                            transitionFramesPerSegment: job.transitionFramesPerSegment,
                            segmentCount: job.segmentCount, selector: job.selector, seed: job.seed,
                            loopCycles: job.loopCycles, stagger: job.stagger, out: job.out,
                            loopRepeatCount: job.loopRepeatCount)

            let longForm = job.settings.segmentFrameBudget > 0
            // Same-actor synchronous call: `run`/`runLongForm` return the stream
            // immediately and attach their own unstructured Task.
            let sub = longForm ? self.runLongForm(effective) : self.run(effective)
            do {
                for try await p in sub {
                    let frac = (Double(j) + Double(p.currentFrame) / Double(max(1, p.totalFrames))) / Double(total)
                    yield(BatchProgress(jobIndex: j, totalJobs: total, jobFrame: p.currentFrame,
                                        jobTotalFrames: p.totalFrames, aggregateFraction: frac, failed: false))
                }
            } catch {
                // Defensive cleanup of this job's partial + long-form temps. The
                // inner `runJob`/`runLongFormJob` already cleans on throw; this
                // catches any stray a stream-error path could leave (the partial
                // URL is `<out>.partial-<pid>.<ext>`, beside `out` on the same
                // volume → safe to remove).
                try? FileManager.default.removeItem(at: effective.partialURL)
                if longForm {
                    let outDir = effective.out.deletingLastPathComponent()
                    if let entries = try? FileManager.default.contentsOfDirectory(atPath: outDir.path) {
                        for e in entries where e.hasPrefix("m6-seg-") {
                            try? FileManager.default.removeItem(at: outDir.appendingPathComponent(e))
                        }
                    }
                }
                // Cancel (cooperative or external) ALWAYS stops the batch — it
                // is not a recordable failure, it is an out-of-band "stop all".
                if case ExportError.cancelled = error { throw error }
                // Otherwise: record the per-job failure and continue, or stop on
                // `failFast`. The yielded event lets the consumer tally
                // failures and compute the batch exit code.
                yield(BatchProgress(jobIndex: j, totalJobs: total, jobFrame: 0, jobTotalFrames: 0,
                                    aggregateFraction: Double(j) / Double(total), failed: true))
                if failFast { return }
                // else: continue to the next job.
            }
        }
    }

    private func makeSelector(_ spec: SelectorSpec) -> any PairSelector {
        switch spec {
        case .sequential: return Sequential(seed: 0)
        case .similarity: return Sequential(seed: 0)   // M6: sequential only; similarity is a follow-up
        }
    }

    /// Loop-repeat memory guard (v0.5.0). When `loopRepeatCount > 1`, the
    /// coordinator caches one loop segment's frames in memory
    /// (`framesPerSegment × W × H × 4` bytes) before replaying them. This refuses
    /// the job up front if that cache would exceed the safe threshold: ~50% of
    /// physical RAM, floored at 2 GB (tiny machines) and ceiling ~12 GB (huge
    /// machines, so the guard is machine-independent for a given cache size).
    /// No-op when `loopRepeatCount == 1` (no cache is built). Checked BEFORE
    /// `diskPrecheck` and encoder creation → no partial file on refusal.
    private static func checkLoopRepeatMemory(job: ExportJob, width: Int, height: Int) throws {
        guard job.loopRepeatCount > 1 else { return }
        let frames = Int64(job.framesPerSegment)
        let cacheBytes = frames * Int64(width) * Int64(height) * 4
        let phys = Int64(ProcessInfo.processInfo.physicalMemory)
        // floor 2 GB, ceiling ~12 GB; target 50% of physical RAM.
        let floor: Int64 = 2_000_000_000
        let ceiling: Int64 = 12_000_000_000
        let threshold = min(max(phys / 2, floor), ceiling)
        if cacheBytes > threshold {
            throw ExportError.loopRepeatMemoryExceeded(
                neededMB: Int(cacheBytes / 1_000_000),
                availableMB: Int(threshold / 1_000_000))
        }
    }

    private static func diskPrecheck(job: ExportJob) throws {
        // Estimate per spec D13: ceil(bitrate * durationSeconds / 8 * 1.25) +
        // 25% headroom. bitrate is bits/s; /8 -> bytes/s; *duration -> total
        // bytes; *1.25 -> headroom for VBR peaks + container overhead. The
        // auto-bitrate table mirrors VideoEncoder.autoBitrate at the chosen
        // codec/res/fps so the estimate tracks the encoder's actual target.
        // Total frames sums per-kind (loops use framesPerSegment, transitions
        // use transitionFramesPerSegment) — matches `Schedule.totalFrames`,
        // scaled by `loopRepeatCount` for loops (v0.5.0: a repeated loop emits
        // `loopRepeatCount`× its frames to disk).
        let loops = (job.segmentCount + 1) / 2
        let trans = job.segmentCount / 2
        let totalFrames = loops * job.framesPerSegment * job.loopRepeatCount
            + trans * job.transitionFramesPerSegment
        let fps = max(1, job.settings.fps)
        let durationSeconds = Double(totalFrames) / Double(fps)
        let mbps: Int
        switch job.settings.bitrate {
        case .auto:
            if job.settings.codec.isProRes {
                // ProRes 422 HQ ≈ 220 Mbps @ 1080p25, scaling linearly with
                // pixels × fps (≈ 0.45 × W×H×fps / (1920×1080×25) Mbps). The
                // disk guard matters: 4K60 ≈ 1.8 GB/min. ProRes ignores the
                // bitrate table (autoBitrateMbps returns 0 for it), so the
                // data-rate is estimated here directly.
                let pixels = Double(job.settings.resolution.width * job.settings.resolution.height)
                mbps = max(1, Int(0.45 * pixels * Double(fps) / (1920.0 * 1080.0 * 25.0)))
            } else {
                mbps = Self.autoBitrateMbps(codec: job.settings.codec, res: job.settings.resolution, fps: fps)
            }
        case .mbps(let m):
            mbps = m
        }
        let bytes = Int64(Double(mbps) * 1_000_000 * durationSeconds / 8.0 * 1.25).advanced(by: 1)
        let parent = job.out.deletingLastPathComponent()
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: parent.path),
           let free = attrs[.systemFreeSize] as? NSNumber, free.int64Value < bytes {
            throw ExportError.diskFull
        }
    }

    /// Mirrors `VideoEncoder.autoBitrate` (Mbps, pre-`*1_000_000`) for the disk
    /// precheck (kept here so it does not depend on instantiating a
    /// `VideoEncoder`). ProRes returns 0 here — the disk estimate for ProRes is
    /// computed from the known data rate in `diskPrecheck` (the bitrate table
    /// does not apply). MUST stay in sync with `VideoEncoder.autoBitrate`.
    private static func autoBitrateMbps(codec: ExportSettings.Codec, res: ExportSettings.Resolution, fps: Int) -> Int {
        if codec.isProRes { return 0 }
        let hevc: [ExportSettings.Resolution: Int] = [.p720: 25, .p1080: 50, .p1440: 80, .p4k: 150]
        let h264: [ExportSettings.Resolution: Int] = [.p720: 40, .p1080: 80, .p1440: 130, .p4k: 240]
        let isHEVC = codec == .hevc
        let table = isHEVC ? hevc : h264
        let fallback = isHEVC ? 50 : 80
        let big = isHEVC ? 150 : 240
        let base = table[res] ?? (res.width * res.height >= 3_840 * 2160 ? big : fallback)
        let fpsMult = fps >= 60 ? 1.5 : 1.0
        return Int(Double(base) * fpsMult)
    }
}
