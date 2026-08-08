import XCTest
@testable import EmberweftUI
import FlameExport
import FlameKit
import FlameRenderer

@MainActor
final class ExportManagerTests: XCTestCase {

    // MARK: - Fixtures

    /// A renderable flame (non-degenerate camera + a positive-weight xform).
    private func renderableFlame() -> Flame {
        Flame(
            camera: Camera(center: .zero, scale: 250, zoom: 0, rotation: 0),
            quality: Quality(oversample: 1, samplesPerPixel: 50),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])]
        )
    }

    private func outURL(_ name: String = "out") -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).mp4")
    }

    private func batchDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("emberweft-export-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func progressEvent(frame: Int, total: Int) -> ExportProgress {
        ExportProgress(phase: .rendering, currentFrame: frame, totalFrames: total,
                       elapsed: Double(frame) * 0.03, renderFPS: 30)
    }

    private func batchEvent(job: Int, totalJobs: Int, frame: Int, totalFrames: Int,
                            failed: Bool = false) -> BatchProgress {
        let frac = totalJobs > 0
            ? (Double(job) + (totalFrames > 0 ? Double(frame) / Double(totalFrames) : 0)) / Double(totalJobs)
            : 0
        return BatchProgress(jobIndex: job, totalJobs: totalJobs, jobFrame: frame,
                             jobTotalFrames: totalFrames, aggregateFraction: frac, failed: failed)
    }

    // MARK: - FakeCoordinator (spec §9.4: an `ExportCoordinating` fake)

    /// An actor fake for `ExportCoordinating` — automatically `Sendable` (crosses
    /// the `coordinatorFactory` boundary). Scripts its stream via `Script` and
    /// records `cancel()`/`run`/`runBatch` for assertions. Cancel cooperation is
    /// race-free under actor serialization: `cancel()` sets a flag + finishes a
    /// stored continuation; a `.yieldUntilCancelled` run checks the flag after
    /// yielding (or throws immediately if cancel already ran).
    actor FakeCoordinator: ExportCoordinating {
        enum Script {
            /// `run` yields these `ExportProgress` events then finishes (success).
            case yieldProgress([ExportProgress])
            /// `run` throws immediately.
            case throwImmediately(Error)
            /// `run` yields events then throws.
            case yieldThenThrow([ExportProgress], Error)
            /// `run` yields one event then parks until `cancel()` finishes the stream.
            case yieldUntilCancelled
            /// `runBatch` yields these `BatchProgress` events then finishes.
            case batchYield([BatchProgress])
            /// `runBatch` throws immediately.
            case batchThrow(Error)
        }

        private let script: Script
        private(set) var cancelCount = 0
        private(set) var runPartialURLs: [URL] = []
        private(set) var runSegmentCounts: [Int] = []
        private(set) var runLoopRepeatCounts: [Int] = []
        private(set) var runBatchCalls: [(jobCount: Int, failFast: Bool)] = []
        private(set) var runBatchOuts: [URL] = []
        private(set) var runBatchLoopRepeatCounts: [Int] = []
        private var cancelled = false
        private var storedSingleCont: AsyncThrowingStream<ExportProgress, Error>.Continuation?

        init(script: Script) { self.script = script }

        func run(_ job: ExportJob) async -> AsyncThrowingStream<ExportProgress, Error> {
            runPartialURLs.append(job.partialURL)
            runSegmentCounts.append(job.segmentCount)
            runLoopRepeatCounts.append(job.loopRepeatCount)
            return AsyncThrowingStream { continuation in
                // The build closure is `@Sendable`; hop back onto this actor via a
                // Task to read/write isolated state (mirrors the real coordinator).
                Task { [self] in
                    await self.driveSingle(continuation)
                }
            }
        }

        private func driveSingle(_ cont: AsyncThrowingStream<ExportProgress, Error>.Continuation) async {
            switch script {
            case .yieldProgress(let events):
                for e in events { cont.yield(e) }
                cont.finish()
            case .throwImmediately(let err):
                cont.finish(throwing: err)
            case .yieldThenThrow(let events, let err):
                for e in events { cont.yield(e) }
                cont.finish(throwing: err)
            case .yieldUntilCancelled:
                // Race-free under actor serialization: either cancel() ran first
                // (cancelled == true ⇒ throw now), or it runs after we park
                // (cancel() finishes storedSingleCont).
                storedSingleCont = cont
                cont.yield(ExportProgress(phase: .rendering, currentFrame: 0,
                                          totalFrames: 10, elapsed: 0, renderFPS: 30))
                if cancelled {
                    storedSingleCont = nil
                    cont.finish(throwing: ExportError.cancelled)
                }
            case .batchYield, .batchThrow:
                // `run` got a batch script: no progress to yield; finish cleanly
                // (a misconfigured test, not a real scenario).
                cont.finish()
            }
        }

        func runBatch(_ jobs: [ExportJob], failFast: Bool) async -> AsyncThrowingStream<BatchProgress, Error> {
            runBatchCalls.append((jobs.count, failFast))
            runBatchOuts.append(contentsOf: jobs.map(\.out))
            runBatchLoopRepeatCounts.append(contentsOf: jobs.map(\.loopRepeatCount))
            return AsyncThrowingStream { continuation in
                Task { [self] in
                    await self.driveBatch(continuation)
                }
            }
        }

        private func driveBatch(_ cont: AsyncThrowingStream<BatchProgress, Error>.Continuation) async {
            switch script {
            case .batchYield(let events):
                for e in events { cont.yield(e) }
                cont.finish()
            case .batchThrow(let err):
                cont.finish(throwing: err)
            default:
                cont.finish()   // runBatch got a single script; no-op
            }
        }

        func cancel() async {
            cancelCount += 1
            cancelled = true
            let cont = storedSingleCont
            storedSingleCont = nil
            cont?.finish(throwing: ExportError.cancelled)
        }
    }

    // MARK: - Helpers

    /// Install a fake as the coordinator factory and return it for assertions.
    @discardableResult
    private func installFake(_ vm: ExportManager, script: FakeCoordinator.Script) -> FakeCoordinator {
        let fake = FakeCoordinator(script: script)
        vm.coordinatorFactory = { _, _ in fake }
        return fake
    }

    /// No-op sleep-token hooks (so tests don't actually prevent system sleep).
    private func useNoOpSleepHooks(_ vm: ExportManager) {
        vm.beginSleepActivity = { NSObject() }
        vm.endSleepActivity = { _ in }
    }

    // MARK: - State machine (spec §9.4 testExportManagerStateMachine)

    func testIdleInitialState() {
        let vm = ExportManager()
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.snapshot, .empty)
        XCTAssertTrue(vm.canStart)
    }

    func testStateMachineSuccessTransitionsToCompleted() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .yieldProgress([
            progressEvent(frame: 0, total: 2),
            progressEvent(frame: 1, total: 2),
            progressEvent(frame: 2, total: 2),
        ]))
        let out = outURL()

        await vm.exportSingle(flame: renderableFlame(), displayName: "Sierpinski", out: out, seed: 1)
        await vm.awaitCompletion()

        XCTAssertEqual(vm.state, .completed(out))
        // The fake recorded the job's partialURL (engine D13 cleanup target).
        let partials = await fake.runPartialURLs
        XCTAssertEqual(partials.count, 1)
        XCTAssertTrue(partials[0].path.contains(".partial-"))
    }

    func testStateMachineDiskFullTransitionsToFailed() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .throwImmediately(ExportError.diskFull))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()

        guard case .failed(let message) = vm.state else {
            return XCTFail("expected .failed, got \(vm.state)")
        }
        XCTAssertEqual(message, "Not enough free disk space.")
    }

    func testStateMachineMetalUnavailableTransitionsToFailed() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .throwImmediately(ExportError.metalUnavailable))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()

        guard case .failed(let message) = vm.state else {
            return XCTFail("expected .failed, got \(vm.state)")
        }
        XCTAssertEqual(message, "Metal is unavailable. Try the CPU backend.")
    }

    func testStateMachineGenericErrorTransitionsToFailed() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        struct Weird: Error, LocalizedError {
            var errorDescription: String? { "weird failure" }
        }
        installFake(vm, script: .throwImmediately(Weird()))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()

        guard case .failed(let message) = vm.state else {
            return XCTFail("expected .failed, got \(vm.state)")
        }
        XCTAssertEqual(message, "weird failure")
    }

    func testStateMachineErrorAfterYieldTransitionsToFailed() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .yieldThenThrow(
            [progressEvent(frame: 0, total: 4)], ExportError.encodeFailed))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()

        if case .failed = vm.state { /* ok */ } else {
            XCTFail("expected .failed after mid-stream error, got \(vm.state)")
        }
    }

    func testStateMachineSequenceSuccessTransitionsToCompleted() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .yieldProgress([progressEvent(frame: 1, total: 3)]))
        let flames = [renderableFlame(), renderableFlame()]
        let out = outURL("seq")

        await vm.exportSequence(flames: flames, displayName: "Collection", out: out, seed: 7)
        await vm.awaitCompletion()

        XCTAssertEqual(vm.state, .completed(out))
        // Sequence routes through a single `run(job)` with segmentCount = 2N-1.
        let partials = await fake.runPartialURLs
        XCTAssertEqual(partials.count, 1)
    }

    // MARK: - Sequence segmentCount (the "3 of 5" truncation fix)

    /// `Schedule` alternates loop/transition by segment-id parity (seg0=loop(g0),
    /// seg1=trans(g0→g1), seg2=loop(g1), …). A full pass through N genomes (each
    /// looped once + transitions between consecutive ones) = N loops + (N−1)
    /// transitions = `2N − 1` segments. Passing only N walked the first N segments
    /// = loop,trans,loop,trans,loop = ⌈(N+1)/2⌉ genomes (3 of 5) — the bug.
    func testExportSequenceSegmentCountCoversAllGenomes() async {
        // N → expected segmentCount == 2N-1 (N=1 → single loop; N=3 → 5; N=5 → 9).
        let cases: [(n: Int, expected: Int)] = [(1, 1), (2, 3), (3, 5), (5, 9)]
        for (n, expected) in cases {
            let vm = ExportManager()
            useNoOpSleepHooks(vm)
            let fake = installFake(vm, script: .yieldProgress([progressEvent(frame: 1, total: 1)]))
            let flames = (0..<n).map { _ in renderableFlame() }

            await vm.exportSequence(flames: flames, displayName: "seq\(n)",
                                    out: outURL("seq\(n)"), seed: 1)
            await vm.awaitCompletion()

            let counts = await fake.runSegmentCounts
            XCTAssertEqual(counts, [expected],
                "N=\(n) must yield segmentCount == \(expected) (2N-1), got \(counts)")
        }
    }

    /// `skipNotice` surfaces a silent `isRenderable` drop (transparency only —
    /// the export continues with the renderable subset). Nil when nothing is
    /// filtered.
    func testExportSequenceSkipNoticeWhenSomeGenomesUnrenderable() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        _ = installFake(vm, script: .yieldProgress([progressEvent(frame: 1, total: 1)]))
        let bad = Flame(
            camera: Camera(center: SIMD2<Double>(.nan, .nan), scale: .nan),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])
        let flames = [renderableFlame(), bad, renderableFlame(), bad]   // 2 of 4 renderable

        await vm.exportSequence(flames: flames, displayName: "mixed", out: outURL(), seed: 1)
        await vm.awaitCompletion()

        XCTAssertNotNil(vm.skipNotice, "skipNotice must be set when some genomes are filtered")
        XCTAssertTrue(vm.skipNotice?.contains("2 of 4") ?? false,
            "skipNotice must report the skip count, got: \(vm.skipNotice ?? "nil")")

        // And nil when nothing is filtered:
        let vm2 = ExportManager()
        useNoOpSleepHooks(vm2)
        _ = installFake(vm2, script: .yieldProgress([progressEvent(frame: 1, total: 1)]))
        await vm2.exportSequence(flames: [renderableFlame(), renderableFlame()],
                                 displayName: "clean", out: outURL("b"), seed: 2)
        await vm2.awaitCompletion()
        XCTAssertNil(vm2.skipNotice, "skipNotice must be nil when no genomes are filtered")
    }

    func testStateMachineBatchSuccessTransitionsToCompletedDir() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .batchYield([
            batchEvent(job: 0, totalJobs: 3, frame: 0, totalFrames: 2),
            batchEvent(job: 1, totalJobs: 3, frame: 0, totalFrames: 2),
            batchEvent(job: 2, totalJobs: 3, frame: 2, totalFrames: 2),
        ]))
        let dir = batchDir()
        let items: [(flame: Flame, name: String)] = [
            (renderableFlame(), "alpha"), (renderableFlame(), "beta"), (renderableFlame(), "gamma"),
        ]

        await vm.exportBatch(items: items, baseDir: dir, seed: 9)
        await vm.awaitCompletion()

        XCTAssertEqual(vm.state, .completed(dir))
        let calls = await fake.runBatchCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].jobCount, 3)
        XCTAssertEqual(calls[0].failFast, false)
    }

    // MARK: - Cancel (spec §9.4 testExportManagerCancelCleansPartial / D-G13)

    func testCancelTransitionsToCancelledAndInvokesCoordinatorCancel() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .yieldUntilCancelled)

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        // The fake yields one event then parks. Cancel it.
        await vm.cancel()
        await vm.awaitCompletion()

        XCTAssertEqual(vm.state, .cancelled)
        let cancelCount = await fake.cancelCount
        XCTAssertEqual(cancelCount, 1, "cancel() must invoke coordinator.cancel() exactly once")
        // The partial was recorded (engine cleans the real file; the fake records it).
        let partials = await fake.runPartialURLs
        XCTAssertEqual(partials.count, 1)
    }

    func testCancelOnIdleManagerIsSafeNoOp() async {
        let vm = ExportManager()
        // No coordinator; cancel must not crash or change state.
        await vm.cancel()
        XCTAssertEqual(vm.state, .idle)
    }

    func testCancelOnAlreadyCompletedManagerIsNoOp() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .yieldProgress([progressEvent(frame: 1, total: 1)]))
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()
        let before = await fake.cancelCount

        await vm.cancel()   // already completed; must not invoke coordinator.cancel

        let after = await fake.cancelCount
        XCTAssertEqual(after, before, "cancel() after completion must be a no-op")
        if case .completed = vm.state { /* ok */ } else {
            XCTFail("cancel() after completion must not change state, got \(vm.state)")
        }
    }

    // MARK: - canStart gate (spec §9.4 testCanStartGate)

    func testCanStartFalseWhileRunning() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .yieldUntilCancelled)

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        XCTAssertEqual(vm.state, .running)
        XCTAssertFalse(vm.canStart, "canStart must be false while running")

        await vm.cancel()
        await vm.awaitCompletion()
    }

    func testCanStartFalseWhileCancelling() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .yieldUntilCancelled)

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.cancel()
        XCTAssertEqual(vm.state, .cancelling)
        XCTAssertFalse(vm.canStart, "canStart must be false while cancelling")

        await vm.awaitCompletion()
        XCTAssertEqual(vm.state, .cancelled)
        XCTAssertTrue(vm.canStart, "canStart must be true again after cancel completes")
    }

    func testExportRejectedWhileRunningDoesNotStartSecond() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .yieldUntilCancelled)

        await vm.exportSingle(flame: renderableFlame(), displayName: "first", out: outURL("a"), seed: 1)
        XCTAssertEqual(vm.state, .running)
        XCTAssertEqual(vm.sourceLabel, "first")
        XCTAssertFalse(vm.canStart, "canStart must be false while the first is running")

        // A second start while the first is running must be rejected by the
        // canStart guard: state, sourceLabel, and the in-flight coordinator are
        // all unchanged (the second never reaches startExport).
        await vm.exportSingle(flame: renderableFlame(), displayName: "second", out: outURL("b"), seed: 2)
        XCTAssertEqual(vm.state, .running, "second export must not change state")
        XCTAssertEqual(vm.sourceLabel, "first", "second export must not overwrite sourceLabel")

        // Only the first export's run was recorded (the second was rejected
        // before constructing a coordinator / job).
        while await fake.runPartialURLs.count == 0 { await Task.yield() }   // let first run register
        let runCount = await fake.runPartialURLs.count
        XCTAssertEqual(runCount, 1, "exactly one run() call — the rejected export must not run")

        await vm.cancel()
        await vm.awaitCompletion()
    }

    // MARK: - resolveBackend (spec §9.4 testResolveBackend)

    func testResolveBackendAutoWithMetal() {
        let vm = ExportManager()
        vm.backendChoice = .auto
        XCTAssertEqual(vm.resolveBackend(metalAvailable: true), .metal)
    }

    func testResolveBackendAutoWithoutMetalFallsBackToCpu() {
        let vm = ExportManager()
        vm.backendChoice = .auto
        XCTAssertEqual(vm.resolveBackend(metalAvailable: false), .cpu)
    }

    func testResolveBackendCpuIsAlwaysCpu() {
        let vm = ExportManager()
        vm.backendChoice = .cpu
        XCTAssertEqual(vm.resolveBackend(metalAvailable: true), .cpu)
        XCTAssertEqual(vm.resolveBackend(metalAvailable: false), .cpu)
    }

    func testResolveBackendMetalWithAvailability() {
        let vm = ExportManager()
        vm.backendChoice = .metal
        XCTAssertEqual(vm.resolveBackend(metalAvailable: true), .metal)
    }

    func testResolveBackendMetalWithoutMetalFallsBackToCpu() {
        // Graceful fallback: an explicit Metal pick with no Metal falls back to
        // CPU (the sheet surfaces a notice; the export still runs).
        let vm = ExportManager()
        vm.backendChoice = .metal
        XCTAssertEqual(vm.resolveBackend(metalAvailable: false), .cpu)
    }

    // MARK: - Sleep token (spec §9.4 testSleepTokenAcquiredAndReleased — 3 sub-tests)

    func testSleepTokenAcquiredAndReleasedOnSuccess() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .yieldProgress([progressEvent(frame: 1, total: 1)]))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        // Acquired immediately on start (synchronously, before the await).
        XCTAssertTrue(vm.activityAcquired(), "token must be acquired exactly once at start")
        XCTAssertEqual(vm.activityAcquireCount, 1)
        XCTAssertEqual(vm.activityReleaseCount, 0)

        await vm.awaitCompletion()

        XCTAssertTrue(vm.activityAcquired())
        XCTAssertTrue(vm.activityReleased(), "token must be released exactly once on success")
        XCTAssertEqual(vm.activityAcquireCount, 1)
        XCTAssertEqual(vm.activityReleaseCount, 1)
    }

    func testSleepTokenAcquiredAndReleasedOnCancel() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .yieldUntilCancelled)

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        XCTAssertEqual(vm.activityAcquireCount, 1)

        await vm.cancel()
        await vm.awaitCompletion()

        XCTAssertEqual(vm.state, .cancelled)
        XCTAssertTrue(vm.activityReleased(), "token must be released exactly once on cancel")
        XCTAssertEqual(vm.activityAcquireCount, 1)
        XCTAssertEqual(vm.activityReleaseCount, 1)
    }

    func testSleepTokenAcquiredAndReleasedOnFailure() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .throwImmediately(ExportError.diskFull))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        XCTAssertEqual(vm.activityAcquireCount, 1)

        await vm.awaitCompletion()

        if case .failed = vm.state { /* ok */ } else {
            return XCTFail("expected .failed, got \(vm.state)")
        }
        XCTAssertTrue(vm.activityReleased(), "token must be released exactly once on failure")
        XCTAssertEqual(vm.activityAcquireCount, 1)
        XCTAssertEqual(vm.activityReleaseCount, 1)
    }

    // MARK: - Snapshot mapping (spec §9.4 testSnapshotMappingIsDeterministic)

    func testSnapshotFromExportProgressNormalizesToSingleJob() {
        let p = ExportProgress(phase: .encoding, currentFrame: 42, totalFrames: 100,
                               elapsed: 12.5, renderFPS: 7.5)
        let s = ExportManager.snapshot(from: .single(p))
        XCTAssertEqual(s.phase, .encoding)
        XCTAssertEqual(s.currentFrame, 42)
        XCTAssertEqual(s.totalFrames, 100)
        XCTAssertEqual(s.elapsed, 12.5, accuracy: 1e-9)
        XCTAssertEqual(s.renderFPS, 7.5, accuracy: 1e-9)
        XCTAssertEqual(s.jobIndex, 0, "single/sequence ⇒ jobIndex == 0")
        XCTAssertEqual(s.totalJobs, 1, "single/sequence ⇒ totalJobs == 1")
        XCTAssertEqual(s.fraction, 0.42, accuracy: 1e-9)
    }

    func testSnapshotFromBatchProgressCarriesJobIndex() {
        let b = BatchProgress(jobIndex: 2, totalJobs: 5, jobFrame: 10, jobTotalFrames: 20,
                              aggregateFraction: 0.5, failed: false)
        let s = ExportManager.snapshot(from: .batch(b))
        XCTAssertEqual(s.jobIndex, 2, "batch ⇒ jobIndex from event")
        XCTAssertEqual(s.totalJobs, 5, "batch ⇒ totalJobs from event")
        XCTAssertEqual(s.currentFrame, 10, "batch ⇒ currentFrame = jobFrame")
        XCTAssertEqual(s.totalFrames, 20, "batch ⇒ totalFrames = jobTotalFrames")
        XCTAssertEqual(s.fraction, 0.5, accuracy: 1e-9, "batch fraction = jobFrame/jobTotalFrames")
    }

    func testSnapshotMappingIsDeterministicAcrossRuns() {
        // Rule #2: the same input sequence must produce the same output sequence
        // (pure value mapping; no Dict/Set float sums). Re-derive twice and compare.
        let events: [ProgressEvent] = [
            .single(progressEvent(frame: 0, total: 4)),
            .single(progressEvent(frame: 2, total: 4)),
            .batch(batchEvent(job: 0, totalJobs: 2, frame: 1, totalFrames: 3)),
            .batch(batchEvent(job: 1, totalJobs: 2, frame: 3, totalFrames: 3)),
        ]
        let run1 = events.map { ExportManager.snapshot(from: $0) }
        let run2 = events.map { ExportManager.snapshot(from: $0) }
        XCTAssertEqual(run1, run2, "snapshot(from:) must be a pure deterministic mapping")
    }

    func testSnapshotUpdatesDuringStream() async {
        // The consumeTask must publish each event into `snapshot` (so the banner
        // can observe progress), not just the last one.
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .yieldProgress([
            progressEvent(frame: 1, total: 3),
            progressEvent(frame: 2, total: 3),
            progressEvent(frame: 3, total: 3),
        ]))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()

        // After completion the snapshot reflects the LAST yielded event.
        XCTAssertEqual(vm.snapshot.currentFrame, 3)
        XCTAssertEqual(vm.snapshot.totalFrames, 3)
        XCTAssertEqual(vm.snapshot.fraction, 1.0, accuracy: 1e-9)
    }

    func testSnapshotEmptyFractionIsZero() {
        XCTAssertEqual(ExportProgressSnapshot.empty.fraction, 0,
            "empty snapshot must not divide by zero")
    }

    // MARK: - Validation / routing

    func testExportSingleRejectsUnrenderableFlame() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        _ = installFake(vm, script: .yieldProgress([progressEvent(frame: 1, total: 1)]))
        // NaN camera ⇒ not renderable (GenomeHealth).
        let bad = Flame(
            camera: Camera(center: SIMD2<Double>(.nan, .nan), scale: .nan),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])

        await vm.exportSingle(flame: bad, displayName: "x", out: outURL(), seed: 1)

        guard case .failed(let msg) = vm.state else {
            return XCTFail("expected .failed for unrenderable flame, got \(vm.state)")
        }
        XCTAssertTrue(msg.lowercased().contains("renderable"))
    }

    func testExportBatchFiltersUnrenderableAndContinues() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .batchYield([
            batchEvent(job: 0, totalJobs: 2, frame: 0, totalFrames: 1),
            batchEvent(job: 1, totalJobs: 2, frame: 1, totalFrames: 1),
        ]))
        let dir = batchDir()
        let bad = Flame(
            camera: Camera(center: SIMD2<Double>(.nan, .nan), scale: .nan),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])
        let items: [(flame: Flame, name: String)] = [
            (renderableFlame(), "good1"), (bad, "bad"), (renderableFlame(), "good2"),
        ]

        await vm.exportBatch(items: items, baseDir: dir, seed: 1)
        await vm.awaitCompletion()

        XCTAssertEqual(vm.state, .completed(dir))
        let calls = await fake.runBatchCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].jobCount, 2, "unrenderable items must be filtered before runBatch")
    }

    func testExportBatchDedupesCollidingNamesWithinBatch() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .batchYield([
            batchEvent(job: 0, totalJobs: 2, frame: 1, totalFrames: 1),
            batchEvent(job: 1, totalJobs: 2, frame: 1, totalFrames: 1),
        ]))
        let dir = batchDir()
        // Two items with the same name ⇒ the second gets a `-2` suffix.
        let items: [(flame: Flame, name: String)] = [
            (renderableFlame(), "sheep"), (renderableFlame(), "sheep"),
        ]

        await vm.exportBatch(items: items, baseDir: dir, seed: 1)
        await vm.awaitCompletion()

        XCTAssertEqual(vm.state, .completed(dir))
        let outs = await fake.runBatchOuts
        XCTAssertEqual(outs.count, 2, "both colliding items must produce distinct jobs")
        XCTAssertEqual(outs[0].lastPathComponent, "sheep.mov")
        XCTAssertEqual(outs[1].lastPathComponent, "sheep-2.mov",
            "within-batch name collision must get a -2 suffix (extension preserved)")
        XCTAssertNotEqual(outs[0], outs[1])
    }

    // MARK: - reset()

    func testResetReturnsToIdleFromTerminalStates() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        _ = installFake(vm, script: .yieldProgress([progressEvent(frame: 1, total: 1)]))
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()
        XCTAssertEqual(vm.state, .completed(outURL()))

        vm.reset()
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.snapshot, .empty)
        XCTAssertEqual(vm.sourceLabel, "")
        XCTAssertNil(vm.skipNotice, "reset must clear skipNotice")
    }

    func testResetIsNoOpWhileRunning() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        _ = installFake(vm, script: .yieldUntilCancelled)
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)

        vm.reset()
        XCTAssertEqual(vm.state, .running, "reset must not interrupt a running export")

        await vm.cancel()
        await vm.awaitCompletion()
    }

    // MARK: - Loop render-once-repeat (v0.5.0)

    /// Owner's optimal pacing defaults: 15 s loop + 12 s edge, loop repeated
    /// twice (15 s render + repeat×2 = 30 s perceived loop).
    func testExportManagerPacingDefaultsAreOwnerOptimal() {
        let vm = ExportManager()
        XCTAssertEqual(vm.loopDurationSeconds, 15.0, "loop default = 15 s (render once, repeat×2 = 30 s perceived)")
        XCTAssertEqual(vm.transitionDurationSeconds, 12.0, "transition default = 12 s edge")
        XCTAssertEqual(vm.loopRepeatCount, 2, "loop repeat default = 2 (halves loop render cost)")
    }

    /// `loopRepeatCount` flows from the manager into the `ExportJob` for the
    /// single export path (and sequence, which shares `run`).
    func testExportManagerLoopRepeatFlowsIntoSingleJob() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        vm.loopRepeatCount = 3
        let fake = installFake(vm, script: .yieldProgress([progressEvent(frame: 1, total: 1)]))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()

        let repeats = await fake.runLoopRepeatCounts
        XCTAssertEqual(repeats, [3], "loopRepeatCount must flow into the single ExportJob")
    }

    /// `loopRepeatCount` also flows into batch jobs (each carries the value).
    func testExportManagerLoopRepeatFlowsIntoBatchJobs() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        vm.loopRepeatCount = 2
        let fake = installFake(vm, script: .batchYield([
            batchEvent(job: 0, totalJobs: 2, frame: 1, totalFrames: 1),
            batchEvent(job: 1, totalJobs: 2, frame: 1, totalFrames: 1),
        ]))
        let dir = batchDir()
        let items: [(flame: Flame, name: String)] = [
            (renderableFlame(), "alpha"), (renderableFlame(), "beta"),
        ]

        await vm.exportBatch(items: items, baseDir: dir, seed: 1)
        await vm.awaitCompletion()

        let repeats = await fake.runBatchLoopRepeatCounts
        XCTAssertEqual(repeats, [2, 2], "loopRepeatCount must flow into every batch ExportJob")
    }

    /// repeat=1 is the no-op (flows as 1, the CLI/byte-identity default).
    func testExportManagerLoopRepeatOneIsNoOpValue() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        vm.loopRepeatCount = 1
        let fake = installFake(vm, script: .yieldProgress([progressEvent(frame: 1, total: 1)]))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()

        let repeats = await fake.runLoopRepeatCounts
        XCTAssertEqual(repeats, [1], "repeat=1 flows as 1 (no cache/replay)")
    }

    // MARK: - ETA / EMA (v0.5.0 — export progress banner ETA)

    /// Helper: install a scripted `nowProvider` that advances a fixed `dt` seconds
    /// per call. The EMA is a pure function of these (scripted) instants, so the
    /// ETA is deterministic (rule #2). Returns the base instant for reference.
    @discardableResult
    private func installScriptedClock(_ vm: ExportManager, dt: Double) -> ContinuousClock.Instant {
        let base = ContinuousClock.now
        var step = 0
        vm.nowProvider = {
            let t = base.advanced(by: .seconds(Double(step) * dt))
            step += 1
            return t
        }
        return base
    }

    /// `etaSeconds` is nil during cold-start (fewer than `coldStartFloor`
    /// rendering snapshots), so the banner shows "estimating…" until the EMA has
    /// sampled enough frames.
    func testETAIsNilDuringColdStart() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installScriptedClock(vm, dt: 0.5)
        // 7 rendering snapshots < coldStartFloor (8) → etaSeconds stays nil.
        let snaps = (0..<7).map { i in
            ExportProgress(phase: .rendering, currentFrame: i, totalFrames: 100,
                           elapsed: Double(i) * 0.5, renderFPS: 2.0)
        }
        installFake(vm, script: .yieldProgress(snaps))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()

        XCTAssertNil(vm.snapshot.etaSeconds,
            "etaSeconds must be nil during cold-start (< 8 rendering snapshots)")
    }

    /// After warm-up (≥ coldStartFloor rendering snapshots at a stable per-frame
    /// dt) the EMA converges to the true per-frame duration, so
    /// `etaSeconds ≈ (totalFrames − currentFrame) × dt`.
    func testETAConvergesAfterWarmup() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let frameDt = 0.5
        let totalFrames = 100
        let snapCount = 30   // well past coldStartFloor (8) → EMA converges to frameDt
        installScriptedClock(vm, dt: frameDt)
        let snaps = (0..<snapCount).map { i in
            ExportProgress(phase: .rendering, currentFrame: i + 1, totalFrames: totalFrames,
                           elapsed: Double(i + 1) * frameDt, renderFPS: 1.0 / frameDt)
        }
        installFake(vm, script: .yieldProgress(snaps))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()

        guard let eta = vm.snapshot.etaSeconds else {
            return XCTFail("etaSeconds must be non-nil after warm-up (≥ 8 frames)")
        }
        let remaining = totalFrames - snapCount
        let expected = Double(remaining) * frameDt
        // After 30 frames (1 cold dt=0 + 29 real), EMA is within ~0.2% of frameDt;
        // allow 5% for floating-point safety.
        XCTAssertEqual(eta, expected, accuracy: max(expected * 0.05, 0.5),
            "ETA must converge to remaining × frameDt (\(expected) s), got \(eta) s")
    }

    /// On a non-rendering phase (`.concatenating`/`.encoding`/`.finalizing`) the
    /// VM freezes `etaSeconds` at its last computed value (carries it over), so
    /// the banner can show a stable ETA instead of "estimating…" mid-finalize.
    /// This also proves the VM does NOT recompute against the non-rendering
    /// event's frame counts (which would give a different value).
    func testETAFreezesOnNonRenderingPhase() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let frameDt = 0.5
        let totalFrames = 100
        let renderCount = 30
        installScriptedClock(vm, dt: frameDt)
        // 30 rendering frames warm the EMA, then a .concatenating event with
        // DIFFERENT frame counts (currentFrame == totalFrames ⇒ remaining 0).
        // If the VM recomputed, eta would be ~0; if it froze, eta ≈ the last
        // rendering ETA (~remaining × frameDt).
        var events: [ExportProgress] = (0..<renderCount).map { i in
            ExportProgress(phase: .rendering, currentFrame: i + 1, totalFrames: totalFrames,
                           elapsed: Double(i + 1) * frameDt, renderFPS: 1.0 / frameDt)
        }
        events.append(ExportProgress(phase: .concatenating, currentFrame: 50, totalFrames: 50,
                                     elapsed: Double(renderCount) * frameDt, renderFPS: 0))
        installFake(vm, script: .yieldProgress(events))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()

        XCTAssertEqual(vm.snapshot.phase, .concatenating,
            "final snapshot must be the .concatenating event")
        guard let eta = vm.snapshot.etaSeconds else {
            return XCTFail("etaSeconds must be frozen (non-nil) on a non-rendering phase, not reset to nil")
        }
        let remaining = totalFrames - renderCount
        let expectedFrozen = Double(remaining) * frameDt   // the last rendering ETA
        XCTAssertGreaterThan(eta, expectedFrozen * 0.5,
            "frozen ETA (\(eta)) must reflect the last rendering ETA (~\(expectedFrozen)), not the concatenating frame counts (which would recompute to ~0)")
        XCTAssertEqual(eta, expectedFrozen, accuracy: max(expectedFrozen * 0.05, 0.5),
            "frozen ETA must equal the last rendering ETA (~\(expectedFrozen) s), got \(eta) s")
    }
}
