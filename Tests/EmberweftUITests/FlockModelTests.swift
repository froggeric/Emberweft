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
                cont.yield(.plan(hitCount: 0, missCount: 0))
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
        XCTAssertEqual(vm.generateState, .running(skip: 1, render: 3, total: 5))
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
            .plan(hitCount: 2, missCount: 0),
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
