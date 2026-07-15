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
    public var gridWidth: Int { width * oversample }
    public var gridHeight: Int { height * oversample }
    public var totalSamples: Int { width * height * samplesPerPixel }
}

public struct Histogram: Equatable {
    public var counts: [Float]            // gridWidth*gridHeight
    public var colors: [SIMD3<Float>]     // accumulated palette RGB per bin
    public let gridWidth: Int
    public let gridHeight: Int
    public var totalSamples: Float { counts.reduce(0, +) }
    public init(gridWidth: Int, gridHeight: Int) {
        self.gridWidth = gridWidth; self.gridHeight = gridHeight
        counts = Array(repeating: 0, count: gridWidth * gridHeight)
        colors = Array(repeating: .zero, count: gridWidth * gridHeight)
    }
    public subscript(x: Int, y: Int) -> Int { x + y * gridWidth }
}
