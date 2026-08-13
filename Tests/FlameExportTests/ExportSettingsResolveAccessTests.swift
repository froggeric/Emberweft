import XCTest
import FlameExport
import FlameKit

/// M6.5 I4: pin that `ExportSettings.resolve(...)` is public — `FlameFlock` (a sibling
/// module) calls it cross-module to build shard settings (T9).
///
/// It lives in a `public extension ExportSettings { … }` block (ExportSettings.swift:99),
/// so it is already effectively public. This test uses a PLAIN `import FlameExport`
/// (NOT `@testable`) so only `public` symbols are visible; if a future change moves
/// `resolve` out of the public extension (making it `internal`), this file fails to
/// COMPILE — the regression signal. (`@testable` would defeat the pin: it exposes
/// `internal` too, so the call would still compile.)
final class ExportSettingsResolveAccessTests: XCTestCase {
    func testResolveIsCallableWithFullSignature() {
        let flame = Flame(quality: Quality(temporalSamples: 1))
        // If this line compiles under a plain (non-@testable) import, `resolve` is
        // public. Behavior is pinned by ExportSettingsResolveTests; this is the
        // access-level pin only.
        let _ = ExportSettings.resolve(
            quality: .genome, temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p720, segmentFrameBudget: 0,
            baseFlame: flame, backend: .cpu)
        XCTAssertTrue(true)
    }
}
