import XCTest
import Foundation
import FlameKit
@testable import FlameExport

/// M6.1 slice 2 (T7): pins that `ExportSettings` carries the temporal-smoothing
/// decision (`temporalSmoothing`) + resolved α (`smoothingAlpha`), that `resolve`
/// computes α from the quality tier via `TemporalSmoothing.alpha(for:)` (R3), and
/// that a v0.5.1 checkpoint blob (no smoothing keys) decodes without crashing and
/// defaults to `.auto` (P1.1 backward-compat). `ExportSettings` rides in the
/// resume checkpoint via `settings`, so α reproduces on resume for free.
final class ExportSettingsSmoothingTests: XCTestCase {

    /// P1.1: a v0.5.1 checkpoint (no temporalSmoothing/smoothingAlpha keys) must
    /// decode without throwing and default to `.auto` (with the `.auto`-tier α
    /// recomputed from the decoded quality). We synthesize a v0.5.1-shaped blob by
    /// encoding a current `ExportSettings()` and stripping the two new keys —
    /// avoiding hand-writing the synthesized-Codable enum key shapes (S6).
    func testV051CheckpointStrippedOfNewKeysDecodesToAuto() throws {
        let encoded = try JSONEncoder().encode(ExportSettings())
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        json.removeValue(forKey: "temporalSmoothing")
        json.removeValue(forKey: "smoothingAlpha")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let s = try JSONDecoder().decode(ExportSettings.self, from: stripped)
        XCTAssertEqual(s.temporalSmoothing, .auto)
        // Default quality == .genome ⇒ .auto-tier α == 1.0 (OFF) regardless.
        XCTAssertEqual(s.smoothingAlpha, 1.0, accuracy: 1e-9)
    }

    /// R3: `resolve()` computes `smoothingAlpha` for arbitrary spp (flat α=0.2).
    /// spp 8 ⇒ α == 0.20 exactly.
    func testResolveComputesAlphaForSpp() {
        let f = Flame()   // genome default temporalSamples == 1
        let s = ExportSettings.resolve(
            quality: .spp(8), temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: f, backend: .cpu, temporalSmoothing: .auto)
        XCTAssertEqual(s.smoothingAlpha, 0.20, accuracy: 1e-9)
        XCTAssertEqual(s.temporalSmoothing, .auto)
    }

    /// `.off` and `.genome` both resolve to α == 1.0 (OFF). `.off` forces OFF
    /// regardless of quality; `.genome` quality is OFF under `.auto` too.
    func testResolveOffAndGenomeAreIdentity() {
        let f = Flame()
        let off = ExportSettings.resolve(
            quality: .spp(8), temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: f, backend: .cpu, temporalSmoothing: .off)
        XCTAssertEqual(off.smoothingAlpha, 1.0)
        let genome = ExportSettings.resolve(
            quality: .genome, temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: f, backend: .cpu, temporalSmoothing: .auto)
        XCTAssertEqual(genome.smoothingAlpha, 1.0)
    }

    /// Default param (S12): existing call sites omit `temporalSmoothing` ⇒ `.auto`.
    /// spp 30 ⇒ flat α == 0.20 (RETUNED 2026-08-11; was the 0.35 ramp anchor).
    func testResolveDefaultTemporalSmoothingIsAuto() {
        let f = Flame()
        let s = ExportSettings.resolve(
            quality: .spp(30), temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: f, backend: .cpu)   // no temporalSmoothing arg
        XCTAssertEqual(s.temporalSmoothing, .auto)
        XCTAssertEqual(s.smoothingAlpha, 0.20, accuracy: 1e-9)   // spp 30 ⇒ flat α
    }

    /// Round-trip: encode → decode preserves both fields (S6: don't trust
    /// hand-written Codable — pin the round-trip explicitly).
    func testRoundTripPreservesSmoothingFields() throws {
        let f = Flame()
        let original = ExportSettings.resolve(
            quality: .spp(8), temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: f, backend: .cpu, temporalSmoothing: .off)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: data)
        XCTAssertEqual(decoded.temporalSmoothing, .off)
        XCTAssertEqual(decoded.smoothingAlpha, original.smoothingAlpha, accuracy: 1e-12)
    }
}
