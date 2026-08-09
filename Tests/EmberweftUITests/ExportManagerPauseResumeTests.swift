import XCTest
@testable import EmberweftUI
import FlameExport
import FlameKit
import FlameRenderer

/// The fake coordinator lives nested in `ExportManagerTests`; surface it into
/// this file's scope so the same scriptable seam is reused (single fake
/// definition, shared across both test classes).
typealias FakeCoordinator = ExportManagerTests.FakeCoordinator

/// M6.1 Task 6 — the `ExportManager` pause/resume/discard state machine.
/// Uses the `coordinatorFactory` injection seam (mirrors `ExportManagerTests`)
/// to drive the VM with `FakeCoordinator` scripts. Covers spec §5.1–§5.6: the
/// new `.pausing`/`.paused` states, `canStart`/`reset` guards, the
/// `.runResumable` dispatch, the `consumeTask` catch ladder (P3 discard-on-
/// cancel; P12 recoverable→`.paused` only for `.runResumable`), the
/// pause/resume sleep-token balance, and `discardPaused`.
@MainActor
final class ExportManagerPauseResumeTests: XCTestCase {

    // MARK: - Fixtures (mirror ExportManagerTests)

    /// A renderable flame (non-degenerate camera + a positive-weight xform).
    private func renderableFlame() -> Flame {
        Flame(
            camera: Camera(center: .zero, scale: 250, zoom: 0, rotation: 0),
            quality: Quality(oversample: 1, samplesPerPixel: 50),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])]
        )
    }

    private func outURL(_ name: String = "out") -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("m61-\(name)-\(UUID().uuidString).mp4")
    }

    private func batchDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("emberweft-m61-tests-\(UUID().uuidString)")
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

    /// A minimal source locator (file-less ⇒ the VM still builds .runResumable;
    /// the fake ignores the contents). Non-empty ⇒ the VM routes to .runResumable.
    private func sources(_ label: String = "x") -> [ExportCheckpoint.Source] {
        [ExportCheckpoint.Source(fileURL: nil, flameIndex: 0, sha256: nil,
                                 serializedText: nil, displayName: label)]
    }

    /// No-op sleep-token hooks (so tests don't actually prevent system sleep).
    private func useNoOpSleepHooks(_ vm: ExportManager) {
        vm.beginSleepActivity = { NSObject() }
        vm.endSleepActivity = { _ in }
    }

    /// Install a single fake as the coordinator factory (every call returns it).
    @discardableResult
    private func installFake(_ vm: ExportManager, script: FakeCoordinator.Script) -> FakeCoordinator {
        let fake = FakeCoordinator(script: script)
        vm.coordinatorFactory = { _, _ in fake }
        return fake
    }

    /// Encode a minimal checkpoint to disk at `out`'s checkpoint URL, so the
    /// discard paths have a real file to remove. `container` defaults to the
    /// GUI mastering default (.mov).
    private func writeCheckpoint(out: URL, container: ExportSettings.Container = .mov,
                                 interval: Int = 30) throws {
        var settings = ExportSettings()
        settings.container = container
        let cp = ExportCheckpoint(
            settings: settings, framesPerSegment: 8, transitionFramesPerSegment: 8,
            segmentCount: 1, selector: .sequential, seed: 1, loopCycles: 1, stagger: 0,
            out: out, loopRepeatCount: 1, checkpointIntervalFrames: interval,
            totalGlobalFrames: 8, completedChunkIndexes: [], sources: sources())
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try enc.encode(cp).write(to: cpURL)
    }

    // MARK: - Routing (exportSingle/exportSequence → .runResumable when sources)

    /// `exportSingle` with non-empty `sources` routes to `runResumable` (not
    /// `run`): the fake records a `runResumable` call, and `run` is NOT called.
    func testExportSingleWithSourcesRoutesToRunResumable() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .resumableYield([progressEvent(frame: 1, total: 1)], thenThrow: nil))
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(),
                              seed: 1, sources: sources())
        await vm.awaitCompletion()
        let runCalls = await fake.runResumableCalls
        XCTAssertEqual(runCalls, 1, "exportSingle with sources ⇒ exactly one runResumable call")
        let runPartialCount = await fake.runPartialURLs.count
        XCTAssertEqual(runPartialCount, 0, "exportSingle with sources must NOT call run()")
    }

    /// `exportSequence` with non-empty `sources` also routes to `runResumable`.
    func testExportSequenceWithSourcesRoutesToRunResumable() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .resumableYield([progressEvent(frame: 1, total: 1)], thenThrow: nil))
        await vm.exportSequence(flames: [renderableFlame(), renderableFlame()],
                                displayName: "seq", out: outURL(), seed: 1, sources: sources())
        await vm.awaitCompletion()
        let runCalls = await fake.runResumableCalls
        XCTAssertEqual(runCalls, 1, "exportSequence with sources ⇒ exactly one runResumable call")
    }

    /// Without `sources`, `exportSingle` keeps the existing `.runJob` path
    /// (back-comat / byte-identity). The strong D6 checkpoint path activates
    /// only when the caller threads file-backed (or explicit) sources.
    func testExportSingleWithoutSourcesRoutesToRunJob() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .yieldProgress([progressEvent(frame: 1, total: 1)]))
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(), seed: 1)
        await vm.awaitCompletion()
        let runPartialCount = await fake.runPartialURLs.count
        XCTAssertEqual(runPartialCount, 1, "exportSingle without sources ⇒ run() path (back-compat)")
        let resumableCalls = await fake.runResumableCalls
        XCTAssertEqual(resumableCalls, 0, "exportSingle without sources must NOT call runResumable")
    }

    /// `exportBatch` is unchanged (cancel-only this slice) ⇒ `.runBatch`.
    func testExportBatchStillRoutesToRunBatch() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let fake = installFake(vm, script: .batchYield([
            batchEvent(job: 0, totalJobs: 1, frame: 1, totalFrames: 1)]))
        let dir = batchDir()
        await vm.exportBatch(items: [(renderableFlame(), "a")], baseDir: dir, seed: 1)
        await vm.awaitCompletion()
        let batchCalls = await fake.runBatchCalls.count
        XCTAssertEqual(batchCalls, 1, "exportBatch ⇒ runBatch (unchanged)")
    }

    // MARK: - isPausable flag (Task 8 — the banner gates Pause on this)

    /// A `.runResumable` run (sources non-empty) sets `isPausable = true` while
    /// `.running` — the banner shows the Pause button. Parked via
    /// `.yieldUntilCancelled` so the assertion observes the in-flight state.
    func testIsPausableTrueForRunResumableDuringRunning() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .yieldUntilCancelled)
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(),
                              seed: 1, sources: sources())
        XCTAssertEqual(vm.state, .running)
        XCTAssertTrue(vm.isPausable,
                      ".runResumable ⇒ isPausable true (banner shows Pause)")

        await vm.cancel()
        await vm.awaitCompletion()
        XCTAssertFalse(vm.isPausable, "terminal state ⇒ isPausable cleared")
    }

    /// A `.runBatch` run sets `isPausable = false` (batch is cancel-only — no
    /// checkpoint, so a pause is meaningless). The banner hides Pause.
    func testIsPausableFalseForRunBatch() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .batchYield([
            batchEvent(job: 0, totalJobs: 1, frame: 1, totalFrames: 1)]))
        let dir = batchDir()
        await vm.exportBatch(items: [(renderableFlame(), "a")], baseDir: dir, seed: 1)
        XCTAssertFalse(vm.isPausable,
                       ".runBatch ⇒ isPausable false (banner hides Pause)")
        await vm.awaitCompletion()
        XCTAssertFalse(vm.isPausable, "terminal state ⇒ isPausable cleared")
    }

    /// A `.runJob` run (sources empty) sets `isPausable = false` — the legacy
    /// path has no checkpoint either, so Pause stays hidden.
    func testIsPausableFalseForRunJob() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .yieldProgress([progressEvent(frame: 1, total: 1)]))
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(),
                              seed: 1)   // no sources ⇒ .runJob
        XCTAssertFalse(vm.isPausable,
                       ".runJob ⇒ isPausable false (banner hides Pause)")
        await vm.awaitCompletion()
    }

    // MARK: - Pause → .paused → Resume → .completed (the headline AC)

    /// `pause()` `.running`→`.pausing`→(fake throws `.paused`)→`.paused(out, cp,
    /// reason: nil)`; `resume()`→`.running`→`.completed`; sleep counters 2
    /// acquire / 2 release across the pair. The factory returns the pause fake
    /// on the fresh run and the resume fake on `resume()` (which rebuilds the
    /// coordinator via `coordinatorFactory`).
    func testPauseThenResumeCompletesWithBalancedSleepTokens() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("pause")
        let cpURL = ExportCheckpoint.checkpointURL(out: out)

        let pauseFake = FakeCoordinator(script: .resumableYield(
            [progressEvent(frame: 5, total: 10)], thenThrow: ExportError.paused))
        let resumeFake = FakeCoordinator(script: .resumableResume([progressEvent(frame: 10, total: 10)]))
        var factoryCall = 0
        vm.coordinatorFactory = { _, _ in
            factoryCall += 1
            return factoryCall == 1 ? pauseFake : resumeFake
        }

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        XCTAssertEqual(vm.state, .running)

        await vm.pause()
        let pauseCount = await pauseFake.pauseCount
        XCTAssertEqual(pauseCount, 1, "pause() must call coordinator.pause() exactly once")

        await vm.awaitCompletion()
        guard case .paused(let pausedOut, let pausedCP, let reason) = vm.state else {
            return XCTFail("expected .paused after pause, got \(vm.state)")
        }
        XCTAssertEqual(pausedOut, out, ".paused carries the output URL")
        XCTAssertEqual(pausedCP, cpURL, ".paused carries the checkpoint URL beside out")
        XCTAssertNil(reason, "user pause ⇒ reason nil (non-nil = recoverable error)")
        XCTAssertEqual(vm.rememberedCheckpointURL, cpURL,
            "pause must remember the checkpoint URL for resume/relaunch")
        XCTAssertEqual(vm.activityAcquireCount, 1)
        XCTAssertEqual(vm.activityReleaseCount, 1, "token released on .paused (one run so far)")

        // Resume → .running → .completed.
        await vm.resume()
        XCTAssertEqual(vm.state, .running, "resume() transitions .paused → .running")
        await vm.awaitCompletion()
        XCTAssertEqual(vm.state, .completed(out), "resume must drive the run to completion")

        let resumeFroms = await resumeFake.runResumableResumeFromURLs
        XCTAssertEqual(resumeFroms, [cpURL], "resume must drive runResumable(resumeFrom: checkpoint)")
        // Sleep counters across the pair: one acquire+release per RUN; resume is
        // a new run ⇒ a second pair.
        XCTAssertEqual(vm.activityAcquireCount, 2, "two runs ⇒ two acquires")
        XCTAssertEqual(vm.activityReleaseCount, 2, "two runs ⇒ two releases")
        XCTAssertNil(vm.rememberedCheckpointURL, ".completed clears rememberedCheckpointURL")
    }

    // MARK: - .pausing observed + cancel-from-pausing (P3 discard)

    /// `.pausing` is observable when the fake parks WITHOUT pause finishing the
    /// stream (`.yieldUntilCancelled` resumable arm): pause() records but does
    /// not end the stream ⇒ the VM holds `.pausing` until cancel() ends it.
    /// This is also the cancel-from-`.pausing` P3 test: cancel reaches
    /// `.cancelled` AND discards checkpoint+chunks (D3 GUI-cancel-deletes).
    func testCancelFromPausingReachesCancelledAndDiscards() async throws {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("pausing")
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        // .yieldUntilCancelled on the resumable path parks; pause() records but
        // does NOT finish (only the .resumableYield(_, .paused) arm does).
        let fake = installFake(vm, script: .yieldUntilCancelled)

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        XCTAssertEqual(vm.state, .running)

        await vm.pause()
        XCTAssertEqual(vm.state, .pausing, "pause() must hold .pausing while the run loop is parked")
        let pauseCount = await fake.pauseCount
        XCTAssertEqual(pauseCount, 1)

        // Simulate a checkpoint written before the pause (the coordinator writes
        // one after each completed chunk). P3: GUI cancel must discard it.
        try writeCheckpoint(out: out)

        await vm.cancel()
        await vm.awaitCompletion()
        XCTAssertEqual(vm.state, .cancelled, "cancel from .pausing ⇒ .cancelled")

        XCTAssertFalse(FileManager.default.fileExists(atPath: cpURL.path),
            "P3: GUI cancel must discard the checkpoint (D3 GUI-cancel-deletes)")
        XCTAssertNil(vm.rememberedCheckpointURL, "cancel clears rememberedCheckpointURL")
        XCTAssertEqual(vm.activityReleaseCount, 1, "token released on .cancelled")
    }

    // MARK: - cancel-from-paused (discard + .cancelled)

    /// `cancel()` from `.paused` discards checkpoint+chunks and reaches
    /// `.cancelled` (D3: Cancel-from-paused = discard + done).
    func testCancelFromPausedDiscardsAndCancels() async throws {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("frompaused")
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        let pauseFake = FakeCoordinator(script: .resumableYield(
            [progressEvent(frame: 3, total: 9)], thenThrow: ExportError.paused))
        vm.coordinatorFactory = { _, _ in pauseFake }

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        await vm.pause()
        await vm.awaitCompletion()
        guard case .paused = vm.state else { return XCTFail("expected .paused, got \(vm.state)") }
        try writeCheckpoint(out: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cpURL.path))

        await vm.cancel()
        XCTAssertEqual(vm.state, .cancelled, "cancel from .paused ⇒ .cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cpURL.path),
            "cancel from .paused must discard the checkpoint")
        XCTAssertNil(vm.rememberedCheckpointURL)
    }

    // MARK: - discardPaused (D4 — no coordinator needed)

    /// `discardPaused()` deletes checkpoint+chunks via the static helper and
    /// clears `rememberedCheckpointURL`; works when `coordinator == nil` (the
    /// real post-pause condition).
    func testDiscardPausedRemovesCheckpointAndClearsRememberedURL() async throws {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("discard")
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        let chunk0 = ExportCheckpoint.chunkURL(out: out, index: 0, container: .mov)
        let pauseFake = FakeCoordinator(script: .resumableYield(
            [progressEvent(frame: 2, total: 6)], thenThrow: ExportError.paused))
        vm.coordinatorFactory = { _, _ in pauseFake }

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        await vm.pause()
        await vm.awaitCompletion()
        guard case .paused = vm.state else { return XCTFail("expected .paused, got \(vm.state)") }

        // Seed a checkpoint + chunk file on disk (the real coordinator would
        // have written these); the VM's coordinator is now nil (consumeTask
        // cleared it on .paused).
        try writeCheckpoint(out: out)
        try Data().write(to: chunk0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cpURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk0.path))

        vm.discardPaused()
        XCTAssertEqual(vm.state, .idle, "discardPaused ⇒ .idle")
        XCTAssertNil(vm.rememberedCheckpointURL, "discardPaused clears rememberedCheckpointURL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cpURL.path),
            "discardPaused must delete the checkpoint")
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk0.path),
            "discardPaused must delete completed chunks")
    }

    // MARK: - P12: recoverable → .paused only for .runResumable

    /// `.diskFull` on a `.runResumable` run ⇒ `.paused(out, checkpoint, reason:)`
    /// (the checkpoint survives; D7), NOT `.failed`. The reason carries a message.
    func testDiskFullOnRunResumableTransitionsToPausedReason() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("diskfull-resumable")
        installFake(vm, script: .resumableYield(
            [progressEvent(frame: 1, total: 4)], thenThrow: ExportError.diskFull))

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        await vm.awaitCompletion()

        guard case .paused(_, _, let reason) = vm.state else {
            return XCTFail("P12: .diskFull on .runResumable ⇒ .paused, got \(vm.state)")
        }
        XCTAssertNotNil(reason, "recoverable error ⇒ .paused carries a reason message")
        XCTAssertTrue(reason?.lowercased().contains("disk") ?? false,
            "reason should describe the disk-full condition, got: \(reason ?? "nil")")
        XCTAssertNotNil(vm.rememberedCheckpointURL, "checkpoint survives a recoverable error (D7)")
    }

    /// `.encodeFailed` on a `.runResumable` run ⇒ `.paused(reason:)` too
    /// (another recoverable error in the P12 set).
    func testEncodeFailedOnRunResumableTransitionsToPausedReason() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .resumableYield(
            [progressEvent(frame: 1, total: 4)], thenThrow: ExportError.encodeFailed))
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: outURL(),
                              seed: 1, sources: sources())
        await vm.awaitCompletion()
        guard case .paused(_, _, let reason) = vm.state else {
            return XCTFail("P12: .encodeFailed on .runResumable ⇒ .paused, got \(vm.state)")
        }
        XCTAssertNotNil(reason)
    }

    /// The SAME `.diskFull` error on a `.runBatch` run ⇒ `.failed` (P12: the
    /// recoverable→`.paused` mapping applies ONLY to `.runResumable`; batch has
    /// no checkpoint so it stays `.failed`).
    func testDiskFullOnRunBatchTransitionsToFailed() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        installFake(vm, script: .batchThrow(ExportError.diskFull))
        let dir = batchDir()
        await vm.exportBatch(items: [(renderableFlame(), "a")], baseDir: dir, seed: 1)
        await vm.awaitCompletion()
        guard case .failed(let message) = vm.state else {
            return XCTFail("P12: .diskFull on .runBatch ⇒ .failed, got \(vm.state)")
        }
        XCTAssertTrue(message.lowercased().contains("disk"),
            "batch disk-full must map to .failed with a disk message, got: \(message)")
    }

    // MARK: - canStart + reset guards (D1, D2)

    /// `canStart` is false while `.pausing` and `.paused` (D1: must Discard
    /// first — never silently orphan a checkpoint). Held deterministically via
    /// the parking `.yieldUntilCancelled` resumable arm.
    func testCanStartFalseWhilePausingAndPaused() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("canstart")
        installFake(vm, script: .yieldUntilCancelled)

        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        await vm.pause()
        XCTAssertEqual(vm.state, .pausing)
        XCTAssertFalse(vm.canStart, "canStart must be false while .pausing (D1)")

        // Cancel to clear the run, then drive to .paused via the pause fake.
        await vm.cancel()
        await vm.awaitCompletion()
        XCTAssertEqual(vm.state, .cancelled)

        // Now reach .paused via the cooperative-pause fake.
        let out2 = outURL("canstart2")
        let pauseFake = FakeCoordinator(script: .resumableYield(
            [progressEvent(frame: 1, total: 2)], thenThrow: ExportError.paused))
        vm.coordinatorFactory = { _, _ in pauseFake }
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out2,
                              seed: 1, sources: sources())
        // canStart is false during .running too.
        XCTAssertFalse(vm.canStart)
        await vm.pause()
        await vm.awaitCompletion()
        guard case .paused = vm.state else { return XCTFail("expected .paused, got \(vm.state)") }
        XCTAssertFalse(vm.canStart, "canStart must be false while .paused (D1 — Discard first)")
    }

    /// `reset()` from `.paused` ⇒ `.idle`; from `.pausing` it is a no-op (like
    /// `.running` — never reset mid-flight). D2.
    func testResetFromPausedReturnsToIdle() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("reset")
        let pauseFake = FakeCoordinator(script: .resumableYield(
            [progressEvent(frame: 1, total: 2)], thenThrow: ExportError.paused))
        vm.coordinatorFactory = { _, _ in pauseFake }
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        await vm.pause()
        await vm.awaitCompletion()
        guard case .paused = vm.state else { return XCTFail("expected .paused") }

        vm.reset()
        XCTAssertEqual(vm.state, .idle, "reset from .paused ⇒ .idle (D2)")
        XCTAssertEqual(vm.snapshot, .empty)
        XCTAssertEqual(vm.sourceLabel, "")
    }

    /// `reset()` while `.pausing` is a no-op (the run is still in flight).
    func testResetIsNoOpWhilePausing() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("resetpausing")
        installFake(vm, script: .yieldUntilCancelled)
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        await vm.pause()
        XCTAssertEqual(vm.state, .pausing)

        vm.reset()
        XCTAssertEqual(vm.state, .pausing, "reset must not interrupt a pausing run (D2)")

        await vm.cancel()
        await vm.awaitCompletion()
    }

    // MARK: - pause/resume idempotency + guards

    /// `pause()` is idempotent under a double-click (second call is a no-op once
    /// already `.pausing`).
    func testPauseIsIdempotent() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("idempotent")
        let fake = installFake(vm, script: .yieldUntilCancelled)
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())

        await vm.pause()
        await vm.pause()   // double-click ⇒ no-op
        let pauseCount = await fake.pauseCount
        XCTAssertEqual(pauseCount, 1, "double pause() ⇒ coordinator.pause() called once (idempotent)")
        XCTAssertEqual(vm.state, .pausing)

        await vm.cancel()
        await vm.awaitCompletion()
    }

    /// `resume()` from a non-`.paused` state is a no-op (guard).
    func testResumeFromNonPausedIsNoOp() async {
        let vm = ExportManager()
        await vm.resume()   // idle
        XCTAssertEqual(vm.state, .idle, "resume from .idle ⇒ no-op")
    }

    // MARK: - Launch synth (Task 7 / spec §5.5)

    /// A valid, decodable checkpoint at the remembered URL ⇒ synth sets `.paused`
    /// with the checkpoint's stored `out`; coordinator stays nil (Resume rebuilds
    /// it via `coordinatorFactory`). The banner can offer Resume/Discard with no
    /// coordinator running.
    func testSynthesizePausedStateWithValidCheckpoint() throws {
        let vm = ExportManager()
        let out = outURL("synth-valid")
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        try writeCheckpoint(out: out)
        vm.rememberedCheckpointURL = cpURL

        vm.synthesizePausedStateIfNeeded()
        guard case .paused(let pausedOut, let pausedCP, let reason) = vm.state else {
            return XCTFail("valid checkpoint ⇒ .paused, got \(vm.state)")
        }
        XCTAssertEqual(pausedOut, out, "synth uses the checkpoint's stored `out`")
        XCTAssertEqual(pausedCP, cpURL, "synth carries the remembered checkpoint URL")
        XCTAssertNil(reason, "synth ⇒ reason nil (a user-style pause; non-nil = recoverable error)")
    }

    /// Missing checkpoint file ⇒ `.idle`, no crash (D14); the stale remembered URL
    /// is cleared via the hook so a later launch doesn't re-try.
    func testSynthesizePausedStateMissingCheckpointLeavesIdle() {
        let vm = ExportManager()
        var hookWrites: [URL?] = []
        vm.writeRememberedCheckpointURL = { hookWrites.append($0) }
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("emberweft-nonexistent-\(UUID().uuidString).json")
        vm.rememberedCheckpointURL = missing

        vm.synthesizePausedStateIfNeeded()
        XCTAssertEqual(vm.state, .idle, "missing checkpoint ⇒ .idle (D14)")
        XCTAssertNil(vm.rememberedCheckpointURL, "stale remembered URL cleared on missing")
        XCTAssertTrue(hookWrites.contains(nil), "missing ⇒ clear forwarded via the hook")
    }

    /// Corrupt checkpoint file ⇒ `.idle`, no crash (D14); stale remembered URL cleared.
    func testSynthesizePausedStateCorruptCheckpointLeavesIdle() throws {
        let vm = ExportManager()
        let out = outURL("synth-corrupt")
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        try Data("{ this is not a valid checkpoint".utf8).write(to: cpURL)
        vm.rememberedCheckpointURL = cpURL

        vm.synthesizePausedStateIfNeeded()
        XCTAssertEqual(vm.state, .idle, "corrupt checkpoint ⇒ .idle, no crash (D14)")
        XCTAssertNil(vm.rememberedCheckpointURL, "stale remembered URL cleared on corrupt")
    }

    /// Synth is a no-op when the VM is not `.idle` (never overwrites a live state).
    func testSynthesizeNoOpWhenNotIdle() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("synth-noop")
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        try? writeCheckpoint(out: out)
        vm.rememberedCheckpointURL = cpURL

        installFake(vm, script: .yieldUntilCancelled)
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        XCTAssertEqual(vm.state, .running)

        vm.synthesizePausedStateIfNeeded()
        XCTAssertEqual(vm.state, .running, "synth must not overwrite a non-.idle state")

        await vm.cancel()
        await vm.awaitCompletion()
    }

    /// Synth is a no-op when the remembered URL is nil (nothing to resume).
    func testSynthesizeNoOpWhenRememberedURLNil() {
        let vm = ExportManager()
        vm.synthesizePausedStateIfNeeded()
        XCTAssertEqual(vm.state, .idle)
    }

    // MARK: - writeRememberedCheckpointURL hook (Task 7)

    /// `pause()` writes the remembered URL THROUGH the hook (so AppPreferences
    /// persists it). Observed via the hook — the VM is tested in isolation with
    /// no AppPreferences/AppModel.
    func testPauseWritesRememberedCheckpointURLViaHook() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("hook-pause")
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        var written: [URL?] = []
        vm.writeRememberedCheckpointURL = { written.append($0) }

        installFake(vm, script: .resumableYield(
            [progressEvent(frame: 2, total: 4)], thenThrow: ExportError.paused))
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        await vm.pause()
        await vm.awaitCompletion()
        guard case .paused = vm.state else { return XCTFail("expected .paused, got \(vm.state)") }
        XCTAssertTrue(written.contains(cpURL),
                      "pause must forward the checkpoint URL via the hook")
        XCTAssertEqual(vm.rememberedCheckpointURL, cpURL,
                       "in-memory copy and hook write agree")
    }

    /// `.completed` reached via resume clears the remembered URL THROUGH the hook
    /// (nil forwarded). Proves the resume→completed path persists the clear.
    func testResumeCompletedClearsRememberedCheckpointURLViaHook() async {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("hook-completed")
        let cpURL = ExportCheckpoint.checkpointURL(out: out)
        var written: [URL?] = []
        vm.writeRememberedCheckpointURL = { written.append($0) }

        let pauseFake = FakeCoordinator(script: .resumableYield(
            [progressEvent(frame: 1, total: 3)], thenThrow: ExportError.paused))
        let resumeFake = FakeCoordinator(script: .resumableResume([progressEvent(frame: 3, total: 3)]))
        var factoryCall = 0
        vm.coordinatorFactory = { _, _ in
            factoryCall += 1
            return factoryCall == 1 ? pauseFake : resumeFake
        }
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        await vm.pause()
        await vm.awaitCompletion()
        XCTAssertTrue(written.contains(cpURL), "pause forwarded the URL via the hook")

        await vm.resume()
        await vm.awaitCompletion()
        XCTAssertEqual(vm.state, .completed(out))
        XCTAssertTrue(written.contains(nil),
                      "completed must clear the URL via the hook (nil forwarded)")
    }

    /// `discardPaused()` clears the remembered URL THROUGH the hook.
    func testDiscardPausedClearsRememberedCheckpointURLViaHook() async throws {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("hook-discard")
        var written: [URL?] = []
        vm.writeRememberedCheckpointURL = { written.append($0) }

        let pauseFake = FakeCoordinator(script: .resumableYield(
            [progressEvent(frame: 1, total: 2)], thenThrow: ExportError.paused))
        vm.coordinatorFactory = { _, _ in pauseFake }
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        await vm.pause()
        await vm.awaitCompletion()
        guard case .paused = vm.state else { return XCTFail("expected .paused") }
        try writeCheckpoint(out: out)   // seed the file discardPaused will sweep

        vm.discardPaused()
        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(written.contains(nil), "discardPaused must clear the URL via the hook")
    }

    /// `cancel()` from `.paused` clears the remembered URL THROUGH the hook (the
    /// cancel-from-paused discard path also persists the clear).
    func testCancelFromPausedClearsRememberedCheckpointURLViaHook() async throws {
        let vm = ExportManager()
        useNoOpSleepHooks(vm)
        let out = outURL("hook-cancel")
        var written: [URL?] = []
        vm.writeRememberedCheckpointURL = { written.append($0) }
        let pauseFake = FakeCoordinator(script: .resumableYield(
            [progressEvent(frame: 1, total: 2)], thenThrow: ExportError.paused))
        vm.coordinatorFactory = { _, _ in pauseFake }
        await vm.exportSingle(flame: renderableFlame(), displayName: "x", out: out,
                              seed: 1, sources: sources())
        await vm.pause()
        await vm.awaitCompletion()
        guard case .paused = vm.state else { return XCTFail("expected .paused") }
        try writeCheckpoint(out: out)

        await vm.cancel()
        XCTAssertEqual(vm.state, .cancelled)
        XCTAssertTrue(written.contains(nil), "cancel from .paused must clear the URL via the hook")
    }
}
