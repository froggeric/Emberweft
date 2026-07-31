import XCTest
@testable import EmberweftUI
import FlameKit
import FlameReference

final class ThumbnailServiceTests: XCTestCase {

    // MARK: - Cache key determinism (rule #2)

    func testCacheKeyDeterministicForSameInputs() {
        let a = ThumbnailService.cacheKey(id: "244_00788",
                                          renderW: 1280, renderH: 720,
                                          displayW: 256, displayH: 144,
                                          spp: 8, backend: "metal", seed: 1)
        let b = ThumbnailService.cacheKey(id: "244_00788",
                                          renderW: 1280, renderH: 720,
                                          displayW: 256, displayH: 144,
                                          spp: 8, backend: "metal", seed: 1)
        XCTAssertEqual(a, b)
    }

    func testCacheKeyVariesWithEveryComponent() {
        let base = ThumbnailService.cacheKey(id: "x", renderW: 1280, renderH: 720,
                                             displayW: 256, displayH: 144,
                                             spp: 8, backend: "metal", seed: 1)
        XCTAssertNotEqual(base, ThumbnailService.cacheKey(id: "y", renderW: 1280, renderH: 720, displayW: 256, displayH: 144, spp: 8, backend: "metal", seed: 1))
        XCTAssertNotEqual(base, ThumbnailService.cacheKey(id: "x", renderW: 640, renderH: 720, displayW: 256, displayH: 144, spp: 8, backend: "metal", seed: 1))
        XCTAssertNotEqual(base, ThumbnailService.cacheKey(id: "x", renderW: 1280, renderH: 360, displayW: 256, displayH: 144, spp: 8, backend: "metal", seed: 1))
        XCTAssertNotEqual(base, ThumbnailService.cacheKey(id: "x", renderW: 1280, renderH: 720, displayW: 128, displayH: 144, spp: 8, backend: "metal", seed: 1))
        XCTAssertNotEqual(base, ThumbnailService.cacheKey(id: "x", renderW: 1280, renderH: 720, displayW: 256, displayH: 72, spp: 8, backend: "metal", seed: 1))
        XCTAssertNotEqual(base, ThumbnailService.cacheKey(id: "x", renderW: 1280, renderH: 720, displayW: 256, displayH: 144, spp: 4, backend: "metal", seed: 1))
        XCTAssertNotEqual(base, ThumbnailService.cacheKey(id: "x", renderW: 1280, renderH: 720, displayW: 256, displayH: 144, spp: 8, backend: "cpu", seed: 1))
        XCTAssertNotEqual(base, ThumbnailService.cacheKey(id: "x", renderW: 1280, renderH: 720, displayW: 256, displayH: 144, spp: 8, backend: "metal", seed: 2))
    }

    func testCacheKeySafeAsFilename() {
        let key = ThumbnailService.cacheKey(id: "sub/deep/path",
                                            renderW: 1280, renderH: 720,
                                            displayW: 256, displayH: 144,
                                            spp: 8, backend: "metal", seed: 1)
        XCTAssertFalse(key.contains("/"))
    }

    // MARK: - Orientation (thumbnail vs playback must match)

    /// `scaled()` must preserve orientation: a bright top / dark bottom image
    /// downscaled must keep bright at the top. (A flipped downscale would put
    /// the bright band at the bottom — the thumbnail-vs-playback mismatch.)
    func testScaledPreservesTopBottomOrientation() {
        let w = 8, h = 8
        let bright = [UInt8](repeating: 255, count: w * 4)   // white opaque row
        let dark = [UInt8](repeating: 0, count: w * 4)       // black row
        var pixels = [UInt8]()
        for _ in 0..<(h / 2) { pixels.append(contentsOf: bright) }   // top half
        for _ in 0..<(h / 2) { pixels.append(contentsOf: dark) }     // bottom half
        let img = RGBA8Image(width: w, height: h, pixels: pixels)

        guard let scaled = img.scaled(toWidth: 4, toHeight: 4) else {
            return XCTFail("scaled returned nil")
        }
        let bpp = 4
        let topRow = Array(scaled.pixels[0..<(4 * bpp)])
        let bottomRow = Array(scaled.pixels[(3 * 4 * bpp)..<(4 * 4 * bpp)])
        XCTAssertGreaterThan(topRow.max() ?? 0, 0, "top half must stay bright (orientation preserved)")
        XCTAssertEqual(bottomRow.max() ?? 1, 0, "bottom half must stay dark (orientation preserved)")
    }

    // MARK: - Degenerate short-circuit (no Metal needed)

    /// A NaN-camera genome is reported degenerate WITHOUT rendering — the cheap
    /// `isRenderable` gate fires first. Uses CPU backend so no GPU is required.
    func testDegenerateGenomeShortCircuits() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emberweft-thumb-\(UUID().uuidString)")
        let svc = ThumbnailService(cacheDirectory: dir)
        let entry = LibraryEntry(id: "nan", source: .bundle,
                                 fileURL: URL(fileURLWithPath: "/dev/null"),
                                 displayName: "nan", rank: nil)
        let nanFlame = Flame(
            camera: Camera(center: SIMD2<Double>(.nan, 0), scale: 250),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])
        let outcome = await svc.thumbnail(
            for: entry, flame: nanFlame,
            renderParams: RenderParams(seed: 1, width: 64, height: 36, oversample: 1, samplesPerPixel: 2),
            displayWidth: 32, displayHeight: 18,
            backend: .cpu)
        if case .degenerate = outcome { /* ok */ } else {
            XCTFail("expected .degenerate, got \(outcome)")
        }
        // No cache file written for a degenerate genome.
        let key = ThumbnailService.cacheKey(id: "nan",
                                            renderW: 64, renderH: 36,
                                            displayW: 32, displayH: 18,
                                            spp: 2, backend: "cpu", seed: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(key).png").path))
    }
}
