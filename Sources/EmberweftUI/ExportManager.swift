import Foundation
import FlameKit
import FlameRenderer
import FlameExport

/// Terminal/non-terminal export state observed by the banner (spec §4.4).
/// `.completed` carries the output URL (single/sequence: the file; batch: the
/// directory). `.failed` carries a localized message.
public enum ExportState: Sendable, Equatable {
    case idle
    case running
    case cancelling
    case completed(URL)
    case failed(String)
    case cancelled
}

/// A single normalized progress sample for the banner (spec §4.4). Pure value
/// type; `fraction` is computed from `currentFrame`/`totalFrames` (deterministic,
/// rule #2 — no float sum over a hashed collection). `jobIndex`/`totalJobs`
/// carry batch context (`0`/`1` for single/sequence).
public struct ExportProgressSnapshot: Sendable, Equatable {
    public var phase: ExportProgress.Phase
    public var currentFrame: Int
    public var totalFrames: Int
    public var elapsed: TimeInterval
    public var renderFPS: Double
    public var jobIndex: Int
    public var totalJobs: Int

    public var fraction: Double {
        totalFrames > 0 ? Double(currentFrame) / Double(totalFrames) : 0
    }

    public init(phase: ExportProgress.Phase, currentFrame: Int, totalFrames: Int,
                elapsed: TimeInterval, renderFPS: Double, jobIndex: Int, totalJobs: Int) {
        self.phase = phase
        self.currentFrame = currentFrame
        self.totalFrames = totalFrames
        self.elapsed = elapsed
        self.renderFPS = renderFPS
        self.jobIndex = jobIndex
        self.totalJobs = totalJobs
    }

    /// Identity element (no frames yet). `totalJobs == 1` so `fraction` is 0
    /// (not divide-by-zero).
    public static let empty = ExportProgressSnapshot(
        phase: .rendering, currentFrame: 0, totalFrames: 0, elapsed: 0,
        renderFPS: 0, jobIndex: 0, totalJobs: 1)
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

    // The editable config (bound two-way by the sheet):
    public var codec: ExportSettings.Codec = .proRes422HQ
    public var container: ExportSettings.Container = .mov
    public var resolution: ExportSettings.Resolution = .p1080
    public var fps: Int = 30
    public var qualityChoice: ExportQualityChoice = .genomeDefault
    public var backendChoice: BackendChoice = .auto
    /// 1 ⇒ genome default (resolved, motion blur); see `ExportSettings.resolve`.
    public var temporalSamples: Int = 1
    /// Loop duration in seconds ⇒ `framesPerSegment = round(loopDurationSeconds * fps)`.
    public var loopDurationSeconds: Double = 6.0
    /// Transition ("edge") duration in seconds ⇒
    /// `transitionFramesPerSegment = round(transitionDurationSeconds * fps)`.
    /// Default SHORTER than the loop (3 s vs 6 s) so loops breathe while edges
    /// stay brief — the owner finds edges less interesting and doesn't want to
    /// get stuck on them. Tunable via the export sheet stepper.
    public var transitionDurationSeconds: Double = 3.0
    public var bitrate: ExportSettings.Bitrate = .auto

    // MARK: - In-flight state (private)

    private var coordinator: (any ExportCoordinating)?
    private var consumeTask: Task<Void, Never>?
    private var activityToken: NSObjectProtocol?   // ProcessInfo sleep token (G10)

    // MARK: - Test seams

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

