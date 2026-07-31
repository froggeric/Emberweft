import FlameKit
import FlameReference
import FlamePlayer

/// CPU `Renderer` conformer — wraps `ReferenceRenderer.render` (the flam3-faithful
/// oracle). NOT `@MainActor`: the CPU path is pure, off-main work. This is the
/// fallback when Metal is unavailable (headless sandbox, unsupported GPU) and the
/// honest backer of `AppPreferences.backend == .cpu`.
public struct CPUFrameRenderer: Renderer {

    public init() {}

    public func render(flame: Flame, params: RenderParams) async -> RGBA8Image {
        ReferenceRenderer.render(flame: flame, params: params)
    }
}
