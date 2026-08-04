import Foundation
import AVFoundation      // AVVideoCodecType for diskPrecheck's bitrate estimate
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

    /// `yield` is `@Sendable` so the closure built in `run`'s unstructured Task
    /// (which captures the `AsyncThrowingStream.Continuation`, itself Sendable)
    /// crosses the actor boundary cleanly under Swift 6 strict concurrency.
    private func runJob(_ job: ExportJob, yield: @Sendable (ExportProgress) -> Void) async throws {
        let res = job.settings.resolution
        let (spp, os) = job.settings.quality.resolvedSamplesPerPixel(for: job.flames[0])
        let params = RenderParams(seed: job.seed, width: max(1, res.width), height: max(1, res.height),
                                  oversample: os, samplesPerPixel: spp)
        let useMetal = (backend == .metal)
        // Disk precheck (D13).
        try Self.diskPrecheck(job: job)
        // Build the plan.
        let selector = makeSelector(job.selector)
        var schedule = Schedule(librarySize: job.flames.count, framesPerSegment: job.framesPerSegment,
                                transitionFramesPerSegment: job.transitionFramesPerSegment,
                                selector: selector, seed: job.seed)
        let plan = FramePlan(schedule: &schedule, segmentCount: job.segmentCount, flames: job.flames,
                             loopCycles: job.loopCycles, stagger: job.stagger,
                             temporalSamples: max(1, job.settings.temporalSamples))
        // Budget (Metal only); nil for CPU. baseSeed = params.seed for byte-identity
        // with the nil path (Task 2 acceleration).
        let budget: MetalRenderer.ThreadSeedBudget? = useMetal ? MetalRenderer.ThreadSeedBudget(baseSeed: params.seed) : nil

        let encoder = try VideoEncoder(settings: job.settings, outputURL: job.partialURL)
        try encoder.start()
        do {
            // Per-frame render loop shared with `runLongForm` (Task 6). Range
            // `[0, totalFrames)` into one encoder = byte-identical to the prior
            // inline loop; the extraction only factors the body into a helper.
            try await renderFrames(plan: plan, params: params, budget: budget, useMetal: useMetal,
                                   range: 0..<plan.totalFrames, into: encoder, yield: yield)
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
    private func renderFrames(
        plan: FramePlan,
        params: RenderParams,
        budget: MetalRenderer.ThreadSeedBudget?,
        useMetal: Bool,
        range: Range<Int>,
        into encoder: VideoEncoder,
        yield: @Sendable (ExportProgress) -> Void
    ) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        for gf in range {
            if cancelled || Task.isCancelled { throw ExportError.cancelled }
            let d = plan.descriptor(for: gf)
            let img: RGBA8Image
            if useMetal && useOffMainMetal {
                // GUI export path (M6-G.2): render off-main via
                // `renderOffMain`/`renderTemporalOffMain` inside a `Task.detached`,
                // so the MainActor is never blocked (no UI freeze). Field names
                // mirror the MainActor branch VERBATIM (`d.blend`/`d.blendAt`/
                // `d.temporal`/`d.sumfilt`; single-vs-temporal via
                // `plan.temporalSamples > 1` — FramePlan.swift:7-24 has no
                // `centerTime`/`flame` field). The SAME `budget`
                // (`ThreadSeedBudget(baseSeed: params.seed)`, built once per export
                // at the single `ThreadSeedBudget(baseSeed:)` site above) is passed
                // — `renderOffMain`/`renderTemporalOffMain` select per-pass seeds
                // internally via `seeds(forPass:threadCount:)`, byte-identical to
                // the MainActor path. nil ⇒ Metal unavailable / render failed /
                // non-box temporal (defensive) ⇒ `.metalUnavailable`.
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
                img = offMainImg
            } else if useMetal {
                img = await MainActor.run {
                    autoreleasepool {
                        plan.temporalSamples > 1
                            ? MetalRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                                   temporal: d.temporal, sumfilt: d.sumfilt, params: params, seedBudget: budget)
                            : MetalRenderer.render(flame: d.blendAt(d.blend), params: params, seedBudget: budget)
                    }
                }
            } else {
                img = await Task.detached(priority: .userInitiated) {
                    plan.temporalSamples > 1
                        ? ReferenceRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                                   temporal: d.temporal, sumfilt: d.sumfilt, params: params)
                        : ReferenceRenderer.render(flame: d.blendAt(d.blend), params: params)
                }.value
            }
            // PTS is LOCAL to this encoder's session (session always starts at
            // .zero). For `runJob` range.lowerBound == 0 so this is identical to
            // the prior inline `atFrame: gf`. For a long-form chunk the local
            // index resets per chunk → each chunk is an independent N-frame
            // stream; the concat shifts each to its cumulative offset. Passing
            // the GLOBAL index here would leave a `lowerBound`-frame black gap
            // at the front of every chunk's stream.
            try await encoder.append(img, atFrame: gf - range.lowerBound)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            yield(ExportProgress(phase: .rendering, currentFrame: gf + 1, totalFrames: plan.totalFrames,
                                 elapsed: elapsed, renderFPS: elapsed > 0 ? Double(gf + 1) / elapsed : 0))
        }
    }

    /// Long-form body. Same setup as `runJob` (params/plan/budget), then chunk
    /// the timeline on segment edges, encode each chunk to a temp `.mov`, concat
    /// via passthrough, atomic-rename to `out`.
    private func runLongFormJob(_ job: ExportJob, yield: @Sendable (ExportProgress) -> Void) async throws {
        let res = job.settings.resolution
        let (spp, os) = job.settings.quality.resolvedSamplesPerPixel(for: job.flames[0])
        let params = RenderParams(seed: job.seed, width: max(1, res.width), height: max(1, res.height),
                                  oversample: os, samplesPerPixel: spp)
        let useMetal = (backend == .metal)
        // Disk precheck (D13) — same estimate as single export.
        try Self.diskPrecheck(job: job)
        let selector = makeSelector(job.selector)
        var schedule = Schedule(librarySize: job.flames.count, framesPerSegment: job.framesPerSegment,
                                transitionFramesPerSegment: job.transitionFramesPerSegment,
                                selector: selector, seed: job.seed)
        let plan = FramePlan(schedule: &schedule, segmentCount: job.segmentCount, flames: job.flames,
                             loopCycles: job.loopCycles, stagger: job.stagger,
                             temporalSamples: max(1, job.settings.temporalSamples))
        let budget: MetalRenderer.ThreadSeedBudget? = useMetal ? MetalRenderer.ThreadSeedBudget(baseSeed: params.seed) : nil

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
                                       range: frameStart..<frameEnd, into: encoder, yield: yield)
                try await encoder.finish()
            } catch {
                encoder.cancel(); try? FileManager.default.removeItem(at: tempURL); throw error
            }
            segStart = segEnd
        }

        // --- Concatenate via AVMutableComposition + passthrough (no re-encode) ---
        yield(ExportProgress(phase: .concatenating, currentFrame: totalFrames, totalFrames: totalFrames,
                             elapsed: 0, renderFPS: 0))
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.encodeFailed
        }
        var cursor = CMTime.zero
        for segURL in temps {
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
        let outType: AVFileType = job.settings.container == .mov ? .mov : .mp4
        exporter.outputURL = job.partialURL
        exporter.outputFileType = outType
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed: cont.resume()
                case .cancelled: cont.resume(throwing: ExportError.cancelled)
                default: cont.resume(throwing: exporter.error ?? ExportError.encodeFailed)
                }
            }
        }
        // Atomic handoff (same pattern as `runJob`). `partialURL` is beside `out`
        // on the same volume → rename is atomic.
        if FileManager.default.fileExists(atPath: job.out.path) { try FileManager.default.removeItem(at: job.out) }
        try FileManager.default.moveItem(at: job.partialURL, to: job.out)
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
                            loopCycles: job.loopCycles, stagger: job.stagger, out: job.out)

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

    private static func diskPrecheck(job: ExportJob) throws {
        // Estimate per spec D13: ceil(bitrate * durationSeconds / 8 * 1.25) +
        // 25% headroom. bitrate is bits/s; /8 -> bytes/s; *duration -> total
        // bytes; *1.25 -> headroom for VBR peaks + container overhead. The
        // auto-bitrate table mirrors VideoEncoder.autoBitrate at the chosen
        // codec/res/fps so the estimate tracks the encoder's actual target.
        // Total frames sums per-kind (loops use framesPerSegment, transitions
        // use transitionFramesPerSegment) — matches `Schedule.totalFrames`.
        let loops = (job.segmentCount + 1) / 2
        let trans = job.segmentCount / 2
        let totalFrames = loops * job.framesPerSegment + trans * job.transitionFramesPerSegment
        let fps = max(1, job.settings.fps)
        let durationSeconds = Double(totalFrames) / Double(fps)
        let mbps: Int
        switch job.settings.bitrate {
        case .auto:
            let codec: AVVideoCodecType = job.settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264
            mbps = Self.autoBitrateMbps(codec: codec, res: job.settings.resolution, fps: fps)
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

    /// Mirrors `VideoEncoder.autoBitrate` (Mbps, pre-`*1_000_000`). Kept here so
    /// the disk precheck does not depend on instantiating a `VideoEncoder`.
    private static func autoBitrateMbps(codec: AVVideoCodecType, res: ExportSettings.Resolution, fps: Int) -> Int {
        let hevc: [ExportSettings.Resolution: Int] = [.p720: 5, .p1080: 10, .p1440: 16, .p4k: 30]
        let base = hevc[res] ?? (res.width * res.height >= 3_840 * 2160 ? 30 : 10)
        let mult = codec == .hevc ? 1.0 : 1.5
        let fpsMult = fps >= 60 ? 1.5 : 1.0
        return Int(Double(base) * mult * fpsMult)
    }
}
