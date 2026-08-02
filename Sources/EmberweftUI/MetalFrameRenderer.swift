import FlameKit
import FlameRenderer
import FlamePlayer

/// Metal `Renderer` conformer — wraps `MetalRenderer.render` on the MainActor.
///
/// `MetalRenderer.render` is `@MainActor`, synchronous, and `fatalError`s on a
/// missing GPU OR any render error (`MetalRenderer.swift:96-104`). This conformer
/// therefore **gates on `MetalRenderer.isAvailable`** (itself `@MainActor`) and
/// returns a blank `RGBA8Image` instead of trapping when Metal is unavailable.
/// The dispatcher's `await renderer.render(...)` is the actor→MainActor crossing.
@MainActor
public struct MetalFrameRenderer: Renderer {

    public init() {}

    /// Whether a Metal GPU is available (forwards `MetalRenderer.isAvailable`).
    /// Exposed so the GUI (which doesn't import `FlameRenderer`) can gate the
    /// backend picker without a new module dependency.
    public static var isMetalAvailable: Bool { MetalRenderer.isAvailable }

    public func render(flame: Flame, params: RenderParams) async -> RGBA8Image {
        guard MetalRenderer.isAvailable else {
            return Self.blank(width: params.width, height: params.height)
        }
        return MetalRenderer.render(flame: flame, params: params)
    }

    /// An all-zero frame (solid black, fully transparent) — the never-trap fallback.
    nonisolated private static func blank(width: Int, height: Int) -> RGBA8Image {
        RGBA8Image(width: max(width, 1), height: max(height, 1),
                   pixels: [UInt8](repeating: 0, count: max(width, 1) * max(height, 1) * 4))
    }
}
