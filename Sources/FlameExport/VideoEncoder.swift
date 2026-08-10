import Foundation
import AVFoundation
import VideoToolbox      // kVTProfileLevel_HEVC_Main10_AutoLevel (HEVC profile)
import CoreVideo
import CoreMedia
import FlameKit

/// AVAssetWriter + Input + PixelBufferAdaptor wrapper. Single serialization queue
/// for status transitions (cancel-safe). Guards `isReadyForMoreMediaData` and
/// appends at exact CFR `CMTime(value: frameIndex, timescale: fps)`.
public final class VideoEncoder: @unchecked Sendable {
    public let settings: ExportSettings
    public let outputURL: URL
    private let queue = DispatchQueue(label: "com.emberweft.export.encoder")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pool: PixelBufferPool?
    private var started = false
    /// Highest PTS appended so far (start-of-session = .zero). Tracked so
    /// `finish()` can call `endSession(atSourceTime:)` with the final frame's
    /// end time (last PTS + one frame duration), pinning the last frame's full
    /// duration in the container. `AVAssetWriterInput` otherwise leaves the
    /// trailing duration implicit (spec D8 / §4.4).
    private var lastEndTime: CMTime = .zero

    public init(settings: ExportSettings, outputURL: URL) throws {
        self.settings = settings
        self.outputURL = outputURL
    }

