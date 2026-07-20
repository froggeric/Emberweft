import Foundation

// MARK: - Pure render value types
//
// Lifted from `FlameReference` so that `FlameRenderer` (Metal) can depend on
// `FlameKit` only. `FlameReference` re-exports `FlameKit`
// (`@_exported import FlameKit`), so every existing call site
// (`FlameReference.RGBA8Image`, `FlameReference.RenderParams`, …) resolves
// unchanged.

public struct RGBA8Image: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]    // RGBA, row-major
    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public struct RenderParams: Sendable, Equatable {
    public let seed: UInt64
    public let width: Int
    public let height: Int
    public let oversample: Int
    public let samplesPerPixel: Int
    public init(seed: UInt64, width: Int, height: Int, oversample: Int, samplesPerPixel: Int) {
        self.seed = seed; self.width = width; self.height = height
        self.oversample = max(1, oversample); self.samplesPerPixel = samplesPerPixel
    }
    /// flam3 default `spatial_filter_radius` (flam3.c:1300). The frozen genomes do
    /// not override it.
    public static let spatialFilterRadius: Double = 0.5
    /// `filter_width` (rect.c:628, `flam3_create_spatial_filter`).
    public var filterWidth: Int { flam3SpatialFilterWidth(oversample: oversample, radius: Self.spatialFilterRadius) }
    /// `gutter_width = (filter_width - oversample) / 2` (rect.c:656). The accumulator
    /// grid is padded by one gutter ring on every side so the spatial filter is fully
    /// centered on border pixels (rect.c:685-686).
    public var gutterWidth: Int { (filterWidth - oversample) / 2 }
    public var gridWidth: Int { width * oversample + 2 * gutterWidth }
    public var gridHeight: Int { height * oversample + 2 * gutterWidth }
    public var totalSamples: Int { width * height * samplesPerPixel }

    /// Builder that returns a copy with `samplesPerPixel` replaced. Keeps the
    /// existing `let` field (Sendable sound) while letting the temporal render
    /// path split the sample budget across sub-passes.
    public func settingSamplesPerPixel(_ n: Int) -> RenderParams {
        RenderParams(seed: seed, width: width, height: height,
                     oversample: oversample, samplesPerPixel: n)
    }
}

public struct Histogram: Equatable, Sendable {
    public var counts: [Double]            // gridWidth*gridHeight — hit count (bucket[4]/255)
    public var colors: [SIMD3<Double>]     // accumulated dmap RGB, PRE-SCALED by WHITE_LEVEL (bucket[0..2])
    public var alpha: [Double]             // accumulated dmap alpha, PRE-SCALED (bucket[3]) — log-density source
    public let gridWidth: Int
    public let gridHeight: Int
    public var sampleSum: Double { counts.reduce(0, +) }
    public init(gridWidth: Int, gridHeight: Int) {
        self.gridWidth = gridWidth; self.gridHeight = gridHeight
        counts = Array(repeating: 0, count: gridWidth * gridHeight)
        colors = Array(repeating: .zero, count: gridWidth * gridHeight)
        alpha = Array(repeating: 0, count: gridWidth * gridHeight)
    }
    /// Flat storage offset for grid cell (x, y). Callers index `counts`/`colors` with it.
    public func binIndex(_ x: Int, _ y: Int) -> Int { x + y * gridWidth }

    /// Elementwise histogram multiplication by `factor` (colors, alpha, AND counts).
    /// General histogram utility — currently exercised only by unit tests, not on
    /// the temporal hot path (the box path passes `colorScalar=1.0` through the
    /// dmap rather than scaling the histogram after accumulation).
    public mutating func scale(by factor: Double) {
        for i in colors.indices {
            colors[i] *= factor
            alpha[i] *= factor
            counts[i] *= factor
        }
    }
    /// Elementwise histogram accumulation across temporal sub-passes (same grid).
    public mutating func accumulate(_ other: Histogram) {
        precondition(gridWidth == other.gridWidth && gridHeight == other.gridHeight,
            "Histogram.accumulate requires equal grid dimensions")
        for i in colors.indices {
            colors[i] += other.colors[i]
            alpha[i]   += other.alpha[i]
            counts[i]  += other.counts[i]
        }
    }
}

/// flam3's spatial-filter kernel width (filters.c:217-269,
/// `flam3_create_spatial_filter`). `fwRaw = 2·support·oversample·radius`; rounded
/// up to even parity with oversample. Shared between the grid-gutter calculation
/// (`RenderParams`) and the kernel build so both reference one identical
/// `filter_width` (rect.c:656,685-686).
public func flam3SpatialFilterWidth(oversample: Int, radius: Double) -> Int {
    let support: Double = 1.5       // flam3_spatial_support[gaussian] (filters.c:31)
    let fwRaw = 2.0 * support * Double(oversample) * radius
    var fwidth = Int(fwRaw) + 1
    if ((fwidth ^ oversample) & 1) != 0 { fwidth += 1 }
    return fwidth
}

// MARK: - Shared builders (CPU + Metal host)

/// `flam3_create_chaos_distrib` (flam3.c:165). The 16384-entry weighted selection
/// table. Shared by the CPU chaos game and the Metal host so the xform-pick
/// *distribution* is bit-identical between backends (only per-thread ordering
/// differs — the source of statistical, not byte-exact, parity).
public enum Flam3XformDistrib {
    /// `CHOOSE_XFORM_GRAIN` (flam3.c:70) — width of the precomputed weighted
    /// xform-selection table. An ISAAC draw masked to 14 bits indexes it.
    public static let grain = 16384

    public static func build(_ weights: [Double]) -> [Int] {
        let n = weights.count
        precondition(n > 0)
        let total = weights.reduce(0, +)
        precondition(total > 0)
        let dr = total / Double(grain)
        var table = [Int](repeating: 0, count: grain)
        var j = 0
        var t = weights[0]
        var r: Double = 0
        for i in 0..<grain {
            while r >= t {
                j += 1
                if j < n { t += weights[j] } else { break }
            }
            table[i] = min(j, n - 1)
            r += dr
        }
        return table
    }
}

/// Build the pre-scaled colormap (dmap) matching flam3 rect.c:778-782.
/// Each entry = `palette[j].color[k] * WHITE_LEVEL * color_scalar` (RGB).
/// `CMAP_SIZE = 256` and `(j*256)/CMAP_SIZE == j`, so dmap[j] ↔ palette[j].
@inlinable
public func buildDmap(_ palette: Palette, whiteLevel: Double, colorScalar: Double) -> [SIMD3<Double>] {
    var dmap = [SIMD3<Double>](repeating: .zero, count: 256)
    let scale = whiteLevel * colorScalar
    for j in 0..<256 {
        let c = palette.colors[j]
        dmap[j] = SIMD3<Double>(c.x * scale, c.y * scale, c.z * scale)
    }
    return dmap
}
