import XCTest
@testable import EmberweftUI
import FlameKit
import FlameExport
import FlameFlock

/// Task 15 (T15) — `FlockModel` state machines + teardown-safe cancel.
///
/// The three coordinator surfaces (generate / stitch / browse) are driven
/// through actor spies injected via the `generateFactory` / `stitchFactory` /
/// `snapshotProvider` seams (mirrors `ExportManager.coordinatorFactory`,
/// ExportManager.swift:212). No real rendering / SQLite / Metal touches these
/// tests — they are fast and deterministic (rule #2).
@MainActor
final class FlockModelTests: XCTestCase {

    // MARK: - Fixtures

    /// A renderable flame (non-degenerate camera + a positive-weight xform).
    private func flame() -> Flame {
        Flame(
            camera: Camera(center: .zero, scale: 250, zoom: 0, rotation: 0),
            quality: Quality(oversample: 1, samplesPerPixel: 50),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])]
        )
    }

    private func shard() -> ShardSpec {
        ShardSpec(name: "1920x1080_30fps", width: 1920, height: 1080, fps: 30,
                  loopSeconds: 15.0, transSeconds: 12.0,
                  loopFrames: 450, transFrames: 360,
                  isCanonical: true, codec: .hevc)
    }

    private func flockRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("emberweft-flock-tests-\(UUID().uuidString)")
    }

    private func outURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flock-stitch-\(UUID().uuidString).mov")
    }

    /// A minimal valid generate request (one loop unit). The spies ignore the
    /// content; only `units.isEmpty` is observed (by FlockModel's guard).
    private func generateRequest(units: [GenerateUnit]? = nil) -> GenerateRequest {
        let resolved = units ?? [
            GenerateUnit(aGen: "248", aId: "00001", bGen: "248", bId: "00001", A: flame())
        ]
        return GenerateRequest(shard: shard(), units: resolved,
                               settings: ExportSettings(), flockRoot: flockRoot())
    }

    private func stitchRequest(flames: [(gen: String, id: String, flame: Flame)]? = nil) -> StitchRequest {
        let resolved = flames ?? [("248", "00001", flame())]
        return StitchRequest(shard: shard(), orderedFlames: resolved,
                             settings: ExportSettings(), flockRoot: flockRoot(), out: outURL())
    }

    // MARK: - Spies (mirror ExportManagerTests.FakeCoordinator race-free pattern)

    /// Actor spy for `GeneratingCoordinating`. Scripts its stream; records
    /// `cancel()`. Cancel-cooperation is race-free under actor serialization:
    /// either cancel() ran first (`cancelled == true` ⇒ the body yields
    /// `.cancelled` + finishes on entry), or the body parks and cancel() yields
    /// `.cancelled` + finishes the stored continuation. Mirrors the REAL
    /// `GenerateCoordinator` cancel branch (yield `.cancelled` then finish).
    actor GenerateSpy: GeneratingCoordinating {
        enum Script {
            /// Yield these events then finish (success path; last should be terminal).
            case yieldProgress([GenerateUIProgress])
            /// Throw immediately (error path).
            case throwImmediately(Error)
            /// Yield `.resolving` + `.running` then park until `cancel()` ends it.
            case yieldUntilCancelled
        }

        private let script: Script
        private(set) var cancelCount = 0
        private var cancelled = false
        private var storedCont: AsyncThrowingStream<GenerateUIProgress, Error>.Continuation?

        init(script: Script) { self.script = script }

        func generate(_ request: GenerateRequest,
                      coordinator: ExportCoordinator) async -> AsyncThrowingStream<GenerateUIProgress, Error> {
            AsyncThrowingStream { continuation in
                Task { [self] in
                    await self.body(continuation)
                }
            }
        }

        private func body(_ cont: AsyncThrowingStream<GenerateUIProgress, Error>.Continuation) async {
            switch script {
            case .yieldProgress(let events):
                for e in events { cont.yield(e) }
                cont.finish()
            case .throwImmediately(let err):
                cont.finish(throwing: err)
            case .yieldUntilCancelled:
                // Race-free: store first, then check the flag. If cancel() already
                // ran we finish now; otherwise we park and cancel() finishes us.
                storedCont = cont
                cont.yield(.resolving)
                cont.yield(.running(skip: 0, render: 0, total: 1))
                if cancelled {
                    storedCont = nil
                    cont.yield(.cancelled)
                    cont.finish()
                }
            }
        }

        func cancel() async {
            cancelCount += 1
            cancelled = true
            let cont = storedCont
            storedCont = nil
            cont?.yield(.cancelled)
            cont?.finish()
        }
    }

    /// Actor spy for `StitchingCoordinating`. Same race-free shape as
    /// `GenerateSpy`. Used to drive all stitch state transitions including the
    /// coordinator-side failure messages (empty sequence / cross-shard /
    /// codec-mismatch) that the REAL `StitchCoordinator` emits.
    actor StitchSpy: StitchingCoordinating {
        enum Script {
            case yieldProgress([StitchUIProgress])
            case throwImmediately(Error)
            case yieldUntilCancelled
        }

        private let script: Script
        private(set) var cancelCount = 0
        private var cancelled = false
        private var storedCont: AsyncThrowingStream<StitchUIProgress, Error>.Continuation?

        init(script: Script) { self.script = script }

        func stitch(_ request: StitchRequest,
                    coordinator: ExportCoordinator) async -> AsyncThrowingStream<StitchUIProgress, Error> {
            AsyncThrowingStream { continuation in
                Task { [self] in
                    await self.body(continuation)
                }
            }
        }

        private func body(_ cont: AsyncThrowingStream<StitchUIProgress, Error>.Continuation) async {
            switch script {
            case .yieldProgress(let events):
                for e in events { cont.yield(e) }
                cont.finish()
            case .throwImmediately(let err):
                cont.finish(throwing: err)
            case .yieldUntilCancelled:
                storedCont = cont
                cont.yield(.resolving)
                cont.yield(.plan(hitCount: 0, missCount: 0, segmentCount: 0))
                cont.yield(.running(hit: 0, generated: 0))
                if cancelled {
                    storedCont = nil
                    cont.yield(.cancelled)
                    cont.finish()
                }
            }
        }

        func cancel() async {
            cancelCount += 1
            cancelled = true
            let cont = storedCont
            storedCont = nil
            cont?.yield(.cancelled)
            cont?.finish()
        }
    }

    // MARK: - Spy installers

    @discardableResult
    private func installGenerateSpy(_ vm: FlockModel, script: GenerateSpy.Script) -> GenerateSpy {
        let spy = GenerateSpy(script: script)
        vm.generateFactory = { _, _ in spy }
        return spy
    }

    @discardableResult
    private func installStitchSpy(_ vm: FlockModel, script: StitchSpy.Script) -> StitchSpy {
        let spy = StitchSpy(script: script)
        vm.stitchFactory = { _, _ in spy }
        return spy
    }

    // MARK: - Generate: initial state + success

    func testGenerateInitialState() {
        let vm = FlockModel()
        XCTAssertEqual(vm.generateState, .idle)
        XCTAssertEqual(vm.stitchState, .idle)
        XCTAssertEqual(vm.browseState, .loading)
    }

    func testGenerateSuccessTransitionsToCompleted() async {
        let vm = FlockModel()
        installGenerateSpy(vm, script: .yieldProgress([
            .resolving,
            .running(skip: 0, render: 0, total: 2),
            .running(skip: 0, render: 1, total: 2),
            .completed(rendered: 2, skipped: 0),
        ]))

        await vm.generate(generateRequest())
        await vm.awaitGenerateCompletion()

        XCTAssertEqual(vm.generateState, .completed(rendered: 2, skipped: 0))
    }

    func testGenerateRunningStateObservedMidFlight() async {
        // A success script ending in .running (no terminal) — assert the last
        // applied state is the running sample (proves apply maps the tuple).
        let vm = FlockModel()
        installGenerateSpy(vm, script: .yieldProgress([
            .resolving,
            .running(skip: 1, render: 3, total: 5),
        ]))
        await vm.generate(generateRequest())
        await vm.awaitGenerateCompletion()
        // etaSeconds is nil: this script has no `.rendering` events, so no unit
        // wall-clock is ever sampled (cold start).
        XCTAssertEqual(vm.generateState, .running(skip: 1, render: 3, total: 5, etaSeconds: nil))
    }

    // MARK: - Generate: within-unit frame progress (v0.5.8)

    func testGenerateRenderingProgressMapsToRenderingState() async {
        // Per-frame `.rendering` events must surface as the `.rendering` UI state
        // carrying the cumulative unit counters + the within-unit frame fraction.
        // etaSeconds is nil (cold start: < floor samples).
        let vm = FlockModel()
        installGenerateSpy(vm, script: .yieldProgress([
            .resolving,
            .running(skip: 0, render: 0, total: 3),
            .rendering(skip: 0, render: 0, total: 3, frame: 1, frameTotal: 360),
            .rendering(skip: 0, render: 0, total: 3, frame: 180, frameTotal: 360),
            .running(skip: 0, render: 1, total: 3),
        ]))
        await vm.generate(generateRequest())
        await vm.awaitGenerateCompletion()
        // The last applied state is the post-unit .running (render advanced).
        XCTAssertEqual(vm.generateState, .running(skip: 0, render: 1, total: 3, etaSeconds: nil))
    }

    // MARK: - Generate: ETA estimator (v0.5.8, pure math)

    func testETAEstimatorColdStartReturnsNilUntilFloor() {
        var eta = GenerateETAEstimator(alpha: 0.5, coldStartFloor: 3)
        // Below the floor (3 samples): always nil.
        eta.record(unitSeconds: 10)
        XCTAssertNil(eta.etaSeconds(remainingUnits: 5), "< floor ⇒ nil")
        eta.record(unitSeconds: 10)
        XCTAssertNil(eta.etaSeconds(remainingUnits: 5), "< floor ⇒ nil")
        // At/above the floor: returns remaining × EMA.
        eta.record(unitSeconds: 10)
        let got = eta.etaSeconds(remainingUnits: 5)
        XCTAssertNotNil(got, ">= floor ⇒ non-nil")
        // Three uniform 10 s samples ⇒ EMA ≈ 10 s ⇒ 5 units ≈ 50 s (within the
        // EMA's smoothing tolerance).
        XCTAssertEqual(got!, 50.0, accuracy: 5.0, "uniform 10 s/unit × 5 units ≈ 50 s")
    }

    func testETAEstimatorClampsOutlierAndIsNonNegative() {
        var eta = GenerateETAEstimator(alpha: 0.5, coldStartFloor: 2)
        eta.record(unitSeconds: 10)   // warm-up (EMA still 0 → effective = 10)
        eta.record(unitSeconds: 10)   // EMA = 10, past floor
        // Now a huge outlier (1000 s) is clamped to 3×EMA = 30 before blending.
        eta.record(unitSeconds: 1000)
        let ema = eta.unitSecondsEMA
        // α=0.5: effective = min(1000, 30) = 30 ⇒ EMA = 0.5*30 + 0.5*10 = 20.
        XCTAssertEqual(ema, 20.0, accuracy: 0.01, "outlier clamped to 3×EMA before blending")
        // Remaining ≤ 0 ⇒ 0 (never negative).
        XCTAssertEqual(eta.etaSeconds(remainingUnits: 0)!, 0.0, "zero remaining ⇒ 0 s")
    }

    // MARK: - Generate: error cases

    func testGenerateEmptyUnitsFailsImmediately() async {
        // FlockModel-side guard (spec line 1833): no coordinator is constructed.
        let vm = FlockModel()
        let req = GenerateRequest(shard: shard(), units: [],
                                  settings: ExportSettings(), flockRoot: flockRoot())
        await vm.generate(req)
        // No task spawned → no awaitCompletion needed.
        XCTAssertEqual(vm.generateState, .failed("No genomes to generate from."))
    }

    func testGenerateFailedFromCoordinatorError() async {
        let vm = FlockModel()
        installGenerateSpy(vm, script: .throwImmediately(
            NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "disk gone"])))
        await vm.generate(generateRequest())
        await vm.awaitGenerateCompletion()
        if case .failed(let m) = vm.generateState {
            XCTAssertTrue(m.contains("disk gone"), "expected error message propagated, got \(m)")
        } else {
            XCTFail("expected .failed, got \(vm.generateState)")
        }
    }

    // MARK: - Generate: cancel (M4 §13.2 teardown safety)

    func testCancelGenerateInvokesCoordinatorCancel() async {
        let vm = FlockModel()
        let spy = installGenerateSpy(vm, script: .yieldUntilCancelled)

        await vm.generate(generateRequest())   // fire-and-forget
        vm.cancelGenerate()                     // task.cancel() + await coord.cancel()
        await vm.awaitGenerateCompletion()

        XCTAssertEqual(vm.generateState, .cancelled)
        let cancels = await spy.cancelCount
        XCTAssertEqual(cancels, 1,
                       "cancelGenerate must invoke the coordinator actor's cancel() (cross-isolation flag)")
    }

    func testCancelGenerateOnIdleIsSafeNoOp() {
        let vm = FlockModel()
        // No task / no coordinator — must not crash.
        vm.cancelGenerate()
        XCTAssertEqual(vm.generateState, .idle)
    }

    func testSubsequentGenerateAfterCancelStartsCleanly() async {
        let vm = FlockModel()
        let spy1 = installGenerateSpy(vm, script: .yieldUntilCancelled)
        await vm.generate(generateRequest())
        vm.cancelGenerate()
        await vm.awaitGenerateCompletion()
        XCTAssertEqual(vm.generateState, .cancelled)
        let cancels1 = await spy1.cancelCount
        XCTAssertEqual(cancels1, 1)

        // Second run with a fresh spy: starts cleanly, reaches .completed.
        let spy2 = installGenerateSpy(vm, script: .yieldProgress([
            .resolving,
            .completed(rendered: 1, skipped: 0),
        ]))
        await vm.generate(generateRequest())
        await vm.awaitGenerateCompletion()
        XCTAssertEqual(vm.generateState, .completed(rendered: 1, skipped: 0))
        let cancels2 = await spy2.cancelCount
        XCTAssertEqual(cancels2, 0, "second run's coordinator must not be cancelled")
    }

    // MARK: - Stitch: success + error cases

    func testStitchSuccessTransitionsToCompleted() async {
        let vm = FlockModel()
        let out = outURL()
        installStitchSpy(vm, script: .yieldProgress([
            .resolving,
            .plan(hitCount: 2, missCount: 0, segmentCount: 2),
            .running(hit: 2, generated: 0),
            .completed(out: out),
        ]))
        await vm.stitch(stitchRequest())
        await vm.awaitStitchCompletion()
        XCTAssertEqual(vm.stitchState, .completed(out))
    }

    func testStitchEmptySequenceFails() async {
        // The coordinator (real or spy) yields this for empty orderedFlames.
        let vm = FlockModel()
        installStitchSpy(vm, script: .yieldProgress([
            .failed("Sequence is empty."),
        ]))
        await vm.stitch(stitchRequest(flames: []))
        await vm.awaitStitchCompletion()
        XCTAssertEqual(vm.stitchState, .failed("Sequence is empty."))
    }

    func testStitchCrossShardFails() async {
        let vm = FlockModel()
        installStitchSpy(vm, script: .yieldProgress([
            .resolving,
            .failed("Stitch requires a single shard."),
        ]))
        await vm.stitch(stitchRequest())
        await vm.awaitStitchCompletion()
        XCTAssertEqual(vm.stitchState, .failed("Stitch requires a single shard."))
    }

    func testStitchCodecMismatchFails() async {
        let vm = FlockModel()
        installStitchSpy(vm, script: .yieldProgress([
            .resolving,
            .failed("Archive shard has mixed codecs. Run 'flock rebuild'."),
        ]))
        await vm.stitch(stitchRequest())
        await vm.awaitStitchCompletion()
        XCTAssertEqual(vm.stitchState, .failed("Archive shard has mixed codecs. Run 'flock rebuild'."))
    }

    func testStitchFailedFromCoordinatorError() async {
        let vm = FlockModel()
        installStitchSpy(vm, script: .throwImmediately(
            NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "concat failed"])))
        await vm.stitch(stitchRequest())
        await vm.awaitStitchCompletion()
        if case .failed(let m) = vm.stitchState {
            XCTAssertTrue(m.contains("concat failed"), "got \(m)")
        } else {
            XCTFail("expected .failed, got \(vm.stitchState)")
        }
    }

    func testStitchCancelTransitionsToCancelled() async {
        let vm = FlockModel()
        let spy = installStitchSpy(vm, script: .yieldUntilCancelled)
        await vm.stitch(stitchRequest())
        vm.cancelStitch()
        await vm.awaitStitchCompletion()
        XCTAssertEqual(vm.stitchState, .cancelled)
        let cancels = await spy.cancelCount
        XCTAssertEqual(cancels, 1)
    }

    // MARK: - Stitch: per-frame progress, plan total, concat phase (v0.5.9)

    func testStitchRunningCarriesPlanTotalAndColdStartETA() async {
        let vm = FlockModel()
        // No terminal ⇒ the last applied state is observable (.running). The
        // plan deliberately has segmentCount (5) ≠ hit + miss (3) — the
        // loop-repetition shape: 3 unique archive keys across 5 timeline slots.
        installStitchSpy(vm, script: .yieldProgress([
            .resolving,
            .plan(hitCount: 2, missCount: 1, segmentCount: 5),
            .running(hit: 2, generated: 1),
        ]))
        await vm.stitch(stitchRequest())
        await vm.awaitStitchCompletion()
        // The state-driven total is the plan's SEGMENT (slot) count, NOT
        // hit + miss (unique work) and NOT the view's own sequence count. ETA
        // nil: no completed-MISS sample yet (cold start).
        XCTAssertEqual(vm.stitchState, .running(hit: 2, generated: 1, total: 5, etaSeconds: nil))
    }

    func testStitchRenderingMapsToStateWithColdStartETA() async {
        let vm = FlockModel()
        installStitchSpy(vm, script: .yieldProgress([
            .resolving,
            .plan(hitCount: 0, missCount: 3, segmentCount: 3),
            .running(hit: 0, generated: 0),
            .rendering(segment: 1, total: 3, isLoop: true, frame: 0, frameTotal: 450),
            .rendering(segment: 1, total: 3, isLoop: true, frame: 180, frameTotal: 450),
        ]))
        await vm.stitch(stitchRequest())
        await vm.awaitStitchCompletion()
        XCTAssertEqual(vm.stitchState,
                       .rendering(segment: 1, total: 3, isLoop: true,
                                  frame: 180, frameTotal: 450, etaSeconds: nil))
    }

    func testStitchConcatenatingMapsToState() async {
        let vm = FlockModel()
        installStitchSpy(vm, script: .yieldProgress([
            .resolving,
            .plan(hitCount: 0, missCount: 1, segmentCount: 1),
            .running(hit: 0, generated: 1),
            .concatenating(segments: 2),
        ]))
        await vm.stitch(stitchRequest())
        await vm.awaitStitchCompletion()
        XCTAssertEqual(vm.stitchState, .concatenating(segments: 2))
    }

    // MARK: - Elapsed on completion (v0.5.9)

    func testStitchElapsedRecordedOnCompletionAndResetOnNewRun() async {
        let vm = FlockModel()
        let out = outURL()
        installStitchSpy(vm, script: .yieldProgress([
            .resolving, .plan(hitCount: 0, missCount: 0, segmentCount: 0), .completed(out: out),
        ]))
        await vm.stitch(stitchRequest())
        await vm.awaitStitchCompletion()
        XCTAssertNotNil(vm.stitchElapsedSeconds, "completion must publish the run elapsed")
        // A fresh run clears it until it completes again.
        installStitchSpy(vm, script: .yieldProgress([.resolving]))
        await vm.stitch(stitchRequest())
        await vm.awaitStitchCompletion()
        XCTAssertNil(vm.stitchElapsedSeconds, "a new in-flight run clears the stale elapsed")
    }

    func testGenerateElapsedRecordedOnCompletion() async {
        let vm = FlockModel()
        installGenerateSpy(vm, script: .yieldProgress([
            .resolving, .completed(rendered: 2, skipped: 0),
        ]))
        await vm.generate(generateRequest())
        await vm.awaitGenerateCompletion()
        XCTAssertNotNil(vm.generateElapsedSeconds)
    }

    // MARK: - Global activity summary (sidebar presence, v0.5.9)

    func testFlockActivityNilWhenIdle() {
        let vm = FlockModel()
        XCTAssertNil(vm.flockActivity, "no run in flight ⇒ no sidebar indicator")
    }

    func testFlockActivityFromGenerateRunning() async {
        let vm = FlockModel()
        installGenerateSpy(vm, script: .yieldProgress([
            .running(skip: 1, render: 3, total: 5),
        ]))
        await vm.generate(generateRequest())
        await vm.awaitGenerateCompletion()
        XCTAssertEqual(vm.flockActivity,
                       FlockActivitySummary(kind: .generate, fraction: 4.0 / 5.0,
                                            completed: 4, total: 5, etaSeconds: nil))
    }

    func testFlockActivityFromGenerateRenderingIncludesFrameFraction() async {
        let vm = FlockModel()
        installGenerateSpy(vm, script: .yieldProgress([
            .rendering(skip: 0, render: 2, total: 5, frame: 90, frameTotal: 360),
        ]))
        await vm.generate(generateRequest())
        await vm.awaitGenerateCompletion()
        // (2 + 90/360) / 5 = 2.25 / 5 = 0.45 exactly.
        XCTAssertEqual(vm.flockActivity,
                       FlockActivitySummary(kind: .generate, fraction: 0.45,
                                            completed: 2, total: 5, etaSeconds: nil))
    }

    func testFlockActivityFromStitchRendering() async {
        let vm = FlockModel()
        installStitchSpy(vm, script: .yieldProgress([
            .plan(hitCount: 1, missCount: 2, segmentCount: 3),
            .rendering(segment: 2, total: 3, isLoop: true, frame: 3, frameTotal: 6),
        ]))
        await vm.stitch(stitchRequest())
        await vm.awaitStitchCompletion()
        // (1 + 3/6) / 3 = 0.5 exactly; completed counts whole segments.
        XCTAssertEqual(vm.flockActivity,
                       FlockActivitySummary(kind: .stitch, fraction: 0.5,
                                            completed: 1, total: 3, etaSeconds: nil))
    }

    func testFlockActivityIndeterminatePhasesAreSpinnerOnly() async {
        // resolving / plan / concatenating ⇒ fraction nil (the sidebar shows a
        // spinner, no bar).
        let vm = FlockModel()
        installGenerateSpy(vm, script: .yieldProgress([.resolving]))
        await vm.generate(generateRequest())
        await vm.awaitGenerateCompletion()
        XCTAssertEqual(vm.flockActivity?.fraction, nil)
        XCTAssertEqual(vm.flockActivity?.kind, .generate)

        let vm2 = FlockModel()
        installStitchSpy(vm2, script: .yieldProgress([.plan(hitCount: 2, missCount: 1, segmentCount: 3)]))
        await vm2.stitch(stitchRequest())
        await vm2.awaitStitchCompletion()
        XCTAssertEqual(vm2.flockActivity?.fraction, nil)
        XCTAssertEqual(vm2.flockActivity?.kind, .stitch)

        let vm3 = FlockModel()
        installStitchSpy(vm3, script: .yieldProgress([.concatenating(segments: 3)]))
        await vm3.stitch(stitchRequest())
        await vm3.awaitStitchCompletion()
        XCTAssertEqual(vm3.flockActivity?.fraction, nil)
    }

    func testFlockActivityPrefersMostRecentlyStartedRun() async {
        // Both machines in flight ⇒ the later-started run (the user's current
        // focus) drives the sidebar indicator. Deterministic: the start instants
        // are set synchronously at run start, and stitch() runs after generate().
        let vm = FlockModel()
        installGenerateSpy(vm, script: .yieldProgress([.running(skip: 0, render: 1, total: 4)]))
        await vm.generate(generateRequest())
        await vm.awaitGenerateCompletion()
        XCTAssertEqual(vm.flockActivity?.kind, .generate)

        installStitchSpy(vm, script: .yieldProgress([
            .plan(hitCount: 0, missCount: 2, segmentCount: 2), .running(hit: 0, generated: 1),
        ]))
        await vm.stitch(stitchRequest())
        await vm.awaitStitchCompletion()
        XCTAssertEqual(vm.flockActivity?.kind, .stitch,
                       "the most recently started run wins the sidebar indicator")
        XCTAssertEqual(vm.flockActivity?.fraction, 0.5)
    }

    // MARK: - Shared formatter + compact token (v0.5.9)

    func testProgressFormattingLabels() {
        XCTAssertEqual(ProgressFormatting.etaLabel(3), "~3 s remaining")
        XCTAssertEqual(ProgressFormatting.etaLabel(59.4), "~59 s remaining")
        XCTAssertEqual(ProgressFormatting.etaLabel(72), "~1 m 12 s remaining")
        XCTAssertEqual(ProgressFormatting.etaLabel(3725), "~1 h 2 m remaining")
        XCTAssertEqual(ProgressFormatting.etaToken(nil), "estimating…")
        XCTAssertEqual(ProgressFormatting.etaToken(90), "~1 m 30 s remaining")
        XCTAssertEqual(ProgressFormatting.elapsedLabel(42), "42 s")
        XCTAssertEqual(ProgressFormatting.elapsedLabel(252), "4 m 12 s")
        XCTAssertEqual(ProgressFormatting.elapsedLabel(3785), "1 h 3 m")
        XCTAssertEqual(ProgressFormatting.elapsedLabel(-5), "0 s", "never negative")
    }

    func testFlockActivitySummaryCompactStatus() {
        XCTAssertEqual(FlockActivitySummary(kind: .generate, fraction: nil, completed: nil,
                                            total: nil, etaSeconds: 756).compactStatus, "~12:36")
        XCTAssertEqual(FlockActivitySummary(kind: .stitch, fraction: nil, completed: nil,
                                            total: nil, etaSeconds: 3807).compactStatus, "~1:03:27")
        XCTAssertEqual(FlockActivitySummary(kind: .stitch, fraction: 0.25, completed: 3,
                                            total: 12, etaSeconds: nil).compactStatus, "3/12")
        XCTAssertEqual(FlockActivitySummary(kind: .generate, fraction: nil, completed: nil,
                                            total: nil, etaSeconds: nil).compactStatus, "")
        XCTAssertEqual(FlockActivitySummary(kind: .generate, fraction: nil, completed: nil,
                                            total: nil, etaSeconds: nil).kindLabel, "Generating")
        XCTAssertEqual(FlockActivitySummary(kind: .stitch, fraction: nil, completed: nil,
                                            total: nil, etaSeconds: nil).kindLabel, "Stitching")
    }


    // MARK: - Browse: loaded / empty / failed

    func testBrowseLoaded() async {
        let vm = FlockModel()
        let snap = FlockSnapshot(shardCount: 1, artifactCount: 4)
        vm.snapshotProvider = { snap }
        await vm.refreshBrowse()
        XCTAssertEqual(vm.browseState, .loaded(snap))
    }

    func testBrowseEmptyWhenNoShardsOrArtifacts() async {
        let vm = FlockModel()
        vm.snapshotProvider = { FlockSnapshot(shardCount: 0, artifactCount: 0) }
        await vm.refreshBrowse()
        XCTAssertEqual(vm.browseState, .empty)
    }

    func testBrowseFailed() async {
        let vm = FlockModel()
        struct Boom: Error {}
        vm.snapshotProvider = { throw Boom() }
        await vm.refreshBrowse()
        if case .failed = vm.browseState {
            // ok
        } else {
            XCTFail("expected .failed, got \(vm.browseState)")
        }
    }
}
