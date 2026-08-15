import class Foundation.Bundle

/// Locates this module's SwiftPM resource bundle (`emberweft_FlameRenderer.bundle`, which
/// carries the Metal shaders) in every launch context.
///
/// SwiftPM 6's generated `Bundle.module` accessor only searches
/// `Bundle.main.bundleURL/<name>.bundle` and a compile-time `.build` path:
///
/// - Bare CLI (`dist/emberweft`, `swift run`): `bundleURL` is the executable's directory,
///   where the sibling bundle sits — works, unchanged.
/// - `.app` bundle (`make dist` → `Emberweft.app`): `bundleURL` is the .app ROOT, where
///   `codesign` rejects foreign entries ("unsealed contents present in the bundle root"),
///   and the `.build` path only exists on the build machine. The standard
///   `Contents/Resources/` placement — exactly `Bundle.main.resourceURL` — is never
///   consulted, so a bundled app crash-exits at launch ("could not load resource bundle").
///
/// We therefore resolve `Bundle.main.resourceURL` FIRST: for a bundled app that is
/// `Contents/Resources/`; for a bare executable it is the executable's directory (the same
/// sibling bundle `Bundle.module` finds). Everything else falls through to `Bundle.module`
/// unchanged (tests, `.build` runs).
enum ModuleResources {
    static let bundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL,
            let bundled = Bundle(url: resourceURL.appendingPathComponent("emberweft_FlameRenderer.bundle"))
        {
            return bundled
        }
        return Bundle.module
    }()
}
