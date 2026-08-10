import XCTest
import Metal
@testable import FlameRenderer
import FlameKit

/// Direct unit tests for `MetalHistogramDecode.decode`.
///
/// `MetalHistogramDecodeTests`'s test methods are PLAIN (non-isolated) — they
/// do NOT carry `@MainActor`. This is deliberate: it pins that
/// `MetalHistogramDecode.decode` (a nonisolated static func on a non-isolated
/// enum) is reachable from an off-main context under Swift 6 strict
/// concurrency — the exact requirement of the T6 off-main readback core. To
/// stay nonisolated end-to-end, device availability is probed via the C
/// `MTLCreateSystemDefaultDevice()` instead of the `@MainActor`
/// `MetalRenderer.isAvailable` getter.
final class MetalHistogramDecodeTests: XCTestCase {

    /// Builds a 2-bin synthetic atomic histogram, decodes it, and asserts the
    /// Double `Histogram` (counts exact; r/g/b/a divided by `colorScale`).
    func testDecodeRecoversDmapUnitsFromSyntheticBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let bins: [MetalHistogramDecode.AtomicBinHost] = [
            // colorScale = 255 → bin0 is full-red, full-alpha, 1 hit.
            MetalHistogramDecode.AtomicBinHost(count: 1, r: 255, g: 0,   b: 0,   a: 255),
            // bin1 is 2×green, 2×alpha, 2 hits (g=510 overflows one byte but the
            // atomic sum is a raw uint32, so decode recovers 510/255 = 2.0).
            MetalHistogramDecode.AtomicBinHost(count: 2, r: 0,   g: 510, b: 0,   a: 510),
        ]
        guard let buf = bins.withUnsafeBytes({ raw -> MTLBuffer? in
            device.makeBuffer(bytes: raw.baseAddress!,
                              length: raw.count,
                              options: .storageModeShared)
        }) else {
            throw XCTSkip("Metal buffer allocation failed")
        }

        let hist = MetalHistogramDecode.decode(histBuf: buf,
                                               binCount: bins.count,
                                               gridWidth: 2,
                                               gridHeight: 1,
                                               colorScale: 255.0)

        XCTAssertEqual(hist.gridWidth, 2)
        XCTAssertEqual(hist.gridHeight, 1)
        XCTAssertEqual(hist.counts.count, 2)

        // counts are exact (1 per hit).
        XCTAssertEqual(hist.counts[0], 1.0, accuracy: 1e-12)
        XCTAssertEqual(hist.counts[1], 2.0, accuracy: 1e-12)
        XCTAssertEqual(hist.sampleSum, 3.0, accuracy: 1e-12)

        // colors/alpha recovered by dividing the raw uint32 by colorScale.
        XCTAssertEqual(hist.colors[0].x, 1.0, accuracy: 1e-12)
        XCTAssertEqual(hist.colors[0].y, 0.0, accuracy: 1e-12)
        XCTAssertEqual(hist.colors[0].z, 0.0, accuracy: 1e-12)
        XCTAssertEqual(hist.colors[1].x, 0.0, accuracy: 1e-12)
        XCTAssertEqual(hist.colors[1].y, 2.0, accuracy: 1e-12)
        XCTAssertEqual(hist.colors[1].z, 0.0, accuracy: 1e-12)

        XCTAssertEqual(hist.alpha[0], 1.0, accuracy: 1e-12)
        XCTAssertEqual(hist.alpha[1], 2.0, accuracy: 1e-12)
    }

    /// A zeroed buffer decodes to an all-zero histogram (no NaN from 1/255; the
    /// scale is constant, not per-bin, so zeros stay zero).
    func testDecodeOfZeroedBufferIsAllZero() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let zeroBins = [MetalHistogramDecode.AtomicBinHost](repeating: .init(), count: 4)
        guard let buf = zeroBins.withUnsafeBytes({ raw -> MTLBuffer? in
            device.makeBuffer(bytes: raw.baseAddress!,
                              length: raw.count,
                              options: .storageModeShared)
        }) else {
            throw XCTSkip("Metal buffer allocation failed")
        }

        let hist = MetalHistogramDecode.decode(histBuf: buf,
                                               binCount: 4,
                                               gridWidth: 2,
                                               gridHeight: 2,
                                               colorScale: 255.0)

        XCTAssertEqual(hist.sampleSum, 0.0)
        XCTAssertTrue(hist.alpha.allSatisfy { $0 == 0.0 })
        XCTAssertTrue(hist.colors.allSatisfy { $0 == .zero })
    }
}
