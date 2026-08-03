import XCTest
@testable import FlameRenderer
import FlameKit

/// Parity pins for the off-main temporal Metal path (M6-G.1).
///
/// `renderTemporalOffMain` is the temporal twin of `renderOffMain`: it runs the
/// SAME `renderTemporalFusedCore` (extracted verbatim from `renderTemporalFused`)
/// on `offMainQueue` instead of the MainActor. The GPU computation is
/// thread-independent (already pinned by `MetalFrameRendererSmokeTests` for the
/// single-pass path), so the temporal core inherits byte-identity by construction.
/// These three tests pin that invariant for the motion-blur (temporal) path:
///   1. ts>1 frozen fixture (sierpinski_ts4) — off-main == MainActor, byte-exact.
///   2. ts>1 real gen-248 genome — same invariant on a complex multi-xform flame.
///   3. non-box temporal — off-main returns nil (does NOT trap).
@MainActor
final class OffMainTemporalParityTests: XCTestCase {

    /// `#filePath`-relative loader for frozen goldens in `Tests/Goldens/genomes/`
    /// (copy of `TemporalBlurMetalTests.loadFrozen`).
    private func loadFrozen(_ name: String) throws -> Flame {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name).flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture missing: \(url.path)")
        }
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }

    /// `#filePath`-relative loader for the ts4 fixture (lives in `fixtures/`,
    /// NOT `genomes/` — the exact-6 golden-set guard, CLAUDE.md).
    private func loadTS4() throws -> Flame {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/fixtures/sierpinski_ts4.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture missing: \(url.path)")
        }
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }

    /// CWD-relative real gen-248 loader (the big archive lives at repo root;
    /// sample `sheep/gen-248/` directly, NOT `-path '*248*'` — CLAUDE.md).
    private func loadRealGen248(_ id: String) throws -> Flame {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("genomes/electric-sheep/sheep/gen-248/\(id).flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture missing: \(url.path)")
        }
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }

    /// ts>1 frozen fixture: pixels of `renderTemporalOffMain` must equal the
    /// `@MainActor` path (`MetalRenderer.render(blendAt:…)` → `renderTemporalFused`
    /// → `renderTemporalFusedCore`). Same device + seedBudget (nil).
    func testRenderTemporalOffMainMatchesMainActorPath() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try loadTS4()
        let (temporal, sumfilt) = TemporalFilter.samples(4, type: .box, width: 1.0, exp: 0)
        let params = RenderParams(seed: 1, width: 200, height: 150,
                                  oversample: 1, samplesPerPixel: 200)
        let mainActorImg = MetalRenderer.render(
            blendAt: { _ in flame }, centerTime: 0.5, temporal: temporal,
            sumfilt: sumfilt, params: params, seedBudget: nil)
        let offMainImg = try XCTUnwrap(MetalRenderer.renderTemporalOffMain(
            blendAt: { _ in flame }, centerTime: 0.5, temporal: temporal,
            sumfilt: sumfilt, params: params, seedBudget: nil),
            "off-main temporal must succeed (Metal available, box temporal)")
        XCTAssertEqual(mainActorImg.pixels, offMainImg.pixels,
            "renderTemporalOffMain must be byte-identical to the @MainActor temporal path")
    }

    /// Same invariant on a real (multi-xform, explicit-palette) gen-248 genome
    /// at ts>1 — rules out an off-main bug that only manifests on complex flames.
    /// XCTSkip if the gen-248 archive is absent.
    func testRenderTemporalOffMainMatchesMainActorPathOnRealGenome() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try loadRealGen248("electricsheep.248.05739")
        let (temporal, sumfilt) = TemporalFilter.samples(8, type: .box, width: 1.2, exp: 0)
        let params = RenderParams(seed: 1, width: 200, height: 150,
                                  oversample: 1, samplesPerPixel: 300)
        let a = MetalRenderer.render(blendAt: { _ in flame }, centerTime: 0.5,
            temporal: temporal, sumfilt: sumfilt, params: params)
        let b = try XCTUnwrap(MetalRenderer.renderTemporalOffMain(
            blendAt: { _ in flame }, centerTime: 0.5, temporal: temporal,
            sumfilt: sumfilt, params: params))
        XCTAssertEqual(a.pixels, b.pixels,
            "off-main temporal must be byte-identical on a real (complex) genome")
    }

    /// Non-box temporal (a sub-sample with weight != 1.0) must return nil
    /// off-main — NOT trap. The `@MainActor` public entry `render(blendAt:…)`
    /// fatalErrors on non-box; the off-main twin returns nil instead (a
    /// background-thread fatalError is undesirable; nil ⇒ coordinator throws
    /// `.metalUnavailable`).
    func testRenderTemporalOffMainReturnsNilOnNonBox() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try loadFrozen("sierpinski")
        // gaussian N>1 produces sub-sample weights < 1.0 → trips the box guard.
        let nonBox = TemporalFilter.samples(4, type: .gaussian, width: 1.0, exp: 0)
        let tiny = RenderParams(seed: 1, width: 16, height: 16,
                                oversample: 1, samplesPerPixel: 4)
        let res = MetalRenderer.renderTemporalOffMain(
            blendAt: { _ in flame }, centerTime: 0, temporal: nonBox.0,
            sumfilt: nonBox.1, params: tiny)
        XCTAssertNil(res, "non-box temporal must return nil off-main, not trap")
    }
}
