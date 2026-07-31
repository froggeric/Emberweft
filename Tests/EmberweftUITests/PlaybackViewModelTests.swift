import XCTest
@testable import EmberweftUI
import FlameKit
import FlamePlayer

@MainActor
final class PlaybackViewModelTests: XCTestCase {

    private func simpleFlame() -> Flame {
        Flame(xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])
    }
    private func tinyParams() -> RenderParams {
        RenderParams(seed: 1, width: 16, height: 16, oversample: 1, samplesPerPixel: 1)
    }

    /// A @MainActor counting renderer (Renderer is Sendable; MainActor-isolated ⇒ Sendable).
    @MainActor
    final class CountingRenderer: Renderer {
        var calls = 0
        func render(flame: Flame, params: RenderParams) async -> RGBA8Image {
            calls += 1
            return RGBA8Image(width: params.width, height: params.height,
                              pixels: [UInt8](repeating: 0, count: params.width * params.height * 4))
        }
    }

    /// A clock whose `sleep(until:)` returns immediately (no real waiting).
    struct NoSleepClock: PlaybackClock {
        func now() -> Double { 0 }
        func sleep(until deadline: Double) async {}
    }

    // MARK: - load / play / pause

    func testLoadDoesNotStartPlayback() async {
        let vm = PlaybackViewModel()
        vm.load(flame: simpleFlame(), params: tinyParams(), backend: .cpu, targetFPS: 60)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertFalse(vm.debugLoopAlive)
        XCTAssertEqual(vm.position, 0)
    }

    func testPlayPauseToggleIsPlaying() async {
        let vm = PlaybackViewModel()
        vm.setRenderer(CountingRenderer()); vm.setClock(NoSleepClock())
        vm.load(flame: simpleFlame(), params: tinyParams(), backend: .cpu, targetFPS: 60)
        vm.play(); XCTAssertTrue(vm.isPlaying); XCTAssertTrue(vm.debugLoopAlive)
        vm.pause(); XCTAssertFalse(vm.isPlaying); XCTAssertFalse(vm.debugLoopAlive)
        vm.togglePlaying(); XCTAssertTrue(vm.isPlaying)
    }

    func testStopResetsPositionAndStopsLoop() async {
        let vm = PlaybackViewModel()
        vm.setRenderer(CountingRenderer()); vm.setClock(NoSleepClock())
        vm.load(flame: simpleFlame(), params: tinyParams(), backend: .cpu, targetFPS: 60)
        vm.play()
        await vm.stop()
        XCTAssertFalse(vm.isPlaying)
        XCTAssertFalse(vm.debugLoopAlive)
        XCTAssertEqual(vm.position, 0)
    }

    // MARK: - scrub (render on demand while paused)

    func testScrubWhilePausedRendersExactlyOneFrame() async {
        let vm = PlaybackViewModel()
        vm.load(flame: simpleFlame(), params: tinyParams(), backend: .cpu, targetFPS: 60)
        // Inject the counting renderer AFTER load (load sets the backend renderer).
        let r = CountingRenderer(); vm.setRenderer(r)
        vm.setClock(NoSleepClock())
        let before = r.calls
        await vm.scrub(to: 0.5)
        XCTAssertEqual(vm.position, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.calls - before, 1, "paused scrub renders exactly one frame")
    }

    func testScrubClampsToUnitRange() async {
        let vm = PlaybackViewModel()
        vm.setRenderer(CountingRenderer()); vm.setClock(NoSleepClock())
        vm.load(flame: simpleFlame(), params: tinyParams(), backend: .cpu, targetFPS: 60)
        await vm.scrub(to: 5.0); XCTAssertLessThanOrEqual(vm.position, 1.0)
        await vm.scrub(to: -3.0); XCTAssertGreaterThanOrEqual(vm.position, 0.0)
    }

    // MARK: - determinism (rule #2)

    func testRenderOnceIsDeterministicAtFixedSeed() async {
        let vm = PlaybackViewModel()
        // Real CPU renderer (deterministic at fixed seed) — no Metal needed.
        vm.load(flame: simpleFlame(), params: tinyParams(), backend: .cpu, targetFPS: 60)
        // Capture both frames via a renderer that returns the real CPU image.
        let a = await captureFrame(vm, at: 0.25)
        let b = await captureFrame(vm, at: 0.25)
        XCTAssertEqual(a, b, "same position + seed ⇒ identical pixels")
    }

    private func captureFrame(_ vm: PlaybackViewModel, at p: Double) async -> RGBA8Image {
        final class Box: @unchecked Sendable { var img: RGBA8Image? }
        final class CapturingRenderer: Renderer, @unchecked Sendable {
            let inner = CPUFrameRenderer(); let box = Box()
            func render(flame: Flame, params: RenderParams) async -> RGBA8Image {
                let img = await inner.render(flame: flame, params: params)
                box.img = img; return img
            }
        }
        let c = CapturingRenderer(); vm.setRenderer(c)
        await vm.renderOnce(at: p)
        return c.box.img ?? RGBA8Image(width: 1, height: 1, pixels: [0,0,0,0])
    }

    // MARK: - degenerate guard

    func testNonRenderableFlameRendersNothing() async {
        let vm = PlaybackViewModel()
        let nan = Flame(camera: Camera(center: SIMD2<Double>(.nan, 0), scale: 250),
                        xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])
        vm.load(flame: nan, params: tinyParams(), backend: .cpu, targetFPS: 60)
        let r = CountingRenderer(); vm.setRenderer(r)   // inject after load
        let before = r.calls
        await vm.renderOnce(at: 0.5)   // guarded ⇒ no render
        await vm.scrub(to: 0.5)
        XCTAssertEqual(r.calls, before, "non-renderable flame renders nothing (guarded), no trap")
    }
}