    /// True iff an export can start now (not running/cancelling).
    public var canStart: Bool {
        switch state {
        case .running, .cancelling: return false
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

    /// Export a single genome (one loop). Routed to `coordinator.run(job)` with
    /// `segmentCount == 1`.
    public func exportSingle(flame: Flame, displayName: String, out: URL, seed: UInt64) async {
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
            loopCycles: 1, stagger: 0.0, out: out)
        startExport(.runJob(job: job), label: displayName, backend: backend)
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
    public func exportSequence(flames: [Flame], displayName: String, out: URL, seed: UInt64) async {
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
            loopCycles: 1, stagger: 0.0, out: out)
        startExport(.runJob(job: job), label: displayName, backend: backend)
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
                loopCycles: 1, stagger: 0.0, out: out)
            jobs.append(job)
        }
        startExport(.runBatch(jobs: jobs, baseDir: baseDir),
                    label: "\(renderable.count) genome\(renderable.count == 1 ? "" : "s")",
                    backend: backend)
    }

    /// Cancel the in-flight export (D-G13). Sets `.cancelling`, then
    /// `await coordinator?.cancel()` (the coordinator's flag is the authoritative
    /// stop — checked between frames in `renderFrames`). The in-flight frame
    /// finishes, the next iteration throws `.cancelled`, and `consumeTask`'s
    /// catch sets `.cancelled` + clears `coordinator`/`consumeTask`.
    ///
    /// Does NOT `consumeTask?.cancel()` as the cancel path: the coordinator's
    /// inner `Task` is not a child of `consumeTask`, so `Task.cancel()` does not
    /// reach it; only `coordinator.cancel()` (the flag) does.
    public func cancel() async {
        // Guard: nothing to cancel (idle, already cancelled, or consumeTask
        // already completed and cleared the coordinator).
        guard coordinator != nil else { return }
        guard state == .running else { return }
        state = .cancelling
        await coordinator?.cancel()
    }

    /// Reset to `.idle` (clears snapshot/result so the banner dismisses).
    /// No-op while an export is in flight (safety).
    public func reset() {
        switch state {
        case .running, .cancelling:
            break
        case .idle, .completed, .failed, .cancelled:
            state = .idle
            snapshot = .empty
            sourceLabel = ""
            skipNotice = nil
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

    /// What the entry point built. `runJob` covers single+sequence (one
    /// continuous encode via `coordinator.run`); `runBatch` covers batch
    /// (serial `coordinator.runBatch`).
    private enum ExportKind {
        case runJob(job: ExportJob)
        case runBatch(jobs: [ExportJob], baseDir: URL)
    }

    private func resolveSettings(baseFlame: Flame, backend: ExportCoordinator.Backend) -> ExportSettings {
        ExportSettings.resolve(
            quality: qualityChoice.exportQuality,
            temporalSamples: temporalSamples,
            codec: codec, container: container, fps: fps, bitrate: bitrate,
            resolution: resolution, segmentFrameBudget: 0,
            baseFlame: baseFlame, backend: backend)
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
        let coord = coordinatorFactory(backend, true)
        coordinator = coord
        state = .running
        acquireActivity()
        consumeTask = Task { [weak self] in
            // [weak self] is SAFE here: ExportManager is held by AppModel
            // (app-lifetime @State), so it is never released mid-export. Weak
            // still guards the theoretical app-teardown path.
            guard let self else { return }
            guard let coord = self.coordinator else { return }   // no force-unwrap
            do {
                let completionURL: URL
                switch kind {
                case .runJob(let job):
                    let stream = await coord.run(job)
                    for try await event in stream {
                        if Task.isCancelled { break }
                        self.snapshot = Self.snapshot(from: .single(event))
                    }
                    completionURL = job.out
                case .runBatch(let jobs, let baseDir):
                    let stream = await coord.runBatch(jobs, failFast: false)
                    for try await event in stream {
                        if Task.isCancelled { break }
                        self.snapshot = Self.snapshot(from: .batch(event))
                    }
                    completionURL = baseDir
                }
                self.state = .completed(completionURL)
            } catch is CancellationError {
                self.state = .cancelled
            } catch ExportError.cancelled {
                self.state = .cancelled
            } catch ExportError.diskFull {
                self.state = .failed("Not enough free disk space.")
            } catch ExportError.metalUnavailable {
                self.state = .failed("Metal is unavailable. Try the CPU backend.")
            } catch {
                self.state = .failed(error.localizedDescription)
            }
            // ALWAYS release the sleep token (G10), then clear the cycle.
            self.releaseActivity()
            self.coordinator = nil
            self.consumeTask = nil   // break self → consumeTask → task → self
        }
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
