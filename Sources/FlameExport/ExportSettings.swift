import Foundation
import FlameKit

/// User-facing export settings (Codable + Sendable). The encode-quality source is
/// `ExportQuality` (`.genome` default — byte-matches `animate`; `.spp(N)`).
public struct ExportSettings: Codable, Sendable, Equatable {
    public var codec: Codec = .h264
    public var resolution: Resolution = .p1080
    public var fps: Int = 30                 // 24/25/30/48/50/60 (CMTime timescale)
    public var quality: ExportQuality = .genome
    public var temporalSamples: Int = 1      // motion blur (1 = sharp)
    public var container: Container = .mp4
    public var bitrate: Bitrate = .auto
    public var segmentFrameBudget: Int = 0   // >0 => long-form chunk size in frames
    public var metadata: [MetadataItem] = []
    public init() {}

    public enum Codec: String, Codable, Sendable, CaseIterable { case h264, hevc }
    public enum Container: String, Codable, Sendable, CaseIterable { case mp4, mov }
    public enum Bitrate: Codable, Sendable, Equatable { case auto; case mbps(Int) }
    public struct MetadataItem: Codable, Sendable, Equatable {
        public var key: String; public var value: String
        public init(key: String, value: String) { self.key = key; self.value = value }
    }

    public enum Resolution: Codable, Sendable, Equatable, Hashable {
        case p720, p1080, p1440, p4k, custom(width: Int, height: Int)
        public var width: Int {
            switch self { case .p720: 1280; case .p1080: 1920; case .p1440: 2560;
                         case .p4k: 3840; case .custom(let w, _): w } }
        public var height: Int {
            switch self { case .p720: 720; case .p1080: 1080; case .p1440: 1440;
                         case .p4k: 2160; case .custom(_, let h): h } }
    }
}

/// M6 quality source. Named tiers are deferred to the GUI export-sheet slice.
/// Both modes resolve `oversample = 1` (byte-identity with `animate`).
public enum ExportQuality: Codable, Sendable, Equatable {
    case genome                              // flames[0].quality.samplesPerPixel, oversample 1
    case spp(Int)

    public func resolvedSamplesPerPixel(for baseFlame: Flame) -> (spp: Int, oversample: Int) {
        switch self {
        case .genome: (baseFlame.quality.samplesPerPixel, 1)
        case .spp(let n): (n, 1)
        }
    }
}
