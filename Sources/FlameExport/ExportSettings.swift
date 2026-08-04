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

    public enum Codec: String, Codable, Sendable, CaseIterable { case h264, hevc, proRes422HQ }
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

public extension ExportSettings.Codec {
    /// True for ProRes variants (the mastering codec). ProRes is a fixed
    /// data-rate codec: it does NOT use the bitrate table and its `.mov`
    /// container is mandatory (AVAssetWriter rejects ProRes in `.mp4`).
    public var isProRes: Bool { self == .proRes422HQ }

    /// True iff this codec can ONLY be muxed into a `.mov` container.
    /// ProRes 422 HQ requires `.mov` (AVAssetWriter fails ProRes in `.mp4`).
    public var requiresMOVContainer: Bool { isProRes }
}

public extension ExportSettings {
    /// Metal temporal-samples cap (dispatch-overhead bound). The single source of
    /// truth: `resolve` applies it and the CLI/GUI cap-notice logic reads it, so
    /// the two cannot drift apart.
    public static let metalTemporalCap = 64

    /// Resolve a concrete `ExportSettings` from PARSED CLI/GUI inputs, applying:
    ///  - the motion-blur genome-default fallback: `requestedTS == 1` and
    ///    `baseFlame.quality.temporalSamples > 1` ⇒ use the genome value (mirrors
    ///    `AnimateCommand.swift:147-149` and `ExportCommand.swift:374-377` exactly);
    ///  - the Metal temporal cap (64) when `backend == .metal`
    ///    (`ExportCommand.swift:378-382`) to bound dispatch overhead.
    ///
    /// `baseFlame` MUST be the first RENDERABLE flame (the CLI passes
    /// `renderable[0]`, ExportCommand.swift:375; the GUI pre-filters, so its
    /// `flames[0]` is already renderable). Using the unfiltered `flames[0]` here
    /// would diverge from the CLI when `flames[0]` is degenerate — byte-identity
    /// requires the renderable first flame.
    ///
    /// PURE + SILENT: no I/O, no stderr. The caller detects the Metal cap by
    /// comparing `requestedTS` against the returned `temporalSamples` and prints
    /// its own notice (CLI: `EmberweftCLI.err(…)`; GUI: a sheet notice). This is
    /// the single source of truth so the CLI and GUI build byte-identical jobs
    /// (spec §4.2b / plan task M6-G.3 / defect D-G2).
    ///
    /// String→enum parsing STAYS in the callers: the CLI parses strings (incl.
    /// the `quality`-number → `fallbackFlame.quality.samplesPerPixel` defensive
    /// fallback and the `resolution` unknown → `.p1080` default), and the GUI
    /// builds enums directly from its pickers. Neither can live here because
    /// `FlameExport` does not depend on `EmberweftCLI` (and the GUI has no
    /// strings to parse).
    static func resolve(
        quality: ExportQuality,
        temporalSamples requestedTS: Int,
        codec: ExportSettings.Codec,
        container: ExportSettings.Container,
        fps: Int,
        bitrate: ExportSettings.Bitrate,
        resolution: ExportSettings.Resolution,
        segmentFrameBudget: Int,
        baseFlame: Flame,
        backend: ExportCoordinator.Backend
    ) -> ExportSettings {
        var settings = ExportSettings()
        settings.codec = codec
        settings.container = container
        settings.fps = fps
        settings.quality = quality
        // Motion-blur default: mirror AnimateCommand exactly. When the requested
        // value is the "use genome default" sentinel (1) and the genome carries a
        // temporalSamples > 1, use the genome's value; then cap on Metal to bound
        // dispatch overhead (ExportCommand.swift:374-382).
        var ts = max(1, requestedTS)
        if ts == 1, baseFlame.quality.temporalSamples > 1 {
            ts = baseFlame.quality.temporalSamples
        }
        if backend == .metal, ts > Self.metalTemporalCap {
            ts = Self.metalTemporalCap
        }
        settings.temporalSamples = ts
        settings.bitrate = bitrate
        settings.resolution = resolution
        settings.segmentFrameBudget = max(0, segmentFrameBudget)
        return settings
    }
}
