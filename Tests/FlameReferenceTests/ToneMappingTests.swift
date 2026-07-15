import XCTest
@testable import FlameReference
import FlameKit

final class ToneMappingTests: XCTestCase {
    func testAllZeroIsBlack() {
        let h = Histogram(gridWidth: 4, gridHeight: 4)
        let img = ToneMapping.render(histogram: h, width: 4, height: 4, oversample: 1,
                                     gamma: 2.2, gammaThreshold: 0.01, vibrancy: 1,
                                     sampleDensity: 100, pixelsPerUnit: 100)
        // all-zero histogram -> opaque black background (RGB 0, alpha 255), matching flam3.
        let black = stride(from: 0, to: img.pixels.count, by: 4).allSatisfy {
            img.pixels[$0] == 0 && img.pixels[$0 + 1] == 0 && img.pixels[$0 + 2] == 0
        }
        let opaque = stride(from: 3, to: img.pixels.count, by: 4).allSatisfy { img.pixels[$0] == 255 }
        XCTAssertTrue(black && opaque)
    }
    func testHotWhiteBinBright() {
        var h = Histogram(gridWidth: 4, gridHeight: 4)
        // colors accumulate per-hit (see ChaosGame); avg color = colors/counts, so use 100 to get white avg
        for i in 0..<h.counts.count { h.counts[i] = 100; h.colors[i] = SIMD3(100, 100, 100) }
        let img = ToneMapping.render(histogram: h, width: 4, height: 4, oversample: 1,
                                     gamma: 2.2, gammaThreshold: 0.01, vibrancy: 1,
                                     sampleDensity: 100, pixelsPerUnit: 100)
        XCTAssertGreaterThan(img.pixels[0], 200)
    }
    func testOutputSize() {
        let h = Histogram(gridWidth: 8, gridHeight: 8)
        let img = ToneMapping.render(histogram: h, width: 4, height: 4, oversample: 2,
                                     gamma: 2.2, gammaThreshold: 0.01, vibrancy: 1,
                                     sampleDensity: 100, pixelsPerUnit: 100)
        XCTAssertEqual(img.width, 4); XCTAssertEqual(img.height, 4)
    }
}
