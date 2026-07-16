import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

/// Task 12 — Performance baseline harness (regression guard, non-gating).
///
/// Records single-frame render time for both backends at 720p and 1080p, plus
/// the Metal:CPU speedup. Runs ONLY when `EMBERWEFT_PERF=1` is set (SKIPs
/// otherwise, so it never slows the normal test gate). The only assertion is a
/// lenient sanity floor: Metal must be no slower than CPU at 1080p. The
/// recorded numbers feed CHANGELOG.md (Task 13).
final class PerformanceBaselineTests: XCTestCase {
    private func genomesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes")
    }

    private func time(_ ms: () -> Void) -> TimeInterval {
        let t = Date(); ms(); return Date().timeIntervalSince(t)
    }

    @MainActor func testSingleFrameBaseline() throws {
        guard ProcessInfo.processInfo.environment["EMBERWEFT_PERF"] == "1" else {
            throw XCTSkip("set EMBERWEFT_PERF=1 to run the perf baseline")
        }
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let dir = genomesDir()
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "flam3" } ?? []
        XCTAssertFalse(urls.isEmpty, "no frozen genomes found in \(dir.path)")
        for u in urls {
            let flame = try Flam3Parser.parse(Data(contentsOf: u))[0]
            for (w, h) in [(1280, 720), (1920, 1080)] {
                let p = RenderParams(seed: 0, width: w, height: h, oversample: 1, samplesPerPixel: 100)
                let cpu = time { _ = ReferenceRenderer.render(flame: flame, params: p) }
                let gpu = time { _ = MetalRenderer.render(flame: flame, params: p) }
                let speedup = cpu / max(gpu, 0.001)
                print("[Perf] \(u.lastPathComponent) \(w)×\(h): cpu=\(String(format: "%.2f", cpu))s  metal=\(String(format: "%.2f", gpu))s  speedup=\(String(format: "%.2f", speedup))×")
                if w == 1920 {
                    XCTAssertGreaterThan(speedup, 1.0, "Metal slower than CPU at 1080p on \(u.lastPathComponent)")
                }
            }
        }
    }
}
