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
