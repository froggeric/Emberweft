import XCTest
@testable import EmberweftUI
import FlameKit
import FlameRenderer

@MainActor
final class MetalFrameRendererSmokeTests: XCTestCase {

    private func realGenome(_ name: String) -> Flame? {
        let candidates = [
            FileManager.default.currentDirectoryPath + "/Tests/Goldens/genomes_real/\(name)",
            FileManager.default.currentDirectoryPath + "/Tests/Goldens/genomes/\(name)",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let flame = try? Flam3Parser.parse(data).first
        else { return nil }
        return flame
    }

    /// Renders a known-good genome on Metal and asserts a non-empty (non-all-
    /// black) frame. Skips when Metal is unavailable (headless sandbox / no GPU).
    func testRenderProducesNonEmptyFrame() async throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }

        let flame = Flame(
            camera: Camera(center: .zero, scale: 200),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])
        let params = RenderParams(seed: 1, width: 64, height: 64, oversample: 1, samplesPerPixel: 8)

        let image = await MetalFrameRenderer().render(flame: flame, params: params)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
        XCTAssertGreaterThan(image.pixels.max() ?? 0, 0, "render must be non-empty / non-all-black")
    }

    /// The off-main (thumbnail) render path produces the same non-empty frame,
    /// without touching the MainActor. Gated on Metal availability.
    func testRenderOffMainProducesNonEmptyFrame() async throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }

        let flame = Flame(
            camera: Camera(center: .zero, scale: 200),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])
        let params = RenderParams(seed: 1, width: 64, height: 64, oversample: 1, samplesPerPixel: 8)

        let image = MetalRenderer.renderOffMain(flame: flame, params: params)
        XCTAssertNotNil(image, "off-main render should succeed when Metal is available")
        XCTAssertEqual(image?.width, 64)
        XCTAssertGreaterThan(image?.pixels.max() ?? 0, 0, "off-main render must be non-empty")
    }

    /// The off-main path must be byte-identical to the MainActor path — the
    /// refactor only changed WHICH thread encodes + waits, not the GPU work.
    func testRenderOffMainMatchesMainActorPath() async throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }

        let flame = Flame(
            camera: Camera(center: .zero, scale: 200),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])
        let params = RenderParams(seed: 1, width: 64, height: 64, oversample: 1, samplesPerPixel: 8)

        let mainImg = await MetalFrameRenderer().render(flame: flame, params: params)
        let offImg = MetalRenderer.renderOffMain(flame: flame, params: params)
        XCTAssertEqual(offImg, mainImg,
                       "off-main render must be byte-identical to the MainActor path")
    }

    /// The off-main path must also match the MainActor path on a REAL (multi-xform,
    /// final-xform, explicit-palette) ES genome — ruling out an off-main bug that
    /// could produce false "degenerate" (all-black) thumbnails.
    func testRenderOffMainMatchesMainActorPathOnRealGenome() async throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        guard let flame = realGenome("electricsheep.244.00081.flam3") else {
            throw XCTSkip("real genome fixture not found")
        }
        // GUI thumbnail params: 720p, spp 8.
        let params = RenderParams(seed: 1, width: 1280, height: 720, oversample: 1, samplesPerPixel: 8)
        let mainImg = await MetalFrameRenderer().render(flame: flame, params: params)
        let offImg = MetalRenderer.renderOffMain(flame: flame, params: params)
        XCTAssertEqual(offImg, mainImg,
                       "off-main must be byte-identical on a real (complex) genome")
        XCTAssertGreaterThan(mainImg.pixels.max() ?? 0, 0, "real genome must render non-empty")
    }
}
