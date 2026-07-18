import AppKit
import QuartzCore
import Metal
import FlameKit
import FlameRenderer

// FlameUI — M3 / S7 / Task 22.
//
// A `@MainActor` `NSView` subclass backed by `CAMetalLayer` that hosts the
// `PlaybackDispatcher`'s output and drives vsync-paced presentation.
//
// Conforms to the dispatcher's `FrameSink` protocol (Task 20) — the same
// callback the dispatcher already `await`s. There is NO parallel callback: the
// dispatcher hands over an `RGBA8Image` per global frame and `FlameUI.display`
// crosses the MainActor explicitly (the conformance is `@MainActor`-isolated,
// which satisfies `FrameSink: Sendable`).
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │ Isolation contract (LOAD-BEARING — do not weaken)                       │
// ├─────────────────────────────────────────────────────────────────────────┤
// │ • `FlameUI` is `@MainActor` (NSView + CAMetalLayer are main-thread).    │
// │ • A `@MainActor`-isolated class is implicitly `Sendable`, satisfying     │
// │   `FrameSink: Sendable` without `nonisolated(unsafe)` escape hatches.   │
// │ • The dispatcher's `await sink.display(...)` is the actor crossing.      │
// │ • Teardown of any owned dispatcher is an explicit `async stop()` the     │
// │   owner calls (Swift 6 forbids async work in `deinit`).                 │
// └─────────────────────────────────────────────────────────────────────────┘

/// A `@MainActor` `NSView` backed by `CAMetalLayer` that presents the
/// dispatcher's frames.
@MainActor
public final class FlameUI: NSView {

    // MARK: - Availability

    /// Mirrors `MetalRenderer.isAvailable` — the view is only useful with a
    /// working Metal backend. Gate construction on this (or on a nil device).
    public static var isAvailable: Bool { MetalRenderer.isAvailable }

    // MARK: - Metal device + layer

    /// The system default Metal device, or `nil` if none (headless sandbox).
    public let metalDevice: MTLDevice?

    /// The backing Metal layer. Guaranteed to be a `CAMetalLayer` once
    /// `commonInit` has run (it always has, before any property access from
    /// the outside since `init` drives it synchronously on the MainActor).
    public var metalLayer: CAMetalLayer {
        // `wantsLayer = true` + an explicit `CAMetalLayer` is set in
        // `commonInit`; the cast cannot fail post-init.
        layer as! CAMetalLayer
    }

    /// FrameInfo for the most recently displayed frame (diagnostics).
    public private(set) var lastFrameInfo: FrameInfo?

    // MARK: - Init

    /// Headless convenience initializer (zero-rect) — used by tests and by
    /// embedding code that sizes the view via auto-layout / `layout()`.
    public convenience init() {
        self.init(frame: .zero)
    }

    public override init(frame frameRect: NSRect) {
        // `MTLCreateSystemDefaultDevice()` is the documented way to obtain the
        // system GPU; returns `nil` in a sandboxed headless environment. We
        // tolerate `nil`: `CAMetalLayer` still accepts a `CGImage` as
        // `contents`, and the headless smoke test exercises exactly that path.
        self.metalDevice = MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        self.metalDevice = MTLCreateSystemDefaultDevice()
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true

        let ml = CAMetalLayer()
        ml.device = metalDevice
        // `.bgra8Unorm` matches the renderer's RGBA8 output (component order is
        // irrelevant once we hand the layer a CGImage — the pixel format only
        // governs the drawable path; kept here for the future MTLTexture path).
        ml.pixelFormat = .bgra8Unorm
        // `framebufferOnly = true` is the CAMetalLayer default and the right
        // choice when presenting (no read-back). Honored even though the
        // current contents path uses a CGImage.
        ml.framebufferOnly = true
        ml.contentsGravity = .resizeAspect
        layer = ml
    }

    // MARK: - Layout

    /// Keep the Metal layer pinned to the view's bounds. Wrapped in an explicit
    /// `CATransaction` with implicit animations disabled so resizes don't fade.
    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        CATransaction.commit()
    }

    /// Layer-backed resize hook — mirrors `layout()` for the
    /// `wantsUpdateLayer == false` (default) path.
    public override func updateLayer() {
        metalLayer.frame = bounds
    }

    // MARK: - Frame presentation

    /// Present a freshly rendered frame. Builds a `CGImage` from the renderer's
    /// RGBA8 pixels and hands it to the Metal layer's `contents`. No-fault if the
    /// image can't be built (returns `false`); the dispatcher never depends on
    /// the return value — this is a presentation sink, not a render step.
    ///
    /// On the MainActor; safe to call directly from tests (headless, no window).
    @discardableResult
    public func present(_ image: RGBA8Image) -> Bool {
        guard let cg = Self.makeCGImage(image) else { return false }
        metalLayer.contents = cg
        return true
    }
}

// MARK: - FrameSink conformance

extension FlameUI: FrameSink {

    /// `FrameSink.display` — the single callback the `PlaybackDispatcher`
    /// `await`s per global frame. Hands the image to the Metal layer on the
    /// MainActor (this method's isolation) and records the frame info.
    public func display(_ image: RGBA8Image, info: FrameInfo) async -> Void {
        lastFrameInfo = info
        _ = present(image)
    }
}

// MARK: - RGBA8Image → CGImage

extension FlameUI {

    /// Build a `CGImage` (RGBA, alpha-last) from the renderer's pixel buffer.
    /// `premultipliedLast` matches the display pipeline's premultiplied output.
    /// Rows are emitted top-to-bottom; the layer's default (non-flipped)
    /// coordinate space renders them bottom-up, so we flip via the provider's
    /// row order to preserve the renderer's orientation.
    static func makeCGImage(_ image: RGBA8Image) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        let bytesPerPixel = 4

        // Flip rows (renderer is top-origin; CGImage is bottom-origin).
        var flipped = [UInt8](repeating: 0, count: image.pixels.count)
        for y in 0..<height {
            let srcRow = y * bytesPerRow
            let dstRow = (height - 1 - y) * bytesPerRow
            flipped[dstRow..<(dstRow + bytesPerRow)] =
                image.pixels[srcRow..<(srcRow + bytesPerRow)]
        }

        // `withUnsafeBufferPointer`'s closure is non-escaping, so we can build
        // and return the CGImage directly from it (no thread-local scratch).
        return flipped.withUnsafeBufferPointer { ptr -> CGImage? in
            guard let cfData = CFDataCreate(
                    kCFAllocatorDefault, ptr.baseAddress, ptr.count),
                  let provider = CGDataProvider(data: cfData)
            else { return nil }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8 * bytesPerPixel,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }
}
