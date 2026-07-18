import XCTest
import AppKit
import QuartzCore
import Metal
@testable import FlameRenderer
import FlameKit
@testable import FlamePlayer

// Tests for Task 22: FlameUI — a `@MainActor` `NSView` subclass backed by
// `CAMetalLayer` that hosts the dispatcher's output.
//
// Per the verified headless feasibility note in the task, `NSView` requires no
// window to instantiate and `CAMetalLayer` can be created and fed without a
// backing window. These tests skip cleanly when Metal is unavailable or the
// sandbox blocks device creation. Metal tests need the bash sandbox DISABLED.

@MainActor
final class FlameUITests: XCTestCase {

    // MARK: - Headless construction + layer wiring

    /// `FlameUI` constructs headless (no window), is layer-backed, and exposes
    /// a `CAMetalLayer`. Runs even without a Metal device — only the device
    /// itself is optional.
    func testHeadlessConstructionIsCAMetalLayerBacked() throws {
        let ui = FlameUI()
        XCTAssertTrue(ui.wantsLayer)
        XCTAssertNotNil(ui.layer)
        XCTAssertTrue(ui.layer is CAMetalLayer, "backing layer must be CAMetalLayer")
        // The layer is configured for aspect-fit presentation.
        XCTAssertEqual(ui.metalLayer.contentsGravity, .resizeAspect)
    }

    /// `isAvailable` mirrors `MetalRenderer.isAvailable` exactly.
    func testIsAvailableMirrorsMetalRenderer() {
        XCTAssertEqual(FlameUI.isAvailable, MetalRenderer.isAvailable)
    }

    /// The view reports the system default device when one exists; nil under a
    /// device-blocking sandbox. Either way construction must not fault.
    func testMetalDeviceOrNil() throws {
        let ui = FlameUI()
        if let device = ui.metalDevice {
            // When present, it should match the system default device family.
            XCTAssertEqual(device.name, MTLCreateSystemDefaultDevice()?.name)
            XCTAssertEqual(ui.metalLayer.device?.name, device.name)
        } else {
            // Headless sandbox: device is nil but the layer still exists.
            XCTAssertNil(ui.metalLayer.device)
        }
    }

    // MARK: - Frame acceptance (smoke)

    /// Smoke test: the view accepts at least one synthetic frame without
    /// faulting, regardless of Metal availability. The frame is delivered via
    /// the same `FrameSink.display` callback the dispatcher uses.
    func testAcceptsOneFrameViaFrameSink() async throws {
        let ui = FlameUI()
        // Lay it out so `layout()` runs at least once without fault.
        ui.setBoundsSize(NSSize(width: 4, height: 4))
        ui.layout()

        let image = RGBA8Image(width: 2, height: 2,
                               pixels: [255, 0, 0, 255,
                                        0, 255, 0, 255,
                                        0, 0, 255, 255,
                                        255, 255, 0, 255])
        let info = FrameInfo(globalFrame: 0, segmentId: 0, kind: .loop, blend: 0.5)

        // The dispatcher awaits this exact crossing; call it directly here.
        await ui.display(image, info: info)

        XCTAssertEqual(ui.lastFrameInfo, info, "FrameInfo must be recorded")
        XCTAssertNotNil(ui.metalLayer.contents,
                        "layer.contents must be set after presenting a frame")
    }

    /// `present(_:)` returns true on a valid image, false on an empty one — no
    /// fault in either case.
    func testPresentReturnSemantics() {
        let ui = FlameUI()
        let good = RGBA8Image(width: 1, height: 1, pixels: [10, 20, 30, 255])
        XCTAssertTrue(ui.present(good))
        XCTAssertNotNil(ui.metalLayer.contents)

        // Degenerate (zero-area) image: build fails, returns false, no fault.
        let bad = RGBA8Image(width: 0, height: 0, pixels: [])
        XCTAssertFalse(ui.present(bad))
    }

    // MARK: - Offscreen MetalRenderer render path (skip on no-Metal)

    /// The acceptance-criteria smoke test: render a real frame through the
    /// existing offscreen `MetalRenderer.render` path and hand it to the view.
    /// Skips when Metal is unavailable OR the sandbox blocks device creation.
    func testAcceptsFrameFromOffscreenMetalRenderPath() async throws {
        guard FlameUI.isAvailable else {
            throw XCTSkip("Metal unavailable — FlameUI.isAvailable is false")
        }
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device nil (sandbox blocks device creation)")
        }

        // A minimal valid genome (single linear xform) so the Metal chaos game
        // produces a well-formed frame. Tiny dimensions keep the test cheap.
        var flame = Flame(name: "flameui-smoke")
        flame.size = SIMD2<Int>(8, 8)
        flame.camera = Camera(scale: 100)
        flame.xforms = [Xform(
            affine: AffineTransform(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0),
            variations: [Variation(name: "linear", weight: 1.0)])]

        let params = RenderParams(seed: 0, width: 8, height: 8,
                                  oversample: 1, samplesPerPixel: 4)

        let image = MetalRenderer.render(flame: flame, params: params)
        XCTAssertEqual(image.width * image.height * 4, image.pixels.count)

        let ui = FlameUI()
        ui.setBoundsSize(NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
        ui.layout()

        let info = FrameInfo(globalFrame: 7, segmentId: 1, kind: .transition, blend: 0.25)
        await ui.display(image, info: info)

        XCTAssertEqual(ui.lastFrameInfo, info)
        XCTAssertNotNil(ui.metalLayer.contents,
                        "real Metal frame must land on the layer")
    }

    // MARK: - Layout

    /// `layout()` keeps the Metal layer pinned to the view bounds.
    func testLayoutPinsLayerToBounds() {
        let ui = FlameUI(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
        ui.layout()
        XCTAssertEqual(ui.metalLayer.frame, CGRect(x: 0, y: 0, width: 100, height: 60))

        ui.setBoundsSize(NSSize(width: 320, height: 240))
        ui.layout()
        XCTAssertEqual(ui.metalLayer.frame, CGRect(x: 0, y: 0, width: 320, height: 240))
    }
}
