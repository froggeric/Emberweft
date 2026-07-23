import Foundation

/// flam3 `interpolation` (temporal smoothing of the blend scalar). flam3.c:1284.
public enum TempInterpolation: String, Sendable, Codable {
    case linear, smooth
}

/// flam3 `interpolation_type` (how xform matrices blend). flam3.c:1312 default log.
public enum MatrixInterpolationType: String, Sendable, Codable {
    case linear, log, compat, older
}

/// flam3 `palette_interpolation`. flam3.h:75-78; default hsv_circular.
public enum PaletteInterpolation: String, Sendable, Codable {
    case sweep, rgb, hsv
    case hsvCircular = "hsv_circular"
}

/// flam3 `palette_mode` (flam3.h:82-83; rect.c:471-498). How the chaos game
/// samples the 256-entry dmap between integer color indices. flam3's DEFAULT
/// is `step` (clear_cp, flam3.c:1326) — nearest entry, NO interpolation. The
/// `palette_mode="linear|step"` attr overrides. (Note: the Apophysis
/// `palette_interpolation` attr is a DIFFERENT thing that flam3 ignores.)
/// Linear interp across palette jumps (channel wraparounds / spiky ES
/// palettes) diverges badly from flam3, so the renderer must default to step.
public enum PaletteMode: String, Sendable, Codable {
    case step, linear
}

