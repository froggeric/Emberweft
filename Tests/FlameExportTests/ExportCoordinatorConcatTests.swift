import XCTest
import AVFoundation
import CoreMedia
@testable import FlameExport
import FlameKit

final class ExportCoordinatorConcatTests: XCTestCase {
    /// `concat(segments:container:to:)` is a passthrough wrapper around the private
    /// `concatChunks`: it concatenates already-encoded same-codec segments (in array
    /// order) without re-encoding, then atomically renames the partial to `out`.
    ///
    /// This pin builds TWO independently-encoded HEVC `.mov` segments — each via its
    /// own `renderSegmentRange` call (which builds its own `VideoEncoder` session,
    /// mirroring the archive's per-segment encode pattern that the spec §Codec
    /// evaluation proved is decode-clean under passthrough concat) — then concats
    /// them and asserts the output duration is the SUM of the input durations and
    /// the HEVC track is preserved (no re-encode).
    func testConcatIsPassthroughAndOrdered() async throws {
        let coord = ExportCoordinator(backend: .cpu, useOffMainMetal: false)
        let flame = Flame(quality: Quality(samplesPerPixel: 4, temporalSamples: 1))
        let settings = ExportSettings.resolve(
            quality: .spp(4), temporalSamples: 1, codec: .hevc, container: .mov,
            fps: 30, bitrate: .auto, resolution: .p720, segmentFrameBudget: 0,
            baseFlame: flame, backend: .cpu)
        let params = RenderParams(seed: 42, width: 1280, height: 720, oversample: 1,
                                  samplesPerPixel: 4)

        // 1-segment loop plan; render range 0..<8 (8 frames @ 30 fps = 8/30 s).
        var sched = Schedule(librarySize: 1, framesPerSegment: 8,
                             selector: Sequential(seed: 42), seed: 42)
        let plan = FramePlan(schedule: &sched, segmentCount: 1, flames: [flame])

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let segA = tmp.appendingPathComponent("concatA-\(UUID().uuidString).mov")
        let segB = tmp.appendingPathComponent("concatB-\(UUID().uuidString).mov")
        // Two INDEPENDENT encode sessions (renderSegmentRange builds its own
        // VideoEncoder per call) — mirrors the archive's per-segment pattern, which
        // the spec §Codec evaluation proved is decode-clean under passthrough concat.
        try await coord.renderSegmentRange(
            plan: plan, params: params, budget: nil, useMetal: false,
            range: 0..<8, smoothingAlpha: 1.0, settings: settings, out: segA)
        try await coord.renderSegmentRange(
            plan: plan, params: params, budget: nil, useMetal: false,
            range: 0..<8, smoothingAlpha: 1.0, settings: settings, out: segB)

        let out = tmp.appendingPathComponent("concatOut-\(UUID().uuidString).mov")
        try await coord.concat(segments: [segA, segB], container: .mov, to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        let asset = AVURLAsset(url: out)
        let dur = try await asset.load(.duration)
        // Two 8-frame @ 30 fps segments ⇒ 16/30 s total.
        XCTAssertEqual(CMTimeGetSeconds(dur), 16.0 / 30.0, accuracy: 0.02)
        // loadTracks(withMediaType:) carries a deprecation warning on macOS 26 but
        // reliably returns real AVAssetTrack values (the load(.tracks) shorthand
        // lands in AVAsyncProperty-wrapped element territory on this SDK).
        // Warning-only — acceptable per the task's deprecation note.
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            XCTFail("concat output must have a video track"); return
        }
        // AVAssetTrack has no `codecTypes` (that's on AVAssetVariant, and Swift-
        // private). The SDK-endorsed modern read is load(.formatDescriptions)
        // (per the AVAssetTrack.formatDescriptions deprecation message) → read the
        // media subtype FourCharCode. kCMVideoCodecType_HEVC == 'hvc1'. Passthrough
        // concat preserves the codec, so the subtype must remain HEVC.
        let formats = try await videoTrack.load(.formatDescriptions)
        guard let fmt = formats.first else {
            XCTFail("video track must expose a format description"); return
        }
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fmt),
                       kCMVideoCodecType_HEVC,
                       "HEVC track preserved through passthrough concat")

        [segA, segB, out].forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
