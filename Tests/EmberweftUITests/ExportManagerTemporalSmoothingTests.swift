import XCTest
@testable import EmberweftUI
import FlameExport
import FlameKit
import FlameRenderer

/// M6.1 slice 2 / Task 10 — pins the `ExportManager.temporalSmoothing` field
/// threads through `resolveSettings` → `ExportSettings.resolve`. The GUI sheet
/// (EmberweftGUI) has no test target, so the testable wiring lives here on the
/// VM (EmberweftUI): the sheet binds the field two-way; `resolveSettings` is the
/// single funnel that reads it and passes it into `ExportSettings.resolve`.
///
/// `.medium` (spp 30) + `.auto` ⇒ α = 0.20 (flat α for any .spp tier);
/// `.off` ⇒ α = 1.0 (forced OFF, byte-identical to the unsmoothed path).
@MainActor
final class ExportManagerTemporalSmoothingTests: XCTestCase {

    /// A non-degenerate flame (matches the `renderableFlame()` fixture in the
    /// sibling ExportManager tests). `resolveSettings` reads only
    /// `baseFlame.quality.temporalSamples` (the motion-blur fallback), but a
    /// realistic flame keeps this resilient.
    private func renderableFlame() -> Flame {
        Flame(
            camera: Camera(center: .zero, scale: 250, zoom: 0, rotation: 0),
            quality: Quality(oversample: 1, samplesPerPixel: 50),
            xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])]
        )
    }

    func testResolveSettingsThreadsTemporalSmoothingAuto() {
        let em = ExportManager()
        em.qualityChoice = .medium
        em.temporalSmoothing = .auto
        let s = em.resolveSettings(baseFlame: renderableFlame(), backend: .cpu)
        XCTAssertEqual(s.temporalSmoothing, .auto)
        // .medium ⇒ .spp(30); flat α = 0.20 for any .spp tier.
        XCTAssertEqual(s.smoothingAlpha, 0.20, accuracy: 1e-9)
    }

    func testResolveSettingsOffForcesAlphaOne() {
        let em = ExportManager()
        em.qualityChoice = .medium
        em.temporalSmoothing = .off
        let s = em.resolveSettings(baseFlame: renderableFlame(), backend: .cpu)
        XCTAssertEqual(s.temporalSmoothing, .off)
        XCTAssertEqual(s.smoothingAlpha, 1.0)
    }

    /// Genome-default quality ⇒ smoothing is a no-op (α = 1.0 regardless of the
    /// toggle), mirroring `TemporalSmoothing.alpha(for: .genome) == 1.0`. This is
    /// why the sheet disables the toggle at `.genomeDefault`.
    func testResolveSettingsGenomeDefaultIsNoOp() {
        let em = ExportManager()
        em.qualityChoice = .genomeDefault
        em.temporalSmoothing = .auto
        let s = em.resolveSettings(baseFlame: renderableFlame(), backend: .cpu)
        XCTAssertEqual(s.smoothingAlpha, 1.0)
        // The choice still threads through (so the checkpoint records `.auto`),
        // even though α collapses to 1.0 at genome quality.
        XCTAssertEqual(s.temporalSmoothing, .auto)
    }

    /// Default field value is `.auto` (matches the other `@Observable` config
    /// fields and the `ExportSettings.resolve` default).
    func testTemporalSmoothingDefaultsToAuto() {
        let em = ExportManager()
        XCTAssertEqual(em.temporalSmoothing, .auto)
    }
}
