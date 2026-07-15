import Foundation
import FlameKit

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
}

public struct Histogram: Equatable, Sendable {
    public var counts: [Double]            // gridWidth*gridHeight — hit count (bucket[4]/255)
    public var colors: [SIMD3<Double>]     // accumulated dmap RGB, PRE-SCALLED by WHITE_LEVEL (bucket[0..2])
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
}