    public func start() throws {
        precondition(!started)
        // ProRes requires a `.mov` container — AVAssetWriter rejects ProRes in
        // `.mp4` (the writer fails at startWriting/first append). Fail fast with
        // a descriptive error so the caller can surface "pick .mov" rather than
        // a deep AVFoundation failure.
        if settings.codec.requiresMOVContainer && settings.container != .mov {
            throw ExportError.proResRequiresMOV
        }
        let fileType: AVFileType = settings.container == .mov ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let codecType: AVVideoCodecType = Self.avCodecType(for: settings.codec)
        var compression: [String: Any] = [:]
        switch settings.codec {
        case .proRes422HQ:
            // ProRes variant is selected ENTIRELY via AVVideoCodecType
            // (.proRes422HQ, underlying "apch"); AVVideoProfileLevelKey does NOT
            // apply to ProRes (Apple's ProRes codecs have no profile/level
            // dimension — the codec type IS the variant). Do NOT set
            // AVVideoAverageBitRateKey: ProRes is a fixed data-rate codec and
            // supplying a bit rate can confuse encoder revisions; the codec's
            // own ~220 Mbps @ 1080p25 is the target.
            break
        case .h264, .hevc:
            // High/Main10 profile (8×8 / 10-bit) for fine fractal-flame detail.
            // AutoLevel lets the encoder pick the level from the resolution.
            compression[AVVideoProfileLevelKey] = settings.codec == .h264
                ? AVVideoProfileLevelH264HighAutoLevel
                : kVTProfileLevel_HEVC_Main10_AutoLevel
            switch settings.bitrate {
            case .auto:
                compression[AVVideoAverageBitRateKey] =
                    Self.autoBitrate(codec: settings.codec, res: settings.resolution, fps: settings.fps)
            case .mbps(let m):
                compression[AVVideoAverageBitRateKey] = m * 1_000_000
            }
            // 1-sec GOP (keyframe every `fps` frames AND every 1.0 s) for clean
            // seeking + the expected-source-fps hint. Do NOT set
            // AVVideoQualityKey (it conflicts with an explicit average bit rate).
            compression[AVVideoMaxKeyFrameIntervalKey] = settings.fps
            compression[AVVideoMaxKeyFrameIntervalDurationKey] = 1.0
            compression[AVVideoExpectedSourceFrameRateKey] = settings.fps
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: settings.resolution.width,
            AVVideoHeightKey: settings.resolution.height,
            AVVideoCompressionPropertiesKey: compression
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
        writer.add(input)
        self.writer = writer; self.input = input; self.adaptor = adaptor
        self.pool = PixelBufferPool(width: settings.resolution.width,
                                    height: settings.resolution.height, maxInFlight: 3)
        guard writer.startWriting() else {
            throw NSError(domain: "VideoEncoder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "startWriting failed: \(String(describing: writer.error))"])
        }
        writer.startSession(atSourceTime: .zero)
        lastEndTime = .zero
        started = true
    }

    /// Polls `isReadyForMoreMediaData` (yields while not ready), copies the frame
    /// into a pooled BGRA buffer, and appends at CMTime(value: frameIndex, timescale: fps).
    public func append(_ image: RGBA8Image, atFrame index: Int) async throws {
        guard started, let input, let adaptor, let pool else {
            throw NSError(domain: "VideoEncoder", code: 2, userInfo: [NSLocalizedDescriptionKey: "not started"])
        }
        while !input.isReadyForMoreMediaData {
            if let writer, writer.status == .failed { throw writer.error ?? ExportError.encodeFailed }
            try await Task.sleep(nanoseconds: 1_000_000)   // 1 ms
        }
        let pb = await pool.acquire()
        pool.fill(pb, from: image)
        let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(settings.fps))
        adaptor.append(pb, withPresentationTime: time)
        pool.release(pb)
        // End-of-session target = this frame's PTS + one frame duration.
        lastEndTime = CMTime(value: CMTimeValue(index + 1), timescale: CMTimeScale(settings.fps))
    }

    public func finish() async throws {
        guard started, let writer, let input else { return }
        input.markAsFinished()
        // Pin the session end so the final frame's full duration lands in the
        // container (D8). Safe to call after markAsFinished; AVFoundation accepts
        // endSession before finishWriting. Skipped iff no frames were appended
        // (lastEndTime stays .zero -> the session is already empty + ended).
        if lastEndTime != .zero {
            writer.endSession(atSourceTime: lastEndTime)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writer.finishWriting { [outputURL] in
                if writer.status == .completed { cont.resume() }
                else { try? FileManager.default.removeItem(at: outputURL); cont.resume(throwing: writer.error ?? ExportError.encodeFailed) }
            }
        }
        started = false
    }

    /// Cancel an in-progress write. `started` guard + `cancelWriting()` are both
    /// routed through `queue.sync` so the status read/write and the `started`
    /// flag flip are atomic w.r.t. any other `queue.sync` block (the writer
    /// lifecycle transitions in `start`/`finish`). In practice the
    /// `ExportCoordinator` owns one encoder and drives `append`/`cancel`/`finish`
    /// from its actor (which serializes them), so there is no real concurrency
    /// here — but the `queue.sync` keeps that invariant local to the encoder
    /// rather than trusting every caller. The file removal is idempotent
    /// (`try?`) and outside the lock: it does not depend on encoder state.
    public func cancel() {
        queue.sync {
            guard started, let writer else { return }
            if writer.status == .writing { writer.cancelWriting() }
            started = false
        }
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// Raised BPP-derived bitrate tiers (Mbps, pre-`*1_000_000`) for "no visible
    /// degradation on busy fractal-flame content." ProRes returns 0 (sentinel):
    /// it does NOT use the table — the call site omits `AVVideoAverageBitRateKey`
    /// (ProRes is a fixed data-rate codec). The `fps≥60 × 1.5` multiplier is
    /// kept (double the frames → double the bits for the same per-frame quality).
    /// MUST stay in sync with `ExportCoordinator.autoBitrateMbps` (the disk-
    /// precheck mirror).
    private static func autoBitrate(codec: ExportSettings.Codec, res: ExportSettings.Resolution, fps: Int) -> Int {
        if codec.isProRes { return 0 }
        let hevc: [ExportSettings.Resolution: Int] = [.p720: 25, .p1080: 50, .p1440: 80, .p4k: 150]
        let h264: [ExportSettings.Resolution: Int] = [.p720: 40, .p1080: 80, .p1440: 130, .p4k: 240]
        let isHEVC = codec == .hevc
        let table = isHEVC ? hevc : h264
        let fallback = isHEVC ? 50 : 80
        let big = isHEVC ? 150 : 240
        let base = table[res] ?? (res.width * res.height >= 3_840 * 2160 ? big : fallback)
        let fpsMult = fps >= 60 ? 1.5 : 1.0
        return Int(Double(base) * fpsMult) * 1_000_000
    }

    /// Maps the user-facing `Codec` to AVFoundation's `AVVideoCodecType`. ProRes
    /// variants are selected entirely via this type (no profile/level key).
    private static func avCodecType(for codec: ExportSettings.Codec) -> AVVideoCodecType {
        switch codec {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proRes422HQ: return .proRes422HQ
        }
    }

    /// True iff this host can encode `codec`. Used by `ExportCommand`'s HEVC
    /// fallback AND by capability tests. Probes by constructing a throwaway
    /// writer+input at 64x48 and appending one black frame; if
    /// `startWriting`/append/`finishWriting` leaves `writer.status == .completed`,
    /// the codec is accepted. Any `.failed` status means the codec is unavailable
    /// on this host. Cheap (one frame at 64x48; output goes to a temp file that
    /// is removed in `defer`). `VTIsHardwareDecodeSupported`-style APIs probe
    /// DECODE, not encode, and are unreliable for this — a real encode is the
    /// only ground truth `AVAssetWriter` exposes.
    public static func canEncode(_ codec: ExportSettings.Codec) -> Bool {
        // Probe at 64×48 first; some encoder revisions have min-frame-size
        // quirks (observed on certain ProRes revisions), so bump to 128×72 if
        // the small probe fails. A real encode is the only ground truth
        // AVAssetWriter exposes (VTIsHardwareDecodeSupported probes DECODE).
        if probeEncode(codec, w: 64, h: 48) { return true }
        return probeEncode(codec, w: 128, h: 72)
    }

    private static func probeEncode(_ codec: ExportSettings.Codec, w: Int, h: Int) -> Bool {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6probe-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var s = ExportSettings()
        s.codec = codec; s.container = .mov
        s.resolution = .custom(width: w, height: h); s.fps = 30
        guard let writer = try? AVAssetWriter(outputURL: tmp, fileType: .mov) else { return false }
        let codecType: AVVideoCodecType
        switch codec {
        case .h264: codecType = .h264
        case .hevc: codecType = .hevc
        case .proRes422HQ: codecType = .proRes422HQ
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        // One black frame.
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_32BGRA, nil, &pb)
        if let pb { adaptor.append(pb, withPresentationTime: CMTime(value: 0, timescale: 30)) }
        input.markAsFinished()
        // Drive finishWriting synchronously via a semaphore (probe is one-shot).
        // The `Box` is `@unchecked Sendable` to satisfy Swift 6's
        // captured-var-mutation check: the write happens-before the read via
        // `sem.wait()` (single completion-handler fire), so it's race-free.
        // Same idiom the enclosing `VideoEncoder` class uses for its own
        // `@unchecked Sendable` annotation.
        final class Box: @unchecked Sendable { var ok = false }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { box.ok = (writer.status == .completed); sem.signal() }
        sem.wait()
        return box.ok
    }
}

public enum ExportError: Error, Equatable, Sendable {
    case cancelled
    case encodeFailed
    case metalUnavailable
    case genomeUnparseable
    case diskFull
    /// ProRes variants require a `.mov` container; AVAssetWriter rejects ProRes
    /// in `.mp4`. Thrown by `VideoEncoder.start()` (and surfaced by the CLI/GUI)
    /// so the user picks a `.mov` destination instead.
    case proResRequiresMOV
    /// M6.1 pause/resume. `runResumable` checks a pause flag between chunks; a
    /// cooperative pause surfaces as this case (caught by the GUI/CLI layer, which
    /// then re-enters `runResumable` to resume from the checkpoint).
    case paused
    /// The resume source set does not match the checkpoint's recorded sources
    /// (spec §3.5: resume is locked to the SAME genome set the run started with,
    /// by index). `index` is the offending source index. Determinism (rule #2):
    /// a different genome set would render different frames.
    case checkpointSourceChanged(index: Int)
    /// The checkpoint JSON file exists but could not be decoded (corrupt /
    /// truncated, e.g. a crash mid-write). The caller offers to discard + restart.
    case checkpointUnreadable
    /// The checkpoint decoded but its `schemaVersion` is newer than (or otherwise
    /// unsupported by) this build. `version` is the schema we refused. A future
    /// Emberweft that bumps the schema would emit this against an older binary.
    case checkpointSchemaUnsupported(version: Int)
    /// Loop render-once-repeat memory guard (v0.5.0). The per-loop cache
    /// (`framesPerSegment × W × H × 4` bytes) would exceed the safe threshold
    /// (~50% of physical RAM, floored 2 GB, ceiling ~12 GB). `neededMB` is the
    /// estimated cache; `availableMB` is the threshold. Checked BEFORE any
    /// rendering/encoding starts, so no partial file is left.
    case loopRepeatMemoryExceeded(neededMB: Int, availableMB: Int)
    /// T8′ temporal smoothing (centered box window) requires every histogram fed
    /// to one `TemporalBoxWindow` to share the same accumulator-grid dimensions
    /// (`gridWidth`/`gridHeight`). The grid is a step function of each frame's
    /// center-flame `filterRadius` (via `flam3SpatialFilterWidth`); a transition
    /// between genomes whose `filter` attrs fall in different width buckets
    /// (e.g. the default 0.5 vs an explicit 1.0) produces histograms with
    /// incompatible grids — averaging them is undefined. Thrown INSTEAD of the
    /// `TemporalBoxWindow.feed` precondition trap, so the export fails with a
    /// clear message rather than crashing. Fix: disable smoothing
    /// (`temporalSmoothing: .off`) or use a library whose genomes share a filter.
    case smoothingGridMismatch(frame: Int)
}
