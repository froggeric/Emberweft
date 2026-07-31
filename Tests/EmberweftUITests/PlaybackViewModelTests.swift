import XCTest
@testable import EmberweftUI
import FlameKit
import FlameRenderer

@MainActor
final class PlaybackViewModelTests: XCTestCase {

    private func simpleFlame() -> Flame {
        Flame(xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])
    }

    private func tinyParams() -> RenderParams {
        RenderParams(seed: 1, width: 16, height: 16, oversample: 1, samplesPerPixel: 1)
    }

    func testStartCreatesOneDispatcher() async {
        let vm = PlaybackViewModel()
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.debugDispatcherCount, 0)

        await vm.start(flame: simpleFlame(), params: tinyParams(),
                       backend: .cpu, targetFPS: 60)
        XCTAssertTrue(vm.isPlaying)
        XCTAssertEqual(vm.debugDispatcherCount, 1)

        await vm.stop()
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.debugDispatcherCount, 0)
    }

    func testStopIsIdempotent() async {
        let vm = PlaybackViewModel()
        await vm.start(flame: simpleFlame(), params: tinyParams(),
                       backend: .cpu, targetFPS: 60)
        await vm.stop()
        await vm.stop()  // must not trap; still zero dispatchers
        XCTAssertEqual(vm.debugDispatcherCount, 0)
    }

    func testSequentialRestartLeavesOneDispatcher() async {
        let vm = PlaybackViewModel()
        await vm.start(flame: simpleFlame(), params: tinyParams(),
                       backend: .cpu, targetFPS: 60)
        XCTAssertEqual(vm.debugDispatcherCount, 1)
        await vm.start(flame: simpleFlame(), params: tinyParams(),
                       backend: .cpu, targetFPS: 60)  // start tears down the prior
        XCTAssertLessThanOrEqual(vm.debugDispatcherCount, 1)
        await vm.stop()
        XCTAssertEqual(vm.debugDispatcherCount, 0)
    }

    func testBackendToggleSelectsMetalWhenAvailable() async throws {
        // Metal may be unavailable under sandbox — the invariant here is only
        // that `.metal` doesn't trap on start when available.
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let vm = PlaybackViewModel()
        await vm.start(flame: simpleFlame(), params: tinyParams(),
                       backend: .metal, targetFPS: 60)
        XCTAssertEqual(vm.debugDispatcherCount, 1)
        await vm.stop()
    }
}
