import XCTest
import AVFoundation
@testable import FlameExport
import FlameKit

final class RenderSegmentRangeTests: XCTestCase {
    /// renderSegmentRange routes through the SAME renderFrames primitive as runJob;
    /// the byte-identity guarantee is architectural (same code path). The OBSERVABLE
    /// pin is the test-seam frame counts: appendedFrameCount == range.count, and
    /// renderCallCount == range.count (CPU, ts=1, smoothing OFF ⇒ renderImage per frame).
    /// Decoded video frames are NOT byte-comparable (all codecs lossy on round-trip).
    func testSegmentRangeRendersSameFrameCountAsExportPath() async throws {
        let flame = Flame(quality: Quality(samplesPerPixel: 4, temporalSamples: 1))
        let settings = ExportSettings.resolve(
            quality: .spp(4), temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p720, segmentFrameBudget: 0,
            baseFlame: flame, backend: .cpu)
        let params = RenderParams(seed: 42, width: 1280, height: 720, oversample: 1,
                                  samplesPerPixel: 4)

        // 1-segment loop plan (segment 0 is loop(flame)).
        var sched = Schedule(librarySize: 1, framesPerSegment: 8,
                             selector: Sequential(seed: 42), seed: 42)
        let plan = FramePlan(schedule: &sched, segmentCount: 1, flames: [flame])

        let coord = ExportCoordinator(backend: .cpu, useOffMainMetal: false)
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("segRange-\(UUID().uuidString).mp4")
        try await coord.renderSegmentRange(
            plan: plan, params: params, budget: nil, useMetal: false,
            range: 0..<8, smoothingAlpha: 1.0, settings: settings, out: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        // The test seams (internal private(set), visible via @testable) prove the
        // range was driven through the same per-frame path the export uses. Read
        // into locals first — actor-isolated properties can't be referenced from
        // XCTAssertEqual's nonisolated autoclosure.
        let appended = await coord.appendedFrameCount
        let rendered = await coord.renderCallCount
        XCTAssertEqual(appended, 8, "must append exactly range.count frames")
        XCTAssertEqual(rendered, 8, "must render exactly range.count frames (CPU OFF path)")
        try? FileManager.default.removeItem(at: out)
    }

    /// v0.5.11 cancel-path cleanup pin: a pre-cancelled coordinator throws
    /// `ExportError.cancelled` at the FIRST per-frame guard (before any render
    /// or append), and the throw path tears down the encoder session and
    /// removes the `.<out>.partial` temp beside `out` — no dangling
    /// AVAssetWriter, no temp remnant (the same contract `runJob`'s catch
    /// already honored; `renderSegmentRange` used to skip it).
    func testSegmentRangeCancelThrowsAndRemovesPartial() async throws {
        let flame = Flame(quality: Quality(samplesPerPixel: 4, temporalSamples: 1))
        let settings = ExportSettings.resolve(
            quality: .spp(4), temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p720, segmentFrameBudget: 0,
            baseFlame: flame, backend: .cpu)
        let params = RenderParams(seed: 42, width: 1280, height: 720, oversample: 1,
                                  samplesPerPixel: 4)
        var sched = Schedule(librarySize: 1, framesPerSegment: 8,
                             selector: Sequential(seed: 42), seed: 42)
        let plan = FramePlan(schedule: &sched, segmentCount: 1, flames: [flame])

        let coord = ExportCoordinator(backend: .cpu, useOffMainMetal: false)
        await coord.cancel()   // pre-set: the first per-frame guard fires
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("segCancel-\(UUID().uuidString).mp4")
        let partial = out.deletingLastPathComponent()
            .appendingPathComponent("." + out.lastPathComponent + ".partial")
        do {
            try await coord.renderSegmentRange(
                plan: plan, params: params, budget: nil, useMetal: false,
                range: 0..<8, smoothingAlpha: 1.0, settings: settings, out: out)
            XCTFail("a pre-cancelled renderSegmentRange must throw")
        } catch {
            XCTAssertEqual(error as? ExportError, .cancelled,
                           "expected ExportError.cancelled, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path),
                       "the throw path must remove the .partial temp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "no file may land at out on cancel")
        let appended = await coord.appendedFrameCount
        XCTAssertEqual(appended, 0, "cancel must fire before the first append")
    }
}
