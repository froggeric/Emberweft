import Foundation
import AVFoundation
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
        let fileType: AVFileType = settings.container == .mov ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let codec: AVVideoCodecType = settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264
        var compression: [String: Any] = [:]
        switch settings.bitrate {
        case .auto: compression[AVVideoAverageBitRateKey] = Self.autoBitrate(codec: codec, res: settings.resolution, fps: settings.fps)
        case .mbps(let m): compression[AVVideoAverageBitRateKey] = m * 1_000_000
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
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

    public func cancel() {
        guard started, let writer else { return }
        queue.sync {
            if writer.status == .writing { writer.cancelWriting() }
        }
        try? FileManager.default.removeItem(at: outputURL)
        started = false
    }

    private static func autoBitrate(codec: AVVideoCodecType, res: ExportSettings.Resolution, fps: Int) -> Int {
        // Preliminary Mbps (H.264 ~1.5x HEVC for parity). Tunable.
        let hevc: [ExportSettings.Resolution: Int] = [.p720: 5, .p1080: 10, .p1440: 16, .p4k: 30]
        let base = hevc[res] ?? (res.width * res.height >= 3_840 * 2160 ? 30 : 10)
        let mult = codec == .hevc ? 1.0 : 1.5
        let fpsMult = fps >= 60 ? 1.5 : 1.0
        return Int(Double(base) * mult * fpsMult) * 1_000_000
    }
}

public enum ExportError: Error, Sendable {
    case cancelled
    case encodeFailed
    case metalUnavailable
    case genomeUnparseable
    case diskFull
    case overwriteNeedsForce
}
